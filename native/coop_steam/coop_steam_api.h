/* coop_steam_api.h - the few Steamworks flat-API declarations coop_steam.c needs, written by hand.
 *
 * Target: the game's own steam_api64.dll (Engine\Binaries\ThirdParty\Steamworks\Steamv157\Win64), which is an
 * SDK 1.53-era build (SteamUser021, SteamFriends017, SteamMatchmaking009, SteamUtils010, SteamNetworkingMessages002,
 * SteamNetworkingUtils004). No Steamworks SDK file is used or shipped. Every function is looked up by name at run time.
 *
 * Marks (also listed in README.md):
 *   [C] certain: name seen in the DLL's export table, or a layout/value that has been stable in public headers for
 *       many SDK versions.
 *   [U] uncertain: recalled from public headers/docs; the first live run checks it (see the log lines named there).
 *
 * All flat functions use the one x64 calling convention. "this" (the interface pointer) is the first argument.
 * C++ references in the flat API ("const SteamNetworkingIdentity &") are passed as pointers. C++ bool is one byte:
 * declared here as sbool (unsigned char) so nothing depends on how a C compiler treats _Bool.
 */
#ifndef COOP_STEAM_API_H
#define COOP_STEAM_API_H

#include <stdint.h>
#include <stddef.h>

typedef unsigned char sbool;
typedef uint64_t SteamAPICall_t;
typedef int32_t HSteamUser;

/* ---------------------------------------------------------------- opaque interface pointers */
typedef struct ISteamUser ISteamUser;
typedef struct ISteamFriends ISteamFriends;
typedef struct ISteamMatchmaking ISteamMatchmaking;
typedef struct ISteamUtils ISteamUtils;
typedef struct ISteamApps ISteamApps;
typedef struct ISteamNetworkingMessages ISteamNetworkingMessages;
typedef struct ISteamNetworkingUtils ISteamNetworkingUtils;

/* ---------------------------------------------------------------- SteamNetworkingIdentity
 * Real layout (pack 1): int m_eType; int m_cbSize; union { ... char[128] } = 136 bytes [C since SDK 1.46].
 * We never touch its fields from production code: filled with SteamNetworkingIdentity_SetSteamID64 and read with
 * SteamNetworkingIdentity_GetSteamID64 (both exported). The buffer is oversized on purpose. */
#define STEAM_IDENTITY_SIZE 136
typedef struct SteamNetIdentity { uint8_t raw[STEAM_IDENTITY_SIZE]; uint8_t spare[120]; } SteamNetIdentity;

/* ---------------------------------------------------------------- SteamNetworkingMessage_t
 * Only m_pData, m_cbSize, m_identityPeer and m_nChannel are read; the message is freed with the exported
 * SteamAPI_SteamNetworkingMessage_t_Release. Offsets [C] for 1.47..1.53+ on x64 (m_idxLane was added at the end). */
#pragma pack(push, 8)
typedef struct SteamNetworkingMessage_t {
    void *m_pData;                      /* 0   */
    int m_cbSize;                       /* 8   */
    uint32_t m_conn;                    /* 12  */
    uint8_t m_identityPeer[STEAM_IDENTITY_SIZE]; /* 16 (pack-1 struct, 136 bytes) */
    int64_t m_nConnUserData;            /* 152 */
    int64_t m_usecTimeReceived;         /* 160 */
    int64_t m_nMessageNumber;           /* 168 */
    void (*m_pfnFreeData)(struct SteamNetworkingMessage_t *); /* 176 */
    void (*m_pfnRelease)(struct SteamNetworkingMessage_t *);  /* 184 */
    int m_nChannel;                     /* 192 */
    int m_nFlags;                       /* 196 */
    int64_t m_nUserData;                /* 200 */
    uint16_t m_idxLane;                 /* 208 (1.53+) */
    uint16_t m_pad;
} SteamNetworkingMessage_t;
#pragma pack(pop)

