/* coop_steam.c - Manor Lords co-op: the Steam link (replaces coop-link.ps1 for Steam players).
 *
 * Loaded by the Lua mod with package.loadlib(<path>, "coop_steam_tick") and called once per game frame on the game
 * thread. It never touches the Lua state and always returns 0. Everything else goes through files in the link folder:
 *   steam_cmd.txt     commands, appended by the mod (HOST, INVITE, JOIN <lobbyid>, LEAVE, KICK <steamid>, QUIT)
 *   steam_status.txt  state, rewritten atomically by this DLL (format: README.md)
 *   host.txt, friend1.txt .. friend7.txt   the mod's link files, mirrored between PCs exactly like coop-link.ps1 does
 *   coop_steam.log    a plain log (capped at about 1 MB)
 * It uses the game's already initialised steam_api64.dll (never loads, initialises, pumps or shuts it down):
 * lobbies for joining, the overlay for invites, ISteamNetworkingMessages for the data.
 * Wire meaning is coop-link.ps1 protocol 1 carried inside Steam messages (one message = one protocol line), except
 * that save chunks carry raw bytes instead of base64 and the friend's slot is given by the host.
 *
 * Build: build.cmd (MSVC x64, /MT, /W4). Test: build.cmd test (the same source with COOP_STEAM_MOCK and a fake Steam).
 */
#define WIN32_LEAN_AND_MEAN
#ifndef _CRT_SECURE_NO_WARNINGS
#define _CRT_SECURE_NO_WARNINGS
#endif
#include <windows.h>
#include <bcrypt.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <ctype.h>
#include "coop_steam_api.h"

#define COOP_STEAM_VERSION "0.5"     /* 0.2 (lane 33): coat pictures travel with the save; link files turn over
                                      * 0.3 (lane 62): a host that lost its own lobby says so and the next INVITE opens a
                                      *                new one; no persona names in the log
                                      * 0.4 (lane 62, part two): a short drop does not end the session (GRACE_MS)
                                      * 0.5 (lane 65): no file opened per tick (kept handles, attribute looks); a status
                                      *                that differs only in pings written at most every 5 s */
#define PROTO_VERSION      1
#define MAX_LINE           65536u          /* longest mod line (bytes, without newline) */
#define PING_EVERY_MS      2000
/* A copy that is loading a save cannot answer: its game thread is busy for the whole load, which took more than a
 * minute on a friend's PC in the first session between two PCs (2026-11-11; the 10 s used until then dropped that
 * friend in the middle of the join). A player who really leaves is seen at once through the lobby's member list. */
#ifndef DEAD_AFTER_MS
#define DEAD_AFTER_MS      300000
#endif
#define STR2_(x) #x
#define STR_(x) STR2_(x)
#define DEAD_TEXT          "no answer for " STR_(DEAD_AFTER_MS) " ms"
#define HELLO_EVERY_MS     2000
#define HI_EVERY_MS        2000
#define MEMBERS_EVERY_MS   500
/* (lane 62) The host's own place in its lobby. Steam's own word (a lobby chat update that names this host as left,
 * disconnected, kicked or banned) counts at once. Its polled twin (lobby owner is not this host, or this host is not a
 * member; asked every MEMBERS_EVERY_MS) was never seen on real Steam, and acting on it ends the lobby for good: it must
 * fail OWN_MISSES times in a row (3 s) first. Right after Steam was offline and came back, one failed check is enough. */
#ifndef OWN_MISSES
#define OWN_MISSES         6
#endif
/* (lane 62, part two) A SHORT DROP DOES NOT END THE SESSION. In the live case the host's lobby membership dropped for a
 * VPN route change while its game and Steam came back within seconds, and everybody was sent home at once. Now a loss
 * sign starts a window of GRACE_MS (30 s, the number of the mod's silence rule) on both sides:
 *   host    keeps its peers and their slots and asks Steam to let it back into the SAME lobby (JoinLobby every
 *           REJOIN_EVERY_MS; the friends keep the lobby alive). It counts as back only on Steam's answer to such a call
 *           (LobbyEnter, success): never on its own member list, which may be stale after a drop. Back as a member while a
 *           friend's copy holds the ownership (Steam moved it when the host left): that copy hands it back
 *           (SetLobbyOwner); until then the host works as a member. The lobby gone, or the window over: host_lost_lobby
 *           (part one: peers dropped, the notice, the next INVITE makes a new lobby).
 *   friend  does not leave when Steam says the host is out of the lobby: it stays in the lobby, keeps the host's Steam
 *           id trusted for messages and sessions, and leaves as before only when the window ends (or at once on BYE).
 * MOCK-TESTED ONLY: nothing of this has run on real Steam. */
#ifndef GRACE_MS
#define GRACE_MS           30000
#endif
#define REJOIN_EVERY_MS    2000
#define LOBBY_HOST_KEY     "mlcoop_host"   /* the host's Steam id: a joiner must not take a friend that holds the ownership for the host */
#define INVITE_WAIT_MS     120000          /* an INVITE waits this long for Steam to be online and a lobby of ours to exist */
#define CREATE_RETRY_MS    3000            /* between two tries to create a lobby for a waiting INVITE */
#define NOMOD_AFTER_MS     30000
#define QUEUE_CAP          (16u << 20)     /* bytes waiting for one peer */
#define MAX_SAVE_BYTES     (64u << 20)
#define CHUNK_RAW          65536u          /* file bytes per C message */
#define SAVE_WAIT_MS       15000
#define SAVE_STABLE_MS     300
#define SAVE_POLL_MS       50
#define FILE_BUDGET        (1u << 20)      /* file bytes handed to Steam per peer per tick */
#define CALL_TIMEOUT_MS    20000
#define STEAM_WAIT_MS      60000           /* how long to wait for the game to initialise Steam */
#define LOG_CAP            (1u << 20)
#define STATUS_MIN_MS      100
#define CLOSE_DELAY_MS     1500
#define EVQ                256
#define EV_DATA            160
#ifndef MAX_FRIENDS
#define MAX_FRIENDS        7          /* 8 players: the host and 7 friends (the mock test builds with 3) */
#endif
#define LOBBY_KEY          "mlcoop"
#define LOBBY_BUILD_KEY    "mlcoop_build"
#define LOBBY_SLOTS_KEY    "mlcoop_slots"

#ifdef COOP_STEAM_MOCK
#define CS_STATIC
#else
#define CS_STATIC static
#endif

/* (lane 65) FILE OPENS. Live, 2026-11-17: on a friend's PC whose real-time scan checks every file opened after a write,
 * each open of a link file cost milliseconds, and this DLL opened several a frame (the command file, the friend's own
 * file, the mirror file at every write, the log at every line). Now a handle is kept while a file is in use and let go
 * when it has been quiet for HANDLE_IDLE_MS (or on a turnover, a restart, a failure); a file not held is first looked
 * at by its attributes (no open), and opened only when its size changed. The mock test counts every open
 * (test/coop_steam_test.c, "file opens"). */
#define HANDLE_IDLE_MS     1000
#define STATUS_PING_MS     5000       /* a status that differs only in pings is written at most this often */
static void close_h(HANDLE *h) { if (*h && *h != INVALID_HANDLE_VALUE) CloseHandle(*h); *h = NULL; }

/* layout checks for the structs we read or pass by size */
typedef char sa_msg_data[offsetof(SteamNetworkingMessage_t, m_pData) == 0 ? 1 : -1];
typedef char sa_msg_size[offsetof(SteamNetworkingMessage_t, m_cbSize) == 8 ? 1 : -1];
typedef char sa_msg_peer[offsetof(SteamNetworkingMessage_t, m_identityPeer) == 16 ? 1 : -1];
typedef char sa_msg_chan[offsetof(SteamNetworkingMessage_t, m_nChannel) == 192 ? 1 : -1];
typedef char sa_lobbycreated[sizeof(LobbyCreated_t) == 16 ? 1 : -1];
typedef char sa_lobbyenter[sizeof(LobbyEnter_t) == 24 ? 1 : -1];
typedef char sa_lobbychat[sizeof(LobbyChatUpdate_t) == 32 ? 1 : -1];
typedef char sa_joinreq[sizeof(GameLobbyJoinRequested_t) == 16 ? 1 : -1];
typedef char sa_overlay[sizeof(GameOverlayActivated_t) == 8 ? 1 : -1];
typedef char sa_cbbase[offsetof(CoopCallback, m_nCallbackFlags) == 8 && offsetof(CoopCallback, m_iCallback) == 12 ? 1 : -1];

/* ================================================================ Steam function table */
typedef struct SteamFns {
    PFN_GetHSteamUser GetHSteamUser;
    PFN_RegisterCallback RegisterCallback;
    PFN_SteamUser SteamUser;
    PFN_SteamFriends SteamFriends;
    PFN_SteamMatchmaking SteamMatchmaking;
    PFN_SteamUtils SteamUtils;
    PFN_SteamApps SteamApps;
    PFN_SteamNetMsgs SteamNetMsgs;
    PFN_SteamNetUtils SteamNetUtils;
    PFN_User_GetSteamID User_GetSteamID;
    PFN_User_BLoggedOn User_BLoggedOn;
    PFN_Friends_GetPersonaName Friends_GetPersonaName;
    PFN_Friends_GetFriendPersonaName Friends_GetFriendPersonaName;
    PFN_Friends_RequestUserInformation Friends_RequestUserInformation;
    PFN_Friends_ActivateInviteDialog Friends_ActivateInviteDialog;
    PFN_Utils_GetAppID Utils_GetAppID;
    PFN_Utils_IsOverlayEnabled Utils_IsOverlayEnabled;
    PFN_Utils_IsAPICallCompleted Utils_IsAPICallCompleted;
    PFN_Utils_GetAPICallResult Utils_GetAPICallResult;
    PFN_Utils_GetAPICallFailureReason Utils_GetAPICallFailureReason;
    PFN_Apps_GetAppBuildId Apps_GetAppBuildId;
    PFN_MM_CreateLobby MM_CreateLobby;
    PFN_MM_JoinLobby MM_JoinLobby;
    PFN_MM_LeaveLobby MM_LeaveLobby;
    PFN_MM_SetLobbyData MM_SetLobbyData;
    PFN_MM_GetLobbyData MM_GetLobbyData;
    PFN_MM_GetNumLobbyMembers MM_GetNumLobbyMembers;
    PFN_MM_GetLobbyMemberByIndex MM_GetLobbyMemberByIndex;
    PFN_MM_GetLobbyOwner MM_GetLobbyOwner;
    PFN_MM_SetLobbyOwner MM_SetLobbyOwner;
    PFN_NM_SendMessageToUser NM_SendMessageToUser;
    PFN_NM_ReceiveMessagesOnChannel NM_ReceiveMessagesOnChannel;
    PFN_NM_AcceptSessionWithUser NM_AcceptSessionWithUser;
    PFN_NM_CloseSessionWithUser NM_CloseSessionWithUser;
    PFN_NU_InitRelayNetworkAccess NU_InitRelayNetworkAccess;
    PFN_NU_GetRelayNetworkStatus NU_GetRelayNetworkStatus;
    PFN_NU_SetGlobalConfigValueInt32 NU_SetGlobalConfigValueInt32;
    PFN_Identity_SetSteamID64 Identity_SetSteamID64;
    PFN_Identity_GetSteamID64 Identity_GetSteamID64;
    PFN_Message_Release Message_Release;
} SteamFns;

#define EXP(name, field, req) { name, offsetof(SteamFns, field), req }
static const struct { const char *name; size_t off; int required; } k_exports[] = {
    EXP("SteamAPI_GetHSteamUser", GetHSteamUser, 1),
    EXP("SteamAPI_RegisterCallback", RegisterCallback, 1),
    EXP("SteamAPI_SteamUser_v021", SteamUser, 1),
    EXP("SteamAPI_SteamFriends_v017", SteamFriends, 1),
    EXP("SteamAPI_SteamMatchmaking_v009", SteamMatchmaking, 1),
    EXP("SteamAPI_SteamUtils_v010", SteamUtils, 1),
    EXP("SteamAPI_SteamApps_v008", SteamApps, 0),
    EXP("SteamAPI_SteamNetworkingMessages_SteamAPI_v002", SteamNetMsgs, 1),
    EXP("SteamAPI_SteamNetworkingUtils_SteamAPI_v004", SteamNetUtils, 1),
    EXP("SteamAPI_ISteamUser_GetSteamID", User_GetSteamID, 1),
    EXP("SteamAPI_ISteamUser_BLoggedOn", User_BLoggedOn, 1),
    EXP("SteamAPI_ISteamFriends_GetPersonaName", Friends_GetPersonaName, 1),
    EXP("SteamAPI_ISteamFriends_GetFriendPersonaName", Friends_GetFriendPersonaName, 1),
    EXP("SteamAPI_ISteamFriends_RequestUserInformation", Friends_RequestUserInformation, 0),
    EXP("SteamAPI_ISteamFriends_ActivateGameOverlayInviteDialog", Friends_ActivateInviteDialog, 1),
    EXP("SteamAPI_ISteamUtils_GetAppID", Utils_GetAppID, 1),
    EXP("SteamAPI_ISteamUtils_IsOverlayEnabled", Utils_IsOverlayEnabled, 1),
    EXP("SteamAPI_ISteamUtils_IsAPICallCompleted", Utils_IsAPICallCompleted, 1),
    EXP("SteamAPI_ISteamUtils_GetAPICallResult", Utils_GetAPICallResult, 1),
    EXP("SteamAPI_ISteamUtils_GetAPICallFailureReason", Utils_GetAPICallFailureReason, 0),
    EXP("SteamAPI_ISteamApps_GetAppBuildId", Apps_GetAppBuildId, 0),
    EXP("SteamAPI_ISteamMatchmaking_CreateLobby", MM_CreateLobby, 1),
    EXP("SteamAPI_ISteamMatchmaking_JoinLobby", MM_JoinLobby, 1),
    EXP("SteamAPI_ISteamMatchmaking_LeaveLobby", MM_LeaveLobby, 1),
    EXP("SteamAPI_ISteamMatchmaking_SetLobbyData", MM_SetLobbyData, 1),
    EXP("SteamAPI_ISteamMatchmaking_GetLobbyData", MM_GetLobbyData, 1),
    EXP("SteamAPI_ISteamMatchmaking_GetNumLobbyMembers", MM_GetNumLobbyMembers, 1),
    EXP("SteamAPI_ISteamMatchmaking_GetLobbyMemberByIndex", MM_GetLobbyMemberByIndex, 1),
    EXP("SteamAPI_ISteamMatchmaking_GetLobbyOwner", MM_GetLobbyOwner, 1),
    EXP("SteamAPI_ISteamMatchmaking_SetLobbyOwner", MM_SetLobbyOwner, 0),
    EXP("SteamAPI_ISteamNetworkingMessages_SendMessageToUser", NM_SendMessageToUser, 1),
    EXP("SteamAPI_ISteamNetworkingMessages_ReceiveMessagesOnChannel", NM_ReceiveMessagesOnChannel, 1),
    EXP("SteamAPI_ISteamNetworkingMessages_AcceptSessionWithUser", NM_AcceptSessionWithUser, 1),
    EXP("SteamAPI_ISteamNetworkingMessages_CloseSessionWithUser", NM_CloseSessionWithUser, 1),
    EXP("SteamAPI_ISteamNetworkingUtils_InitRelayNetworkAccess", NU_InitRelayNetworkAccess, 1),
    EXP("SteamAPI_ISteamNetworkingUtils_GetRelayNetworkStatus", NU_GetRelayNetworkStatus, 1),
    EXP("SteamAPI_ISteamNetworkingUtils_SetGlobalConfigValueInt32", NU_SetGlobalConfigValueInt32, 0),
    EXP("SteamAPI_SteamNetworkingIdentity_SetSteamID64", Identity_SetSteamID64, 1),
    EXP("SteamAPI_SteamNetworkingIdentity_GetSteamID64", Identity_GetSteamID64, 1),
    EXP("SteamAPI_SteamNetworkingMessage_t_Release", Message_Release, 1),
};
#undef EXP

static const struct { int id; int size; const char *name; int certain; } k_callbacks[] = {
    { CB_GameOverlayActivated, (int)sizeof(GameOverlayActivated_t), "GameOverlayActivated", 0 },
    { CB_GameLobbyJoinRequested, (int)sizeof(GameLobbyJoinRequested_t), "GameLobbyJoinRequested", 0 },
    { CB_LobbyEnter, (int)sizeof(LobbyEnter_t), "LobbyEnter", 0 },
    { CB_LobbyChatUpdate, (int)sizeof(LobbyChatUpdate_t), "LobbyChatUpdate", 0 },
    { CB_LobbyCreated, (int)sizeof(LobbyCreated_t), "LobbyCreated", 0 },
    { CB_NetMsgSessionRequest, SIZE_NetMsgSessionRequest, "NetworkingMessagesSessionRequest", 0 },
    { CB_NetMsgSessionFailed, SIZE_NetMsgSessionFailed, "NetworkingMessagesSessionFailed", 0 },
};
#define NCB ((int)(sizeof(k_callbacks) / sizeof(k_callbacks[0])))

/* ================================================================ small types */
typedef struct Buf { uint8_t *p; size_t n, cap; } Buf;

typedef struct SaveFile { char name[64]; uint8_t *data; uint32_t len; char sha[65]; } SaveFile;
#define SAVE_FILES_MAX     24         /* main, descr, extradata (up to 18 here), 4 coat pictures */
enum { JOB_WAIT, JOB_READY, JOB_FAILED, JOB_SKIP };
typedef struct SaveJob {
    int refs, state;
    char save[32];
    char reason[200], why[260];
    uint64_t startAt, deadline, nextPoll, sigSince;
    int started;
    char sig[4096];
    SaveFile files[SAVE_FILES_MAX];
    int nfiles;
    uint64_t total;
} SaveJob;

typedef struct Item {            /* one queued message for a peer, or a place-holder for a save */
    struct Item *next, *prev;
    uint8_t *msg; uint32_t len;
    int isS, lines;
    SaveJob *job;
} Item;
typedef struct Queue { Item *head, *tail, *snode; uint64_t bytes; int count; } Queue;

typedef struct Xfer { SaveJob *job; int idx, phase; uint32_t off; uint64_t t0; } Xfer;

typedef struct Recv {
    int active, skip, bad;
    char name[64], sha[65];
    uint64_t size, got, t0;
    HANDLE fh;
    wchar_t tmp[MAX_PATH];
} Recv;

enum { PS_NONE, PS_CONNECTING, PS_CONNECTED, PS_DISCONNECTED };
typedef struct Peer {
    int used, slot, inLobby, ready, state;
    uint64_t sid;
    uint32_t nonce, epoch;
    uint64_t born, lastRecv, lastPing, lastHi;
    int rtt, needPong;
    char pongTs[24];
    Queue ctl, q;
    int overflow, nomodNoted, fileNoted, infoAsked;
    uint32_t sskipped, in, out;
    Xfer x;
} Peer;

/* A link file is a chain of files (lane 33): host.txt, host.2.txt, host.3.txt, ... (README "Link file turnover").
 * follow = 1: a "~NEXT <k>" line moves the tail to file k. */
typedef struct Tail { wchar_t leaf[32]; wchar_t base[16]; int seg, follow; uint64_t off; Buf part; int skip, oversize, active;
                      HANDLE h; uint64_t growAt; } Tail;   /* (lane 65) h: the kept read handle of leaf, or NULL */
#define MIRROR_CUTS 16
#define LINK_KEEP          2          /* files kept before the current one (the mod's coop.lua keeps the same number) */
#ifndef LINK_KEEP_MS
#define LINK_KEEP_MS       30000      /* an old file is deleted no sooner than this after the last turnover ... */
#endif
#define LINK_KEEP_TICKS    300        /* ... and after this many ticks of this DLL */
typedef struct Mirror {
    wchar_t leaf[32]; wchar_t base[16]; int seg, low;        /* low: the oldest file not yet deleted (1 = the first file is whole) */
    uint64_t switchAt; uint32_t switchTick;                   /* when the last turnover happened */
    Buf pend; uint64_t warnAt;
    size_t cutAt[MIRROR_CUTS]; int cutTo[MIRROR_CUTS]; int ncut;   /* pend up to cutAt goes to the current file, then file cutTo */
    int stale[8], nstale;                                     /* files of an earlier chain still to delete (were in use) */
    int dropped;                                              /* lines were dropped (logged at the next flush) */
    HANDLE h; uint64_t usedAt;                                /* (lane 65) the kept write handle of leaf, or NULL */
} Mirror;

typedef struct FifoE {
    struct FifoE *next;
    uint8_t *msg; uint32_t len;
    int isS, lines;
    unsigned targets;            /* bit per slot 1..MAX_FRIENDS */
    uint32_t epoch[MAX_FRIENDS + 1];
    SaveJob *job;
    unsigned jobTargets;         /* the save goes only to these slots (bit per slot); 0 = to every friend */
} FifoE;

typedef struct Event { int id; DWORD thread; uint8_t data[EV_DATA]; } Event;
typedef struct RecvMark { char name[64]; int ok; } RecvMark;