/* ---------------------------------------------------------------- callback structs (VALVE_CALLBACK_PACK_LARGE = 8 on Windows) */
#pragma pack(push, 8)
/* LobbyCreated_t, k_iSteamMatchmakingCallbacks + 13 = 513 [U base 500]. Fields [C]. */
typedef struct LobbyCreated_t { int32_t m_eResult; uint64_t m_ulSteamIDLobby; } LobbyCreated_t;
/* LobbyEnter_t, +4 = 504 [U base]. Fields [C]. */
typedef struct LobbyEnter_t { uint64_t m_ulSteamIDLobby; uint32_t m_rgfChatPermissions; sbool m_bLocked; uint32_t m_EChatRoomEnterResponse; } LobbyEnter_t;
/* LobbyChatUpdate_t, +6 = 506 [U base]. Fields [C]. */
typedef struct LobbyChatUpdate_t { uint64_t m_ulSteamIDLobby; uint64_t m_ulSteamIDUserChanged; uint64_t m_ulSteamIDMakingChange; uint32_t m_rgfChatMemberStateChange; } LobbyChatUpdate_t;
/* GameLobbyJoinRequested_t, k_iSteamFriendsCallbacks + 33 = 333 [U base 300]. Two CSteamIDs [C]. */
typedef struct GameLobbyJoinRequested_t { uint64_t m_steamIDLobby; uint64_t m_steamIDFriend; } GameLobbyJoinRequested_t;
/* GameOverlayActivated_t, +31 = 331 [U base]. m_bActive [C]; the two later fields [U] (added around SDK 1.48-1.52). */
typedef struct GameOverlayActivated_t { uint8_t m_bActive; sbool m_bUserInitiated; uint32_t m_nAppID; } GameOverlayActivated_t;
#pragma pack(pop)

/* Callback ids. */
#define CB_GameOverlayActivated     331   /* [U] 300 + 31 */
#define CB_GameLobbyJoinRequested   333   /* [U] 300 + 33 */
#define CB_LobbyEnter               504   /* [U] 500 + 4  */
#define CB_LobbyChatUpdate          506   /* [U] 500 + 6  */
#define CB_LobbyCreated             513   /* [U] 500 + 13 */
#define CB_NetMsgSessionRequest     1251  /* [U] 1250 + 1; payload = SteamNetworkingIdentity (136 bytes) */
#define CB_NetMsgSessionFailed      1252  /* [U] 1250 + 2; payload = SteamNetConnectionInfo_t, only its identity (first 136 bytes) is read */

#define SIZE_NetMsgSessionRequest   136   /* [C] one identity */
#define SIZE_NetMsgSessionFailed    696   /* [U] SteamNetConnectionInfo_t of this era; only used as the advertised size */

/* ---------------------------------------------------------------- constants */
#define k_ELobbyTypePrivate                 0    /* [C] Private 0 (invite only), FriendsOnly 1, Public 2, Invisible 3 */
#define k_ELobbyTypeFriendsOnly             1
#define k_nSteamNetworkingSend_Reliable     8    /* [C] */
#define k_nSteamNetworkingSend_NoNagle      1    /* [C] */
#define k_EResultOK                         1    /* [C] */
#define k_EResultLimitExceeded              25   /* [C] */
#define k_EChatRoomEnterResponseSuccess     1    /* [C] */
#define k_EChatMemberStateChangeEntered     0x01 /* [C] */
#define k_EChatMemberStateChangeLeft        0x02
#define k_EChatMemberStateChangeDisconnected 0x04
#define k_EChatMemberStateChangeKicked      0x08
#define k_EChatMemberStateChangeBanned      0x10
#define k_ESteamNetworkingConfig_SendBufferSize 9   /* [U] only used when coop_steam.cfg asks for it */
#define k_ESteamNetworkingConfig_SendRateMin    10  /* [U] */
#define k_ESteamNetworkingConfig_SendRateMax    11  /* [U] */
/* ESteamNetworkingAvailability [C]: CannotTry -102, Failed -101, Previously -100, Retrying -10, NeverTried 1,
 * Waiting 2, Attempting 3, Current 100. */

/* ---------------------------------------------------------------- the hand-built callback object
 * C++ CCallbackBase (steam_api_common.h, unchanged for many SDKs): vtable pointer, uint8 m_nCallbackFlags at 8,
 * int m_iCallback at 12. vtable: Run(void*), Run(void*, bool, SteamAPICall_t), GetCallbackSizeBytes(). MSVC may
 * order the two Run overloads either way, so the same handler sits in slots 0 and 1 (x64: "this" in RCX, the
 * parameter pointer in RDX in both cases; the extra arguments of the 3-argument form are ignored). Slot 2 returns
 * the size. No virtual destructor. Our own fields follow the base part, like a C++ derived class would. */
typedef struct CoopCallback CoopCallback;
typedef void (*CoopRunFn)(CoopCallback *self, void *param, sbool ioFailure, SteamAPICall_t call);
typedef int (*CoopSizeFn)(CoopCallback *self);
typedef void (*CoopAnyFn)(void);
struct CoopCallback {
    CoopAnyFn *vtable;       /* 0  */
    uint8_t m_nCallbackFlags; /* 8  */
    int m_iCallback;         /* 12 */
    /* --- ours --- */
    int id;
    int size;
    void *owner;             /* the Coop instance */
};

/* ---------------------------------------------------------------- function pointer types (exact export names in the table in coop_steam.c) */
typedef HSteamUser (*PFN_GetHSteamUser)(void);
typedef void (*PFN_RegisterCallback)(CoopCallback *cb, int id);
typedef void (*PFN_UnregisterCallback)(CoopCallback *cb);