enum { ST_OFF, ST_IDLE, ST_CREATING, ST_HOSTING, ST_JOINING, ST_JOINED };
enum { CALL_NONE, CALL_CREATE, CALL_JOIN, CALL_REJOIN };       /* CALL_REJOIN: a host asks to be let back into its own lobby */

typedef struct Coop {
    int started, off, busy, steamOk, cbDone;
    char offReason[256];
    const char *phase;
    uint64_t (*clock)(void);
    uint64_t now;
    uint32_t ticks;
    /* paths and settings */
    wchar_t dllDir[MAX_PATH], linkDir[MAX_PATH], saveDir[MAX_PATH];
    int pathsSet, haveSaveDir, sendRateKB, sendBufKB;
    const wchar_t *cmdline;
    /* steam */
    SteamFns f;
    ISteamUser *user; ISteamFriends *friends; ISteamMatchmaking *mm; ISteamUtils *utils;
    ISteamApps *apps; ISteamNetworkingMessages *nm; ISteamNetworkingUtils *nu;
    uint64_t steamGiveUpAt, steamRetryAt, infoAt;
    uint64_t me;
    char myName[96];
    uint32_t appId;
    int overlay, loggedOn, buildId, relay;
    CoopCallback cbs[8];
    int seenCb[8];
    CRITICAL_SECTION cs;
    Event ev[EVQ];
    int evHead, evCount;
    volatile LONG evDropped;
    LONG evDroppedLogged;
    /* session */
    int st;
    uint64_t lobby;
    SteamAPICall_t call;
    int callKind;
    uint64_t callAt, callDoneAt;
    Peer peers[MAX_FRIENDS + 1]; /* host: [1..MAX_FRIENDS] friends; friend: [0] the host */
    int mySlot;
    uint32_t myNonce;
    uint64_t lastHello, membersAt, ownerAt;
    int membersDirty;
    Tail hostTail, myTail, cmdTail;
    Mirror mirrors[MAX_FRIENDS + 1]; /* [0] host.txt, [1..MAX_FRIENDS] friendN.txt */
    FifoE *fifoHead, *fifoTail;
    uint64_t bans[16];
    int nbans;
    RecvMark marks[32];
    int nmarks;
    char note[300];
    char slotsSent[256];
    char roster[256];
    uint64_t closeAt, closeSids[MAX_FRIENDS + 1];
    int nclose;
    Buf status, lastStatus, scratch, msgBuf;
    uint64_t statusAt;
    int shapeOnly;
    Buf shape, lastShape;        /* (lane 65) the status without its pings: a change of pings alone waits STATUS_PING_MS */
    uint64_t logBytes;
    HANDLE logH; uint64_t logAt; /* (lane 65) the kept log handle, let go when quiet */
    int logChecked;
    uint32_t badSender;
    int quitting, saveOffNoted;
    /* (lane 62) the host's own place in its lobby */
    int lostN, lostFriends;      /* times this host lost its lobby in this run; friends connected at the last time */
    int ownMiss, backOnline;     /* polled checks failed in a row; Steam was offline and is back: check at once */
    uint64_t ownAt;
    int inviteWanted, inviteOffNoted;   /* INVITE: Steam's invite window opens as soon as a lobby of ours exists */
    uint64_t inviteUntil, createRetryAt;
    /* (lane 62, part two) the window after a loss sign */
    uint64_t lostAt;             /* host: its place in its lobby is lost since then (0: not); friend: the host is out of the lobby since then */
    uint64_t rejoinAt;           /* host: when the next JoinLobby is sent */
    int rejoinTries;
    int memberOnly;              /* host: back by a confirmed JoinLobby, but a friend's copy holds the ownership (it hands it back) */
    int backN;                   /* times the link came back inside the window, in this run (status "back <n>") */
    uint64_t handAt;             /* friend: when it last tried to hand the ownership back */
    int handTries;
    uint64_t sendWarnAt;
    Recv rcv;                    /* friend: the one incoming save file */
} Coop;

/* ================================================================ forward declarations */
static void logf_(Coop *c, const char *fmt, ...);
static void session_reset(Coop *c, int toState);
static int send_raw(Coop *c, uint64_t sid, const void *data, uint32_t len);

/* ================================================================ buffers and small helpers */
static int buf_reserve(Buf *b, size_t need)
{
    if (need <= b->cap) return 1;
    size_t cap = b->cap ? b->cap : 256;
    while (cap < need) cap *= 2;
    uint8_t *p = (uint8_t *)realloc(b->p, cap);
    if (!p) return 0;
    b->p = p; b->cap = cap;
    return 1;
}
static int buf_add(Buf *b, const void *d, size_t n)
{
    if (!buf_reserve(b, b->n + n + 1)) return 0;
    if (n) memcpy(b->p + b->n, d, n);
    b->n += n;
    b->p[b->n] = 0;
    return 1;
}
static int buf_printf(Buf *b, const char *fmt, ...)
{
    char tmp[1024];
    va_list ap;
    va_start(ap, fmt);
    int n = _vsnprintf(tmp, sizeof(tmp) - 1, fmt, ap);
    va_end(ap);
    if (n < 0) n = (int)sizeof(tmp) - 1;
    tmp[n] = 0;
    return buf_add(b, tmp, (size_t)n);
}
static void buf_free(Buf *b) { free(b->p); b->p = NULL; b->n = b->cap = 0; }

static uint64_t parse_u64(const char *s, const char **end)
{
    uint64_t v = 0; int n = 0;
    while (*s >= '0' && *s <= '9' && n < 20) { v = v * 10 + (uint64_t)(*s - '0'); s++; n++; }
    if (end) *end = s;
    return n ? v : 0;
}

static void copy_str(char *dst, size_t cap, const char *src)
{
    if (!cap) return;
    size_t n = src ? strlen(src) : 0;
    if (n >= cap) n = cap - 1;
    if (n) memcpy(dst, src, n);
    dst[n] = 0;
}

/* text from Steam or the network made safe for a one-line file: control characters become '?' */
static void safe_text(char *dst, size_t cap, const char *src, size_t maxBytes)
{
    size_t n = 0;
    if (src) {
        while (src[n] && n < maxBytes && n + 1 < cap) n++;
        /* do not cut a UTF-8 sequence in half */
        if (src[n] && n > 0) { while (n > 0 && ((unsigned char)src[n] & 0xC0) == 0x80) n--; }
    }
    for (size_t i = 0; i < n; i++) {
        unsigned char ch = (unsigned char)src[i];
        dst[i] = (ch < 0x20 || ch == 0x7F) ? '?' : (char)ch;
    }
    dst[n] = 0;
    if (n == 0 && cap > 1) { dst[0] = '?'; dst[1] = 0; }
}

static void to_wide(const char *s, wchar_t *out, int cap)
{
    if (!MultiByteToWideChar(CP_UTF8, 0, s, -1, out, cap)) out[0] = 0;
}
static void to_utf8(const wchar_t *s, char *out, int cap)
{
    if (!WideCharToMultiByte(CP_UTF8, 0, s, -1, out, cap, NULL, NULL)) out[0] = 0;
}