typedef ISteamUser *(*PFN_SteamUser)(void);
typedef ISteamFriends *(*PFN_SteamFriends)(void);
typedef ISteamMatchmaking *(*PFN_SteamMatchmaking)(void);
typedef ISteamUtils *(*PFN_SteamUtils)(void);
typedef ISteamApps *(*PFN_SteamApps)(void);
typedef ISteamNetworkingMessages *(*PFN_SteamNetMsgs)(void);
typedef ISteamNetworkingUtils *(*PFN_SteamNetUtils)(void);

typedef uint64_t (*PFN_User_GetSteamID)(ISteamUser *);
typedef sbool (*PFN_User_BLoggedOn)(ISteamUser *);

typedef const char *(*PFN_Friends_GetPersonaName)(ISteamFriends *);
typedef const char *(*PFN_Friends_GetFriendPersonaName)(ISteamFriends *, uint64_t steamID);
typedef sbool (*PFN_Friends_RequestUserInformation)(ISteamFriends *, uint64_t steamID, sbool nameOnly);
typedef void (*PFN_Friends_ActivateInviteDialog)(ISteamFriends *, uint64_t lobbyID);

typedef uint32_t (*PFN_Utils_GetAppID)(ISteamUtils *);
typedef sbool (*PFN_Utils_IsOverlayEnabled)(ISteamUtils *);
typedef sbool (*PFN_Utils_IsAPICallCompleted)(ISteamUtils *, SteamAPICall_t, sbool *failed);
typedef sbool (*PFN_Utils_GetAPICallResult)(ISteamUtils *, SteamAPICall_t, void *out, int cb, int expectedId, sbool *failed);
typedef int (*PFN_Utils_GetAPICallFailureReason)(ISteamUtils *, SteamAPICall_t);

typedef int (*PFN_Apps_GetAppBuildId)(ISteamApps *);

typedef SteamAPICall_t (*PFN_MM_CreateLobby)(ISteamMatchmaking *, int lobbyType, int maxMembers);
typedef SteamAPICall_t (*PFN_MM_JoinLobby)(ISteamMatchmaking *, uint64_t lobby);
typedef void (*PFN_MM_LeaveLobby)(ISteamMatchmaking *, uint64_t lobby);
typedef sbool (*PFN_MM_SetLobbyData)(ISteamMatchmaking *, uint64_t lobby, const char *key, const char *value);
typedef const char *(*PFN_MM_GetLobbyData)(ISteamMatchmaking *, uint64_t lobby, const char *key);
typedef int (*PFN_MM_GetNumLobbyMembers)(ISteamMatchmaking *, uint64_t lobby);
typedef uint64_t (*PFN_MM_GetLobbyMemberByIndex)(ISteamMatchmaking *, uint64_t lobby, int index);
typedef uint64_t (*PFN_MM_GetLobbyOwner)(ISteamMatchmaking *, uint64_t lobby);
/* (lane 62, part two) [U] never called on real Steam yet. Only the lobby's owner may call it, and the new owner must be a
 * member (Steamworks: ISteamMatchmaking::SetLobbyOwner). A friend's copy that got the ownership while the host was out
 * hands it back with this. Optional: without it the host goes on as a member. */
typedef sbool (*PFN_MM_SetLobbyOwner)(ISteamMatchmaking *, uint64_t lobby, uint64_t newOwner);

typedef int (*PFN_NM_SendMessageToUser)(ISteamNetworkingMessages *, const SteamNetIdentity *to, const void *data, uint32_t len, int flags, int channel);
typedef int (*PFN_NM_ReceiveMessagesOnChannel)(ISteamNetworkingMessages *, int channel, SteamNetworkingMessage_t **out, int max);
typedef sbool (*PFN_NM_AcceptSessionWithUser)(ISteamNetworkingMessages *, const SteamNetIdentity *who);
typedef sbool (*PFN_NM_CloseSessionWithUser)(ISteamNetworkingMessages *, const SteamNetIdentity *who);

typedef void (*PFN_NU_InitRelayNetworkAccess)(ISteamNetworkingUtils *);
typedef int (*PFN_NU_GetRelayNetworkStatus)(ISteamNetworkingUtils *, void *detailsOrNull);
typedef sbool (*PFN_NU_SetGlobalConfigValueInt32)(ISteamNetworkingUtils *, int key, int32_t value);

typedef void (*PFN_Identity_SetSteamID64)(SteamNetIdentity *, uint64_t steamID);
typedef uint64_t (*PFN_Identity_GetSteamID64)(const void *identity);
typedef void (*PFN_Message_Release)(SteamNetworkingMessage_t *);

#endif