static int is_digit_str(const char *s, int maxLen)
{
    int n = 0;
    while (s[n]) { if (s[n] < '0' || s[n] > '9') return 0; n++; }
    return n > 0 && n <= maxLen;
}
static int is_hex64(const char *s)
{
    int n = 0;
    for (; s[n]; n++) {
        char ch = s[n];
        if (!((ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f') || (ch >= 'A' && ch <= 'F'))) return 0;
    }
    return n == 64;
}

/* ^coop_join_[1-3](_descr|_extradata[0-9]{1,2})?\.sav$ and ^coop_join_[1-3]_coat_[0-3]\.png$ : the only save file
 * names ever sent or written. The four coat pictures are the lords' coats of arms the game saves beside the save
 * (lane 33, 2026-11-13: before this they did not travel, so a friend on another PC showed an old or missing coat). */
static int save_name_ok(const char *s)
{
    if (strncmp(s, "coop_join_", 10) != 0) return 0;
    if (s[10] < '1' || s[10] > '3') return 0;
    const char *p = s + 11;
    if (strncmp(p, "_coat_", 6) == 0) return p[6] >= '0' && p[6] <= '3' && strcmp(p + 7, ".png") == 0;
    if (strncmp(p, "_descr", 6) == 0) p += 6;
    else if (strncmp(p, "_extradata", 10) == 0) {
        p += 10;
        int d = 0;
        while (*p >= '0' && *p <= '9' && d < 3) { p++; d++; }
        if (d < 1 || d > 2) return 0;
    }
    return strcmp(p, ".sav") == 0;
}
/* ^coop_join_[1-3]$ : the save names a J LOAD line may ask for */
static int load_name_ok(const char *s) { return strncmp(s, "coop_join_", 10) == 0 && s[10] >= '1' && s[10] <= '3' && s[11] == 0; }

/* ================================================================ paths (only these files are ever touched) */
/* "host" or "friend1".."friend<MAX_FRIENDS>": the names of the mod's link files (n characters of b) */
static int link_base_ok(const wchar_t *b, size_t n)
{
    if (n == 4 && wcsncmp(b, L"host", 4) == 0) return 1;
    return n == 7 && wcsncmp(b, L"friend", 6) == 0 && b[6] >= L'1' && b[6] <= L'0' + MAX_FRIENDS;
}
/* the number k of "<base>.<k>.txt" (2..999999, no leading zero), or 0 */
static int seg_number(const wchar_t *leaf, size_t *baseLen)
{
    const wchar_t *dot = wcschr(leaf, L'.');
    if (!dot || !link_base_ok(leaf, (size_t)(dot - leaf))) return 0;
    const wchar_t *q = dot + 1;
    int k = 0, d = 0;
    if (*q == L'0') return 0;
    while (*q >= L'0' && *q <= L'9' && d < 7) { k = k * 10 + (*q - L'0'); q++; d++; }
    if (d < 1 || d > 6 || k < 2 || wcscmp(q, L".txt") != 0) return 0;
    if (baseLen) *baseLen = (size_t)(dot - leaf);
    return k;
}
static int link_leaf_ok(const wchar_t *leaf)
{
    if (wcsncmp(leaf, L"friend", 6) == 0 && leaf[6] >= L'1' && leaf[6] <= L'0' + MAX_FRIENDS && wcscmp(leaf + 7, L".txt") == 0) return 1;
    if (seg_number(leaf, NULL)) return 1;           /* host.<k>.txt, friend<n>.<k>.txt: the later files of a chain */
    static const wchar_t *ok[] = { L"host.txt", L"steam_cmd.txt",
                                   L"steam_status.txt", L"steam_status.txt.tmp", L"coop_steam.log", L"coop_steam.log.old" };
    for (size_t i = 0; i < sizeof(ok) / sizeof(ok[0]); i++) if (wcscmp(ok[i], leaf) == 0) return 1;
    return 0;
}
static int link_path(Coop *c, const wchar_t *leaf, wchar_t *out)
{
    if (!link_leaf_ok(leaf)) return 0;
    return _snwprintf(out, MAX_PATH, L"%s\\%s", c->linkDir, leaf) > 0;
}
static int save_path(Coop *c, const char *name, const wchar_t *suffix, wchar_t *out)
{
    if (!c->haveSaveDir || !save_name_ok(name)) return 0;
    wchar_t wn[80];
    to_wide(name, wn, 80);
    return _snwprintf(out, MAX_PATH, L"%s\\%s%s", c->saveDir, wn, suffix ? suffix : L"") > 0;
}

/* ================================================================ log */
static void log_raw(Coop *c, const char *text)
{
    wchar_t p[MAX_PATH];
    if (!c->linkDir[0] || !link_path(c, L"coop_steam.log", p)) return;
    /* (lane 65) the handle is kept while lines come; let go after HANDLE_IDLE_MS without one (coop_tick) and at the move
     * to coop_steam.log.old */
    if (!c->logH) {
        c->logH = CreateFileW(p, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
        if (c->logH == INVALID_HANDLE_VALUE) { c->logH = NULL; return; }
    }
    HANDLE h = c->logH;
    c->logAt = c->now;
    if (!c->logChecked) {
        LARGE_INTEGER sz;
        if (GetFileSizeEx(h, &sz)) c->logBytes = (uint64_t)sz.QuadPart;
        c->logChecked = 1;
    }
    SYSTEMTIME t;
    GetLocalTime(&t);
    char line[1400];
    int n = _snprintf(line, sizeof(line) - 2, "%04u-%02u-%02u %02u:%02u:%02u.%03u %s", t.wYear, t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond, t.wMilliseconds, text);
    if (n < 0) n = (int)sizeof(line) - 2;
    line[n++] = '\n';
    DWORD w = 0;
    if (!WriteFile(h, line, (DWORD)n, &w, NULL)) close_h(&c->logH);
    c->logBytes += (uint64_t)n;
    if (c->logBytes > LOG_CAP) {
        wchar_t old[MAX_PATH];
        close_h(&c->logH);
        if (link_path(c, L"coop_steam.log.old", old) && MoveFileExW(p, old, MOVEFILE_REPLACE_EXISTING)) c->logBytes = 0;
    }
}
static void logf_(Coop *c, const char *fmt, ...)
{
    char text[1200];
    va_list ap;
    va_start(ap, fmt);
    int n = _vsnprintf(text, sizeof(text) - 1, fmt, ap);
    va_end(ap);
    if (n < 0) n = (int)sizeof(text) - 1;
    text[n] = 0;
    log_raw(c, text);
}
/* a plain sentence for the menu (status "note" line); also logged */
static void notef(Coop *c, const char *fmt, ...)
{
    char text[300];
    va_list ap;
    va_start(ap, fmt);
    int n = _vsnprintf(text, sizeof(text) - 1, fmt, ap);
    va_end(ap);
    if (n < 0) n = (int)sizeof(text) - 1;
    text[n] = 0;
    safe_text(c->note, sizeof(c->note), text, sizeof(c->note) - 1);
    logf_(c, "note: %s", c->note);
}
/* (lane 62) the same for a sentence that names a player: the menu gets it, the log does not (the caller logs the slot
 * and the id instead). Since 0.3 no persona name is written to coop_steam.log: a bug report carries that file. */
static void note_only(Coop *c, const char *fmt, ...)
{
    char text[300];
    va_list ap;
    va_start(ap, fmt);
    int n = _vsnprintf(text, sizeof(text) - 1, fmt, ap);
    va_end(ap);
    if (n < 0) n = (int)sizeof(text) - 1;
    text[n] = 0;
    safe_text(c->note, sizeof(c->note), text, sizeof(c->note) - 1);
}

/* ================================================================ link files: status, tail, mirror */
static int write_whole_atomic(Coop *c, const wchar_t *leaf, const wchar_t *tmpLeaf, const void *data, size_t n)
{
    wchar_t p[MAX_PATH], t[MAX_PATH];
    if (!link_path(c, leaf, p) || !link_path(c, tmpLeaf, t)) return 0;
    HANDLE h = CreateFileW(t, GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_DELETE, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) return 0;
    DWORD w = 0;
    BOOL ok = WriteFile(h, data, (DWORD)n, &w, NULL) && w == (DWORD)n;
    CloseHandle(h);
    if (!ok) return 0;
    return MoveFileExW(t, p, MOVEFILE_REPLACE_EXISTING) != 0;
}

/* ---------------------------------------------------------------- link file turnover (lane 33, 2026-11-13)
 * MOCK-TESTED ONLY. NOT RUN IN THE GAME YET: the lead runs it on test copies and on two PCs (lane_s21_33 report).
 * A player's link file is a chain: <base>.txt, then <base>.2.txt, <base>.3.txt, ... The writer (the mod for its own
 * file, this DLL for a mirror) ends a full file with the line "<seq> <wallclock> ~NEXT <k>" and goes on in file k
 * (made before the line is written). Every reader follows that line. The writer keeps the two files before the
 * current one (LINK_KEEP) and deletes older ones; <base>.txt is never deleted but becomes a one-line pointer
 * "0 0.000 ~NEXT <k>" to the oldest file kept, so a reader that starts finds the chain. A restart of the writer empties
 * <base>.txt and deletes the numbered files: a reader whose numbered file is gone, with no later file, starts again at
 * <base>.txt (like a file that got shorter). */
static void seg_leaf(const wchar_t *base, int seg, wchar_t out[32])
{
    if (seg <= 1) _snwprintf(out, 32, L"%s.txt", base);
    else _snwprintf(out, 32, L"%s.%d.txt", base, seg);
    out[31] = 0;
}
/* "<seq> <wallclock> ~NEXT <k>" (k 2..999999): the writer goes on in file k. Returns k, or 0 for any other line. */
static int next_marker(const uint8_t *b, uint32_t n)
{
    char t[96];
    if (n == 0 || n > 80) return 0;
    memcpy(t, b, n); t[n] = 0;
    if (t[n - 1] == '\r') t[--n] = 0;
    const char *p = strchr(t, ' ');
    if (!p || p == t) return 0;
    const char *q = strchr(p + 1, ' ');
    if (!q || q == p + 1) return 0;
    if (strncmp(q + 1, "~NEXT ", 6) != 0) return 0;
    const char *k = q + 7;
    if (k[0] == '0' || !is_digit_str(k, 6)) return 0;
    int v = atoi(k);
    return v >= 2 ? v : 0;
}
static int seg_exists(Coop *c, const wchar_t *base, int seg)
{
    wchar_t leaf[32], p[MAX_PATH];
    seg_leaf(base, seg, leaf);
    return link_path(c, leaf, p) && GetFileAttributesW(p) != INVALID_FILE_ATTRIBUTES;
}
/* the lowest numbered file of this chain above `after`, or 0 */
static int seg_lowest_above(Coop *c, const wchar_t *base, int after)
{
    wchar_t pat[MAX_PATH];
    _snwprintf(pat, MAX_PATH, L"%s\\%s.*.txt", c->linkDir, base);
    WIN32_FIND_DATAW fd;
    HANDLE h = FindFirstFileW(pat, &fd);
    if (h == INVALID_HANDLE_VALUE) return 0;
    int best = 0;
    size_t bl = wcslen(base), got;
    do {
        int k = seg_number(fd.cFileName, &got);
        if (k > after && got == bl && wcsncmp(fd.cFileName, base, bl) == 0 && (!best || k < best)) best = k;
    } while (FindNextFileW(h, &fd));
    FindClose(h);
    return best;
}
/* deletes every numbered file of this chain; the numbers that could not be deleted (in use) go to left[] */
static int seg_delete_numbered(Coop *c, const wchar_t *base, int *left, int cap)
{
    int nleft = 0;
    for (int k = seg_lowest_above(c, base, 1), guard = 0; k && guard < 100000; k = seg_lowest_above(c, base, k), guard++) {
        wchar_t leaf[32], p[MAX_PATH];
        seg_leaf(base, k, leaf);
        if (link_path(c, leaf, p) && !DeleteFileW(p) && GetLastError() != ERROR_FILE_NOT_FOUND && nleft < cap) left[nleft++] = k;
    }
    return nleft;
}
/* the k of a "~NEXT <k>" line that ends this open file, or 0 */
static int last_line_marker(HANDLE h)
{
    LARGE_INTEGER sz;
    if (!GetFileSizeEx(h, &sz) || sz.QuadPart < 2) return 0;
    uint64_t len = (uint64_t)sz.QuadPart, win = len < 120 ? len : 120;
    uint8_t buf[128];
    LARGE_INTEGER pos; pos.QuadPart = (LONGLONG)(len - win);
    DWORD got = 0;
    if (!SetFilePointerEx(h, pos, NULL, FILE_BEGIN) || !ReadFile(h, buf, (DWORD)win, &got, NULL) || got != win) return 0;
    if (buf[got - 1] != '\n') return 0;
    int64_t i = (int64_t)got - 2;
    while (i >= 0 && buf[i] != '\n') i--;
    if (i < 0 && len > win) return 0;
    return next_marker(buf + i + 1, (uint32_t)(got - 1 - (uint64_t)(i + 1)));
}
/* the newest file of a chain: follow the "~NEXT" lines from <base>.txt (deleted files are stepped over) */
static int seg_last(Coop *c, const wchar_t *base)
{
    int k = 1, last = 1;
    for (int guard = 0; guard < 100000; guard++) {
        wchar_t leaf[32], p[MAX_PATH];
        seg_leaf(base, k, leaf);
        if (!link_path(c, leaf, p)) return last;
        int nx;
        HANDLE h = CreateFileW(p, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
        if (h != INVALID_HANDLE_VALUE) {
            last = k;
            nx = last_line_marker(h);
            CloseHandle(h);
            if (nx <= k) return k;          /* (a file made a moment before its "~NEXT" line: that line is read next) */
        } else {
            if (k == 1) return 1;
            nx = seg_lowest_above(c, base, k);
            if (!nx) return last;
        }
        k = nx;
    }
    return last;
}

static void tail_close(Tail *t) { close_h(&t->h); }
static void tail_init(Tail *t, const wchar_t *leaf)
{
    tail_close(t);
    wcsncpy(t->leaf, leaf, 31); t->leaf[31] = 0;
    t->base[0] = 0; t->seg = 1; t->follow = 0;
    t->off = 0; t->part.n = 0; t->skip = 0; t->oversize = 0; t->active = 1;
}
/* a link file: base "host" or "friend<n>", read as a chain */
static void tail_init_link(Tail *t, const wchar_t *base)
{
    wchar_t leaf[32];
    seg_leaf(base, 1, leaf);
    tail_init(t, leaf);
    wcsncpy(t->base, base, 15); t->base[15] = 0;
    t->follow = 1;
}
static void tail_set_seg(Tail *t, int seg)
{
    tail_close(t);                                     /* (lane 65) the kept handle was of the file before */
    t->seg = seg;
    seg_leaf(t->base, seg, t->leaf);
    t->off = 0; t->part.n = 0; t->skip = 0;
}
/* offset just after the last complete line, so nothing old is replayed and we never start inside a line */
static void tail_to_end(Coop *c, Tail *t)
{
    wchar_t p[MAX_PATH];
    if (t->follow) tail_set_seg(t, seg_last(c, t->base));
    t->off = 0; t->part.n = 0; t->skip = 0;
    if (!link_path(c, t->leaf, p)) return;
    HANDLE h = CreateFileW(p, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) return;
    LARGE_INTEGER sz;
    if (GetFileSizeEx(h, &sz) && sz.QuadPart > 0) {
        uint64_t len = (uint64_t)sz.QuadPart, win = len < 70000 ? len : 70000;
        uint8_t *buf = (uint8_t *)malloc((size_t)win);
        LARGE_INTEGER pos; pos.QuadPart = (LONGLONG)(len - win);
        DWORD got = 0;
        if (buf && SetFilePointerEx(h, pos, NULL, FILE_BEGIN) && ReadFile(h, buf, (DWORD)win, &got, NULL)) {
            int64_t i = (int64_t)got - 1;
            while (i >= 0 && buf[i] != '\n') i--;
            if (i >= 0) t->off = len - win + (uint64_t)i + 1;
            else if (len > 70000) t->off = len;
        }
        free(buf);
    }
    CloseHandle(h);
}
typedef void (*LineFn)(Coop *c, void *ctx, const uint8_t *line, uint32_t len);
typedef void (*ShrinkFn)(Coop *c, void *ctx);
/* one file of the tail. Returns 2 when the tail moved to another file of its chain (read that one at once), else 0. */
static int tail_read_one(Coop *c, Tail *t, LineFn fn, ShrinkFn onShrink, void *ctx, int *shrunk)
{
    wchar_t p[MAX_PATH];
    if (!t->active) { tail_close(t); return 0; }
    if (!link_path(c, t->leaf, p)) return 0;
    /* (lane 65) a kept handle, or a look at the attributes first (no open): opened only when the size changed. The
     * handle shares delete, so a writer that starts again can delete the file meanwhile; such a file grows no more,
     * and its handle is let go after HANDLE_IDLE_MS. */
    HANDLE h = t->h;
    if (!h) {
        WIN32_FILE_ATTRIBUTE_DATA fa;
        if (GetFileAttributesExW(p, GetFileExInfoStandard, &fa)) {
            uint64_t sz0 = ((uint64_t)fa.nFileSizeHigh << 32) | fa.nFileSizeLow;
            if (sz0 == t->off) return 0;                   /* nothing new, nothing shorter */
            h = CreateFileW(p, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
            if (h == INVALID_HANDLE_VALUE) return 0;       /* (in use or going: the next tick tries again) */
            t->h = h; t->growAt = c->now;
        } else h = INVALID_HANDLE_VALUE;
    }
    if (h == INVALID_HANDLE_VALUE) {
        DWORD e = GetLastError();
        if (!t->follow || t->seg <= 1 || (e != ERROR_FILE_NOT_FOUND && e != ERROR_PATH_NOT_FOUND)) return 0;
        char nm[40]; to_utf8(t->leaf, nm, 40);
        int nx = seg_lowest_above(c, t->base, t->seg);
        if (nx) {                    /* only when this reader is more than a whole file behind: never in normal play */
            logf_(c, "%s was deleted before it was read to its end; going on with file %d (lines may be lost)", nm, nx);
            tail_set_seg(t, nx);
            return 2;
        }
        if (seg_exists(c, t->base, 1)) {   /* the writer started again: it emptied the first file and deleted the rest */
            logf_(c, "%s is gone and no later file exists: the game started again; reading the first file from its start", nm);
            tail_set_seg(t, 1);
            *shrunk = 1;
            if (onShrink) onShrink(c, ctx);
            return 2;
        }
        return 0;
    }
    int moved = 0;
    LARGE_INTEGER sz;
    if (!GetFileSizeEx(h, &sz)) { tail_close(t); return 0; }
    uint64_t len = (uint64_t)sz.QuadPart;
    if (len != t->off) t->growAt = c->now;
    if (len < t->off) { *shrunk = 1; t->off = 0; t->part.n = 0; t->skip = 0; if (onShrink) onShrink(c, ctx); }
    if (len > t->off) {
        uint64_t want = len - t->off;
        if (want > (4u << 20)) want = 4u << 20;
        LARGE_INTEGER pos; pos.QuadPart = (LONGLONG)t->off;
        DWORD got = 0;
        if (buf_reserve(&t->part, t->part.n + (size_t)want + 1) && SetFilePointerEx(h, pos, NULL, FILE_BEGIN) &&
            ReadFile(h, t->part.p + t->part.n, (DWORD)want, &got, NULL) && got > 0) {
            t->growAt = c->now;
            t->off += got;
            t->part.n += got;
            uint8_t *d = t->part.p;
            size_t n = t->part.n, at = 0;
            for (;;) {
                uint8_t *nl = (uint8_t *)memchr(d + at, '\n', n - at);
                if (!nl) break;
                size_t e = (size_t)(nl - d), l = e - at;
                if (l > 0 && d[e - 1] == '\r') l--;
                if (t->skip) t->skip = 0;                  /* end of an oversize line we are discarding */
                else if (l > MAX_LINE) t->oversize++;
                else if (l > 0) {
                    int nx = t->follow ? next_marker(d + at, (uint32_t)l) : 0;
                    fn(c, ctx, d + at, (uint32_t)l);       /* the "~NEXT" line travels too: the far side's mirror follows it */
                    if (nx > t->seg) { moved = nx; break; }
                }
                at = e + 1;
            }
            if (!moved) {
                size_t rest = n - at;
                if (t->skip) t->part.n = 0;
                else if (rest > MAX_LINE) { t->skip = 1; t->oversize++; t->part.n = 0; }
                else { if (at) memmove(d, d + at, rest); t->part.n = rest; }
            }
        } else tail_close(t);                              /* (lane 65) a failed read: opened again next time */
    }
    if (t->h && c->now - t->growAt >= HANDLE_IDLE_MS) tail_close(t);   /* (lane 65) quiet: let go */
    if (moved) { tail_set_seg(t, moved); return 2; }    /* anything after the "~NEXT" line in the old file is not read */
    return 0;
}
/* reads what was appended since last time; complete lines go to fn. If the file got shorter (the mod emptied it),
 * onShrink is called first, before any line read after it, and 1 is returned. A link file's tail follows its chain. */
static int tail_read(Coop *c, Tail *t, LineFn fn, ShrinkFn onShrink, void *ctx)
{
    int shrunk = 0;
    for (int hop = 0; hop < 8; hop++) if (tail_read_one(c, t, fn, onShrink, ctx, &shrunk) != 2) break;
    return shrunk;
}

/* a mirror: base "host" or "friend<n>". It writes the same chain of files the far side's mod writes (turnover above). */
static void mirror_close(Mirror *m) { close_h(&m->h); }
static void mirror_init(Mirror *m, const wchar_t *base)
{
    mirror_close(m);
    wcsncpy(m->base, base, 15); m->base[15] = 0;
    m->seg = 1; m->low = 1; m->ncut = 0; m->nstale = 0;
    seg_leaf(m->base, 1, m->leaf);
    m->pend.n = 0;
}
static void mirror_add(Mirror *m, const uint8_t *d, uint32_t n)
{
    buf_add(&m->pend, d, n); buf_add(&m->pend, "\n", 1);
    int k = next_marker(d, n);
    if (k > (m->ncut ? m->cutTo[m->ncut - 1] : m->seg)) {
        if (m->ncut < MIRROR_CUTS) { m->cutAt[m->ncut] = m->pend.n; m->cutTo[m->ncut] = k; m->ncut++; }
        else { m->pend.n = 0; m->ncut = 0; m->dropped = 1; }   /* the file stayed locked through 16 turnovers: drop what waits
                                                                     (as a stuck file always was); this file goes on being used */
    }
}
/* the file is closed by the far side's "~NEXT k" line just written: go on in file k */
static void mirror_switch(Coop *c, Mirror *m, int k)
{
    wchar_t leaf[32], p[MAX_PATH];
    mirror_close(m);                                   /* (lane 65) the old file is done */
    seg_leaf(m->base, k, leaf);
    if (link_path(c, leaf, p)) {
        HANDLE h = CreateFileW(p, GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
        if (h != INVALID_HANDLE_VALUE) CloseHandle(h);
    }
    m->seg = k;
    wcscpy(m->leaf, leaf);
    m->switchAt = c->now; m->switchTick = c->ticks;
    char nm[40]; to_utf8(m->leaf, nm, 40);
    logf_(c, "link file turnover: writing %s from now on", nm);
}
/* Removes the files older than the LINK_KEEP files before the current one, once the last turnover is LINK_KEEP_MS
 * old and this DLL has ticked LINK_KEEP_TICKS times since (the mod on this PC reads every frame, on the same thread:
 * after a long load both wake together, and the mod catches up in a few frames). The first file is not deleted but
 * becomes the one-line pointer "0 0.000 ~NEXT <oldest file kept>". A file in use is tried again next tick. */
static void mirror_cleanup(Coop *c, Mirror *m)
{
    if (m->low > m->seg - LINK_KEEP - 1) return;
    if (c->now - m->switchAt < LINK_KEEP_MS || c->ticks - m->switchTick < LINK_KEEP_TICKS) return;
    int was = m->low;
    while (m->low <= m->seg - LINK_KEEP - 1) {
        wchar_t leaf[32], p[MAX_PATH];
        seg_leaf(m->base, m->low, leaf);
        if (m->low >= 2 && link_path(c, leaf, p) && !DeleteFileW(p) && GetLastError() != ERROR_FILE_NOT_FOUND) break;
        m->low++;
    }
    wchar_t first[32], p[MAX_PATH];
    seg_leaf(m->base, 1, first);
    if (m->low != was && link_path(c, first, p)) {
        char stub[48]; int sn = snprintf(stub, sizeof(stub), "0 0.000 ~NEXT %d\n", m->low);
        HANDLE h = CreateFileW(p, GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
        DWORD w = 0;
        if (h != INVALID_HANDLE_VALUE) { WriteFile(h, stub, (DWORD)sn, &w, NULL); CloseHandle(h); }
    }
}
static int mirror_write(Coop *c, Mirror *m, const uint8_t *d, size_t n)
{
    wchar_t p[MAX_PATH];
    if (!link_path(c, m->leaf, p)) return 1;
    /* (lane 65) the handle is kept while lines come (each WriteFile goes to the file at once: the mod on this PC reads
     * it in the same frame); let go on a turnover, a clear, a failure, and after HANDLE_IDLE_MS without a line
     * (mirror_flush). It does not share delete: nobody else deletes a mirror file, and a delete that went through
     * under a kept handle would leave later lines in a file nobody reads. */
    if (!m->h) {
        m->h = CreateFileW(p, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
        if (m->h == INVALID_HANDLE_VALUE) m->h = NULL;
    }
    DWORD w = 0;
    int ok = m->h && WriteFile(m->h, d, (DWORD)n, &w, NULL) && w == (DWORD)n;
    DWORD err = ok ? 0 : GetLastError();
    if (!ok && m->h && w > 0 && w < (DWORD)n) {
        /* a part was written: the rest must follow it, never the whole again (a line would be doubled) */
        memmove(m->pend.p, m->pend.p + w, m->pend.n - w);
        m->pend.n -= w;
        for (int i = 0; i < m->ncut; i++) m->cutAt[i] -= w;
    }
    if (!ok && c->now >= m->warnAt) {
        char nm[40]; to_utf8(m->leaf, nm, 40);
        logf_(c, "could not write to %s (error %lu), will keep trying", nm, err);
        m->warnAt = c->now + 10000;
    }
    if (!ok) mirror_close(m);                          /* opened again at the next try */
    else m->usedAt = c->now;
    return ok;
}
static void mirror_flush(Coop *c, Mirror *m)
{
    if (m->dropped) { m->dropped = 0; logf_(c, "dropped lines for a mirror file that stayed locked through 16 turnovers"); }
    for (int guard = 0; guard < 4 * MIRROR_CUTS; guard++) {
        if (m->ncut && m->cutAt[0] == 0) {
            mirror_switch(c, m, m->cutTo[0]);
            m->ncut--;
            memmove(m->cutAt, m->cutAt + 1, sizeof(m->cutAt[0]) * (size_t)m->ncut);
            memmove(m->cutTo, m->cutTo + 1, sizeof(m->cutTo[0]) * (size_t)m->ncut);
            continue;
        }
        if (m->pend.n == 0) break;
        size_t upto = m->ncut ? m->cutAt[0] : m->pend.n;
        if (!mirror_write(c, m, m->pend.p, upto)) break;   /* (a part written is taken off pend there) */
        memmove(m->pend.p, m->pend.p + upto, m->pend.n - upto);
        m->pend.n -= upto;
        for (int i = 0; i < m->ncut; i++) m->cutAt[i] -= upto;
    }
    if (m->h && c->now - m->usedAt >= HANDLE_IDLE_MS) mirror_close(m);   /* (lane 65) quiet: let go */
    mirror_cleanup(c, m);
    if (m->nstale) {             /* the earlier chain's files that were in use when it was cleared */
        int k = 0;
        for (int i = 0; i < m->nstale; i++) {
            wchar_t leaf[32], p[MAX_PATH];
            if (m->stale[i] <= m->seg) continue;              /* the new chain reached that number: it is the new file now */
            seg_leaf(m->base, m->stale[i], leaf);
            if (link_path(c, leaf, p) && !DeleteFileW(p) && GetLastError() != ERROR_FILE_NOT_FOUND) m->stale[k++] = m->stale[i];
        }
        m->nstale = k;
    }
    if (m->pend.n > (8u << 20)) { m->pend.n = 0; m->ncut = 0; logf_(c, "dropped lines for a mirror file that stayed locked too long"); }
}
/* the far side started again (or a new session): empty the first file, then delete the numbered ones */
static void mirror_clear(Coop *c, Mirror *m)
{
    mirror_close(m);                                   /* (lane 65) before the file is emptied and the rest deleted */
    m->pend.n = 0; m->ncut = 0;
    m->seg = 1; m->low = 1;
    seg_leaf(m->base, 1, m->leaf);
    wchar_t p[MAX_PATH];
    if (!link_path(c, m->leaf, p)) return;
    HANDLE h = CreateFileW(p, GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h != INVALID_HANDLE_VALUE) {
        LARGE_INTEGER z; z.QuadPart = 0;
        SetFilePointerEx(h, z, NULL, FILE_BEGIN);
        SetEndOfFile(h);
        CloseHandle(h);
    }
    m->nstale = seg_delete_numbered(c, m->base, m->stale, 8);
    if (m->nstale) logf_(c, "%d old link file(s) could not be deleted yet (in use); trying again", m->nstale);
}

/* ================================================================ SHA-256 (bcrypt, a Windows system DLL) */
static BCRYPT_ALG_HANDLE g_sha;
static int sha_begin(BCRYPT_HASH_HANDLE *hh)
{
    if (!g_sha && BCryptOpenAlgorithmProvider(&g_sha, BCRYPT_SHA256_ALGORITHM, NULL, 0) != 0) { g_sha = NULL; return 0; }
    return BCryptCreateHash(g_sha, hh, NULL, 0, NULL, 0, 0) == 0;
}
static void sha_end(BCRYPT_HASH_HANDLE hh, char out[65])
{
    uint8_t d[32];
    static const char *hx = "0123456789abcdef";
    out[0] = 0;
    if (BCryptFinishHash(hh, d, 32, 0) == 0) {
        for (int i = 0; i < 32; i++) { out[i * 2] = hx[d[i] >> 4]; out[i * 2 + 1] = hx[d[i] & 15]; }
        out[64] = 0;
    }
    BCryptDestroyHash(hh);
}
static int sha_mem(const uint8_t *d, size_t n, char out[65])
{
    BCRYPT_HASH_HANDLE hh;
    if (!sha_begin(&hh)) return 0;
    size_t at = 0;
    while (at < n) { ULONG k = (ULONG)((n - at) > (1u << 30) ? (1u << 30) : (n - at)); BCryptHashData(hh, (PUCHAR)(d + at), k, 0); at += k; }
    sha_end(hh, out);
    return out[0] != 0;
}
static int sha_file(const wchar_t *path, char out[65])
{
    HANDLE h = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) return 0;
    BCRYPT_HASH_HANDLE hh;
    if (!sha_begin(&hh)) { CloseHandle(h); return 0; }
    uint8_t *buf = (uint8_t *)malloc(1u << 20);
    DWORD got = 0;
    int ok = buf != NULL;
    while (ok && ReadFile(h, buf, 1u << 20, &got, NULL) && got > 0) BCryptHashData(hh, buf, got, 0);
    free(buf);
    CloseHandle(h);
    sha_end(hh, out);
    return ok && out[0] != 0;
}

/* ================================================================ queues */
static Item *item_new(const uint8_t *msg, uint32_t len, int isS, int lines, SaveJob *job)
{
    Item *it = (Item *)calloc(1, sizeof(Item));
    if (!it) return NULL;
    if (len) {
        it->msg = (uint8_t *)malloc(len);
        if (!it->msg) { free(it); return NULL; }
        memcpy(it->msg, msg, len);
    }
    it->len = len; it->isS = isS; it->lines = lines; it->job = job;
    return it;
}
static void job_release(SaveJob *j)
{
    if (!j || --j->refs > 0) return;
    for (int i = 0; i < j->nfiles; i++) free(j->files[i].data);
    free(j);
}
static void item_free(Item *it) { if (!it) return; if (it->job) job_release(it->job); free(it->msg); free(it); }
static void q_unlink(Queue *q, Item *it)
{
    if (it->prev) it->prev->next = it->next; else q->head = it->next;
    if (it->next) it->next->prev = it->prev; else q->tail = it->prev;
    if (q->snode == it) q->snode = NULL;
    q->bytes -= it->len; q->count--;
    it->next = it->prev = NULL;
}
static void q_append(Queue *q, Item *it)
{
    it->prev = q->tail; it->next = NULL;
    if (q->tail) q->tail->next = it; else q->head = it;
    q->tail = it;
    q->bytes += it->len; q->count++;
}
static void q_clear(Queue *q) { while (q->head) { Item *it = q->head; q_unlink(q, it); item_free(it); } q->snode = NULL; }

/* a mod line for this peer. State snapshots replace an older one that is still waiting (only while the link is behind). */
static void peer_push_line(Peer *p, const uint8_t *msg, uint32_t len, int isS, int lines)
{
    if (isS && p->q.snode) { Item *old = p->q.snode; q_unlink(&p->q, old); item_free(old); p->sskipped++; }
    Item *it = item_new(msg, len, isS, lines, NULL);
    if (!it) return;
    q_append(&p->q, it);
    if (isS) p->q.snode = it;
    if (p->q.bytes > QUEUE_CAP) p->overflow = 1;
}
static void peer_push_ctl(Peer *p, const char *text)
{
    Item *it = item_new((const uint8_t *)text, (uint32_t)strlen(text), 0, 0, NULL);
    if (it) q_append(&p->ctl, it);
}
static void peer_push_job(Peer *p, SaveJob *j)
{
    Item *it = item_new(NULL, 0, 0, 0, j);
    if (!it) return;
    j->refs++;
    q_append(&p->q, it);
}
static void peer_stop_streams(Peer *p)
{
    q_clear(&p->ctl);
    q_clear(&p->q);
    if (p->x.job) { job_release(p->x.job); p->x.job = NULL; }
    p->needPong = 0; p->overflow = 0;
}

/* "<seq> <wallclock> S ..." is a state snapshot */
static int is_state_line(const uint8_t *b, uint32_t n)
{
    const uint8_t *i = (const uint8_t *)memchr(b, ' ', n);
    if (!i) return 0;
    const uint8_t *j = (const uint8_t *)memchr(i + 1, ' ', n - (uint32_t)(i + 1 - b));
    if (!j) return 0;
    uint32_t k = (uint32_t)(j + 1 - b);
    if (k >= n) return 0;
    return b[k] == 'S' && (k + 1 == n || b[k + 1] == ' ');
}
/* "<seq> <wallclock> J LOAD <saveName> <level> [<friendN,friendM> <id>]": returns 1 and the save name.
 * A single load (the mod's coop_join.lua, "SINGLE") names the friends that load: *only then gets a bit per named
 * slot, and the save is sent to those friends alone. Without the field (every copy loads) *only is 0: everybody. */
static int load_info(const uint8_t *b, uint32_t n, char *save, size_t cap, unsigned *only)
{
    char tmp[400];
    uint32_t m = n < sizeof(tmp) - 1 ? n : (uint32_t)sizeof(tmp) - 1;
    memcpy(tmp, b, m); tmp[m] = 0;
    char *w[8] = { 0 };
    int nw = 0;
    char *ctx = NULL;
    for (char *t = strtok_s(tmp, " ", &ctx); t && nw < 8; t = strtok_s(NULL, " ", &ctx)) w[nw++] = t;
    if (nw < 4 || strcmp(w[2], "J") != 0 || strcmp(w[3], "LOAD") != 0) return 0;
    copy_str(save, cap, nw >= 5 ? w[4] : "");
    if (only) {
        *only = 0;
        if (nw >= 7) {
            char *c2 = NULL;
            for (char *t = strtok_s(w[6], ",", &c2); t; t = strtok_s(NULL, ",", &c2))
                if (strncmp(t, "friend", 6) == 0 && t[6] >= '1' && t[6] <= '0' + MAX_FRIENDS && t[7] == 0) *only |= 1u << (t[6] - '0');
        }
    }
    return 1;
}

/* ================================================================ Steam helpers */
static void ident(Coop *c, SteamNetIdentity *id, uint64_t sid) { memset(id, 0, sizeof(*id)); c->f.Identity_SetSteamID64(id, sid); }

/* returns 1 sent, 0 buffer full (try again next tick), -1 other failure */
static int send_raw(Coop *c, uint64_t sid, const void *data, uint32_t len)
{
    SteamNetIdentity id;
    ident(c, &id, sid);
    int r = c->f.NM_SendMessageToUser(c->nm, &id, data, len, k_nSteamNetworkingSend_Reliable | k_nSteamNetworkingSend_NoNagle, 0);
    if (r == k_EResultOK) return 1;
    if (r == k_EResultLimitExceeded) return 0;
    if (c->now >= c->sendWarnAt) { logf_(c, "SendMessageToUser to %llu failed with result %d (will retry)", (unsigned long long)sid, r); c->sendWarnAt = c->now + 5000; }
    return -1;
}
static int send_text(Coop *c, uint64_t sid, const char *text) { return send_raw(c, sid, text, (uint32_t)strlen(text)); }

static void persona(Coop *c, uint64_t sid, char *out, size_t cap)
{
    const char *n = NULL;
    if (sid == c->me) n = c->f.Friends_GetPersonaName(c->friends);
    else n = c->f.Friends_GetFriendPersonaName(c->friends, sid);
    safe_text(out, cap, n, 64);
}

static int lobby_members(Coop *c, uint64_t *out, int cap)
{
    if (!c->lobby) return 0;
    int n = c->f.MM_GetNumLobbyMembers(c->mm, c->lobby), k = 0;
    if (n < 0 || n > 64) n = 0;
    for (int i = 0; i < n && k < cap; i++) {
        uint64_t s = c->f.MM_GetLobbyMemberByIndex(c->mm, c->lobby, i);
        if (s) out[k++] = s;
    }
    return k;
}
static int is_member(Coop *c, uint64_t sid)
{
    uint64_t m[16];
    int n = lobby_members(c, m, 16);
    for (int i = 0; i < n; i++) if (m[i] == sid) return 1;
    return 0;
}

static const char *relay_word(int r)
{
    switch (r) {
    case -102: return "cannot-try"; case -101: return "failed"; case -100: return "previously-worked";
    case -10: return "retrying"; case 1: return "never-tried"; case 2: return "waiting"; case 3: return "attempting";
    case 100: return "ok"; default: return "unknown";
    }
}
static const char *enter_word(uint32_t r)
{
    switch (r) {
    case 1: return "success"; case 2: return "the lobby does not exist any more"; case 3: return "not allowed";
    case 4: return "the lobby is full"; case 5: return "Steam error"; case 6: return "banned from that lobby";
    case 7: return "limited Steam account"; case 9: return "community ban"; case 10: return "a member has blocked you";
    case 11: return "you have blocked a member"; case 15: return "too many attempts, wait a little";
    default: return "refused";
    }
}

/* ================================================================ callbacks: the hand-built object */
static void cb_run(CoopCallback *self, void *param, sbool ioFailure, SteamAPICall_t call)
{
    (void)ioFailure; (void)call;
    __try {
        Coop *c = (Coop *)self->owner;
        if (!c || !param) return;
        uint8_t tmp[EV_DATA];
        int n = self->size < EV_DATA ? self->size : EV_DATA;
        memset(tmp, 0, sizeof(tmp));
        memcpy(tmp, param, (size_t)n);          /* copy first: a bad pointer faults here, outside the lock */
        EnterCriticalSection(&c->cs);
        if (c->evCount < EVQ) {
            Event *e = &c->ev[(c->evHead + c->evCount) % EVQ];
            e->id = self->id;
            e->thread = GetCurrentThreadId();     /* the thread Steam delivers callbacks on (logged once per id) */
            memcpy(e->data, tmp, EV_DATA);
            c->evCount++;
        } else InterlockedIncrement(&c->evDropped);
        LeaveCriticalSection(&c->cs);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
    }
}
static int cb_size(CoopCallback *self) { return self->size; }
static CoopAnyFn g_vtable[3] = { (CoopAnyFn)cb_run, (CoopAnyFn)cb_run, (CoopAnyFn)cb_size };

static void register_callbacks(Coop *c)
{
    for (int i = 0; i < NCB; i++) {
        CoopCallback *cb = &c->cbs[i];
        cb->vtable = g_vtable;
        cb->m_nCallbackFlags = 0;
        cb->m_iCallback = k_callbacks[i].id;
        cb->id = k_callbacks[i].id;
        cb->size = k_callbacks[i].size;
        cb->owner = c;
        __try {
            c->f.RegisterCallback(cb, k_callbacks[i].id);
        } __except (EXCEPTION_EXECUTE_HANDLER) {
            logf_(c, "registering callback %d (%s) faulted; it will not be heard", k_callbacks[i].id, k_callbacks[i].name);
        }
    }
    logf_(c, "registered %d Steam callbacks (one handler in vtable slots 0 and 1, size getter in slot 2); flags after registering:", NCB);
    for (int i = 0; i < NCB; i++)
        logf_(c, "  callback %d %s size %d flags 0x%02x", c->cbs[i].id, k_callbacks[i].name, c->cbs[i].size, c->cbs[i].m_nCallbackFlags);
}

/* ================================================================ status file */
static const char *ps_word(int s)
{
    switch (s) { case PS_CONNECTING: return "connecting"; case PS_CONNECTED: return "connected"; case PS_DISCONNECTED: return "disconnected"; default: return "connecting"; }
}
static void status_player(Coop *c, Buf *b, int slot, uint64_t sid, const char *state, int ping)
{
    char nm[100];
    persona(c, sid, nm, sizeof(nm));
    if (c->shapeOnly && ping >= 0) ping = 0;          /* (lane 65) the shape: a ping is only "some ping" */
    buf_printf(b, "%d %llu %s %d %s\n", slot, (unsigned long long)sid, state, ping, nm);
}
static void build_status(Coop *c, Buf *b)
{
    b->n = 0;
    unsigned long long me = (unsigned long long)c->me, lob = (unsigned long long)c->lobby;
    switch (c->st) {
    case ST_OFF: buf_printf(b, "off %llu %s\n", me, c->offReason[0] ? c->offReason : "unknown reason"); break;
    case ST_IDLE: case ST_CREATING: buf_printf(b, "idle %llu\n", me); break;
    case ST_HOSTING: buf_printf(b, "hosting %llu %llu\n", me, lob); break;
    case ST_JOINING: buf_printf(b, "joining %llu %llu\n", me, lob); break;
    case ST_JOINED:
        if (c->mySlot > 0) buf_printf(b, "joined %llu %llu slot %d\n", me, lob, c->mySlot);
        else buf_printf(b, "joined %llu %llu slot -\n", me, lob);
        break;
    }
    if (c->steamOk)
        buf_printf(b, "info appid %u overlay %d relay %s loggedon %d build %d proto %d dll %s\n", c->appId, c->overlay, relay_word(c->relay), c->loggedOn, c->buildId, PROTO_VERSION, COOP_STEAM_VERSION);
    if (c->note[0]) buf_printf(b, "note %s\n", c->note);
    if (c->lostN) buf_printf(b, "lost %d %d\n", c->lostN, c->lostFriends);   /* (lane 62) this host lost its lobby: times, friends then */
    /* (lane 62, part two) the window: a host that tries to get back into its lobby, a friend that waits for the host */
    if (c->st == ST_HOSTING && c->lostAt) buf_printf(b, "reconnecting %d\n", GRACE_MS / 1000);
    if (c->st == ST_JOINED && c->lostAt) buf_printf(b, "hostlost %d\n", GRACE_MS / 1000);
    if (c->backN) buf_printf(b, "back %d\n", c->backN);
    if (c->st == ST_HOSTING) {
        status_player(c, b, 0, c->me, "connected", 0);
        for (int s = 1; s <= MAX_FRIENDS; s++) {
            Peer *p = &c->peers[s];
            if (p->used) status_player(c, b, s, p->sid, ps_word(p->state), p->ready ? p->rtt : -1);
        }
    } else if (c->st == ST_JOINED) {
        Peer *h = &c->peers[0];
        status_player(c, b, 0, h->sid, ps_word(h->state), h->ready ? h->rtt : -1);
        /* the others, from the host's slot list in the lobby data ("sid:slot,...") */
        char tmp[256];
        copy_str(tmp, sizeof(tmp), c->roster);
        char *ctx = NULL;
        for (char *t = strtok_s(tmp, ",", &ctx); t; t = strtok_s(NULL, ",", &ctx)) {
            const char *e;
            uint64_t sid = parse_u64(t, &e);
            if (!sid || *e != ':') continue;
            int slot = (int)parse_u64(e + 1, NULL);
            if (slot < 1 || slot > MAX_FRIENDS) continue;
            if (sid != c->me && slot != c->mySlot && is_member(c, sid)) status_player(c, b, slot, sid, "connected", -1);
        }
        if (c->mySlot > 0) status_player(c, b, c->mySlot, c->me, h->ready ? "connected" : "disconnected", h->ready ? h->rtt : -1);
    }
}
static void write_status(Coop *c, int force)
{
    if (!c->linkDir[0]) return;
    if (!force && c->now - c->statusAt < STATUS_MIN_MS && c->statusAt) return;
    build_status(c, &c->status);
    if (!force && c->lastStatus.n == c->status.n && c->status.n && memcmp(c->lastStatus.p, c->status.p, c->status.n) == 0) return;
    /* (lane 65) only the pings changed (every PING_EVERY_MS): written at most every STATUS_PING_MS. Every write is a
     * new file (temp file and replace) that the mod opens up to four times a second, and a new file is what a
     * real-time scan looks at again; any other change is written at once, as before. */
    c->shapeOnly = 1; build_status(c, &c->shape); c->shapeOnly = 0;
    if (!force && c->lastShape.n == c->shape.n && c->shape.n && memcmp(c->lastShape.p, c->shape.p, c->shape.n) == 0 &&
        c->now - c->statusAt < STATUS_PING_MS) return;
    if (write_whole_atomic(c, L"steam_status.txt", L"steam_status.txt.tmp", c->status.p, c->status.n)) {
        c->lastStatus.n = 0;
        buf_add(&c->lastStatus, c->status.p, c->status.n);
        c->lastShape.n = 0;
        buf_add(&c->lastShape, c->shape.p, c->shape.n);
        c->statusAt = c->now;
    }
}

static void go_off(Coop *c, const char *fmt, ...)
{
    char text[256];
    va_list ap;
    va_start(ap, fmt);
    int n = _vsnprintf(text, sizeof(text) - 1, fmt, ap);
    va_end(ap);
    if (n < 0) n = (int)sizeof(text) - 1;
    text[n] = 0;
    safe_text(c->offReason, sizeof(c->offReason), text, sizeof(c->offReason) - 1);
    c->off = 1;
    c->st = ST_OFF;
    logf_(c, "OFF: %s", c->offReason);
    write_status(c, 1);
    /* (lane 65) nothing of this DLL stays open once it is off */
    for (int i = 0; i <= MAX_FRIENDS; i++) mirror_close(&c->mirrors[i]);
    tail_close(&c->hostTail); tail_close(&c->myTail); tail_close(&c->cmdTail);
    close_h(&c->logH);
}

/* ================================================================ configuration */
static void trim(char *s)
{
    size_t n = strlen(s);
    while (n && (s[n - 1] == ' ' || s[n - 1] == '\t' || s[n - 1] == '\r' || s[n - 1] == '\n')) s[--n] = 0;
    size_t i = 0;
    while (s[i] == ' ' || s[i] == '\t') i++;
    if (i) memmove(s, s + i, n - i + 1);
}
static void load_config(Coop *c)
{
    wchar_t cfg[MAX_PATH];
    char linkdir[600] = "", savedir[600] = "";
    _snwprintf(cfg, MAX_PATH, L"%s\\coop_steam.cfg", c->dllDir);
    FILE *f = _wfopen(cfg, L"rb");
    if (f) {
        char line[700];
        while (fgets(line, sizeof(line), f)) {
            if (line[0] == '#') continue;
            char *eq = strchr(line, '=');
            if (!eq) continue;
            *eq = 0;
            char *k = line, *v = eq + 1;
            trim(k); trim(v);
            if ((unsigned char)k[0] == 0xEF && (unsigned char)k[1] == 0xBB && (unsigned char)k[2] == 0xBF) memmove(k, k + 3, strlen(k + 3) + 1);
            if (_stricmp(k, "linkdir") == 0) copy_str(linkdir, sizeof(linkdir), v);
            else if (_stricmp(k, "savedir") == 0) copy_str(savedir, sizeof(savedir), v);
            else if (_stricmp(k, "sendrate_kb") == 0) c->sendRateKB = atoi(v);
            else if (_stricmp(k, "sendbuffer_kb") == 0) c->sendBufKB = atoi(v);
        }
        fclose(f);
    }
    wchar_t w[MAX_PATH];
    if (linkdir[0]) to_wide(linkdir, w, MAX_PATH);
    else _snwprintf(w, MAX_PATH, L"%s\\..\\link", c->dllDir);
    if (!GetFullPathNameW(w, MAX_PATH, c->linkDir, NULL)) wcsncpy(c->linkDir, w, MAX_PATH - 1);
    size_t n = wcslen(c->linkDir);
    while (n > 3 && (c->linkDir[n - 1] == L'\\' || c->linkDir[n - 1] == L'/')) c->linkDir[--n] = 0;
    if (savedir[0]) {
        to_wide(savedir, w, MAX_PATH);
        if (!GetFullPathNameW(w, MAX_PATH, c->saveDir, NULL)) wcsncpy(c->saveDir, w, MAX_PATH - 1);
        n = wcslen(c->saveDir);
        while (n > 3 && (c->saveDir[n - 1] == L'\\' || c->saveDir[n - 1] == L'/')) c->saveDir[--n] = 0;
        c->haveSaveDir = 1;
    }
}

/* ================================================================ save transfer, host side */
static void job_probe(Coop *c, SaveJob *j)
{
    char leaves[SAVE_FILES_MAX][64];
    int nl = 0;
    snprintf(leaves[nl++], 64, "%s_descr.sav", j->save);
    snprintf(leaves[nl++], 64, "%s.sav", j->save);
    /* extradata files, sorted */
    wchar_t pat[MAX_PATH], wsave[40];
    to_wide(j->save, wsave, 40);
    _snwprintf(pat, MAX_PATH, L"%s\\%s_extradata*.sav", c->saveDir, wsave);
    WIN32_FIND_DATAW fd;
    HANDLE fh = FindFirstFileW(pat, &fd);
    if (fh != INVALID_HANDLE_VALUE) {
        do {
            char nm[300];
            to_utf8(fd.cFileName, nm, sizeof(nm));
            char pre[64];
            snprintf(pre, sizeof(pre), "%s_extradata", j->save);
            if (nl < SAVE_FILES_MAX - 4 && save_name_ok(nm) && strncmp(nm, pre, strlen(pre)) == 0) copy_str(leaves[nl++], 64, nm);
        } while (FindNextFileW(fh, &fd));
        FindClose(fh);
    } else if (GetLastError() != ERROR_FILE_NOT_FOUND && GetFileAttributesW(c->saveDir) == INVALID_FILE_ATTRIBUTES) {
        snprintf(j->reason, sizeof(j->reason), "the save folder cannot be read"); j->sig[0] = 0; return;
    }
    for (int a = 2; a < nl; a++) for (int b = a + 1; b < nl; b++) if (strcmp(leaves[a], leaves[b]) > 0) { char t[64]; memcpy(t, leaves[a], 64); memcpy(leaves[a], leaves[b], 64); memcpy(leaves[b], t, 64); }
    /* the four coat-of-arms pictures, last. A picture that does not exist is not sent and is not an error; one that
     * exists is part of the save: it must be still like the rest, and it is checked and sent the same way. */
    for (int k = 0; k < 4; k++) {
        char cn[64];
        snprintf(cn, sizeof(cn), "%s_coat_%d.png", j->save, k);
        wchar_t cp[MAX_PATH];
        if (save_path(c, cn, NULL, cp) && GetFileAttributesW(cp) != INVALID_FILE_ATTRIBUTES && nl < SAVE_FILES_MAX) copy_str(leaves[nl++], 64, cn);
    }

    uint64_t len[SAVE_FILES_MAX], ticks[SAVE_FILES_MAX];
    char sig[4096];
    sig[0] = 0;
    size_t sl = 0;
    for (int i = 0; i < nl; i++) {
        wchar_t p[MAX_PATH];
        if (!save_path(c, leaves[i], NULL, p)) { j->state = JOB_FAILED; snprintf(j->why, sizeof(j->why), "bad save name"); return; }
        HANDLE h = CreateFileW(p, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
        if (h == INVALID_HANDLE_VALUE) {
            DWORD e = GetLastError();
            if (e == ERROR_FILE_NOT_FOUND || e == ERROR_PATH_NOT_FOUND) snprintf(j->reason, sizeof(j->reason), "%s does not exist yet", leaves[i]);
            else snprintf(j->reason, sizeof(j->reason), "%s cannot be read yet (the game may still be writing it)", leaves[i]);
            j->sig[0] = 0;
            return;
        }
        BY_HANDLE_FILE_INFORMATION bi;
        BOOL ok = GetFileInformationByHandle(h, &bi);
        CloseHandle(h);
        if (!ok) { snprintf(j->reason, sizeof(j->reason), "%s cannot be read yet", leaves[i]); j->sig[0] = 0; return; }
        len[i] = ((uint64_t)bi.nFileSizeHigh << 32) | bi.nFileSizeLow;
        ticks[i] = ((uint64_t)bi.ftLastWriteTime.dwHighDateTime << 32) | bi.ftLastWriteTime.dwLowDateTime;
        if (len[i] > MAX_SAVE_BYTES) { j->state = JOB_FAILED; snprintf(j->why, sizeof(j->why), "%s is larger than 64 MB, which is not sent", leaves[i]); return; }
        int k = snprintf(sig + sl, sizeof(sig) - sl, "%s|%llu|%llu;", leaves[i], (unsigned long long)len[i], (unsigned long long)ticks[i]);
        if (k > 0 && sl + (size_t)k < sizeof(sig)) sl += (size_t)k;
    }
    if (strcmp(sig, j->sig) != 0) { copy_str(j->sig, sizeof(j->sig), sig); j->sigSince = c->now; snprintf(j->reason, sizeof(j->reason), "the files are still changing"); return; }
    if (c->now - j->sigSince < SAVE_STABLE_MS) { snprintf(j->reason, sizeof(j->reason), "the files are still changing"); return; }
    if (len[0] == 0 || len[1] == 0) { snprintf(j->reason, sizeof(j->reason), "%s.sav or %s_descr.sav is empty", j->save, j->save); return; }
    /* a name is used again after three saves: an old main file must not be mistaken for the new save */
    if (ticks[1] + 20000000ull < ticks[0]) { snprintf(j->reason, sizeof(j->reason), "%s.sav is older than %s_descr.sav (the game has not rewritten it yet)", j->save, j->save); return; }
    /* complete and still: one copy of each file into memory */
    for (int i = 0; i < nl; i++) {
        wchar_t p[MAX_PATH];
        save_path(c, leaves[i], NULL, p);
        HANDLE h = CreateFileW(p, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
        uint8_t *data = (uint8_t *)malloc(len[i] ? (size_t)len[i] : 1);
        DWORD got = 0;
        BY_HANDLE_FILE_INFORMATION bi;
        int good = h != INVALID_HANDLE_VALUE && data && (len[i] == 0 || (ReadFile(h, data, (DWORD)len[i], &got, NULL) && got == (DWORD)len[i])) &&
                   GetFileInformationByHandle(h, &bi) && (((uint64_t)bi.nFileSizeHigh << 32) | bi.nFileSizeLow) == len[i] &&
                   ((((uint64_t)bi.ftLastWriteTime.dwHighDateTime << 32) | bi.ftLastWriteTime.dwLowDateTime) == ticks[i]);
        if (h != INVALID_HANDLE_VALUE) CloseHandle(h);
        if (!good) {
            free(data);
            for (int k = 0; k < j->nfiles; k++) { free(j->files[k].data); j->files[k].data = NULL; }
            j->nfiles = 0; j->sig[0] = 0;
            snprintf(j->reason, sizeof(j->reason), "%s changed while it was being read", leaves[i]);
            return;
        }
        SaveFile *sf = &j->files[j->nfiles++];
        copy_str(sf->name, sizeof(sf->name), leaves[i]);
        sf->data = data; sf->len = (uint32_t)len[i];
        sha_mem(data, sf->len, sf->sha);
        j->total += sf->len;
    }
    j->state = JOB_READY;
}
static void job_step(Coop *c, SaveJob *j)
{
    if (j->state != JOB_WAIT) return;
    if (!j->started) { j->started = 1; j->startAt = c->now; j->deadline = c->now + SAVE_WAIT_MS; }
    if (c->now >= j->nextPoll) { j->nextPoll = c->now + SAVE_POLL_MS; job_probe(c, j); }
    if (j->state == JOB_WAIT && c->now >= j->deadline) { j->state = JOB_FAILED; snprintf(j->why, sizeof(j->why), "gave up after %d seconds: %s", SAVE_WAIT_MS / 1000, j->reason); }
    if (j->state == JOB_FAILED) logf_(c, "could not send the save %s: %s. The J LOAD line goes to the friends anyway.", j->save, j->why);
    else if (j->state == JOB_READY) logf_(c, "the save %s is complete on disk: %d file(s), %.1f MB; sending it before the J LOAD line", j->save, j->nfiles, j->total / 1048576.0);
}

/* the next save message for this peer (does not advance: xfer_advance does that once Steam took it) */
static int xfer_build(Coop *c, Peer *p, Buf *m)
{
    Xfer *x = &p->x;
    SaveJob *j = x->job;
    m->n = 0;
    if (x->idx >= j->nfiles) return 0;
    SaveFile *f = &j->files[x->idx];
    if (x->phase == 0) { buf_printf(m, "F %s %u %s", f->name, f->len, f->sha); return 1; }
    if (x->phase == 1) {
        uint32_t k = f->len - x->off;
        if (k > CHUNK_RAW) k = CHUNK_RAW;
        buf_add(m, "C ", 2);
        buf_add(m, f->data + x->off, k);
        return 1;
    }
    buf_printf(m, "E %s", f->name);
    (void)c;
    return 1;
}
static void xfer_advance(Coop *c, Peer *p)
{
    Xfer *x = &p->x;
    SaveFile *f = &x->job->files[x->idx];
    if (x->phase == 0) { x->phase = f->len ? 1 : 2; x->off = 0; }
    else if (x->phase == 1) { uint32_t k = f->len - x->off; if (k > CHUNK_RAW) k = CHUNK_RAW; x->off += k; if (x->off >= f->len) x->phase = 2; }
    else { x->phase = 0; x->idx++; }
    if (x->idx >= x->job->nfiles) {
        logf_(c, "sent the save %s to friend%d (%.1f MB in %.1f s)", x->job->save, p->slot, x->job->total / 1048576.0, (c->now - x->t0) / 1000.0);
        job_release(x->job);
        x->job = NULL;
    }
}

/* pushes what Steam takes right now: control messages, then a save in progress, then queued lines */
static void send_pending(Coop *c, Peer *p)
{
    uint32_t budget = FILE_BUDGET;
    for (int guard = 0; guard < 100000; guard++) {
        if (p->ctl.head) {
            Item *it = p->ctl.head;
            if (send_raw(c, p->sid, it->msg, it->len) != 1) return;
            q_unlink(&p->ctl, it); item_free(it);
            continue;
        }
        if (!p->ready) return;
        if (p->needPong) {
            char t[64]; snprintf(t, sizeof(t), "PONG %s", p->pongTs);
            if (send_text(c, p->sid, t) != 1) return;
            p->needPong = 0;
            continue;
        }
        if (p->x.job) {
            if (budget == 0) return;
            if (!xfer_build(c, p, &c->msgBuf)) { xfer_advance(c, p); continue; }
            if (send_raw(c, p->sid, c->msgBuf.p, (uint32_t)c->msgBuf.n) != 1) return;
            budget = c->msgBuf.n >= budget ? 0 : budget - (uint32_t)c->msgBuf.n;
            xfer_advance(c, p);
            continue;
        }
        if (p->q.head) {
            Item *it = p->q.head;
            if (it->job) {
                q_unlink(&p->q, it);
                p->x.job = it->job; it->job = NULL;          /* the reference moves to the transfer */
                p->x.idx = 0; p->x.phase = 0; p->x.off = 0; p->x.t0 = c->now;
                item_free(it);
                continue;
            }
            if (send_raw(c, p->sid, it->msg, it->len) != 1) return;
            p->out += (uint32_t)it->lines;
            q_unlink(&p->q, it); item_free(it);
            continue;
        }
        return;
    }
}

/* ================================================================ save transfer, friend side */
static void mark_recv(Coop *c, const char *name, int ok)
{
    for (int i = 0; i < c->nmarks; i++) if (strcmp(c->marks[i].name, name) == 0) { c->marks[i].ok = ok; return; }
    if (c->nmarks < (int)(sizeof(c->marks) / sizeof(c->marks[0]))) { copy_str(c->marks[c->nmarks].name, 64, name); c->marks[c->nmarks].ok = ok; c->nmarks++; }
}
static void recv_close(Recv *r, int deleteTmp)
{
    if (r->fh && r->fh != INVALID_HANDLE_VALUE) CloseHandle(r->fh);
    r->fh = NULL;
    if (deleteTmp && r->tmp[0]) DeleteFileW(r->tmp);
    r->tmp[0] = 0;
}
static void recv_fail(Coop *c, Recv *r, const char *why)
{
    if (!r->active || r->skip || r->bad) return;
    recv_close(r, 1);
    r->bad = 1;
    mark_recv(c, r->name, 0);
    logf_(c, "the file %s did not arrive correctly (%s); the unfinished copy was deleted", r->name, why);
}
static void recv_start(Coop *c, Recv *r, const uint8_t *d, uint32_t n)
{
    if (r->active && !r->skip && !r->bad) recv_fail(c, r, "a new file was announced before the last one ended");
    recv_close(r, 1);
    memset(r, 0, sizeof(*r));
    r->active = 1;
    char text[320];
    uint32_t m = n < sizeof(text) - 1 ? n : (uint32_t)sizeof(text) - 1;
    memcpy(text, d, m); text[m] = 0;
    char *w[6] = { 0 };
    int nw = 0;
    char *ctx = NULL;
    for (char *t = strtok_s(text, " ", &ctx); t && nw < 6; t = strtok_s(NULL, " ", &ctx)) w[nw++] = t;
    char shown[80];
    safe_text(shown, sizeof(shown), nw >= 2 ? w[1] : "?", 60);
    if (!c->haveSaveDir) {
        if (!c->saveOffNoted) { c->saveOffNoted = 1; logf_(c, "the host sent a save file, but save transfer is off on this PC (no savedir in coop_steam.cfg); it is ignored"); }
        r->skip = 1; return;
    }
    const char *why = NULL;
    if (nw != 4) why = "the announcement is malformed";
    else if (!save_name_ok(w[1])) why = "that is not a co-op save file name, so it is never written";
    else if (!is_digit_str(w[2], 12)) why = "the size is not a number";
    else if (_strtoui64(w[2], NULL, 10) > MAX_SAVE_BYTES) why = "it is larger than 64 MB";
    else if (!is_hex64(w[3])) why = "the checksum is malformed";
    if (why) {
        logf_(c, "refused the file '%s': %s", shown, why);
        if (nw >= 2 && save_name_ok(w[1])) mark_recv(c, w[1], 0);
        r->skip = 1;
        return;
    }
    copy_str(r->name, sizeof(r->name), w[1]);
    r->size = _strtoui64(w[2], NULL, 10);
    copy_str(r->sha, sizeof(r->sha), w[3]);
    for (char *q = r->sha; *q; q++) if (*q >= 'A' && *q <= 'F') *q = (char)(*q - 'A' + 'a');
    if (!save_path(c, r->name, L".cooppart", r->tmp)) { r->skip = 1; return; }
    r->fh = CreateFileW(r->tmp, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (r->fh == INVALID_HANDLE_VALUE) {
        r->fh = NULL;
        logf_(c, "could not create a temporary file for %s (error %lu); the file is skipped", r->name, GetLastError());
        mark_recv(c, r->name, 0);
        r->tmp[0] = 0;
        r->skip = 1;
        return;
    }
    r->t0 = c->now;
}
static void recv_chunk(Coop *c, Recv *r, const uint8_t *d, uint32_t n)
{
    if (!r->active || r->skip || r->bad) return;
    if (n > CHUNK_RAW) { recv_fail(c, r, "a block of data was larger than allowed"); return; }
    if (r->got + n > r->size) { recv_fail(c, r, "more data came than was announced"); return; }
    DWORD w = 0;
    if (!WriteFile(r->fh, d, n, &w, NULL) || w != n) { recv_fail(c, r, "it could not be written"); return; }
    r->got += n;
}
static void recv_end(Coop *c, Recv *r, const uint8_t *d, uint32_t n)
{
    if (!r->active) return;
    if (r->skip || r->bad) { memset(r, 0, sizeof(*r)); return; }
    char nm[80];
    uint32_t m = n < sizeof(nm) - 1 ? n : (uint32_t)sizeof(nm) - 1;
    memcpy(nm, d, m); nm[m] = 0;
    if (strcmp(nm, r->name) != 0) { recv_fail(c, r, "the end marker names another file"); memset(r, 0, sizeof(*r)); return; }
    if (r->got != r->size) { char why[80]; snprintf(why, sizeof(why), "only %llu of %llu bytes arrived", (unsigned long long)r->got, (unsigned long long)r->size); recv_fail(c, r, why); memset(r, 0, sizeof(*r)); return; }
    FlushFileBuffers(r->fh);
    CloseHandle(r->fh); r->fh = NULL;
    char hex[65];
    if (!sha_file(r->tmp, hex) || strcmp(hex, r->sha) != 0) { recv_fail(c, r, "its checksum does not match the host's"); memset(r, 0, sizeof(*r)); return; }
    wchar_t fin[MAX_PATH];
    int done = 0;
    if (save_path(c, r->name, NULL, fin)) {
        for (int t = 0; t < 4 && !done; t++) { if (MoveFileExW(r->tmp, fin, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) done = 1; else Sleep(20); }
    }
    if (!done) { char why[80]; snprintf(why, sizeof(why), "it could not be put in place (error %lu)", GetLastError()); recv_fail(c, r, why); memset(r, 0, sizeof(*r)); return; }
    mark_recv(c, r->name, 1);
    logf_(c, "received %s (%.1f MB, checksum OK) in %.1f s", r->name, r->size / 1048576.0, (c->now - r->t0) / 1000.0);
    memset(r, 0, sizeof(*r));
}
static void check_load_arrived(Coop *c, const char *save)
{
    if (!load_name_ok(save)) return;
    char a[64], b[64];
    snprintf(a, sizeof(a), "%s.sav", save);
    snprintf(b, sizeof(b), "%s_descr.sav", save);
    int ma = -1, mb = -1, coats = 0, coatsBad = 0;
    char cp[64]; snprintf(cp, sizeof(cp), "%s_coat_", save);
    for (int i = 0; i < c->nmarks; i++) {
        if (!strcmp(c->marks[i].name, a)) ma = c->marks[i].ok;
        if (!strcmp(c->marks[i].name, b)) mb = c->marks[i].ok;
        if (!strncmp(c->marks[i].name, cp, strlen(cp))) { if (c->marks[i].ok) coats++; else coatsBad++; }
    }
    if (ma == 1 && mb == 1) logf_(c, "the J LOAD line for %s arrived after its files (%d coat picture(s)%s)", save, coats, coatsBad ? ", some pictures did not arrive correctly" : "");
    else if (ma == 0 || mb == 0) logf_(c, "warning: the files of the save %s did not arrive correctly; the game may not find it or may load an old copy", save);
    else logf_(c, "note: no files for the save %s came with this message (fine if both PCs share one save folder)", save);
    int k = 0;
    for (int i = 0; i < c->nmarks; i++) if (strncmp(c->marks[i].name, save, strlen(save)) != 0) c->marks[k++] = c->marks[i];
    c->nmarks = k;
}
static void remove_stale_parts(Coop *c)
{
    if (!c->haveSaveDir) return;
    wchar_t pat[MAX_PATH];
    _snwprintf(pat, MAX_PATH, L"%s\\coop_join_*.cooppart", c->saveDir);
    WIN32_FIND_DATAW fd;
    HANDLE h = FindFirstFileW(pat, &fd);
    if (h == INVALID_HANDLE_VALUE) return;
    do {
        char nm[300];
        to_utf8(fd.cFileName, nm, sizeof(nm));
        size_t l = strlen(nm);
        if (l > 9 && strcmp(nm + l - 9, ".cooppart") == 0) {
            nm[l - 9] = 0;
            wchar_t p[MAX_PATH];
            if (save_path(c, nm, L".cooppart", p)) DeleteFileW(p);
        }
    } while (FindNextFileW(h, &fd));
    FindClose(h);
}

/* ================================================================ session */
static void schedule_close(Coop *c, uint64_t sid)
{
    if (!sid || c->nclose >= MAX_FRIENDS + 1) return;
    c->closeSids[c->nclose++] = sid;
    c->closeAt = c->now + CLOSE_DELAY_MS;
}
static void free_fifo(Coop *c)
{
    while (c->fifoHead) {
        FifoE *e = c->fifoHead;
        c->fifoHead = e->next;
        if (e->job) job_release(e->job);
        free(e->msg);
        free(e);
    }
    c->fifoTail = NULL;
}
/* leave whatever we are in and go to state toState (idle or off) */
static void session_reset(Coop *c, int toState)
{
    for (int s = 0; s <= MAX_FRIENDS; s++) {
        Peer *p = &c->peers[s];
        if (p->used && p->sid) schedule_close(c, p->sid);
        peer_stop_streams(p);
        memset(p, 0, sizeof(*p));
    }
    recv_close(&c->rcv, 1);
    memset(&c->rcv, 0, sizeof(c->rcv));
    for (int i = 0; i <= MAX_FRIENDS; i++) { mirror_flush(c, &c->mirrors[i]); mirror_close(&c->mirrors[i]); }   /* (lane 65) */
    free_fifo(c);
    if (c->lobby && (c->st == ST_HOSTING || c->st == ST_JOINED || c->st == ST_JOINING)) {
        c->f.MM_LeaveLobby(c->mm, c->lobby);
        logf_(c, "left lobby %llu", (unsigned long long)c->lobby);
    }
    c->lobby = 0; c->call = 0; c->callKind = CALL_NONE;
    c->mySlot = 0; c->roster[0] = 0; c->slotsSent[0] = 0;
    c->hostTail.active = 0; c->myTail.active = 0; tail_close(&c->hostTail); tail_close(&c->myTail);   /* (lane 65) */
    c->nbans = 0; c->nmarks = 0;
    c->ownMiss = 0; c->backOnline = 0;
    c->lostAt = 0; c->memberOnly = 0; c->rejoinTries = 0; c->handTries = 0;
    c->st = toState;
}

/* (lane 62) A goodbye names its lobby: "BYE <lobby id>". Steam's messages go by Steam id, not by lobby, and a message
 * sent to a player whose session is closed waits until that player talks to the sender again. A host that gave its
 * lobby up says goodbye to friends that have left already; when such a friend then accepts the invite to the host's
 * NEW lobby, the old goodbye arrives first, and it took it for the end of the new game (found in the mock: the friend
 * joined the new lobby and was back at the main menu a moment later). A goodbye for another lobby is ignored.
 * "BYE" without a number (a DLL before 0.3) counts as before. */
static void say_bye(Coop *c)
{
    char t[40];
    snprintf(t, sizeof(t), "BYE %llu", (unsigned long long)c->lobby);
    if (c->st == ST_HOSTING) { for (int s = 1; s <= MAX_FRIENDS; s++) if (c->peers[s].used && c->peers[s].inLobby) send_text(c, c->peers[s].sid, t); }
    else if (c->st == ST_JOINED && c->peers[0].sid) send_text(c, c->peers[0].sid, t);
}
/* 1: a goodbye for the lobby this copy is in; 0: not a goodbye; -1: a goodbye for another lobby (logged, ignored) */
static int bye_kind(Coop *c, uint64_t sid, const char *text)
{
    if (strncmp(text, "BYE", 3) != 0 || (text[3] && text[3] != ' ')) return 0;
    if (!text[3]) return 1;
    uint64_t id = parse_u64(text + 4, NULL);
    if (!id || id == c->lobby) return 1;
    logf_(c, "a goodbye from %llu for another lobby (%llu; this copy is in %llu) was ignored: it was sent before this game", (unsigned long long)sid, (unsigned long long)id, (unsigned long long)c->lobby);
    return -1;
}

static void start_join(Coop *c, uint64_t lobby, const char *why)
{
    if (!lobby) { notef(c, "no lobby number was given"); return; }
    if ((c->st == ST_JOINED || c->st == ST_JOINING) && c->lobby == lobby) return;
    if (c->st == ST_HOSTING || c->st == ST_CREATING) { notef(c, "you are hosting: leave your own game first to join another"); return; }
    if (c->st == ST_JOINED || c->st == ST_JOINING) { say_bye(c); session_reset(c, ST_IDLE); }
    c->call = c->f.MM_JoinLobby(c->mm, lobby);
    c->callKind = CALL_JOIN; c->callAt = c->now; c->callDoneAt = 0;
    c->lobby = lobby;
    c->st = ST_JOINING;
    c->note[0] = 0;
    logf_(c, "joining lobby %llu (%s), call %llu", (unsigned long long)lobby, why, (unsigned long long)c->call);
}

static void publish_slots(Coop *c)
{
    char s[256];
    s[0] = 0;
    size_t n = 0;
    for (int k = 1; k <= MAX_FRIENDS; k++) {
        Peer *p = &c->peers[k];
        if (!p->used) continue;
        int w = snprintf(s + n, sizeof(s) - n, "%s%llu:%d", n ? "," : "", (unsigned long long)p->sid, k);
        if (w > 0 && n + (size_t)w < sizeof(s)) n += (size_t)w;
    }
    if (strcmp(s, c->slotsSent) == 0) return;
    if (c->f.MM_SetLobbyData(c->mm, c->lobby, LOBBY_SLOTS_KEY, s)) copy_str(c->slotsSent, sizeof(c->slotsSent), s);
}

static void on_lobby_created(Coop *c, int result, uint64_t lobby)
{
    if (c->st != ST_CREATING) return;
    c->call = 0; c->callKind = CALL_NONE;
    if (result != k_EResultOK || !lobby) { notef(c, "Steam could not create the lobby (result %d). Try again in a moment.", result); c->st = ST_IDLE; c->createRetryAt = c->now + CREATE_RETRY_MS; return; }
    c->lobby = lobby;
    c->st = ST_HOSTING;
    c->ownMiss = 0; c->backOnline = 0; c->ownAt = c->now;
    c->lostAt = 0; c->memberOnly = 0;
    char v[16]; snprintf(v, sizeof(v), "%d", PROTO_VERSION);
    sbool ok1 = c->f.MM_SetLobbyData(c->mm, lobby, LOBBY_KEY, v);
    { char hs[24]; snprintf(hs, sizeof(hs), "%llu", (unsigned long long)c->me); c->f.MM_SetLobbyData(c->mm, lobby, LOBBY_HOST_KEY, hs); }   /* (lane 62, part two) */
    if (c->buildId > 0) { char b[24]; snprintf(b, sizeof(b), "%d", c->buildId); c->f.MM_SetLobbyData(c->mm, lobby, LOBBY_BUILD_KEY, b); }
    const char *back = c->f.MM_GetLobbyData(c->mm, lobby, LOBBY_KEY);
    logf_(c, "hosting lobby %llu; lobby data %s=%s set=%d read back '%s'; members %d", (unsigned long long)lobby, LOBBY_KEY, v, ok1, back ? back : "(null)", c->f.MM_GetNumLobbyMembers(c->mm, lobby));
    for (int s = 1; s <= MAX_FRIENDS; s++) mirror_clear(c, &c->mirrors[s]);
    tail_init_link(&c->hostTail, L"host");
    tail_to_end(c, &c->hostTail);
    c->membersDirty = 1;
    c->note[0] = 0;
}

static void on_lobby_entered(Coop *c, uint64_t lobby, uint32_t response)
{
    if (c->st != ST_JOINING || lobby != c->lobby) return;
    c->call = 0; c->callKind = CALL_NONE;
    if (response != k_EChatRoomEnterResponseSuccess) {
        c->lobby = 0;
        c->st = ST_IDLE;
        notef(c, "could not join the host's game: %s", enter_word(response));
        return;
    }
    c->st = ST_JOINED;     /* from here on, leaving goes through session_reset */
    const char *v = c->f.MM_GetLobbyData(c->mm, lobby, LOBBY_KEY);
    char want[16]; snprintf(want, sizeof(want), "%d", PROTO_VERSION);
    if (!v || !v[0]) { session_reset(c, ST_IDLE); notef(c, "that Steam lobby is not a Manor Lords co-op game"); return; }
    if (strcmp(v, want) != 0) { char sv[20]; safe_text(sv, sizeof(sv), v, 10); session_reset(c, ST_IDLE); notef(c, "the host uses co-op version %s and you have version %s: both need the same mod version", sv, want); return; }
    const char *b = c->f.MM_GetLobbyData(c->mm, lobby, LOBBY_BUILD_KEY);
    int hb = b ? atoi(b) : 0;
    if (hb > 0 && c->buildId > 0 && hb != c->buildId) { session_reset(c, ST_IDLE); notef(c, "the host runs another version of the game (build %d, yours is %d): both need the same game update", hb, c->buildId); return; }
    uint64_t owner = c->f.MM_GetLobbyOwner(c->mm, lobby);
    /* (lane 62, part two) the host is the player the lobby's data names (DLL 0.4), not whoever owns the lobby now: while
     * a host is out for a moment, Steam gives the ownership to a friend, and an invite accepted then must not take
     * that friend for the host. A lobby without the name (an older host): its owner, as before. */
    const char *hk = c->f.MM_GetLobbyData(c->mm, lobby, LOBBY_HOST_KEY);
    uint64_t named = (hk && is_digit_str(hk, 20)) ? parse_u64(hk, NULL) : 0;
    if (named && named != owner) logf_(c, "the lobby names %llu as its host; its owner is %llu right now (the host may be out for a moment)", (unsigned long long)named, (unsigned long long)owner);
    if (named) owner = named;
    if (!owner || owner == c->me) { session_reset(c, ST_IDLE); notef(c, "the host of that game is not there any more"); return; }
    Peer *h = &c->peers[0];
    memset(h, 0, sizeof(*h));
    h->used = 1; h->sid = owner; h->slot = 0; h->state = PS_CONNECTING; h->born = c->now; h->inLobby = 1;
    if (c->f.Friends_RequestUserInformation) c->f.Friends_RequestUserInformation(c->friends, owner, 1);
    c->mySlot = 0;
    c->myNonce = (uint32_t)(c->now * 2654435761u) ^ (uint32_t)(c->me) ^ 0x5eed;
    if (!c->myNonce) c->myNonce = 1;
    c->lastHello = 0;
    mirror_clear(c, &c->mirrors[0]);
    remove_stale_parts(c);
    c->note[0] = 0;
    logf_(c, "joined lobby %llu, host %llu; saying hello", (unsigned long long)lobby, (unsigned long long)owner);
}

/* ================================================================ host */
static Peer *peer_by_sid(Coop *c, uint64_t sid)
{
    for (int s = 1; s <= MAX_FRIENDS; s++) if (c->peers[s].used && c->peers[s].sid == sid) return &c->peers[s];
    return NULL;
}
static int is_banned(Coop *c, uint64_t sid) { for (int i = 0; i < c->nbans; i++) if (c->bans[i] == sid) return 1; return 0; }

static Peer *assign_slot(Coop *c, uint64_t sid)
{
    Peer *p = peer_by_sid(c, sid);
    if (p) return p;
    int pick = 0;
    for (int s = 1; s <= MAX_FRIENDS && !pick; s++) if (!c->peers[s].used) pick = s;
    for (int s = 1; s <= MAX_FRIENDS && !pick; s++) if (!c->peers[s].inLobby && !c->peers[s].ready) pick = s;   /* reuse a slot whose player left */
    if (!pick) return NULL;
    p = &c->peers[pick];
    peer_stop_streams(p);
    memset(p, 0, sizeof(*p));
    p->used = 1; p->slot = pick; p->sid = sid; p->state = PS_CONNECTING; p->born = c->now; p->rtt = -1;
    if (c->f.Friends_RequestUserInformation) c->f.Friends_RequestUserInformation(c->friends, sid, 1);
    logf_(c, "slot %d given to %llu", pick, (unsigned long long)sid);
    return p;
}

static void host_drop(Coop *c, Peer *p, const char *why)
{
    if (p->ready) logf_(c, "friend%d (%llu) left: %s", p->slot, (unsigned long long)p->sid, why);
    peer_stop_streams(p);
    p->ready = 0;
    p->state = PS_DISCONNECTED;
    mirror_flush(c, &c->mirrors[p->slot]);
}

/* (lane 62) ---------------------------------------------------------------- the host's own place in its lobby
 * First public session, two PCs (2026-11-17): the host switched a VPN on, Steam dropped the HOST's lobby membership
 * (a lobby chat update for the host's own id, change 0x4), and this DLL went on as "hosting": it called the friend
 * "left the Steam lobby" and opened Steam's invite window for the dead lobby, so no invite ever reached the friend.
 * Now: this host is "in its lobby" only while Steam says it is the owner AND a member. When that ends (host_lost_lobby)
 * the hosting state ends with it; the next INVITE makes a new lobby and invites to that one (invite_step). */
static int host_in_lobby(Coop *c)
{
    return c->lobby && c->f.MM_GetLobbyOwner(c->mm, c->lobby) == c->me && is_member(c, c->me);
}
/* The one place where a host gives its lobby up while its game lives on. The friends are told goodbye (those whose
 * own copy has not seen it yet go back to their main menu, as every friend of a host that is gone), the old lobby is
 * left for good (never a second lobby beside a half-dead one), every peer is dropped, and the player is told once
 * (status line "lost <times> <friends connected then>", and the note). */
static void host_lost_lobby(Coop *c, const char *how)
{
    int friends = 0;
    for (int s = 1; s <= MAX_FRIENDS; s++) if (c->peers[s].used && c->peers[s].ready) friends++;
    logf_(c, "THIS HOST LOST ITS OWN PLACE IN LOBBY %llu (%s). %d friend(s) were connected: they are dropped here and go back to their main menu. The game on this PC goes on; the next INVITE opens a new lobby.",
          (unsigned long long)c->lobby, how, friends);
    say_bye(c);
    session_reset(c, ST_IDLE);
    c->lostN++; c->lostFriends = friends;
    notef(c, "%s", friends ? "Your Steam connection dropped. Your friends were sent to the main menu. Press Invite Friends to bring them back."
                           : "Your Steam connection dropped. Press Invite Friends to open a new lobby.");
}
/* (part two) A loss sign starts the window; it no longer ends the lobby by itself. */
static void host_window_begin(Coop *c, const char *how)
{
    if (c->lostAt) return;
    c->lostAt = c->now; c->rejoinAt = c->now; c->rejoinTries = 0;
    c->memberOnly = 0; c->ownMiss = 0;
    if (c->callKind == CALL_REJOIN) { c->call = 0; c->callKind = CALL_NONE; }   /* only a JoinLobby sent after this sign proves anything */
    logf_(c, "THIS HOST'S PLACE IN LOBBY %llu IS LOST (%s). For %d s it asks Steam to let it back into the same lobby; the friends and their slots are kept meanwhile.",
          (unsigned long long)c->lobby, how, GRACE_MS / 1000);
    notef(c, "Your Steam connection dropped. Trying to reconnect (%d s)...", GRACE_MS / 1000);
}
/* Steam's answer to a JoinLobby of the window (LobbyEnter by callback or call result). This is the ONLY proof that the
 * host is in its lobby again: its own member list may still show the state before the drop. */
static void host_rejoin_answer(Coop *c, uint32_t response)
{
    c->call = 0; c->callKind = CALL_NONE;
    if (c->st != ST_HOSTING || !c->lostAt) return;
    if (response == k_EChatRoomEnterResponseSuccess) {
        uint64_t owner = c->f.MM_GetLobbyOwner(c->mm, c->lobby);
        double took = (c->now - c->lostAt) / 1000.0;
        c->lostAt = 0; c->backN++;
        c->ownMiss = 0; c->ownAt = c->now;
        c->memberOnly = owner != c->me;
        if (c->memberOnly) logf_(c, "THIS HOST IS BACK IN LOBBY %llu after %.1f s (Steam let it in again, try %d). Its owner is %llu now (Steam moved the ownership when the host was out): that copy hands it back; until then this host works as a member.",
                                 (unsigned long long)c->lobby, took, c->rejoinTries, (unsigned long long)owner);
        else logf_(c, "THIS HOST IS BACK IN LOBBY %llu after %.1f s (Steam let it in again, try %d) and is its owner.", (unsigned long long)c->lobby, took, c->rejoinTries);
        notef(c, "%s", "Reconnected.");
        c->membersDirty = 1; c->slotsSent[0] = 0;
        for (int s = 1; s <= MAX_FRIENDS; s++) if (c->peers[s].used && c->peers[s].ready) c->peers[s].lastRecv = c->now;   /* the silence clock starts afresh */
        return;
    }
    if (response == 2) { host_lost_lobby(c, "Steam says the lobby does not exist any more (every friend has left it)"); return; }
    logf_(c, "Steam did not let this host back into its lobby (%s, answer %u); trying again", enter_word(response), response);
}
/* every tick of the window. Returns 1 when the lobby was given up (the hosting state is over). */
static int host_window_step(Coop *c)
{
    if (c->now - c->lostAt >= GRACE_MS) {
        char how[100];
        snprintf(how, sizeof(how), "not back in it %d s after its place was lost (%d JoinLobby tries)", GRACE_MS / 1000, c->rejoinTries);
        host_lost_lobby(c, how);
        return 1;
    }
    if (c->loggedOn && !c->call && c->now >= c->rejoinAt) {
        c->call = c->f.MM_JoinLobby(c->mm, c->lobby);
        c->callKind = CALL_REJOIN; c->callAt = c->now; c->callDoneAt = 0;
        c->rejoinAt = c->now + REJOIN_EVERY_MS; c->rejoinTries++;
        logf_(c, "asking Steam to let this host back into lobby %llu (JoinLobby call %llu, try %d)", (unsigned long long)c->lobby, (unsigned long long)c->call, c->rejoinTries);
    }
    return 0;
}

/* the polled twin of Steam's word, and the check right after Steam came back online. A failed check starts the window. */
static void host_own_check(Coop *c)
{
    if (c->backOnline) {
        c->backOnline = 0;
        c->ownAt = c->now;
        if (!host_in_lobby(c) && !(c->memberOnly && is_member(c, c->me))) { host_window_begin(c, "Steam was offline and is back: it no longer has this host as owner and member"); return; }
        c->ownMiss = 0;
        logf_(c, "Steam is back and still has this host as owner and member of lobby %llu", (unsigned long long)c->lobby);
        return;
    }
    if (c->now - c->ownAt < MEMBERS_EVERY_MS) return;
    c->ownAt = c->now;
    if (!c->loggedOn) return;           /* Steam is offline: what it says of lobbies means nothing now (checked at once when it is back) */
    if (host_in_lobby(c)) {
        if (c->ownMiss) logf_(c, "Steam has this host as owner and member of its lobby again (after %d failed check(s))", c->ownMiss);
        if (c->memberOnly) { c->memberOnly = 0; c->slotsSent[0] = 0; logf_(c, "this host is the owner of lobby %llu again (the ownership was handed back)", (unsigned long long)c->lobby); }
        c->ownMiss = 0;
        return;
    }
    /* (part two) back by a confirmed rejoin, a friend's copy still holds the ownership: a member is enough until it is handed back */
    if (c->memberOnly && is_member(c, c->me)) { c->ownMiss = 0; return; }
    c->ownMiss++;
    if (c->ownMiss == 1) logf_(c, "Steam does not have this host as owner and member of its lobby %llu (owner %llu, %d member(s)); asked again for %d s before this counts",
                               (unsigned long long)c->lobby, (unsigned long long)c->f.MM_GetLobbyOwner(c->mm, c->lobby), c->f.MM_GetNumLobbyMembers(c->mm, c->lobby), OWN_MISSES * MEMBERS_EVERY_MS / 1000);
    if (c->ownMiss < OWN_MISSES) return;
    char how[120];
    snprintf(how, sizeof(how), "asked of Steam %d times in %d s: this host is not its owner or not a member", OWN_MISSES, OWN_MISSES * MEMBERS_EVERY_MS / 1000);
    host_window_begin(c, how);
}

static void host_members(Coop *c)
{
    uint64_t m[16];
    int n = lobby_members(c, m, 16);
    /* (lane 62) a list without this host says nothing about the friends: nobody is called "left the Steam lobby" on
     * it (the live fault above). Whether this host still has its lobby is host_own_check's question. */
    int me = 0;
    for (int i = 0; i < n; i++) if (m[i] == c->me) me = 1;
    if (!me) return;
    for (int s = 1; s <= MAX_FRIENDS; s++) c->peers[s].inLobby = 0;
    for (int i = 0; i < n; i++) {
        if (m[i] == c->me || is_banned(c, m[i])) continue;
        Peer *p = assign_slot(c, m[i]);
        if (p) p->inLobby = 1;
    }
    for (int s = 1; s <= MAX_FRIENDS; s++) {
        Peer *p = &c->peers[s];
        if (!p->used) continue;
        if (!p->inLobby && p->state != PS_DISCONNECTED) host_drop(c, p, "left the Steam lobby");
        if (p->inLobby && !p->ready && !p->nomodNoted && p->state == PS_CONNECTING && c->now - p->born > NOMOD_AFTER_MS) {
            p->nomodNoted = 1;
            char nm[100]; persona(c, p->sid, nm, sizeof(nm));
            note_only(c, "%s is in the lobby but the co-op mod on that PC has not answered for 30 s (mod missing or Steam link off?)", nm);
            logf_(c, "note: the co-op mod of friend%d (%llu) has not answered for 30 s though that player is in the lobby (mod missing or Steam link off?)", p->slot, (unsigned long long)p->sid);
        }
    }
    publish_slots(c);
}

static void host_hello(Coop *c, uint64_t sid, const char *text)
{
    unsigned ver = 0, nonce = 0;
    if (sscanf(text, "HELLO %u %u", &ver, &nonce) != 2) { logf_(c, "a bad hello from %llu was ignored", (unsigned long long)sid); return; }
    /* (lane 62, part two) inside the window the member list is not to be trusted: a friend that has a slot stays known */
    if (!is_member(c, sid) && !(c->lostAt && peer_by_sid(c, sid))) { logf_(c, "hello from %llu, who is not in our lobby: ignored", (unsigned long long)sid); return; }
    if (is_banned(c, sid)) { send_text(c, sid, "REFUSE kicked the host removed you from this game"); return; }
    if (ver != PROTO_VERSION) {
        char t[160]; snprintf(t, sizeof(t), "REFUSE bad-version this host speaks co-op version %d, you sent %u", PROTO_VERSION, ver);
        send_text(c, sid, t);
        logf_(c, "refused %llu: version %u", (unsigned long long)sid, ver);
        return;
    }
    Peer *p = assign_slot(c, sid);
    if (!p) { send_text(c, sid, "REFUSE host-full the host has no free place"); logf_(c, "refused %llu: host full", (unsigned long long)sid); return; }
    p->inLobby = 1;
    char w[64]; snprintf(w, sizeof(w), "WELCOME %d %u", p->slot, nonce);
    if (p->ready && p->nonce == nonce) { peer_push_ctl(p, w); return; }        /* a repeated hello: same answer */
    peer_stop_streams(p);
    p->ready = 1; p->nonce = nonce; p->epoch++;
    p->state = PS_CONNECTED;
    p->lastRecv = c->now; p->lastPing = c->now; p->rtt = -1;
    peer_push_ctl(p, w);
    logf_(c, "%llu connected as friend%d", (unsigned long long)sid, p->slot);     /* (lane 62) no persona name in the log */
    publish_slots(c);
}

/* lines read from host.txt: each goes to the friends connected right now, in order; a J LOAD line waits for its save */
static void host_line(Coop *c, void *ctx, const uint8_t *line, uint32_t len)
{
    unsigned targets = *(unsigned *)ctx;
    if (!targets) return;
    FifoE *e = (FifoE *)calloc(1, sizeof(FifoE));
    if (!e) return;
    e->msg = (uint8_t *)malloc(len + 2);
    if (!e->msg) { free(e); return; }
    e->msg[0] = 'L'; e->msg[1] = ' ';
    memcpy(e->msg + 2, line, len);
    e->len = len + 2; e->isS = is_state_line(line, len); e->lines = 1; e->targets = targets;
    for (int s = 1; s <= MAX_FRIENDS; s++) e->epoch[s] = c->peers[s].epoch;
    char save[64];
    unsigned only = 0;
    if (load_info(line, len, save, sizeof(save), &only)) {
        e->jobTargets = only;
        char shown[80]; safe_text(shown, sizeof(shown), save, 60);
        if (!c->haveSaveDir) logf_(c, "the game asked everybody to load a save (%s), but save transfer is off (no savedir), so no file is sent", shown);
        else if (!load_name_ok(save)) logf_(c, "the game asked to load a save called '%s'; only coop_join_1..3 are ever sent, so no file is sent", shown);
        else {
            SaveJob *j = (SaveJob *)calloc(1, sizeof(SaveJob));
            if (j) { j->refs = 1; copy_str(j->save, sizeof(j->save), save); j->state = JOB_WAIT; copy_str(j->reason, sizeof(j->reason), "the game has not written the files yet"); e->job = j; }
        }
    }
    if (c->fifoTail) c->fifoTail->next = e; else c->fifoHead = e;
    c->fifoTail = e;
}
static int target_live(Coop *c, FifoE *e, int s) { return (e->targets & (1u << s)) && c->peers[s].ready && c->peers[s].epoch == e->epoch[s]; }

/* host.txt got shorter (the mod restarted): a T goes to the connected friends before any line read after it */
static void host_shrink(Coop *c, void *ctx)
{
    unsigned targets = *(unsigned *)ctx;
    logf_(c, "host.txt was emptied (the game restarted); reading it again from the start");
    if (!targets) return;
    FifoE *e = (FifoE *)calloc(1, sizeof(FifoE));
    if (!e) return;
    e->msg = (uint8_t *)malloc(1);
    if (!e->msg) { free(e); return; }
    e->msg[0] = 'T'; e->len = 1; e->targets = targets;
    for (int s = 1; s <= MAX_FRIENDS; s++) e->epoch[s] = c->peers[s].epoch;
    if (c->fifoTail) c->fifoTail->next = e; else c->fifoHead = e;
    c->fifoTail = e;
}
static void host_own_file(Coop *c)
{
    unsigned targets = 0;
    for (int s = 1; s <= MAX_FRIENDS; s++) if (c->peers[s].ready) targets |= 1u << s;
    tail_read(c, &c->hostTail, host_line, host_shrink, &targets);
    if (c->hostTail.oversize) { logf_(c, "skipped %d line(s) in host.txt longer than 64 KB", c->hostTail.oversize); c->hostTail.oversize = 0; }
}
static void host_fifo(Coop *c)
{
    while (c->fifoHead) {
        FifoE *e = c->fifoHead;
        if (e->job && e->job->state == JOB_WAIT) {
            int live = 0;
            for (int s = 1; s <= MAX_FRIENDS; s++) if (target_live(c, e, s) && (!e->jobTargets || (e->jobTargets & (1u << s)))) live = 1;
            if (!live) e->job->state = JOB_SKIP;
            else { job_step(c, e->job); if (e->job->state == JOB_WAIT) break; }
        }
        c->fifoHead = e->next;
        if (!c->fifoHead) c->fifoTail = NULL;
        for (int s = 1; s <= MAX_FRIENDS; s++) {
            if (!target_live(c, e, s)) continue;
            Peer *p = &c->peers[s];
            if (e->job && e->job->state == JOB_READY && (!e->jobTargets || (e->jobTargets & (1u << s)))) peer_push_job(p, e->job);
            peer_push_line(p, e->msg, e->len, e->isS, e->lines);
            send_pending(c, p);
        }
        if (e->job) job_release(e->job);
        free(e->msg);
        free(e);
    }
}

static void host_message(Coop *c, uint64_t sid, const uint8_t *d, uint32_t n)
{
    char text[320];
    uint32_t m = n < sizeof(text) - 1 ? n : (uint32_t)sizeof(text) - 1;
    memcpy(text, d, m); text[m] = 0;
    if (n >= 6 && memcmp(d, "HELLO ", 6) == 0) { host_hello(c, sid, text); return; }
    Peer *p = peer_by_sid(c, sid);
    if (!p || !p->ready) return;                 /* not (or no longer) connected: say hello first */
    p->lastRecv = c->now;
    if (n >= 2 && d[0] == 'L' && d[1] == ' ') {
        if (n - 2 > MAX_LINE) { host_drop(c, p, "sent a line longer than 64 KB"); return; }
        if (n > 2) { mirror_add(&c->mirrors[p->slot], d + 2, n - 2); p->in++; }
        return;
    }
    if (n >= 2 && d[1] == ' ' && (d[0] == 'F' || d[0] == 'C' || d[0] == 'E')) {
        if (!p->fileNoted) { p->fileNoted = 1; logf_(c, "friend%d sent a file; the host never accepts files, so it was ignored", p->slot); }
        return;
    }
    if (strncmp(text, "PING", 4) == 0) {
        const char *ts = text[4] == ' ' ? text + 5 : "0";
        if (!is_digit_str(ts, 15)) ts = "0";
        copy_str(p->pongTs, sizeof(p->pongTs), ts);
        p->needPong = 1;
    } else if (strncmp(text, "PONG ", 5) == 0) {
        uint64_t v = parse_u64(text + 5, NULL);
        if (v && v <= c->now) p->rtt = (int)(c->now - v);
    } else if (strcmp(text, "T") == 0) {
        mirror_flush(c, &c->mirrors[p->slot]);
        mirror_clear(c, &c->mirrors[p->slot]);
    } else if (bye_kind(c, sid, text) == 1) {
        host_drop(c, p, "left the game");
        schedule_close(c, sid);
    }
}

static void host_tick(Coop *c)
{
    /* (lane 62) this host's own place in its lobby: a loss sign starts the window (part two); the window may end the hosting */
    if (c->lostAt) { if (host_window_step(c)) return; }
    else host_own_check(c);
    /* (lane 62: not while Steam is offline, and not inside the window: its member list means nothing then. In the live
     * fault that list, read right after the host's own drop, made the friend "left the Steam lobby".) */
    if (!c->lostAt && c->loggedOn && (c->membersDirty || c->now - c->membersAt >= MEMBERS_EVERY_MS)) { c->membersDirty = 0; c->membersAt = c->now; host_members(c); }
    /* say "HI" to members who have not said hello: opens the session from our side even if no callback fires */
    for (int s = 1; s <= MAX_FRIENDS; s++) {
        Peer *p = &c->peers[s];
        if (p->used && p->inLobby && !p->ready && c->now - p->lastHi >= HI_EVERY_MS) { p->lastHi = c->now; send_text(c, p->sid, "HI"); }
    }
    host_own_file(c);
    host_fifo(c);
    for (int s = 1; s <= MAX_FRIENDS; s++) {
        Peer *p = &c->peers[s];
        if (!p->used) continue;
        if (p->ready && c->now - p->lastPing >= PING_EVERY_MS) { char t[40]; snprintf(t, sizeof(t), "PING %llu", (unsigned long long)c->now); peer_push_ctl(p, t); p->lastPing = c->now; }
        if (p->overflow) host_drop(c, p, "too far behind (its link is too slow)");
        else if (p->ready && c->now - p->lastRecv > DEAD_AFTER_MS) host_drop(c, p, DEAD_TEXT);
        send_pending(c, p);
    }
    for (int s = 1; s <= MAX_FRIENDS; s++) mirror_flush(c, &c->mirrors[s]);
}

/* ================================================================ friend */
static void friend_line(Coop *c, void *ctx, const uint8_t *line, uint32_t len)
{
    (void)ctx;
    Peer *h = &c->peers[0];
    uint8_t *m = (uint8_t *)malloc(len + 2);
    if (!m) return;
    m[0] = 'L'; m[1] = ' ';
    memcpy(m + 2, line, len);
    peer_push_line(h, m, len + 2, is_state_line(line, len), 1);
    free(m);
    if (h->ready) send_pending(c, h);
}
/* our own file was emptied (the mod restarted): the host empties its copy before the new lines (kept while offline) */
static void friend_shrink(Coop *c, void *ctx)
{
    (void)ctx;
    logf_(c, "friend%d.txt was emptied (the game restarted); reading it again from the start", c->mySlot);
    peer_push_line(&c->peers[0], (const uint8_t *)"T", 1, 0, 0);
}
static void friend_lost(Coop *c, const char *why)
{
    Peer *h = &c->peers[0];
    if (h->ready) logf_(c, "lost the link to the host (%s); trying again", why);
    h->ready = 0;
    h->state = PS_DISCONNECTED;
    q_clear(&h->ctl);
    h->needPong = 0;
    if (c->rcv.active && !c->rcv.skip && !c->rcv.bad) recv_fail(c, &c->rcv, "the link ended in the middle of the file");
    recv_close(&c->rcv, 1);
    memset(&c->rcv, 0, sizeof(c->rcv));
    c->myNonce++;
    if (!c->myNonce) c->myNonce = 1;
    c->lastHello = 0;
    mirror_flush(c, &c->mirrors[0]);
}
static void friend_leave(Coop *c, const char *fmt, const char *arg)
{
    session_reset(c, ST_IDLE);
    notef(c, fmt, arg);
}
static void friend_message(Coop *c, uint64_t sid, const uint8_t *d, uint32_t n)
{
    Peer *h = &c->peers[0];
    if (sid != h->sid) {
        if (c->badSender++ % 100 == 0) logf_(c, "a message from %llu, who is not the host, was ignored", (unsigned long long)sid);
        return;
    }
    char text[320];
    uint32_t m = n < sizeof(text) - 1 ? n : (uint32_t)sizeof(text) - 1;
    memcpy(text, d, m); text[m] = 0;
    if (!h->ready) {
        unsigned slot = 0, nonce = 0;
        if (sscanf(text, "WELCOME %u %u", &slot, &nonce) == 2) {
            if (nonce != c->myNonce || slot < 1 || slot > MAX_FRIENDS) return;      /* an answer to an older hello */
            h->ready = 1; h->state = PS_CONNECTED;
            h->lastRecv = c->now; h->lastPing = c->now; h->rtt = -1;
            if (c->mySlot != (int)slot) {
                c->mySlot = (int)slot;
                wchar_t base[16]; _snwprintf(base, 16, L"friend%u", slot);
                tail_init_link(&c->myTail, base);
                tail_to_end(c, &c->myTail);
            }
            logf_(c, "connected to the host as friend%d", c->mySlot);
            send_pending(c, h);
            return;
        }
        if (strncmp(text, "REFUSE ", 7) == 0) {
            char code[40] = "", reason[260] = "";
            const char *sp = strchr(text + 7, ' ');
            size_t cl = sp ? (size_t)(sp - (text + 7)) : strlen(text + 7);
            if (cl >= sizeof(code)) cl = sizeof(code) - 1;
            memcpy(code, text + 7, cl); code[cl] = 0;
            safe_text(reason, sizeof(reason), sp ? sp + 1 : code, 200);
            say_bye(c);
            friend_leave(c, "the host refused the connection: %s", reason);
            return;
        }
        if (strcmp(text, "HI") == 0 && c->now - c->lastHello >= 500) c->lastHello = 0;   /* answer at once */
        if (bye_kind(c, sid, text) == 1) { friend_leave(c, "%s", "the host closed the game"); return; }
        return;
    }
    /* The host greets ("HI") only players it does not have connected. A greeting while this copy believes it is
     * connected means the host dropped it (first session between two PCs, 2026-11-11: the host dropped a loading
     * friend, kept greeting him, and each greeting counted here as a sign of life, so his copy never said hello
     * again and stayed alone in the town). Connect again at once. */
    if (strcmp(text, "HI") == 0) {
        if (c->now - c->lastHello > 3000) friend_lost(c, "the host no longer has this copy connected");
        return;
    }
    h->lastRecv = c->now;
    if (n >= 2 && d[0] == 'L' && d[1] == ' ') {
        if (n - 2 > MAX_LINE) { friend_lost(c, "the host sent a line longer than 64 KB"); return; }
        if (n > 2) {
            mirror_add(&c->mirrors[0], d + 2, n - 2);
            h->in++;
            char save[64];
            if (c->haveSaveDir && load_info(d + 2, n - 2, save, sizeof(save), NULL)) check_load_arrived(c, save);
        }
        return;
    }
    if (n >= 2 && d[0] == 'C' && d[1] == ' ') { recv_chunk(c, &c->rcv, d + 2, n - 2); return; }
    if (n >= 2 && d[0] == 'F' && d[1] == ' ') { recv_start(c, &c->rcv, d, n); return; }
    if (n >= 2 && d[0] == 'E' && d[1] == ' ') { recv_end(c, &c->rcv, d + 2, n - 2); return; }
    if (strncmp(text, "PING", 4) == 0) {
        const char *ts = text[4] == ' ' ? text + 5 : "0";
        if (!is_digit_str(ts, 15)) ts = "0";
        copy_str(h->pongTs, sizeof(h->pongTs), ts);
        h->needPong = 1;
    } else if (strncmp(text, "PONG ", 5) == 0) {
        uint64_t v = parse_u64(text + 5, NULL);
        if (v && v <= c->now) h->rtt = (int)(c->now - v);
    } else if (strcmp(text, "T") == 0) {
        mirror_flush(c, &c->mirrors[0]);
        mirror_clear(c, &c->mirrors[0]);
    } else if (bye_kind(c, sid, text) == 1) {
        friend_leave(c, "%s", "the host closed the game");
    } else if (strncmp(text, "REFUSE ", 7) == 0) {
        const char *sp = strchr(text + 7, ' ');
        char reason[260]; safe_text(reason, sizeof(reason), sp ? sp + 1 : text + 7, 200);
        friend_leave(c, "the host ended the connection: %s", reason);
    }
}
static void friend_tick(Coop *c)
{
    Peer *h = &c->peers[0];
    if (c->now - c->ownerAt >= MEMBERS_EVERY_MS) {
        c->ownerAt = c->now;
        uint64_t owner = c->f.MM_GetLobbyOwner(c->mm, c->lobby);
        /* this copy itself is out of the lobby: it leaves at once, as before (its own way back is not built) */
        if (!is_member(c, c->me)) { friend_leave(c, "%s", "the host left the game"); return; }
        if (!is_member(c, h->sid)) {
            /* (lane 62, part two) Steam says the host is out of the lobby and there was no BYE: its connection may have
             * dropped for a moment. This copy stays in the lobby (it keeps it alive for the host's way back) and keeps
             * the host's Steam id trusted. It leaves as before when the window ends. */
            if (!c->lostAt) {
                c->lostAt = c->now; c->handTries = 0;
                logf_(c, "Steam says the host %llu is not in the lobby any more (its owner is %llu now) and it did not say goodbye: this copy stays and waits up to %d s for it",
                      (unsigned long long)h->sid, (unsigned long long)owner, GRACE_MS / 1000);
            } else if (c->now - c->lostAt >= GRACE_MS) {
                logf_(c, "the host did not come back into the lobby within %d s", GRACE_MS / 1000);
                friend_leave(c, "%s", "the host left the game");
                return;
            }
        } else {
            if (c->lostAt) {
                logf_(c, "the host is back in the lobby after %.1f s", (c->now - c->lostAt) / 1000.0);
                c->lostAt = 0; c->backN++;
                h->lastRecv = c->now;                        /* the silence clock starts afresh */
                if (!h->ready) c->lastHello = 0;
            }
            /* Steam gave this copy the lobby's ownership while the host was out: handed back (once a second until it is the host's) */
            if (owner == c->me && c->now - c->handAt >= 1000) {
                c->handAt = c->now; c->handTries++;
                if (!c->f.MM_SetLobbyOwner) { if (c->handTries == 1) logf_(c, "this copy holds the lobby's ownership and cannot hand it back (this Steam library has no SetLobbyOwner): the host goes on as a member"); }
                else {
                    sbool okh = c->f.MM_SetLobbyOwner(c->mm, c->lobby, h->sid);
                    if (c->handTries <= 3 || c->handTries % 30 == 0) logf_(c, "this copy holds the lobby's ownership: handing it back to the host %llu (SetLobbyOwner said %d, try %d)", (unsigned long long)h->sid, okh, c->handTries);
                }
            } else if (owner == h->sid && c->handTries) { logf_(c, "the host owns the lobby again"); c->handTries = 0; }
        }
        const char *r = c->f.MM_GetLobbyData(c->mm, c->lobby, LOBBY_SLOTS_KEY);
        copy_str(c->roster, sizeof(c->roster), r ? r : "");
    }
    if (!h->ready && (c->lastHello == 0 || c->now - c->lastHello >= HELLO_EVERY_MS)) {
        char t[64]; snprintf(t, sizeof(t), "HELLO %d %u", PROTO_VERSION, c->myNonce);
        c->lastHello = c->now;
        if (h->ctl.count < 4) peer_push_ctl(h, t);
    }
    if (c->myTail.active) {
        tail_read(c, &c->myTail, friend_line, friend_shrink, NULL);
        if (c->myTail.oversize) { logf_(c, "skipped %d line(s) longer than 64 KB", c->myTail.oversize); c->myTail.oversize = 0; }
    }
    if (h->overflow) { logf_(c, "too many lines piled up while the host was unreachable; dropping the backlog"); q_clear(&h->q); h->overflow = 0; }
    if (h->ready && c->now - h->lastPing >= PING_EVERY_MS) { char t[40]; snprintf(t, sizeof(t), "PING %llu", (unsigned long long)c->now); peer_push_ctl(h, t); h->lastPing = c->now; }
    if (h->ready && c->now - h->lastRecv > DEAD_AFTER_MS) friend_lost(c, "the host: " DEAD_TEXT);
    send_pending(c, h);
    mirror_flush(c, &c->mirrors[0]);
}

/* ================================================================ messages in */
static void receive_messages(Coop *c)
{
    SteamNetworkingMessage_t *arr[32];
    for (int round = 0; round < 64; round++) {
        int n = c->f.NM_ReceiveMessagesOnChannel(c->nm, 0, arr, 32);
        if (n <= 0) break;
        if (n > 32) n = 32;
        for (int i = 0; i < n; i++) {
            SteamNetworkingMessage_t *m = arr[i];
            if (!m) continue;
            uint64_t sid = c->f.Identity_GetSteamID64(m->m_identityPeer);
            if (m->m_pData && m->m_cbSize > 0 && m->m_cbSize <= (int)(MAX_LINE + 1024) && sid && c->st != ST_OFF) {
                if (c->st == ST_HOSTING) host_message(c, sid, (const uint8_t *)m->m_pData, (uint32_t)m->m_cbSize);
                else if (c->st == ST_JOINED) friend_message(c, sid, (const uint8_t *)m->m_pData, (uint32_t)m->m_cbSize);
            }
            c->f.Message_Release(m);
        }
        if (n < 32) break;
    }
}

/* ================================================================ events from callbacks, call results, commands */
static void handle_event(Coop *c, Event *e)
{
    int idx = -1;
    for (int i = 0; i < NCB; i++) if (k_callbacks[i].id == e->id) idx = i;
    if (idx >= 0 && !c->seenCb[idx]) {
        c->seenCb[idx] = 1;
        char hex[3 * 24 + 1];
        for (int i = 0; i < 24; i++) snprintf(hex + i * 3, 4, "%02x ", e->data[i]);
        logf_(c, "first callback %d (%s, our size %d, delivered on thread %lu, game thread %lu): first bytes %s", e->id, k_callbacks[idx].name, k_callbacks[idx].size, e->thread, GetCurrentThreadId(), hex);
    }
    switch (e->id) {
    case CB_GameOverlayActivated: logf_(c, "overlay %s", e->data[0] ? "opened" : "closed"); break;
    case CB_GameLobbyJoinRequested: {
        GameLobbyJoinRequested_t r; memcpy(&r, e->data, sizeof(r));
        logf_(c, "Steam invite accepted: lobby %llu from %llu", (unsigned long long)r.m_steamIDLobby, (unsigned long long)r.m_steamIDFriend);
        start_join(c, r.m_steamIDLobby, "Steam invite accepted");
        break;
    }
    case CB_LobbyEnter: {
        LobbyEnter_t r; memcpy(&r, e->data, sizeof(r));
        logf_(c, "LobbyEnter callback: lobby %llu response %u", (unsigned long long)r.m_ulSteamIDLobby, r.m_EChatRoomEnterResponse);
        if (c->callKind == CALL_REJOIN && c->st == ST_HOSTING && r.m_ulSteamIDLobby == c->lobby) host_rejoin_answer(c, r.m_EChatRoomEnterResponse);   /* (lane 62, part two) */
        else on_lobby_entered(c, r.m_ulSteamIDLobby, r.m_EChatRoomEnterResponse);
        break;
    }
    case CB_LobbyChatUpdate: {
        LobbyChatUpdate_t r; memcpy(&r, e->data, sizeof(r));
        if (r.m_ulSteamIDLobby == c->lobby) {
            logf_(c, "lobby member %llu change 0x%x", (unsigned long long)r.m_ulSteamIDUserChanged, r.m_rgfChatMemberStateChange);
            /* (lane 62) Steam's word that THIS host is out of its own lobby: acted on at once, before the member
             * list is read (host_members would have called every friend "left the Steam lobby") */
            if (c->st == ST_HOSTING && r.m_ulSteamIDUserChanged == c->me &&
                (r.m_rgfChatMemberStateChange & (k_EChatMemberStateChangeLeft | k_EChatMemberStateChangeDisconnected | k_EChatMemberStateChangeKicked | k_EChatMemberStateChangeBanned))) {
                char how[96];
                snprintf(how, sizeof(how), "Steam's word: lobby chat update for this host's own id, change 0x%x", r.m_rgfChatMemberStateChange);
                host_window_begin(c, how);               /* (part two: the window; part one gave the lobby up here) */
                break;
            }
            c->membersDirty = 1; c->ownerAt = 0;
        }
        break;
    }
    case CB_LobbyCreated: {
        LobbyCreated_t r; memcpy(&r, e->data, sizeof(r));
        logf_(c, "LobbyCreated callback: result %d lobby %llu", r.m_eResult, (unsigned long long)r.m_ulSteamIDLobby);
        on_lobby_created(c, r.m_eResult, r.m_ulSteamIDLobby);
        break;
    }
    case CB_NetMsgSessionRequest: {
        uint64_t sid = c->f.Identity_GetSteamID64(e->data);
        int member = sid && (c->st == ST_HOSTING || c->st == ST_JOINED) && is_member(c, sid) && !is_banned(c, sid);
        /* (lane 62, part two) Steam's messages go by Steam id, not by lobby: a session that failed with the drop is
         * opened again by the next message. The host of this game (a friend's copy) and, inside a host's window, a
         * friend that has a slot stay trusted though the lobby does not list them at this moment. */
        if (!member && sid && !is_banned(c, sid)) {
            if (c->st == ST_JOINED && c->peers[0].used && sid == c->peers[0].sid) member = 1;
            if (c->st == ST_HOSTING && c->lostAt && peer_by_sid(c, sid)) member = 1;
        }
        if (member) {
            SteamNetIdentity id; ident(c, &id, sid);
            sbool ok = c->f.NM_AcceptSessionWithUser(c->nm, &id);
            logf_(c, "session request from %llu (lobby member): accepted=%d", (unsigned long long)sid, ok);
        } else logf_(c, "session request from %llu, not a member of our lobby: not accepted", (unsigned long long)sid);
        break;
    }
    case CB_NetMsgSessionFailed: {
        uint64_t sid = c->f.Identity_GetSteamID64(e->data);
        logf_(c, "Steam says the session with %llu failed (the 10 s silence rule decides what happens)", (unsigned long long)sid);
        break;
    }
    }
}
static void drain_events(Coop *c)
{
    for (int k = 0; k < EVQ; k++) {
        Event e;
        int have = 0;
        EnterCriticalSection(&c->cs);
        if (c->evCount > 0) { e = c->ev[c->evHead]; c->evHead = (c->evHead + 1) % EVQ; c->evCount--; have = 1; }
        LeaveCriticalSection(&c->cs);
        if (!have) break;
        handle_event(c, &e);
    }
    LONG d = c->evDropped;
    if (d != c->evDroppedLogged) { logf_(c, "%ld callback event(s) were dropped (queue full)", d - c->evDroppedLogged); c->evDroppedLogged = d; }
}

static void poll_call(Coop *c)
{
    if (!c->call || c->callKind == CALL_NONE) return;
    sbool failed = 0;
    if (!c->callDoneAt && c->f.Utils_IsAPICallCompleted(c->utils, c->call, &failed)) {
        c->callDoneAt = c->now;
        if (c->callKind == CALL_CREATE) {
            LobbyCreated_t r; memset(&r, 0, sizeof(r));
            sbool f2 = 0;
            sbool ok = c->f.Utils_GetAPICallResult(c->utils, c->call, &r, (int)sizeof(r), CB_LobbyCreated, &f2);
            logf_(c, "CreateLobby call completed: got=%d failed=%d/%d result %d lobby %llu", ok, failed, f2, r.m_eResult, (unsigned long long)r.m_ulSteamIDLobby);
            if (ok && !f2) { on_lobby_created(c, r.m_eResult, r.m_ulSteamIDLobby); return; }
        } else {
            LobbyEnter_t r; memset(&r, 0, sizeof(r));
            sbool f2 = 0;
            sbool ok = c->f.Utils_GetAPICallResult(c->utils, c->call, &r, (int)sizeof(r), CB_LobbyEnter, &f2);
            logf_(c, "JoinLobby call completed: got=%d failed=%d/%d lobby %llu response %u", ok, failed, f2, (unsigned long long)r.m_ulSteamIDLobby, r.m_EChatRoomEnterResponse);
            if (ok && !f2 && c->callKind == CALL_REJOIN) { host_rejoin_answer(c, r.m_EChatRoomEnterResponse); return; }   /* (lane 62, part two) */
            if (ok && !f2) { on_lobby_entered(c, c->lobby, r.m_EChatRoomEnterResponse); return; }
        }
        if (c->f.Utils_GetAPICallFailureReason) logf_(c, "call failure reason %d (waiting for the matching callback instead)", c->f.Utils_GetAPICallFailureReason(c->utils, c->call));
    }
    /* the callback path may still deliver it; give up after a while */
    if (c->call && ((c->callDoneAt && c->now - c->callDoneAt > 5000) || c->now - c->callAt > CALL_TIMEOUT_MS)) {
        int kind = c->callKind;
        c->call = 0; c->callKind = CALL_NONE;
        if (kind == CALL_CREATE && c->st == ST_CREATING) { c->st = ST_IDLE; c->createRetryAt = c->now + CREATE_RETRY_MS; notef(c, "%s", "Steam did not answer the request to create a lobby"); }
        else if (kind == CALL_JOIN && c->st == ST_JOINING) { c->f.MM_LeaveLobby(c->mm, c->lobby); c->lobby = 0; c->st = ST_IDLE; notef(c, "%s", "Steam did not answer the request to join that game"); }
        else if (kind == CALL_REJOIN) logf_(c, "Steam did not answer this host's request to get back into its lobby; asked again");   /* (the window goes on) */
    }
}

static void start_create(Coop *c)
{
    c->call = c->f.MM_CreateLobby(c->mm, k_ELobbyTypePrivate, 1 + MAX_FRIENDS);   /* invite only: nothing shows on the host's friends list; friends come in through the invite */
    c->callKind = CALL_CREATE; c->callAt = c->now; c->callDoneAt = 0;
    c->st = ST_CREATING;
    notef(c, "%s", "creating the game's Steam lobby");
    logf_(c, "CreateLobby(invite only, %d) call %llu", 1 + MAX_FRIENDS, (unsigned long long)c->call);
}

/* (lane 62) INVITE asked for Steam's invite window. It is opened only for a lobby this host is in right now (owner and
 * member, asked of Steam at this moment). Without one (never hosted, or the lobby was lost) a new lobby is made first
 * and the window opens for that one. While Steam is offline nothing is made or opened: the note says so, and the
 * window opens when Steam is back (within INVITE_WAIT_MS). Runs every tick while an INVITE waits. */
static void invite_step(Coop *c)
{
    if (!c->inviteWanted) return;
    if (c->st == ST_JOINED || c->st == ST_JOINING) { c->inviteWanted = 0; return; }
    if (c->now >= c->inviteUntil) {
        c->inviteWanted = 0; c->inviteOffNoted = 0;
        notef(c, "%s", "Steam did not open a lobby in time. Press Invite Friends again.");
        return;
    }
    if (!c->f.User_BLoggedOn(c->user)) {
        if (!c->inviteOffNoted) { c->inviteOffNoted = 1; notef(c, "%s", "Steam is not online right now. The invite window opens as soon as Steam is back."); }
        return;
    }
    if (c->st == ST_CREATING) return;                    /* the lobby is on its way */
    if (c->st == ST_HOSTING) {
        if (c->backOnline || c->lostAt) return;          /* Steam just came back, or the window runs: first it is settled whether the lobby is still ours */
        /* not ours right now: host_own_check sees it again or starts the window; then this goes on. (Back by a confirmed
         * rejoin, with the ownership still at a friend's copy: a member may invite.) */
        if (!host_in_lobby(c) && !(c->memberOnly && is_member(c, c->me))) return;
        if (!c->f.Utils_IsOverlayEnabled(c->utils)) notef(c, "%s", "the Steam overlay is off (enable it in Steam) - the invite window may not open");
        else if (c->inviteOffNoted) c->note[0] = 0;
        c->f.Friends_ActivateInviteDialog(c->friends, c->lobby);
        logf_(c, "opened the Steam invite window for lobby %llu", (unsigned long long)c->lobby);
        c->inviteWanted = 0; c->inviteOffNoted = 0;
        return;
    }
    if (c->st == ST_IDLE && c->now >= c->createRetryAt) {
        logf_(c, "INVITE without a lobby of ours: a new lobby is made first");
        start_create(c);
    }
}

static void command(Coop *c, void *ctx, const uint8_t *line, uint32_t len)
{
    (void)ctx;
    char t[200];
    uint32_t m = len < sizeof(t) - 1 ? len : (uint32_t)sizeof(t) - 1;
    memcpy(t, line, m); t[m] = 0;
    trim(t);
    char verb[16] = "";
    const char *arg = "";
    size_t i = 0;
    while (t[i] && t[i] != ' ' && i < sizeof(verb) - 1) { verb[i] = (char)toupper((unsigned char)t[i]); i++; }
    verb[i] = 0;
    arg = t + i;
    while (*arg == ' ') arg++;
    char shown[200]; safe_text(shown, sizeof(shown), t, 150);
    logf_(c, "command: %s", shown);
    if (!strcmp(verb, "HOST")) {
        if (c->st == ST_HOSTING || c->st == ST_CREATING) { notef(c, "%s", "already hosting"); return; }
        if (c->st == ST_JOINED || c->st == ST_JOINING) { say_bye(c); session_reset(c, ST_IDLE); }
        if (!c->loggedOn) { notef(c, "%s", "Steam is not online, so no game can be hosted right now"); return; }
        start_create(c);
    } else if (!strcmp(verb, "INVITE")) {
        /* (lane 62) never Steam's invite window for a lobby this host is not in: invite_step (this tick) decides */
        if (c->st == ST_JOINED || c->st == ST_JOINING) { notef(c, "%s", "you are in another player's game: only its host invites"); return; }
        c->inviteWanted = 1; c->inviteOffNoted = 0; c->inviteUntil = c->now + INVITE_WAIT_MS;
    } else if (!strcmp(verb, "JOIN")) {
        start_join(c, parse_u64(arg, NULL), "JOIN command");
    } else if (!strcmp(verb, "LEAVE")) {
        say_bye(c);
        session_reset(c, ST_IDLE);
        c->inviteWanted = 0;
        notef(c, "%s", "left the game");
    } else if (!strcmp(verb, "KICK")) {
        uint64_t sid = parse_u64(arg, NULL);
        Peer *p = c->st == ST_HOSTING ? peer_by_sid(c, sid) : NULL;
        if (!p) { notef(c, "%s", "nobody with that Steam id is in your game"); return; }
        send_text(c, sid, "REFUSE kicked the host removed you from this game");
        if (c->nbans < 16) c->bans[c->nbans++] = sid;
        peer_stop_streams(p);
        mirror_flush(c, &c->mirrors[p->slot]);
        memset(p, 0, sizeof(*p));
        schedule_close(c, sid);
        publish_slots(c);
        logf_(c, "removed %llu from the game (Steam has no lobby kick: that PC leaves the lobby by itself)", (unsigned long long)sid);
    } else if (!strcmp(verb, "QUIT")) {
        say_bye(c);
        session_reset(c, ST_IDLE);
        c->inviteWanted = 0;
        c->quitting = 1;
    } else {
        logf_(c, "unknown command ignored");
    }
}

/* ================================================================ start-up */
static void refresh_info(Coop *c)
{
    int first = c->infoAt == 0;
    c->infoAt = c->now;
    c->overlay = c->f.Utils_IsOverlayEnabled(c->utils) ? 1 : 0;
    int on = c->f.User_BLoggedOn(c->user) ? 1 : 0;
    if (!first && on != c->loggedOn) {
        /* (lane 62) Steam offline does not end a lobby by itself here (a short break may leave it whole). When Steam is
         * back, a host asks at once whether the lobby is still its own (host_own_check). */
        logf_(c, on ? "Steam is online again (logged on)" : "Steam went offline (not logged on)");
        if (on && c->st == ST_HOSTING) c->backOnline = 1;
    }
    c->loggedOn = on;
    int r = c->f.NU_GetRelayNetworkStatus(c->nu, NULL);
    if (r != c->relay) {
        logf_(c, "Steam relay network: %s (%d)", relay_word(r), r);
        if (r == 100 && !first) c->ownAt = 0;               /* the relay is back: a host asks about its lobby in its next tick (the 3 s rule) */
        c->relay = r;
    }
}

#ifdef COOP_STEAM_MOCK
int mock_bind(Coop *c);                    /* the fake Steam in test/coop_steam_test.c */
static int bind_steam(Coop *c) { return mock_bind(c); }
#else
static int bind_steam(Coop *c)
{
    HMODULE h = GetModuleHandleW(L"steam_api64.dll");     /* the game's copy; never loaded by us */
    if (!h) { go_off(c, "%s", "steam_api64.dll is not loaded in this game (not a Steam copy of the game?)"); return 0; }
    for (size_t i = 0; i < sizeof(k_exports) / sizeof(k_exports[0]); i++) {
        FARPROC p = GetProcAddress(h, k_exports[i].name);
        if (!p && k_exports[i].required) { go_off(c, "steam api mismatch: %s is missing from the game's steam_api64.dll", k_exports[i].name); return 0; }
        if (!p) logf_(c, "optional Steam function %s is missing; that feature is off", k_exports[i].name);
        memcpy((char *)&c->f + k_exports[i].off, &p, sizeof(p));
    }
    return 1;
}
#endif

static int steam_open(Coop *c)
{
    if (!c->f.GetHSteamUser()) { copy_str(c->offReason, sizeof(c->offReason), "the game has not started Steam (was it started outside Steam?)"); return 0; }
    c->user = c->f.SteamUser();
    c->friends = c->f.SteamFriends();
    c->mm = c->f.SteamMatchmaking();
    c->utils = c->f.SteamUtils();
    c->nm = c->f.SteamNetMsgs();
    c->nu = c->f.SteamNetUtils();
    c->apps = c->f.SteamApps ? c->f.SteamApps() : NULL;
    const char *missing = !c->user ? "SteamUser021" : !c->friends ? "SteamFriends017" : !c->mm ? "SteamMatchMaking009" :
                          !c->utils ? "SteamUtils010" : !c->nm ? "SteamNetworkingMessages002" : !c->nu ? "SteamNetworkingUtils004" : NULL;
    if (missing) { snprintf(c->offReason, sizeof(c->offReason), "Steam did not give the %s interface", missing); return 0; }
    return 1;
}

static void steam_ready(Coop *c)
{
    c->steamOk = 1;
    c->st = ST_IDLE;
    c->offReason[0] = 0;
    c->me = c->f.User_GetSteamID(c->user);
    safe_text(c->myName, sizeof(c->myName), c->f.Friends_GetPersonaName(c->friends), 64);
    c->appId = c->f.Utils_GetAppID(c->utils);
    c->buildId = (c->apps && c->f.Apps_GetAppBuildId) ? c->f.Apps_GetAppBuildId(c->apps) : 0;
    register_callbacks(c);
    c->f.NU_InitRelayNetworkAccess(c->nu);
    if (c->f.NU_SetGlobalConfigValueInt32) {
        if (c->sendRateKB > 0) {
            sbool a = c->f.NU_SetGlobalConfigValueInt32(c->nu, k_ESteamNetworkingConfig_SendRateMin, c->sendRateKB * 1024);
            sbool b = c->f.NU_SetGlobalConfigValueInt32(c->nu, k_ESteamNetworkingConfig_SendRateMax, c->sendRateKB * 1024);
            logf_(c, "send rate set to %d KB/s: %d %d", c->sendRateKB, a, b);
        }
        if (c->sendBufKB > 0) logf_(c, "send buffer set to %d KB: %d", c->sendBufKB, c->f.NU_SetGlobalConfigValueInt32(c->nu, k_ESteamNetworkingConfig_SendBufferSize, c->sendBufKB * 1024));
    }
    c->relay = -999;
    refresh_info(c);
    logf_(c, "Steam ready: my id %llu, app id %u, overlay %d, logged on %d, game build %d, game thread %lu",
          (unsigned long long)c->me, c->appId, c->overlay, c->loggedOn, c->buildId, GetCurrentThreadId());
    /* started by Steam from an invite while the game was closed: "+connect_lobby <id>" */
    if (c->cmdline) {
        const wchar_t *p = wcsstr(c->cmdline, L"+connect_lobby");
        if (p) {
            p += 14;
            while (*p == L' ' || *p == L'\t' || *p == L'"') p++;
            uint64_t id = 0;
            int n = 0;
            while (*p >= L'0' && *p <= L'9' && n < 20) { id = id * 10 + (uint64_t)(*p - L'0'); p++; n++; }
            logf_(c, "the command line has +connect_lobby %llu", (unsigned long long)id);
            if (id) start_join(c, id, "+connect_lobby on the command line");
        }
    }
}

static int coop_init(Coop *c)
{
    InitializeCriticalSection(&c->cs);
    if (!c->pathsSet) load_config(c);
    CreateDirectoryW(c->linkDir, NULL);
    DWORD a = GetFileAttributesW(c->linkDir);
    if (a == INVALID_FILE_ATTRIBUTES || !(a & FILE_ATTRIBUTE_DIRECTORY)) {
        char p[MAX_PATH * 3];
        to_utf8(c->linkDir, p, sizeof(p));
        c->linkDir[0] = 0;                      /* nothing can be written: no status, no log */
        c->off = 1; c->st = ST_OFF;
        snprintf(c->offReason, sizeof(c->offReason), "the link folder %s cannot be used", p);
        return 0;
    }
    mirror_init(&c->mirrors[0], L"host");
    for (int s = 1; s <= MAX_FRIENDS; s++) { wchar_t base[16]; _snwprintf(base, 16, L"friend%d", s); mirror_init(&c->mirrors[s], base); }
    /* the command file belongs to this run: anything left from an earlier run is dropped */
    wchar_t cp[MAX_PATH];
    if (link_path(c, L"steam_cmd.txt", cp)) {
        HANDLE h = CreateFileW(cp, GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
        if (h != INVALID_HANDLE_VALUE) { SetEndOfFile(h); CloseHandle(h); }
    }
    tail_init(&c->cmdTail, L"steam_cmd.txt");
    char ld[MAX_PATH * 3], sd[MAX_PATH * 3];
    to_utf8(c->linkDir, ld, sizeof(ld));
    to_utf8(c->saveDir, sd, sizeof(sd));
    logf_(c, "coop_steam %s (protocol %d) started; link folder %s; save transfer %s%s", COOP_STEAM_VERSION, PROTO_VERSION, ld,
          c->haveSaveDir ? "on, save folder " : "off (no savedir in coop_steam.cfg)", c->haveSaveDir ? sd : "");
    if (c->haveSaveDir && GetFileAttributesW(c->saveDir) == INVALID_FILE_ATTRIBUTES) {
        if (CreateDirectoryW(c->saveDir, NULL)) logf_(c, "created the save folder");
        else logf_(c, "note: the save folder does not exist yet");
    }
    c->st = ST_OFF;
    copy_str(c->offReason, sizeof(c->offReason), "waiting for the game to start Steam");
    if (!bind_steam(c)) return 0;
    c->steamGiveUpAt = c->now + STEAM_WAIT_MS;
    c->steamRetryAt = 0;
    return 1;
}

/* one frame of work. Everything happens here, on the game thread. */
CS_STATIC void coop_tick(Coop *c)
{
    c->now = c->clock();
    c->ticks++;
    if (c->logH && c->now - c->logAt >= HANDLE_IDLE_MS) close_h(&c->logH);   /* (lane 65) a quiet log: let go */
    c->phase = "start-up";
    if (!c->started) { c->started = 1; if (!coop_init(c)) { write_status(c, 1); return; } }
    if (c->off) return;
    if (!c->steamOk) {
        if (c->now < c->steamRetryAt) return;
        c->phase = "opening Steam";
        if (steam_open(c)) steam_ready(c);
        else if (c->now >= c->steamGiveUpAt) { char r[256]; copy_str(r, sizeof(r), c->offReason); go_off(c, "%s", r); return; }
        else { c->steamRetryAt = c->now + 2000; write_status(c, 0); return; }
    }
    c->phase = "callback events"; drain_events(c);
    c->phase = "call results"; poll_call(c);
    c->phase = "commands"; tail_read(c, &c->cmdTail, command, NULL, NULL);
    if (c->quitting) { go_off(c, "%s", "stopped by the QUIT command"); return; }
    c->phase = "receiving"; receive_messages(c);
    if (c->st == ST_HOSTING) { c->phase = "host"; host_tick(c); }
    else if (c->st == ST_JOINED) { c->phase = "friend"; friend_tick(c); }
    if (c->inviteWanted) { c->phase = "invite"; invite_step(c); }
    if (c->nclose && c->now >= c->closeAt) {
        c->phase = "closing sessions";
        for (int i = 0; i < c->nclose; i++) {
            int stillPeer = 0;
            for (int s = 0; s <= MAX_FRIENDS; s++) if (c->peers[s].used && c->peers[s].sid == c->closeSids[i]) stillPeer = 1;
            if (!stillPeer) { SteamNetIdentity id; ident(c, &id, c->closeSids[i]); c->f.NM_CloseSessionWithUser(c->nm, &id); }
        }
        c->nclose = 0;
    }
    if (c->now - c->infoAt >= 1000) { c->phase = "info"; refresh_info(c); }
    c->phase = "status"; write_status(c, 0);
}

/* the fault fence: any exception switches the link off for good instead of taking the game down */
CS_STATIC void coop_tick_safe(Coop *c)
{
    DWORD code = 0;
    __try {
        coop_tick(c);
    } __except (code = GetExceptionCode(), EXCEPTION_EXECUTE_HANDLER) {
        c->off = 1;
    }
    if (code) {
        __try {
            go_off(c, "internal fault 0x%08lX during %s; the Steam link switched itself off", code, c->phase ? c->phase : "?");
        } __except (EXCEPTION_EXECUTE_HANDLER) {
        }
    }
}

/* (lane 65, round three) THE FRAME'S ORDER. The mod calls coop_steam_tick FIRST in its frame (what came over Steam is in
 * the mirror files before the mod reads them, the same frame) and coop_steam_flush LAST (what the mod wrote to its own
 * file this frame leaves this frame). The flush only reads this copy's own file and sends what waits: no receive, no
 * lobby work, no status. A mod that calls only coop_steam_tick works as before (one frame later each way). */
CS_STATIC void coop_flush(Coop *c)
{
    if (!c->started || c->off || !c->steamOk) return;
    c->now = c->clock();
    c->phase = "flush";
    if (c->st == ST_HOSTING && !c->lostAt) {                  /* (inside the window the next tick does it, as before) */
        host_own_file(c);
        host_fifo(c);
        for (int s = 1; s <= MAX_FRIENDS; s++) if (c->peers[s].used) send_pending(c, &c->peers[s]);
    } else if (c->st == ST_JOINED) {
        if (c->myTail.active) tail_read(c, &c->myTail, friend_line, friend_shrink, NULL);
        send_pending(c, &c->peers[0]);
    }
}
CS_STATIC void coop_flush_safe(Coop *c)
{
    DWORD code = 0;
    __try {
        coop_flush(c);
    } __except (code = GetExceptionCode(), EXCEPTION_EXECUTE_HANDLER) {
        c->off = 1;
    }
    if (code) {
        __try {
            go_off(c, "internal fault 0x%08lX during %s; the Steam link switched itself off", code, c->phase ? c->phase : "?");
        } __except (EXCEPTION_EXECUTE_HANDLER) {
        }
    }
}

#ifndef COOP_STEAM_MOCK
static Coop g_coop;
static uint64_t real_clock(void) { return GetTickCount64(); }
/* (lane 65) the second export: the end of the mod's frame (see coop_flush) */
__declspec(dllexport) int __cdecl coop_steam_flush(void *L)
{
    (void)L;
    Coop *c = &g_coop;
    if (c->off || c->busy || !c->started) return 0;
    c->busy = 1;
    coop_flush_safe(c);
    c->busy = 0;
    return 0;
}

/* The first export (coop_steam_flush above is the second). lua_CFunction shape; never touches L; always returns 0. */
__declspec(dllexport) int __cdecl coop_steam_tick(void *L)
{
    (void)L;
    Coop *c = &g_coop;
    if (c->off || c->busy) return 0;
    c->busy = 1;
    if (!c->started && !c->clock) {
        /* pin: Lua may close its state and FreeLibrary us, but Steam keeps pointers to our callback objects */
        HMODULE self = NULL;
        GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_PIN, (LPCWSTR)(uintptr_t)&g_coop, &self);
        wchar_t path[MAX_PATH];
        DWORD n = GetModuleFileNameW(self, path, MAX_PATH);
        if (n == 0 || n >= MAX_PATH) wcscpy(path, L".\\coop_steam.dll");
        wchar_t *slash = wcsrchr(path, L'\\');
        if (slash) *slash = 0; else wcscpy(path, L".");
        wcsncpy(c->dllDir, path, MAX_PATH - 1);
        c->clock = real_clock;
        c->cmdline = GetCommandLineW();
    }
    coop_tick_safe(c);
    c->busy = 0;
    return 0;
}
/* no DllMain of our own: with the static CRT (/MT) thread notifications must stay on, so the CRT's default is kept */
#endif
