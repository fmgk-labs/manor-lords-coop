/* coop_steam_test.c - runs the real coop_steam.c logic against a fake, in-process Steam.
 *
 * Built by build.cmd with /DCOOP_STEAM_MOCK. The same source file is included below; only the Steam function table is
 * different: mock_bind() fills it with the functions in this file. Several "PCs" (nodes) live in one process, each
 * with its own Coop instance and its own temporary link and save folders. Time is virtual (no sleeping).
 * The fake Steam has lobbies, call results, callbacks dispatched through the hand-built callback objects (both vtable
 * slots are used, the size getter is checked), session requests, a send buffer that fills up (k_EResultLimitExceeded),
 * a bandwidth limit and a switch that cuts the network between two nodes.
 * Everything is written under %TEMP%\coop_steam_test_<pid>\ and deleted at the end.
 */
#define COOP_STEAM_MOCK 1
#define DEAD_AFTER_MS 10000  /* the mock scenarios time a silent player out after 10 s; the shipped DLL waits 5 minutes */
#define MAX_FRIENDS 3        /* the mock scenarios are written for 4 players; the shipped DLL builds with 7 friends */
#include "../coop_steam.c"

/* ================================================================ checks */
static int g_pass, g_fail;
static void check(int ok, const char *fmt, ...)
{
    char t[600];
    va_list ap;
    va_start(ap, fmt);
    _vsnprintf(t, sizeof(t) - 1, fmt, ap);
    t[sizeof(t) - 1] = 0;
    va_end(ap);
    if (ok) g_pass++; else g_fail++;
    printf("%s  %s\n", ok ? "PASS" : "FAIL", t);
    fflush(stdout);
}

/* ================================================================ the fake Steam */
typedef struct Node Node;
typedef struct MIface { Node *n; } MIface;
typedef struct Msg { struct Msg *next; uint32_t len; uint8_t *data; } Msg;
typedef struct MQ { Msg *head, *tail; uint64_t bytes; } MQ;
typedef struct MCall { SteamAPICall_t h; int kind; uint64_t lobby; int done, fetched; int resultId; uint8_t result[32]; int resultSize; } MCall;
typedef struct MCb { int id; int size; uint8_t data[200]; } MCb;

struct Node {
    MIface user, friends, mm, utils, apps, nm, nu;
    int idx;
    uint64_t sid;
    char name[64];
    int steamRunning, missingExport, crash, build;
    Coop *c;
    wchar_t base[MAX_PATH], link[MAX_PATH], save[MAX_PATH], cmdline[200];
    CoopCallback *cbs[16];
    int ncbs;
    MQ inbox;
    uint64_t accepted[16];
    int nacc;
    uint64_t requested[16];
    int nreq;
    MCall calls[16];
    int ncalls;
    MCb cbq[128];
    int ncbq;
    int slotToggle, inviteDialogs, faultReported;
};

#define MAXN 16
static Node *g_nodes[MAXN];
static int g_nn;
static Node *g_cur;
static Node *g_skip;             /* a copy whose game thread is busy (it loads a save): its DLL is not ticked */
static uint64_t g_now = 5000000;
static uint64_t g_bw = 2u << 20;           /* bytes delivered per pair per pump */
static uint64_t g_sendCap = 512u << 10;    /* send buffer per pair */
static int g_cut[MAXN][MAXN];
static MQ g_transit[MAXN][MAXN];
static SteamAPICall_t g_callSeq = 100;
static int g_postResultCallbacks = 1;      /* Steam also posts LobbyCreated/LobbyEnter as callbacks */
static int g_callResultsVisible = 1;       /* IsAPICallCompleted / GetAPICallResult work */
static int g_sizeMismatch, g_slot0Calls, g_slot1Calls;
static wchar_t g_root[MAX_PATH];

static uint64_t mock_clock(void) { return g_now; }
static Node *N(const void *iface) { return ((const MIface *)iface)->n; }
static Node *node_by_sid(uint64_t sid) { for (int i = 0; i < g_nn; i++) if (g_nodes[i]->sid == sid) return g_nodes[i]; return NULL; }

typedef struct Lobby { uint64_t id, owner; uint64_t mem[8]; int n, max, alive; char k[16][32]; char v[16][256]; int nkv; } Lobby;
static Lobby g_lobbies[32];
static int g_nl;
static uint64_t g_lobbySeq = 109775240000000000ull;
static Lobby *lobby_get(uint64_t id) { for (int i = 0; i < g_nl; i++) if (g_lobbies[i].alive && g_lobbies[i].id == id) return &g_lobbies[i]; return NULL; }
static int lobby_has(Lobby *l, uint64_t sid) { for (int i = 0; i < l->n; i++) if (l->mem[i] == sid) return 1; return 0; }
static void lobby_set(Lobby *l, const char *k, const char *v)
{
    for (int i = 0; i < l->nkv; i++) if (!strcmp(l->k[i], k)) { copy_str(l->v[i], 256, v); return; }
    if (l->nkv < 16) { copy_str(l->k[l->nkv], 32, k); copy_str(l->v[l->nkv], 256, v); l->nkv++; }
}

static void post_cb(Node *n, int id, const void *data, int size)
{
    if (!n || n->ncbq >= 128) return;
    MCb *e = &n->cbq[n->ncbq++];
    e->id = id; e->size = size;
    memset(e->data, 0, sizeof(e->data));
    memcpy(e->data, data, (size_t)size);
}
static void chat_update(Lobby *l, uint64_t who, uint32_t change)
{
    LobbyChatUpdate_t u; memset(&u, 0, sizeof(u));
    u.m_ulSteamIDLobby = l->id; u.m_ulSteamIDUserChanged = who; u.m_ulSteamIDMakingChange = who; u.m_rgfChatMemberStateChange = change;
    for (int i = 0; i < l->n; i++) post_cb(node_by_sid(l->mem[i]), CB_LobbyChatUpdate, &u, sizeof(u));
}
static void lobby_remove(Lobby *l, uint64_t sid)
{
    int k = 0;
    for (int i = 0; i < l->n; i++) if (l->mem[i] != sid) l->mem[k++] = l->mem[i];
    if (k == l->n) return;
    l->n = k;
    if (l->owner == sid) l->owner = l->n ? l->mem[0] : 0;
    if (!l->n) { l->alive = 0; return; }
    chat_update(l, sid, k_EChatMemberStateChangeLeft);
}

/* --- functions given to coop_steam.c --- */
static HSteamUser m_GetHSteamUser(void) { return (g_cur && g_cur->steamRunning) ? 1 : 0; }
static void m_RegisterCallback(CoopCallback *cb, int id) { cb->m_nCallbackFlags |= 1; cb->m_iCallback = id; if (g_cur->ncbs < 16) g_cur->cbs[g_cur->ncbs++] = cb; }
static ISteamUser *m_SteamUser(void) { return g_cur->steamRunning ? (ISteamUser *)&g_cur->user : NULL; }
static ISteamFriends *m_SteamFriends(void) { return g_cur->steamRunning ? (ISteamFriends *)&g_cur->friends : NULL; }
static ISteamMatchmaking *m_SteamMatchmaking(void) { return g_cur->steamRunning ? (ISteamMatchmaking *)&g_cur->mm : NULL; }
static ISteamUtils *m_SteamUtils(void) { return g_cur->steamRunning ? (ISteamUtils *)&g_cur->utils : NULL; }
static ISteamApps *m_SteamApps(void) { return g_cur->steamRunning ? (ISteamApps *)&g_cur->apps : NULL; }
static ISteamNetworkingMessages *m_SteamNetMsgs(void) { return g_cur->steamRunning ? (ISteamNetworkingMessages *)&g_cur->nm : NULL; }
static ISteamNetworkingUtils *m_SteamNetUtils(void) { return g_cur->steamRunning ? (ISteamNetworkingUtils *)&g_cur->nu : NULL; }
static uint64_t m_GetSteamID(ISteamUser *u) { return N(u)->sid; }
static sbool m_BLoggedOn(ISteamUser *u) { (void)u; return 1; }
static const char *m_GetPersonaName(ISteamFriends *f) { return N(f)->name; }
static const char *m_GetFriendPersonaName(ISteamFriends *f, uint64_t sid) { (void)f; Node *o = node_by_sid(sid); return o ? o->name : "[unknown]"; }
static sbool m_RequestUserInformation(ISteamFriends *f, uint64_t sid, sbool nameOnly) { (void)f; (void)sid; (void)nameOnly; return 0; }
static void m_ActivateInviteDialog(ISteamFriends *f, uint64_t lobby) { (void)lobby; N(f)->inviteDialogs++; }
static uint32_t m_GetAppID(ISteamUtils *u) { if (N(u)->crash) { volatile int *p = NULL; *p = 1; } return 1363080; }
static sbool m_IsOverlayEnabled(ISteamUtils *u) { (void)u; return 1; }
static MCall *find_call(Node *n, SteamAPICall_t h) { for (int i = 0; i < n->ncalls; i++) if (n->calls[i].h == h) return &n->calls[i]; return NULL; }
static sbool m_IsAPICallCompleted(ISteamUtils *u, SteamAPICall_t h, sbool *failed)
{
    MCall *k = find_call(N(u), h);
    if (failed) *failed = 0;
    return (sbool)(g_callResultsVisible && k && k->done && !k->fetched);
}
static sbool m_GetAPICallResult(ISteamUtils *u, SteamAPICall_t h, void *out, int cb, int id, sbool *failed)
{
    MCall *k = find_call(N(u), h);
    if (!g_callResultsVisible || !k || !k->done || k->fetched) { if (failed) *failed = 1; return 0; }
    if (cb != k->resultSize || id != k->resultId) { g_sizeMismatch++; if (failed) *failed = 1; return 0; }
    memcpy(out, k->result, (size_t)cb);
    k->fetched = 1;
    if (failed) *failed = 0;
    return 1;
}
static int m_GetAPICallFailureReason(ISteamUtils *u, SteamAPICall_t h) { (void)u; (void)h; return 3; }
static int m_GetAppBuildId(ISteamApps *a) { return N(a)->build; }
static SteamAPICall_t m_CreateLobby(ISteamMatchmaking *mm, int type, int max)
{
    Node *n = N(mm);
    (void)type;
    MCall *k = &n->calls[n->ncalls++ % 16];
    memset(k, 0, sizeof(*k));
    k->h = ++g_callSeq; k->kind = 1; k->lobby = (uint64_t)max;
    return k->h;
}
static SteamAPICall_t m_JoinLobby(ISteamMatchmaking *mm, uint64_t lobby)
{
    Node *n = N(mm);
    MCall *k = &n->calls[n->ncalls++ % 16];
    memset(k, 0, sizeof(*k));
    k->h = ++g_callSeq; k->kind = 2; k->lobby = lobby;
    return k->h;
}
static void m_LeaveLobby(ISteamMatchmaking *mm, uint64_t lobby) { Lobby *l = lobby_get(lobby); if (l) lobby_remove(l, N(mm)->sid); }
static sbool m_SetLobbyData(ISteamMatchmaking *mm, uint64_t lobby, const char *k, const char *v)
{
    Lobby *l = lobby_get(lobby);
    if (!l || l->owner != N(mm)->sid) return 0;
    lobby_set(l, k, v);
    return 1;
}
static const char *m_GetLobbyData(ISteamMatchmaking *mm, uint64_t lobby, const char *k)
{
    (void)mm;
    Lobby *l = lobby_get(lobby);
    if (!l) return "";
    for (int i = 0; i < l->nkv; i++) if (!strcmp(l->k[i], k)) return l->v[i];
    return "";
}
static int m_GetNumLobbyMembers(ISteamMatchmaking *mm, uint64_t lobby) { Lobby *l = lobby_get(lobby); return (l && lobby_has(l, N(mm)->sid)) ? l->n : 0; }
static uint64_t m_GetLobbyMemberByIndex(ISteamMatchmaking *mm, uint64_t lobby, int i) { Lobby *l = lobby_get(lobby); return (l && lobby_has(l, N(mm)->sid) && i >= 0 && i < l->n) ? l->mem[i] : 0; }
static uint64_t m_GetLobbyOwner(ISteamMatchmaking *mm, uint64_t lobby) { Lobby *l = lobby_get(lobby); return (l && lobby_has(l, N(mm)->sid)) ? l->owner : 0; }
static void m_SetSteamID64(SteamNetIdentity *id, uint64_t sid) { int32_t t = 16, s = 8; memcpy(id->raw, &t, 4); memcpy(id->raw + 4, &s, 4); memcpy(id->raw + 8, &sid, 8); }
static uint64_t m_GetSteamID64(const void *p) { int32_t t; uint64_t s; memcpy(&t, p, 4); memcpy(&s, (const uint8_t *)p + 8, 8); return t == 16 ? s : 0; }
static int accepted(Node *n, uint64_t sid) { for (int i = 0; i < n->nacc; i++) if (n->accepted[i] == sid) return 1; return 0; }
static void accept(Node *n, uint64_t sid) { if (!accepted(n, sid) && n->nacc < 16) n->accepted[n->nacc++] = sid; }
static void mq_push(MQ *q, const void *d, uint32_t len)
{
    Msg *m = (Msg *)calloc(1, sizeof(Msg));
    m->data = (uint8_t *)malloc(len ? len : 1);
    memcpy(m->data, d, len);
    m->len = len;
    if (q->tail) q->tail->next = m; else q->head = m;
    q->tail = m;
    q->bytes += len;
}
static Msg *mq_pop(MQ *q)
{
    Msg *m = q->head;
    if (!m) return NULL;
    q->head = m->next;
    if (!q->head) q->tail = NULL;
    q->bytes -= m->len;
    m->next = NULL;
    return m;
}
static void mq_clear(MQ *q) { Msg *m; while ((m = mq_pop(q)) != NULL) { free(m->data); free(m); } }
static int m_SendMessageToUser(ISteamNetworkingMessages *nm, const SteamNetIdentity *to, const void *data, uint32_t len, int flags, int ch)
{
    Node *a = N(nm);
    Node *b = node_by_sid(m_GetSteamID64(to->raw));
    if (ch != 0 || !(flags & k_nSteamNetworkingSend_Reliable)) return 8;
    if (!b) return 3;
    accept(a, b->sid);                      /* sending implicitly accepts that peer */
    if (g_cut[a->idx][b->idx]) return k_EResultOK;
    MQ *q = &g_transit[a->idx][b->idx];
    if (q->bytes + len > g_sendCap) return k_EResultLimitExceeded;
    /* the wire carries: 8 bytes sender id, then the payload */
    uint8_t *w = (uint8_t *)malloc(len + 8);
    memcpy(w, &a->sid, 8);
    memcpy(w + 8, data, len);
    mq_push(q, w, len + 8);
    free(w);
    return k_EResultOK;
}
static void m_free_msg(SteamNetworkingMessage_t *m) { free(m->m_pData); free(m); }
static int m_ReceiveMessagesOnChannel(ISteamNetworkingMessages *nm, int ch, SteamNetworkingMessage_t **out, int max)
{
    Node *n = N(nm);
    int k = 0;
    if (ch != 0) return 0;
    while (k < max && n->inbox.head) {
        Msg *m = mq_pop(&n->inbox);
        SteamNetworkingMessage_t *s = (SteamNetworkingMessage_t *)calloc(1, sizeof(*s));
        uint64_t from; memcpy(&from, m->data, 8);
        s->m_cbSize = (int)(m->len - 8);
        s->m_pData = malloc(m->len - 8 ? m->len - 8 : 1);
        memcpy(s->m_pData, m->data + 8, m->len - 8);
        SteamNetIdentity id; m_SetSteamID64(&id, from);
        memcpy(s->m_identityPeer, id.raw, STEAM_IDENTITY_SIZE);
        s->m_nChannel = 0;
        s->m_pfnRelease = m_free_msg;
        out[k++] = s;
        free(m->data); free(m);
    }
    return k;
}
static sbool m_AcceptSessionWithUser(ISteamNetworkingMessages *nm, const SteamNetIdentity *who) { accept(N(nm), m_GetSteamID64(who->raw)); return 1; }
static sbool m_CloseSessionWithUser(ISteamNetworkingMessages *nm, const SteamNetIdentity *who)
{
    Node *n = N(nm);
    uint64_t sid = m_GetSteamID64(who->raw);
    int k = 0;
    for (int i = 0; i < n->nacc; i++) if (n->accepted[i] != sid) n->accepted[k++] = n->accepted[i];
    n->nacc = k;
    k = 0;
    for (int i = 0; i < n->nreq; i++) if (n->requested[i] != sid) n->requested[k++] = n->requested[i];
    n->nreq = k;
    return 1;
}
static void m_InitRelay(ISteamNetworkingUtils *nu) { (void)nu; }
static int m_GetRelayStatus(ISteamNetworkingUtils *nu, void *d) { (void)nu; (void)d; return 100; }
static sbool m_SetGlobalConfigValueInt32(ISteamNetworkingUtils *nu, int k, int32_t v) { (void)nu; (void)k; (void)v; return 1; }
static void m_Release(SteamNetworkingMessage_t *m) { m->m_pfnRelease(m); }

int mock_bind(Coop *c)
{
    Node *n = g_cur;
    if (n->missingExport) { go_off(c, "steam api mismatch: %s is missing from the game's steam_api64.dll", "SteamAPI_SteamNetworkingMessages_SteamAPI_v002"); return 0; }
    SteamFns *f = &c->f;
    f->GetHSteamUser = m_GetHSteamUser; f->RegisterCallback = m_RegisterCallback;
    f->SteamUser = m_SteamUser; f->SteamFriends = m_SteamFriends; f->SteamMatchmaking = m_SteamMatchmaking; f->SteamUtils = m_SteamUtils;
    f->SteamApps = m_SteamApps; f->SteamNetMsgs = m_SteamNetMsgs; f->SteamNetUtils = m_SteamNetUtils;
    f->User_GetSteamID = m_GetSteamID; f->User_BLoggedOn = m_BLoggedOn;
    f->Friends_GetPersonaName = m_GetPersonaName; f->Friends_GetFriendPersonaName = m_GetFriendPersonaName;
    f->Friends_RequestUserInformation = m_RequestUserInformation; f->Friends_ActivateInviteDialog = m_ActivateInviteDialog;
    f->Utils_GetAppID = m_GetAppID; f->Utils_IsOverlayEnabled = m_IsOverlayEnabled; f->Utils_IsAPICallCompleted = m_IsAPICallCompleted;
    f->Utils_GetAPICallResult = m_GetAPICallResult; f->Utils_GetAPICallFailureReason = m_GetAPICallFailureReason;
    f->Apps_GetAppBuildId = m_GetAppBuildId;
    f->MM_CreateLobby = m_CreateLobby; f->MM_JoinLobby = m_JoinLobby; f->MM_LeaveLobby = m_LeaveLobby; f->MM_SetLobbyData = m_SetLobbyData;
    f->MM_GetLobbyData = m_GetLobbyData; f->MM_GetNumLobbyMembers = m_GetNumLobbyMembers; f->MM_GetLobbyMemberByIndex = m_GetLobbyMemberByIndex;
    f->MM_GetLobbyOwner = m_GetLobbyOwner;
    f->NM_SendMessageToUser = m_SendMessageToUser; f->NM_ReceiveMessagesOnChannel = m_ReceiveMessagesOnChannel;
    f->NM_AcceptSessionWithUser = m_AcceptSessionWithUser; f->NM_CloseSessionWithUser = m_CloseSessionWithUser;
    f->NU_InitRelayNetworkAccess = m_InitRelay; f->NU_GetRelayNetworkStatus = m_GetRelayStatus; f->NU_SetGlobalConfigValueInt32 = m_SetGlobalConfigValueInt32;
    f->Identity_SetSteamID64 = m_SetSteamID64; f->Identity_GetSteamID64 = m_GetSteamID64; f->Message_Release = m_Release;
    return 1;
}

static int expected_size(int id)
{
    switch (id) {
    case CB_LobbyCreated: return 16; case CB_LobbyEnter: return 24; case CB_LobbyChatUpdate: return 32;
    case CB_GameLobbyJoinRequested: return 16; case CB_GameOverlayActivated: return 8;
    case CB_NetMsgSessionRequest: return 136; case CB_NetMsgSessionFailed: return 696;
    }
    return -1;
}

/* one "frame" of the fake Steam: finish calls, move messages, run callbacks */
static void mock_pump(void)
{
    for (int i = 0; i < g_nn; i++) {
        Node *n = g_nodes[i];
        for (int j = 0; j < n->ncalls && j < 16; j++) {
            MCall *k = &n->calls[j];
            if (k->done || !k->h) continue;
            k->done = 1;
            if (k->kind == 1) {
                Lobby *l = &g_lobbies[g_nl++];
                memset(l, 0, sizeof(*l));
                l->id = ++g_lobbySeq; l->owner = n->sid; l->mem[0] = n->sid; l->n = 1; l->max = (int)k->lobby; l->alive = 1;
                LobbyCreated_t r; memset(&r, 0, sizeof(r)); r.m_eResult = 1; r.m_ulSteamIDLobby = l->id;
                memcpy(k->result, &r, sizeof(r)); k->resultSize = sizeof(r); k->resultId = CB_LobbyCreated;
                if (g_postResultCallbacks) {
                    post_cb(n, CB_LobbyCreated, &r, sizeof(r));
                    LobbyEnter_t e; memset(&e, 0, sizeof(e)); e.m_ulSteamIDLobby = l->id; e.m_EChatRoomEnterResponse = 1;
                    post_cb(n, CB_LobbyEnter, &e, sizeof(e));
                }
            } else {
                Lobby *l = lobby_get(k->lobby);
                LobbyEnter_t e; memset(&e, 0, sizeof(e)); e.m_ulSteamIDLobby = k->lobby;
                if (!l) e.m_EChatRoomEnterResponse = 2;
                else if (l->n >= l->max) e.m_EChatRoomEnterResponse = 4;
                else {
                    e.m_EChatRoomEnterResponse = 1;
                    if (!lobby_has(l, n->sid)) { l->mem[l->n++] = n->sid; chat_update(l, n->sid, k_EChatMemberStateChangeEntered); }
                }
                memcpy(k->result, &e, sizeof(e)); k->resultSize = sizeof(e); k->resultId = CB_LobbyEnter;
                if (g_postResultCallbacks) post_cb(n, CB_LobbyEnter, &e, sizeof(e));
            }
        }
    }
    for (int a = 0; a < g_nn; a++) for (int b = 0; b < g_nn; b++) {
        MQ *q = &g_transit[a][b];
        if (g_cut[a][b]) { mq_clear(q); continue; }
        uint64_t budget = g_bw;
        Node *dst = g_nodes[b], *src = g_nodes[a];
        while (q->head && budget > 0) {
            if (!accepted(dst, src->sid)) {
                int asked = 0;
                for (int i = 0; i < dst->nreq; i++) if (dst->requested[i] == src->sid) asked = 1;
                if (!asked && dst->nreq < 16) {
                    dst->requested[dst->nreq++] = src->sid;
                    SteamNetIdentity id; m_SetSteamID64(&id, src->sid);
                    post_cb(dst, CB_NetMsgSessionRequest, id.raw, STEAM_IDENTITY_SIZE);
                }
                break;          /* held until accepted */
            }
            Msg *m = mq_pop(q);
            budget = m->len >= budget ? 0 : budget - m->len;
            mq_push(&dst->inbox, m->data, m->len);
            free(m->data); free(m);
        }
    }
    for (int i = 0; i < g_nn; i++) {
        Node *n = g_nodes[i];
        int cnt = n->ncbq;
        n->ncbq = 0;
        for (int e = 0; e < cnt; e++) {
            MCb *ev = &n->cbq[e];
            for (int k = 0; k < n->ncbs; k++) {
                CoopCallback *cb = n->cbs[k];
                if (cb->m_iCallback != ev->id) continue;
                int sz = ((CoopSizeFn)cb->vtable[2])(cb);
                if (sz != expected_size(ev->id)) g_sizeMismatch++;
                n->slotToggle ^= 1;
                if (n->slotToggle) { ((CoopRunFn)cb->vtable[0])(cb, ev->data, 1, (SteamAPICall_t)0xdeadbeef); g_slot0Calls++; }
                else { ((CoopRunFn)cb->vtable[1])(cb, ev->data, 0, 0); g_slot1Calls++; }
            }
        }
    }
}

/* ================================================================ nodes, files, time */
static void wjoin(wchar_t *out, const wchar_t *a, const wchar_t *b) { _snwprintf(out, MAX_PATH, L"%s\\%s", a, b); }
static void lpath(Node *n, const wchar_t *leaf, wchar_t *out) { wjoin(out, n->link, leaf); }
static void spath(Node *n, const wchar_t *leaf, wchar_t *out) { wjoin(out, n->save, leaf); }

static Node *node_new(const char *name, uint64_t sid)
{
    Node *n = (Node *)calloc(1, sizeof(Node));
    n->user.n = n->friends.n = n->mm.n = n->utils.n = n->apps.n = n->nm.n = n->nu.n = n;
    n->idx = g_nn;
    n->sid = sid;
    copy_str(n->name, sizeof(n->name), name);
    n->steamRunning = 1;
    n->build = 17000001;
    wchar_t wn[64]; _snwprintf(wn, 64, L"node%d", g_nn);
    wjoin(n->base, g_root, wn);
    CreateDirectoryW(n->base, NULL);
    wjoin(n->link, n->base, L"link");
    wjoin(n->save, n->base, L"save");
    CreateDirectoryW(n->link, NULL);
    CreateDirectoryW(n->save, NULL);
    wcscpy(n->cmdline, L"ManorLords-Win64-Shipping.exe -steam");
    g_nodes[g_nn++] = n;
    return n;
}
static void node_start(Node *n)
{
    Coop *c = (Coop *)calloc(1, sizeof(Coop));
    wcscpy(c->linkDir, n->link);
    wcscpy(c->saveDir, n->save);
    c->haveSaveDir = 1;
    c->pathsSet = 1;
    c->clock = mock_clock;
    c->cmdline = n->cmdline;
    n->c = c;
}

static void (*g_after_step)(void);     /* the turnover test's readers (lane 33) */
static void step_once(void)
{
    g_now += 16;
    mock_pump();
    for (int i = 0; i < g_nn; i++) {
        Node *n = g_nodes[i];
        if (!n->c || n == g_skip) continue;
        g_cur = n;
        coop_tick_safe(n->c);
        if (n->c->off && strstr(n->c->offReason, "internal fault") && !n->crash && !n->faultReported) {
            n->faultReported = 1;
            check(0, "%s switched itself off after a fault: %s", n->name, n->c->offReason);
        }
    }
    g_cur = NULL;
    if (g_after_step) g_after_step();
}
static void run_ms(uint64_t ms) { uint64_t end = g_now + ms; while (g_now < end) step_once(); }

static char *read_all(const wchar_t *p, size_t *len)
{
    HANDLE h = CreateFileW(p, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_EXISTING, 0, NULL);
    if (h == INVALID_HANDLE_VALUE) { if (len) *len = 0; return NULL; }
    LARGE_INTEGER sz; GetFileSizeEx(h, &sz);
    char *b = (char *)malloc((size_t)sz.QuadPart + 1);
    DWORD got = 0;
    if (sz.QuadPart) ReadFile(h, b, (DWORD)sz.QuadPart, &got, NULL);
    b[got] = 0;
    CloseHandle(h);
    if (len) *len = got;
    return b;
}
static void append_file(const wchar_t *p, const void *d, size_t n)
{
    HANDLE h = CreateFileW(p, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_ALWAYS, 0, NULL);
    DWORD w = 0;
    WriteFile(h, d, (DWORD)n, &w, NULL);
    CloseHandle(h);
}
static void truncate_file(const wchar_t *p)
{
    HANDLE h = CreateFileW(p, GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_ALWAYS, 0, NULL);
    SetEndOfFile(h);
    CloseHandle(h);
}
static void write_file(const wchar_t *p, const void *d, size_t n)
{
    HANDLE h = CreateFileW(p, GENERIC_WRITE, FILE_SHARE_READ, NULL, CREATE_ALWAYS, 0, NULL);
    DWORD w = 0;
    WriteFile(h, d, (DWORD)n, &w, NULL);
    CloseHandle(h);
}
static void append_line(Node *n, const wchar_t *leaf, const char *line)
{
    wchar_t p[MAX_PATH]; lpath(n, leaf, p);
    char b[200000];
    int k = snprintf(b, sizeof(b), "%s\n", line);
    append_file(p, b, (size_t)k);
}
static void cmd(Node *n, const char *text)
{
    wchar_t p[MAX_PATH]; lpath(n, L"steam_cmd.txt", p);
    char b[256]; int k = snprintf(b, sizeof(b), "%s\n", text);
    append_file(p, b, (size_t)k);
}
static char *status(Node *n) { wchar_t p[MAX_PATH]; lpath(n, L"steam_status.txt", p); char *s = read_all(p, NULL); return s ? s : _strdup(""); }
static int status_starts(Node *n, const char *prefix) { char *s = status(n); int r = strncmp(s, prefix, strlen(prefix)) == 0; free(s); return r; }
static int status_has(Node *n, const char *needle) { char *s = status(n); int r = strstr(s, needle) != NULL; free(s); return r; }
static int file_has(Node *n, const wchar_t *leaf, const char *needle) { wchar_t p[MAX_PATH]; lpath(n, leaf, p); char *s = read_all(p, NULL); int r = s && strstr(s, needle); free(s); return r; }
static int log_has(Node *n, const char *needle) { return file_has(n, L"coop_steam.log", needle); }
static int wait_for(int (*cond)(void *), void *ctx, uint64_t maxMs)
{
    uint64_t end = g_now + maxMs;
    while (g_now < end) { if (cond(ctx)) return 1; step_once(); }
    return cond(ctx);
}
typedef struct SP { Node *n; const char *s; const wchar_t *leaf; } SP;
static int c_status_starts(void *x) { SP *p = (SP *)x; return status_starts(p->n, p->s); }
static int c_status_has(void *x) { SP *p = (SP *)x; return status_has(p->n, p->s); }
static int c_file_has(void *x) { SP *p = (SP *)x; return file_has(p->n, p->leaf, p->s); }
static int wait_status(Node *n, const char *prefix, uint64_t ms) { SP p = { n, prefix, NULL }; return wait_for(c_status_starts, &p, ms); }
static int wait_status_has(Node *n, const char *needle, uint64_t ms) { SP p = { n, needle, NULL }; return wait_for(c_status_has, &p, ms); }
static int wait_file_has(Node *n, const wchar_t *leaf, const char *needle, uint64_t ms) { SP p = { n, needle, leaf }; return wait_for(c_file_has, &p, ms); }

/* split a file into lines (caller frees lines[0] block and the array) */
static int file_lines(Node *n, const wchar_t *leaf, char ***out)
{
    wchar_t p[MAX_PATH]; lpath(n, leaf, p);
    char *s = read_all(p, NULL);
    int cap = 64, k = 0;
    char **v = (char **)malloc(sizeof(char *) * (size_t)cap);
    if (s) {
        char *ctx = NULL;
        for (char *t = strtok_s(s, "\n", &ctx); t; t = strtok_s(NULL, "\n", &ctx)) {
            if (k + 1 >= cap) { cap *= 2; v = (char **)realloc(v, sizeof(char *) * (size_t)cap); }
            v[k++] = t;
        }
    }
    v[k] = NULL;
    if (k == 0) { free(s); v[0] = NULL; }
    *out = v;
    return k;
}
static void free_lines(char **v, int k) { if (k > 0) free(v[0]); free(v); }

static uint32_t g_rng = 12345;
static void fill_random(uint8_t *d, size_t n) { for (size_t i = 0; i < n; i++) { g_rng ^= g_rng << 13; g_rng ^= g_rng >> 17; g_rng ^= g_rng << 5; d[i] = (uint8_t)g_rng; } }
static void make_save(Node *n, const char *name, size_t size)
{
    wchar_t wn[80], p[MAX_PATH];
    to_wide(name, wn, 80);
    spath(n, wn, p);
    uint8_t *d = (uint8_t *)malloc(size ? size : 1);
    fill_random(d, size);
    write_file(p, d, size);
    free(d);
}
static int same_file(Node *a, Node *b, const char *name)
{
    wchar_t wn[80], pa[MAX_PATH], pb[MAX_PATH];
    to_wide(name, wn, 80);
    spath(a, wn, pa); spath(b, wn, pb);
    char ha[65], hb[65];
    if (!sha_file(pa, ha) || !sha_file(pb, hb)) return 0;
    return strcmp(ha, hb) == 0;
}
static int save_exists(Node *n, const wchar_t *leaf) { wchar_t p[MAX_PATH]; spath(n, leaf, p); return GetFileAttributesW(p) != INVALID_FILE_ATTRIBUTES; }

static void rm_tree(const wchar_t *dir)
{
    wchar_t pat[MAX_PATH]; wjoin(pat, dir, L"*");
    WIN32_FIND_DATAW fd;
    HANDLE h = FindFirstFileW(pat, &fd);
    if (h != INVALID_HANDLE_VALUE) {
        do {
            if (!wcscmp(fd.cFileName, L".") || !wcscmp(fd.cFileName, L"..")) continue;
            wchar_t p[MAX_PATH]; wjoin(p, dir, fd.cFileName);
            if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) rm_tree(p); else { SetFileAttributesW(p, FILE_ATTRIBUTE_NORMAL); DeleteFileW(p); }
        } while (FindNextFileW(h, &fd));
        FindClose(h);
    }
    RemoveDirectoryW(dir);
}

/* ================================================================ the save check that runs every step */
typedef struct SaveWatch { Node *host; Node *fr[3]; int nfr; const char *line; const char *files[10]; int nfiles; int seen[3]; int okAtSight[3]; } SaveWatch;
static int c_save_watch(void *x)
{
    SaveWatch *w = (SaveWatch *)x;
    int all = 1;
    for (int i = 0; i < w->nfr; i++) {
        if (w->seen[i]) continue;
        if (file_has(w->fr[i], L"host.txt", w->line)) {
            w->seen[i] = 1;
            int ok = 1;
            for (int k = 0; k < w->nfiles; k++) if (!same_file(w->host, w->fr[i], w->files[k])) ok = 0;
            w->okAtSight[i] = ok;
        } else all = 0;
    }
    return all;
}

/* ================================================================ link file turnover (lane 33) */
static void tw_path(Node *n, const wchar_t *base, int seg, wchar_t *out) { wchar_t leaf[32]; seg_leaf(base, seg, leaf); lpath(n, leaf, out); }
static int tw_exists(Node *n, const wchar_t *base, int seg) { wchar_t p[MAX_PATH]; tw_path(n, base, seg, p); return GetFileAttributesW(p) != INVALID_FILE_ATTRIBUTES; }

/* a writer that does what the mod's coop.lua does (send, cut, start again) */
typedef struct TW { Node *n; const wchar_t *base; int seg, seq; } TW;
static void tw_line(TW *w, const char *text)
{
    wchar_t p[MAX_PATH]; tw_path(w->n, w->base, w->seg, p);
    char b[300]; int k = snprintf(b, sizeof(b), "%d 7.000 %s\n", ++w->seq, text);
    append_file(p, b, (size_t)k);
}
static void tw_cut(TW *w)
{
    int k = w->seg + 1;
    wchar_t p[MAX_PATH];
    tw_path(w->n, w->base, k, p); write_file(p, "", 0);                 /* the next file first ... */
    char t[40]; snprintf(t, sizeof(t), "~NEXT %d", k); tw_line(w, t);   /* ... then the line that points to it */
    w->seg = k;
}
/* what the mod does 30 s after its last turnover: two files are kept before the current one, older ones deleted, and
 * the first file becomes a pointer to the oldest file kept */
static void tw_cleanup(TW *w)
{
    wchar_t p[MAX_PATH];
    for (int j = 2; j <= w->seg - 3; j++) { tw_path(w->n, w->base, j, p); DeleteFileW(p); }
    if (w->seg - 2 >= 2) { tw_path(w->n, w->base, 1, p); char s[40]; int sn = snprintf(s, sizeof(s), "0 0.000 ~NEXT %d\n", w->seg - 2); write_file(p, s, (size_t)sn); }
}
static void tw_restart(TW *w)
{
    wchar_t p[MAX_PATH]; tw_path(w->n, w->base, 1, p); truncate_file(p);   /* empty the first file, then delete the rest */
    int left[8]; seg_delete_numbered(w->n->c, w->base, left, 8);
    w->seg = 1;
}

/* a reader that does what the mod's recv() does: from an offset, following "~NEXT" lines; a gone file with no later one
 * and the first file there = the writer started again. Lines "X tov <id>" are counted: each id once and in order. */
typedef struct TR { Node *n; const wchar_t *base; int seg; uint64_t off; Buf part; int next, dup, gap, moves, restarts, lost, markSeg; uint64_t markOff; } TR;
static TR *g_tr[8];
static int g_ntr;
static void tr_line(TR *r, const uint8_t *d, size_t l, uint64_t endPos)
{
    char t[320];
    if (l >= sizeof(t)) return;
    memcpy(t, d, l); t[l] = 0;
    const char *q = strstr(t, " X tov ");
    if (q) { int id = atoi(q + 7); if (id == r->next) r->next++; else if (id < r->next) r->dup++; else { r->gap++; r->next = id + 1; } }
    if (strstr(t, " J MARK tov")) { r->markSeg = r->seg; r->markOff = endPos; }
}
static void tr_poll(TR *r)
{
    for (int hop = 0; hop < 8; hop++) {
        wchar_t p[MAX_PATH]; tw_path(r->n, r->base, r->seg, p);
        HANDLE h = CreateFileW(p, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_EXISTING, 0, NULL);
        if (h == INVALID_HANDLE_VALUE) {
            if (r->seg <= 1) return;
            int nx = 0;
            for (int j = r->seg + 1; j <= r->seg + 64 && !nx; j++) if (tw_exists(r->n, r->base, j)) nx = j;
            if (nx) { r->lost++; r->seg = nx; r->off = 0; r->part.n = 0; continue; }
            if (tw_exists(r->n, r->base, 1)) { r->restarts++; r->seg = 1; r->off = 0; r->part.n = 0; continue; }
            return;
        }
        LARGE_INTEGER sz; GetFileSizeEx(h, &sz);
        uint64_t len = (uint64_t)sz.QuadPart;
        if (len < r->off) { r->restarts++; r->off = 0; r->part.n = 0; }
        uint64_t start = r->off - r->part.n;
        if (len > r->off) {
            buf_reserve(&r->part, r->part.n + (size_t)(len - r->off) + 1);
            LARGE_INTEGER pos; pos.QuadPart = (LONGLONG)r->off;
            DWORD got = 0;
            SetFilePointerEx(h, pos, NULL, FILE_BEGIN);
            ReadFile(h, r->part.p + r->part.n, (DWORD)(len - r->off), &got, NULL);
            r->part.n += got; r->off += got;
        }
        CloseHandle(h);
        size_t at = 0;
        int moved = 0;
        for (;;) {
            uint8_t *nl = r->part.n > at ? (uint8_t *)memchr(r->part.p + at, '\n', r->part.n - at) : NULL;
            if (!nl) break;
            size_t e = (size_t)(nl - r->part.p);
            int k = next_marker(r->part.p + at, (uint32_t)(e - at));
            if (k > r->seg) { r->moves++; r->seg = k; r->off = 0; r->part.n = 0; moved = 1; break; }
            tr_line(r, r->part.p + at, e - at, start + e + 1);
            at = e + 1;
        }
        if (moved) continue;
        if (at) { memmove(r->part.p, r->part.p + at, r->part.n - at); r->part.n -= at; }
        return;
    }
}
static void tr_start(TR *r, Node *n, const wchar_t *base)
{
    memset(r, 0, sizeof(*r));
    r->n = n; r->base = base;
    r->seg = seg_last(n->c, base);
    wchar_t p[MAX_PATH]; tw_path(n, base, r->seg, p);
    size_t len = 0; free(read_all(p, &len));
    r->off = len;
}
/* the readers run every step, like the mod reads every frame; a copy whose game thread is busy (g_skip) reads nothing */
static void tr_poll_all(void) { for (int i = 0; i < g_ntr; i++) if (g_tr[i]->n != g_skip) tr_poll(g_tr[i]); }
typedef struct TRW { TR *r; int want; } TRW;
static int c_tr_next(void *x) { TRW *w = (TRW *)x; return w->r->next >= w->want; }
static int wait_tr(TR *r, int want, uint64_t ms) { TRW w = { r, want }; return wait_for(c_tr_next, &w, ms); }
static int file_text_is(Node *n, const wchar_t *leaf, const char *text) { wchar_t p[MAX_PATH]; lpath(n, leaf, p); char *s = read_all(p, NULL); int r = s && !strcmp(s, text); free(s); return r; }

/* ================================================================ the test */
int main(void)
{
    wchar_t tmp[MAX_PATH];
    GetTempPathW(MAX_PATH, tmp);
    _snwprintf(g_root, MAX_PATH, L"%scoop_steam_test_%lu", tmp, GetCurrentProcessId());
    CreateDirectoryW(g_root, NULL);
    printf("coop_steam mock test, folder %ls\n", g_root);

    Node *H = node_new("Host Player", 76561190000000001ull);
    Node *F1 = node_new("Friend One", 76561190000000002ull);
    Node *F2 = node_new("Bad\tName\x01", 76561190000000003ull);
    Node *F3 = node_new("Friend Three", 76561190000000004ull);
    Node *F4 = node_new("Late Comer", 76561190000000005ull);
    node_start(H); node_start(F1); node_start(F2); node_start(F3); node_start(F4);
    run_ms(200);

    /* ---- start-up and status format */
    check(status_starts(H, "idle 76561190000000001\n"), "idle after start, status header 'idle <my id>'");
    check(status_has(H, "info appid 1363080 overlay 1 relay ok loggedon 1 build 17000001 proto 1"), "info line: app id, overlay, relay, logged on, build");
    check(log_has(H, "registered 7 Steam callbacks"), "callbacks registered through the hand-built objects");

    /* ---- hosting */
    cmd(H, "HOST");
    int ok = wait_status(H, "hosting 76561190000000001 ", 2000);
    check(ok, "HOST -> 'hosting <me> <lobby>'");
    uint64_t lobby = H->c->lobby;
    Lobby *L = lobby_get(lobby);
    check(L && !strcmp(m_GetLobbyData(NULL, lobby, "mlcoop"), "1") && !strcmp(m_GetLobbyData(NULL, lobby, "mlcoop_build"), "17000001"), "lobby data mlcoop=1 and the game build are set");
    check(status_has(H, "\n0 76561190000000001 connected 0 Host Player\n"), "host lists itself as slot 0");
    cmd(H, "INVITE");
    run_ms(50);
    check(H->inviteDialogs == 1, "INVITE opens the overlay invite dialog once");

    /* ---- joining */
    char jc[64];
    snprintf(jc, sizeof(jc), "JOIN %llu", (unsigned long long)lobby);
    cmd(F1, jc);
    char want[128];
    snprintf(want, sizeof(want), "joined 76561190000000002 %llu slot 1", (unsigned long long)lobby);
    ok = wait_status(F1, want, 5000);
    check(ok, "friend JOIN -> '%s'", want);
    check(wait_status_has(H, "\n1 76561190000000002 connected ", 3000), "host lists friend1 as connected");
    check(status_has(F1, "\n0 76561190000000001 connected "), "friend lists the host as connected");
    check(log_has(H, "session request from 76561190000000002 (lobby member): accepted=1") || log_has(H, "connected as friend1"), "the host accepted the lobby member's session");

    /* ---- lines both ways, in order */
    for (int i = 0; i < 500; i++) { char l[100]; snprintf(l, sizeof(l), "%d 1.%03d X line %d from the host", i + 1, i, i); append_line(H, L"host.txt", l); }
    ok = wait_file_has(F1, L"host.txt", "500 1.499 X line 499 from the host", 5000);
    char **v; int n = file_lines(F1, L"host.txt", &v);
    int inorder = n == 500;
    for (int i = 0; i < n && inorder; i++) { char l[100]; snprintf(l, sizeof(l), "%d 1.%03d X line %d from the host", i + 1, i, i); if (strcmp(v[i], l)) inorder = 0; }
    free_lines(v, n);
    check(ok && inorder, "500 lines appended to host.txt arrive in the friend's host.txt, all, once, in order (got %d)", n);
    for (int i = 0; i < 300; i++) { char l[100]; snprintf(l, sizeof(l), "%d 2.%03d O friend order %d", i + 1, i, i); append_line(F1, L"friend1.txt", l); }
    ok = wait_file_has(H, L"friend1.txt", "300 2.299 O friend order 299", 5000);
    n = file_lines(H, L"friend1.txt", &v);
    inorder = n == 300;
    for (int i = 0; i < n && inorder; i++) { char l[100]; snprintf(l, sizeof(l), "%d 2.%03d O friend order %d", i + 1, i, i); if (strcmp(v[i], l)) inorder = 0; }
    free_lines(v, n);
    check(ok && inorder, "300 lines appended to friend1.txt arrive in the host's friend1.txt, in order (got %d)", n);
    run_ms(4500);
    { char *s = status(F1); int rttOk = strstr(s, "\n0 76561190000000001 connected -1 ") == NULL; free(s); check(rttOk, "PING/PONG gives a round-trip time on the friend (not -1)"); }

    /* ---- truncate (T) both ways */
    { wchar_t p[MAX_PATH]; lpath(H, L"host.txt", p); truncate_file(p); }
    append_line(H, L"host.txt", "1 3.000 X after restart a");
    append_line(H, L"host.txt", "2 3.001 X after restart b");
    ok = wait_file_has(F1, L"host.txt", "after restart b", 3000);
    n = file_lines(F1, L"host.txt", &v);
    check(ok && n == 2 && !strcmp(v[0], "1 3.000 X after restart a"), "host.txt emptied by the mod -> T -> the friend's copy is emptied and gets only the new lines (%d lines)", n);
    free_lines(v, n);
    { wchar_t p[MAX_PATH]; lpath(F1, L"friend1.txt", p); truncate_file(p); }
    append_line(F1, L"friend1.txt", "1 4.000 O friend restarted");
    ok = wait_file_has(H, L"friend1.txt", "friend restarted", 3000);
    n = file_lines(H, L"friend1.txt", &v);
    check(ok && n == 1, "friend1.txt emptied -> T -> the host's copy is emptied (%d lines)", n);
    free_lines(v, n);

    /* ---- oversize line is skipped, the next one goes */
    {
        char *big = (char *)malloc(70010);
        memcpy(big, "3 3.002 X ", 10);
        memset(big + 10, 'z', 70000 - 10);
        big[70000] = 0;
        append_line(H, L"host.txt", big);
        free(big);
        append_line(H, L"host.txt", "4 3.003 X after the oversize line");
        ok = wait_file_has(F1, L"host.txt", "after the oversize line", 3000);
        check(ok && !file_has(F1, L"host.txt", "zzzzzzzzzz") && log_has(H, "longer than 64 KB"), "a line over 64 KB is skipped (and logged), the next line arrives");
    }

    /* ---- S coalescing when the link is behind */
    {
        uint64_t bw = g_bw, cap = g_sendCap;
        g_bw = 1500; g_sendCap = 4000;
        char *blob = (char *)malloc(400 * 300);
        size_t bl = 0;
        int lastS = 0;
        for (int i = 0; i < 300; i++) {
            int seq = 1000 + i;
            if (i % 10 == 9) bl += (size_t)sprintf(blob + bl, "%d 5.%03d X marker %d\n", seq, i, i);
            else { bl += (size_t)sprintf(blob + bl, "%d 5.%03d S state %d %0200d\n", seq, i, i, 7); lastS = i; }
        }
        wchar_t p[MAX_PATH]; lpath(H, L"host.txt", p);
        append_file(p, blob, bl);
        free(blob);
        char lastLine[300]; snprintf(lastLine, sizeof(lastLine), "%d 5.%03d S state %d ", 1000 + lastS, lastS, lastS);
        ok = wait_file_has(F1, L"host.txt", "X marker 299", 20000);
        run_ms(500);
        n = file_lines(F1, L"host.txt", &v);
        int markers = 0, states = 0, lastIsNewest = 0, order = 1, prevSeq = 0;
        for (int i = 0; i < n; i++) {
            int seq = atoi(v[i]);
            if (seq < 1000) continue;
            if (seq <= prevSeq) order = 0;
            prevSeq = seq;
            if (strstr(v[i], " X marker ")) markers++;
            if (strstr(v[i], " S state ")) { states++; lastIsNewest = strncmp(v[i], lastLine, strlen(lastLine)) == 0; }
        }
        free_lines(v, n);
        check(ok && markers == 30 && order, "slow link: all 30 non-state lines arrive, in order (%d)", markers);
        check(states > 0 && states < 270 && lastIsNewest, "slow link: older S lines are replaced by newer ones (%d of 270 sent), the newest S line arrives last", states);
        check(log_has(H, "SendMessageToUser") == 0, "a full send buffer is not an error (LimitExceeded = try again next tick)");
        g_bw = bw; g_sendCap = cap;
    }

    /* ---- more friends: slots 2 and 3; a fifth player finds the lobby full */
    cmd(F2, jc);
    cmd(F3, jc);
    snprintf(want, sizeof(want), "joined 76561190000000003 %llu slot 2", (unsigned long long)lobby);
    ok = wait_status(F2, want, 5000);
    snprintf(want, sizeof(want), "joined 76561190000000004 %llu slot 3", (unsigned long long)lobby);
    ok = wait_status(F3, want, 5000) && ok;
    check(ok, "friends 2 and 3 get slots 2 and 3");
    run_ms(1000);
    check(status_has(H, "\n2 76561190000000003 connected ") && status_has(H, "\n3 76561190000000004 connected "), "host lists 3 friends");
    check(status_has(H, "\n2 76561190000000003 connected ") && status_has(H, " Bad?Name?\n"), "persona names: control characters become '?', the name ends the line");
    check(status_has(F2, "\n1 76561190000000002 connected -1 Friend One\n") && status_has(F2, "\n3 76561190000000004 connected -1 Friend Three\n"), "a friend lists the other friends (from the host's slot list)");
    cmd(F4, jc);
    ok = wait_status_has(F4, "note could not join the host's game: the lobby is full", 3000);
    check(ok && status_starts(F4, "idle "), "a 5th player: 'the lobby is full', back to idle");

    /* ---- a HELLO from someone outside the lobby is not accepted */
    {
        SteamNetIdentity id; m_SetSteamID64(&id, H->sid);
        Node *save = g_cur; g_cur = F4;
        m_SendMessageToUser((ISteamNetworkingMessages *)&F4->nm, &id, "HELLO 1 77", 10, 9, 0);
        g_cur = save;
        run_ms(500);
        check(log_has(H, "session request from 76561190000000005, not a member of our lobby: not accepted") && !status_has(H, "76561190000000005"),
              "a session request from a non-member is not accepted and gets no slot");
    }

    /* ---- save transfer: 3 MB, files complete before the J LOAD line */
    {
        make_save(H, "coop_join_1_descr.sav", 4096);
        make_save(H, "coop_join_1.sav", 3u << 20);
        make_save(H, "coop_join_1_extradata0.sav", 200000);
        make_save(H, "unrelated.sav", 1000);
        /* lane 33: three of the four coat pictures (the fourth is missing: not an error), and pictures of another save */
        make_save(H, "coop_join_1_coat_0.png", 204800);
        make_save(H, "coop_join_1_coat_1.png", 69632);
        make_save(H, "coop_join_1_coat_2.png", 1000);
        make_save(H, "coop_join_2_coat_0.png", 500);
        make_save(H, "other_coat_0.png", 500);
        append_line(H, L"host.txt", "2000 9.000 J LOAD coop_join_1 Mission01_ROBBER");
        SaveWatch w; memset(&w, 0, sizeof(w));
        w.host = H; w.fr[0] = F1; w.fr[1] = F2; w.fr[2] = F3; w.nfr = 3; w.line = "J LOAD coop_join_1 Mission01_ROBBER";
        w.files[0] = "coop_join_1_descr.sav"; w.files[1] = "coop_join_1.sav"; w.files[2] = "coop_join_1_extradata0.sav";
        w.files[3] = "coop_join_1_coat_0.png"; w.files[4] = "coop_join_1_coat_1.png"; w.files[5] = "coop_join_1_coat_2.png"; w.nfiles = 6;
        ok = wait_for(c_save_watch, &w, 60000);
        check(ok, "3 MB save: the J LOAD line reached all 3 friends");
        check(w.okAtSight[0] && w.okAtSight[1] && w.okAtSight[2], "3 MB save: at the moment the J LOAD line appeared, all 3 save files and 3 coat pictures were there with the host's SHA-256 (%d %d %d)", w.okAtSight[0], w.okAtSight[1], w.okAtSight[2]);
        check(!save_exists(F1, L"unrelated.sav") && !save_exists(F1, L"coop_join_1.sav.cooppart"), "only the co-op save files are sent; no temporary file is left");
        check(log_has(F1, "the J LOAD line for coop_join_1 arrived after its files (3 coat picture(s))"), "the friend's log confirms the order, with 3 coat pictures received");
        check(log_has(F2, "received coop_join_1_coat_0.png") && log_has(F3, "received coop_join_1_coat_2.png"), "coat pictures: received and checked (SHA-256) like the save files");
        check(!save_exists(F1, L"coop_join_1_coat_3.png") && !save_exists(F1, L"coop_join_1_coat_3.png.cooppart") && !log_has(H, "could not send the save coop_join_1"),
              "coat pictures: a missing picture is not sent and is not an error");
        check(!save_exists(F1, L"coop_join_2_coat_0.png") && !save_exists(F1, L"other_coat_0.png") && !save_exists(F1, L"coop_join_1_coat_0.png.cooppart"),
              "coat pictures: only the pictures of the save asked for are sent; no temporary file is left");
    }

    /* ---- save transfer for a single load (lane 15): the J LOAD line names friend2; only friend2 gets the files */
    {
        make_save(H, "coop_join_1_descr.sav", 5000);
        make_save(H, "coop_join_1.sav", 1u << 20);
        make_save(H, "coop_join_1_coat_0.png", 150000);          /* the player changed his coat since the last save */
        append_line(H, L"host.txt", "2000 9.050 J LOAD coop_join_1 Mission01_ROBBER friend2 77-1");
        append_line(H, L"host.txt", "2000 9.060 X a line after the single load line");
        ok = wait_file_has(F1, L"host.txt", "a line after the single load line", 60000) && wait_file_has(F2, L"host.txt", "a line after the single load line", 60000)
          && wait_file_has(F3, L"host.txt", "a line after the single load line", 60000);
        check(ok, "single load: the J LOAD line and the line after it reached all 3 friends");
        check(file_has(F1, L"host.txt", "J LOAD coop_join_1 Mission01_ROBBER friend2 77-1") && file_has(F3, L"host.txt", "J LOAD coop_join_1 Mission01_ROBBER friend2 77-1"),
              "single load: the friends that are not named get the line too (their mod ignores it)");
        check(same_file(H, F2, "coop_join_1.sav") && same_file(H, F2, "coop_join_1_descr.sav"), "single load: the named friend has the new save files");
        check(!same_file(H, F1, "coop_join_1.sav") && !same_file(H, F3, "coop_join_1.sav"), "single load: the other friends were sent no file (they still hold the older save)");
        check(same_file(H, F2, "coop_join_1_coat_0.png") && !same_file(H, F1, "coop_join_1_coat_0.png"), "single load: the named friend's old coat picture is replaced by the new one; the others keep theirs");
    }

    /* ---- a friend that loads alone (lane 15): its game thread is busy, so its DLL is not ticked (8 s here; the mock
     * build counts a player as gone after 10 s, the shipped DLL after 5 minutes), while the host keeps writing lines.
     * Afterwards its mirror must hold the MARK line and every line after it, in order: the mod reads them again. */
    {
        char ln[96];
        append_line(H, L"host.txt", "2000 9.070 J MARK 77-2");
        run_ms(200);
        g_skip = F2;
        for (int k = 0; k < 300; k++) {
            snprintf(ln, sizeof(ln), "2000 9.071 W during-the-load %03d", k);
            append_line(H, L"host.txt", ln);
            if (k % 30 == 29) run_ms(800);
        }
        check(!file_has(F2, L"host.txt", "during-the-load 000"), "while the loading friend is not ticked, nothing new is in its mirror");
        check(file_has(F1, L"host.txt", "during-the-load 299"), "the other friends get the lines meanwhile");
        g_skip = NULL;
        ok = wait_file_has(F2, L"host.txt", "during-the-load 299", 20000);
        n = file_lines(F2, L"host.txt", &v);
        int mark = -1, next = 0;
        for (int i = 0; i < n; i++) {
            if (strstr(v[i], "J MARK 77-2")) mark = i;
            if (mark >= 0 && strstr(v[i], "during-the-load")) { snprintf(ln, sizeof(ln), "during-the-load %03d", next); if (strstr(v[i], ln)) next++; else next = -100000; }
        }
        free_lines(v, n);
        check(ok && mark >= 0 && next == 300, "after 8 s without a tick the loading friend's mirror has the MARK and all 300 lines after it, in order (%d)", next);
        check(!status_has(H, "disconnected"), "the host did not count the loading friend as gone");
    }

    /* ---- save transfer: 20 MB, written AFTER the J LOAD line (the host waits until the files are complete and still) */
    {
        make_save(H, "coop_join_2_descr.sav", 8192);
        append_line(H, L"host.txt", "2001 9.100 J LOAD coop_join_2 Mission01_ROBBER");
        append_line(H, L"host.txt", "2002 9.200 X a line after the load line");
        run_ms(400);
        check(!file_has(F1, L"host.txt", "J LOAD coop_join_2"), "while the main file is missing, the J LOAD line is held back");
        { wchar_t p[MAX_PATH]; spath(H, L"coop_join_2.sav", p); uint8_t *d = (uint8_t *)malloc(20u << 20); fill_random(d, 20u << 20); write_file(p, d, 10u << 20); run_ms(100); write_file(p, d, 20u << 20); free(d); }
        SaveWatch w; memset(&w, 0, sizeof(w));
        w.host = H; w.fr[0] = F1; w.fr[1] = F2; w.fr[2] = F3; w.nfr = 3; w.line = "J LOAD coop_join_2 Mission01_ROBBER";
        w.files[0] = "coop_join_2_descr.sav"; w.files[1] = "coop_join_2.sav"; w.nfiles = 2;
        ok = wait_for(c_save_watch, &w, 120000);
        check(ok, "20 MB save: the J LOAD line reached all 3 friends");
        check(w.okAtSight[0] && w.okAtSight[1] && w.okAtSight[2], "20 MB save: files complete with equal SHA-256 before the J LOAD line appeared (%d %d %d)", w.okAtSight[0], w.okAtSight[1], w.okAtSight[2]);
        ok = wait_file_has(F1, L"host.txt", "a line after the load line", 3000);
        n = file_lines(F1, L"host.txt", &v);
        int a = -1, b = -1;
        for (int i = 0; i < n; i++) { if (strstr(v[i], "J LOAD coop_join_2")) a = i; if (strstr(v[i], "a line after the load line")) b = i; }
        free_lines(v, n);
        check(ok && a >= 0 && b == a + 1, "lines held behind the J LOAD line keep their order");
    }

    /* ---- a save that never appears: the line goes anyway after 15 s */
    {
        append_line(H, L"host.txt", "2003 9.300 J LOAD coop_join_3 Mission01_ROBBER");
        ok = wait_file_has(F1, L"host.txt", "J LOAD coop_join_3", 20000);
        check(ok && log_has(H, "could not send the save coop_join_3: gave up after 15 seconds") && !save_exists(F1, L"coop_join_3.sav"),
              "a save whose files never appear: after 15 s the J LOAD line goes anyway, and the host says why");
    }

    /* ---- refusal of bad names, oversize and a wrong checksum (sent as if by the host, straight onto the wire) */
    {
        char h1[65]; sha_mem((const uint8_t *)"0123456789", 10, h1);
        char sha0[65]; wchar_t p0[MAX_PATH]; spath(F1, L"coop_join_1.sav", p0); sha_file(p0, sha0);
        const char *msgs[] = { NULL, "C 0123456789", "E ../evil.sav", NULL, NULL, "C 0123456789", "E coop_join_4.sav", NULL, NULL, "C 0123456789", "E coop_join_3_descr.sav", "L 2004 9.400 X after the refusals" };
        char m0[200], m3[200], m4[200], m7[200], m8[200];
        snprintf(m0, sizeof(m0), "F ../evil.sav 10 %s", h1);
        snprintf(m3, sizeof(m3), "F coop_join_1.sav 70000000 %s", h1);
        snprintf(m4, sizeof(m4), "F coop_join_4.sav 10 %s", h1);
        snprintf(m7, sizeof(m7), "F coop_join_1.sav notanumber %s", h1);
        snprintf(m8, sizeof(m8), "F coop_join_3_descr.sav 10 %064d", 0);
        msgs[0] = m0; msgs[3] = m3; msgs[4] = m4; msgs[7] = m7; msgs[8] = m8;
        SteamNetIdentity id; m_SetSteamID64(&id, F1->sid);
        for (size_t i = 0; i < sizeof(msgs) / sizeof(msgs[0]); i++) m_SendMessageToUser((ISteamNetworkingMessages *)&H->nm, &id, msgs[i], (uint32_t)strlen(msgs[i]), 9, 0);
        ok = wait_file_has(F1, L"host.txt", "after the refusals", 3000);
        wchar_t evil1[MAX_PATH], evil2[MAX_PATH];
        wjoin(evil1, F1->base, L"evil.sav");
        wjoin(evil2, F1->link, L"evil.sav");
        char sha1[65]; sha_file(p0, sha1);
        check(ok && GetFileAttributesW(evil1) == INVALID_FILE_ATTRIBUTES && GetFileAttributesW(evil2) == INVALID_FILE_ATTRIBUTES && !save_exists(F1, L"evil.sav"),
              "a file name with a path in it is refused, nothing is written");
        check(!save_exists(F1, L"coop_join_4.sav") && log_has(F1, "refused the file 'coop_join_4.sav'"), "a name outside coop_join_[1-3] is refused");
        check(!strcmp(sha0, sha1) && log_has(F1, "it is larger than 64 MB") && log_has(F1, "the size is not a number"), "an announced size over 64 MB or not a number is refused; the existing save is untouched");
        check(!save_exists(F1, L"coop_join_3_descr.sav") && !save_exists(F1, L"coop_join_3_descr.sav.cooppart") && log_has(F1, "its checksum does not match"), "a wrong checksum: the file is not put in place, the temporary file is deleted");
    }

    /* ---- coat pictures (lane 33): names that try to leave the save folder or do not fit the pattern are refused */
    {
        char h1[65]; sha_mem((const uint8_t *)"0123456789", 10, h1);
        const char *bad[] = { "..\\coop_join_1_coat_0.png", "../coop_join_1_coat_0.png", "coop_join_1_coat_0.png\\..\\..\\evil.png", "coop_join_1_coat_4.png",
                              "coop_join_1_coat_0.png.exe", "coop_join_4_coat_0.png", "coop_join_1_coat_00.png", "C:\\coop_join_1_coat_0.png" };
        SteamNetIdentity id; m_SetSteamID64(&id, F1->sid);
        for (size_t i = 0; i < sizeof(bad) / sizeof(bad[0]); i++) {
            char m[300]; snprintf(m, sizeof(m), "F %s 10 %s", bad[i], h1);
            m_SendMessageToUser((ISteamNetworkingMessages *)&H->nm, &id, m, (uint32_t)strlen(m), 9, 0);
            m_SendMessageToUser((ISteamNetworkingMessages *)&H->nm, &id, "C 0123456789", 12, 9, 0);
            snprintf(m, sizeof(m), "E %s", bad[i]);
            m_SendMessageToUser((ISteamNetworkingMessages *)&H->nm, &id, m, (uint32_t)strlen(m), 9, 0);
        }
        const char *after = "L 2004 9.410 X after the coat refusals";
        m_SendMessageToUser((ISteamNetworkingMessages *)&H->nm, &id, after, (uint32_t)strlen(after), 9, 0);
        ok = wait_file_has(F1, L"host.txt", "after the coat refusals", 3000);
        wchar_t e1[MAX_PATH], e2[MAX_PATH], e3[MAX_PATH];
        wjoin(e1, F1->base, L"coop_join_1_coat_0.png"); wjoin(e2, F1->link, L"coop_join_1_coat_0.png"); wjoin(e3, g_root, L"evil.png");
        int refused = 0;
        for (size_t i = 0; i < sizeof(bad) / sizeof(bad[0]); i++) { char t[300]; snprintf(t, sizeof(t), "refused the file '%s'", bad[i]); for (char *q = t; *q; q++) if ((unsigned char)*q < 0x20) *q = '?'; if (log_has(F1, t)) refused++; }
        check(ok && refused == 8 && GetFileAttributesW(e1) == INVALID_FILE_ATTRIBUTES && GetFileAttributesW(e2) == INVALID_FILE_ATTRIBUTES && GetFileAttributesW(e3) == INVALID_FILE_ATTRIBUTES
              && !save_exists(F1, L"coop_join_1_coat_4.png") && !save_exists(F1, L"coop_join_4_coat_0.png") && !save_exists(F1, L"coop_join_1_coat_0.png.exe"),
              "coat pictures: 8 bad names (a path out of the save folder, a 5th picture, another extension, ...) are refused and nothing is written (%d refused)", refused);
        int names = save_name_ok("coop_join_1_coat_0.png") && save_name_ok("coop_join_3_coat_3.png") && !save_name_ok("coop_join_1_coat_.png") &&
                    !save_name_ok("coop_join_1_coat_0.PNG") && !save_name_ok("coop_join_0_coat_0.png") && !save_name_ok("coop_join_1_coat_0.png ") &&
                    !save_name_ok("coop_join_1_coat_0.sav") && save_name_ok("coop_join_2_extradata12.sav");
        check(names, "the save name pattern: coop_join_[1-3]_coat_[0-3].png accepted, near misses refused, the old names still accepted");
    }

    /* ---- the host never accepts files */
    {
        SteamNetIdentity id; m_SetSteamID64(&id, H->sid);
        m_SendMessageToUser((ISteamNetworkingMessages *)&F1->nm, &id, "F coop_join_1.sav 10 x", 22, 9, 0);
        run_ms(200);
        check(log_has(H, "the host never accepts files"), "a friend sending a file to the host is ignored");
    }

    /* ---- ping time-out -> disconnected, then back */
    {
        g_cut[H->idx][F1->idx] = g_cut[F1->idx][H->idx] = 1;
        run_ms(11000);
        check(status_has(H, "\n1 76561190000000002 disconnected -1 "), "10 s of silence: the host shows friend1 'disconnected'");
        check(status_has(F1, "\n0 76561190000000001 disconnected -1 "), "10 s of silence: friend1 shows the host 'disconnected'");
        check(status_has(H, "\n2 76561190000000003 connected "), "the other friends stay connected");
        g_cut[H->idx][F1->idx] = g_cut[F1->idx][H->idx] = 0;
        ok = wait_status_has(H, "\n1 76561190000000002 connected ", 8000);
        check(ok && status_has(F1, "slot 1\n"), "when the network is back, friend1 reconnects into the same slot");
        append_line(H, L"host.txt", "2005 9.500 X after the reconnect");
        check(wait_file_has(F1, L"host.txt", "after the reconnect", 3000), "lines flow again after the reconnect");
        append_line(F1, L"friend1.txt", "2 4.100 O friend after reconnect");
        check(wait_file_has(H, L"friend1.txt", "friend after reconnect", 3000), "and in the other direction");
    }

    /* ---- link file turnover (lane 33): the host's file is cut into host.txt, host.2.txt, ... and every reader follows */
    {
        check(link_leaf_ok(L"host.2.txt") && link_leaf_ok(L"friend3.123456.txt") && !link_leaf_ok(L"host.1.txt") && !link_leaf_ok(L"host.0.txt") &&
              !link_leaf_ok(L"host.02.txt") && !link_leaf_ok(L"host.2.txt.exe") && !link_leaf_ok(L"friend4.2.txt") && !link_leaf_ok(L"host.1234567.txt") &&
              !link_leaf_ok(L"..\\host.2.txt") && !link_leaf_ok(L"host..txt") && !link_leaf_ok(L"other.2.txt"),
              "turnover: only host.<k>.txt and friend<n>.<k>.txt (k from 2) are allowed link file names");
        check(next_marker((const uint8_t *)"12 3.500 ~NEXT 2", 16) == 2 && next_marker((const uint8_t *)"0 0.000 ~NEXT 17\r", 17) == 17 &&
              !next_marker((const uint8_t *)"12 3.500 ~NEXT 1", 16) && !next_marker((const uint8_t *)"12 3.500 ~NEXT 2 x", 18) &&
              !next_marker((const uint8_t *)"12 3.500 X ~NEXT 2", 18) && !next_marker((const uint8_t *)"12 ~NEXT 2", 10) && !next_marker((const uint8_t *)"1 2 ~NEXT 02", 12),
              "turnover: the '<seq> <time> ~NEXT <k>' line is told apart from every other line");

        TW hw = { H, L"host", 1, 30000 };
        hw.seg = seg_last(H->c, L"host");
        TR r1, r2, r3;
        tr_start(&r1, F1, L"host"); tr_start(&r2, F2, L"host"); tr_start(&r3, F3, L"host");
        g_tr[0] = &r1; g_tr[1] = &r2; g_tr[2] = &r3; g_ntr = 3;
        g_after_step = tr_poll_all;

        /* three turnovers, two of them in a row (file 3 holds nothing but its "~NEXT" line), all within one tick */
        char ln[80];
        for (int i = 0; i < 100; i++) { snprintf(ln, sizeof(ln), "X tov %d", i); tw_line(&hw, ln); }
        tw_cut(&hw);
        for (int i = 100; i < 150; i++) { snprintf(ln, sizeof(ln), "X tov %d", i); tw_line(&hw, ln); }
        tw_cut(&hw); tw_cut(&hw);
        for (int i = 150; i < 200; i++) { snprintf(ln, sizeof(ln), "X tov %d", i); tw_line(&hw, ln); }
        ok = wait_tr(&r1, 200, 5000) && wait_tr(&r2, 200, 5000) && wait_tr(&r3, 200, 5000);
        check(ok && r1.dup + r2.dup + r3.dup == 0 && r1.gap + r2.gap + r3.gap == 0 && r1.moves == 3 && r2.moves == 3 && r1.lost + r2.lost + r3.lost == 0,
              "turnover: 3 turnovers (two in a row): every friend's reader gets all 200 lines once, in order, and follows host.2/3/4 (moves %d %d %d)", r1.moves, r2.moves, r3.moves);
        check(H->c->hostTail.seg == 4 && F1->c->mirrors[0].seg == 4 && F3->c->mirrors[0].seg == 4 && tw_exists(F1, L"host", 4),
              "turnover: the host's DLL reads host.4.txt and the friends' DLLs write their host.4.txt");
        check(file_has(F1, L"host.txt", "X tov 99") && tw_exists(F1, L"host", 2), "turnover: right after it, old files are kept (deleting waits 30 s after the last turnover)");
        run_ms(31000);
        tw_cleanup(&hw);
        run_ms(100);
        check(r1.restarts + r2.restarts + r3.restarts == 0 && file_text_is(F1, L"host.txt", "0 0.000 ~NEXT 2\n") && tw_exists(F1, L"host", 2) && tw_exists(F1, L"host", 3) && file_text_is(H, L"host.txt", "0 0.000 ~NEXT 2\n"),
              "turnover: after 30 s the first file is a one-line pointer to the oldest file kept; the two files before the current one stay");

        /* a friend that loads alone (its DLL and its mod are not ticked) while the host's file turns over twice */
        tw_line(&hw, "J MARK tov-1");
        run_ms(300);
        int markSeg = r2.markSeg; uint64_t markOff = r2.markOff;
        g_skip = F2;
        for (int i = 200; i < 500; i++) {
            snprintf(ln, sizeof(ln), "X tov %d", i); tw_line(&hw, ln);
            if (i == 300 || i == 400) tw_cut(&hw);
            if (i % 50 == 49) run_ms(800);
        }
        check(r2.next == 200 && r1.next == 500, "turnover: while friend2 loads, it reads nothing; the others read on");
        g_skip = NULL;
        ok = wait_tr(&r2, 500, 20000);
        check(ok && r2.dup == 0 && r2.gap == 0 && r2.lost == 0 && r2.moves == 5 && F2->c->mirrors[0].seg == 6,
              "turnover: after the load friend2's DLL writes host.5 and host.6 in one burst and its reader still gets all 300 lines once, in order (moves %d, lost %d)", r2.moves, r2.lost);
        {
            TR rr; memset(&rr, 0, sizeof(rr));
            rr.n = F2; rr.base = L"host"; rr.seg = markSeg; rr.off = markOff; rr.next = 200;
            tr_poll(&rr); tr_poll(&rr);
            check(markSeg == 4 && tw_exists(F2, L"host", markSeg) && rr.next == 500 && rr.dup == 0 && rr.gap == 0,
                  "turnover: the save's MARK place (file %d) is still there after two turnovers; read again from it, all 300 lines follow in order", markSeg);
            buf_free(&rr.part);
        }

        /* the Steam mirror in the middle of a file: friend1's current host file is locked across two turnovers */
        {
            wchar_t p[MAX_PATH]; tw_path(F1, L"host", F1->c->mirrors[0].seg, p);
            HANDLE lk = CreateFileW(p, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, 0, NULL);
            int segBefore = F1->c->mirrors[0].seg;
            g_ntr = 2;                                          /* friend1's reader waits too (the file is locked for it as well) */
            g_tr[0] = &r2; g_tr[1] = &r3;
            for (int i = 500; i < 650; i++) { snprintf(ln, sizeof(ln), "X tov %d", i); tw_line(&hw, ln); if (i == 549 || i == 599) tw_cut(&hw); }
            run_ms(1500);
            int stuck = F1->c->mirrors[0].seg == segBefore && !tw_exists(F1, L"host", segBefore + 1) && F1->c->mirrors[0].ncut == 2;
            CloseHandle(lk);
            g_tr[2] = &r1; g_ntr = 3;
            ok = wait_tr(&r1, 650, 5000);
            check(lk != INVALID_HANDLE_VALUE && stuck && log_has(F1, "could not write to host.6.txt"), "turnover: a locked mirror file holds the lines and both turnovers (2 waiting), no later file is made early");
            check(ok && r1.dup == 0 && r1.gap == 0 && r1.lost == 0 && F1->c->mirrors[0].seg == 8 && wait_tr(&r3, 650, 2000),
                  "turnover: once the file is free, the lines go to host.6, host.7 and host.8 in the right places; the reader gets all 150 in order");
        }

        /* the host's game starts again: its writer empties host.txt and deletes host.<k>.txt; everybody starts again */
        run_ms(500);
        tw_restart(&hw);
        for (TR **pr = g_tr; pr < g_tr + 3; pr++) { (*pr)->next = 0; (*pr)->restarts = 0; }
        for (int i = 0; i < 20; i++) { snprintf(ln, sizeof(ln), "X tov %d", i); tw_line(&hw, ln); }
        ok = wait_tr(&r1, 20, 5000) && wait_tr(&r3, 20, 5000);
        n = file_lines(F1, L"host.txt", &v);
        free_lines(v, n);
        check(ok && r1.restarts == 1 && r1.dup == 0 && r1.gap == 0 && H->c->hostTail.seg == 1 && F1->c->mirrors[0].seg == 1 && n == 20,
              "turnover: the host's game starts again in host.8: the host's DLL goes back to host.txt (T), the friends' copies are emptied, readers get the 20 new lines only (%d)", n);
        run_ms(500);
        check(!seg_lowest_above(F1->c, L"host", 1) && !seg_lowest_above(F3->c, L"host", 1) && !seg_lowest_above(H->c, L"host", 1),
              "turnover: after the restart no host.<k>.txt is left on any PC");

        /* the other direction: friend1's own file turns over, the host's mirror follows */
        TW fw = { F1, L"friend1", 1, 40000 };
        fw.seg = seg_last(F1->c, L"friend1");
        TR rh; tr_start(&rh, H, L"friend1");
        g_tr[3] = &rh; g_ntr = 4;
        for (int i = 0; i < 100; i++) { snprintf(ln, sizeof(ln), "X tov %d", i); tw_line(&fw, ln); if (i == 49) tw_cut(&fw); }
        ok = wait_tr(&rh, 100, 5000);
        check(ok && rh.dup == 0 && rh.gap == 0 && rh.moves == 1 && H->c->mirrors[1].seg == 2 && F1->c->myTail.seg == 2,
              "turnover: friend1.txt -> friend1.2.txt: the host's mirror follows and its reader gets all 100 lines in order");

        g_after_step = NULL; g_ntr = 0;
        buf_free(&r1.part); buf_free(&r2.part); buf_free(&r3.part); buf_free(&rh.part);
    }

    /* ---- KICK and LEAVE */
    {
        char k[64]; snprintf(k, sizeof(k), "KICK %llu", (unsigned long long)F3->sid);
        cmd(H, k);
        ok = wait_status(F3, "idle ", 3000);
        check(ok && status_has(F3, "removed you from this game"), "KICK: the friend is told in plain words and goes back to idle");
        run_ms(600);
        check(!status_has(H, "76561190000000004"), "KICK: the host no longer lists that player");
        cmd(F2, "LEAVE");
        run_ms(100);
        check(status_starts(F2, "idle ") && status_has(F2, "note left the game"), "LEAVE: the friend is idle");
        ok = wait_status_has(H, "\n2 76561190000000003 disconnected ", 1000);
        check(ok, "LEAVE: the host sees friend2 'disconnected' at once (BYE)");
        run_ms(1000);
        L = lobby_get(lobby);
        check(L && !lobby_has(L, F2->sid) && !lobby_has(L, F3->sid), "LEAVE/KICK: both left the Steam lobby");
        cmd(H, "LEAVE");
        ok = wait_status(F1, "idle ", 3000);
        check(ok && status_has(F1, "note the host closed the game") && status_starts(H, "idle "), "host LEAVE: friend1 is told 'the host closed the game'; both idle");
        run_ms(2000);
        check(lobby_get(lobby) == NULL, "the lobby is gone after everybody left");
    }

    /* ---- invites: +connect_lobby on the command line, and the in-game invite callback */
    {
        cmd(H, "HOST");
        ok = wait_status(H, "hosting ", 2000);
        uint64_t lob2 = H->c->lobby;
        Node *F5 = node_new("Started By Invite", 76561190000000006ull);
        _snwprintf(F5->cmdline, 200, L"\"ManorLords-Win64-Shipping.exe\" -steam +connect_lobby %llu", (unsigned long long)lob2);
        node_start(F5);
        snprintf(want, sizeof(want), "joined 76561190000000006 %llu slot 1", (unsigned long long)lob2);
        ok = wait_status(F5, want, 5000);
        check(ok, "a game started by Steam with +connect_lobby joins that lobby by itself");
        GameLobbyJoinRequested_t r; r.m_steamIDLobby = lob2; r.m_steamIDFriend = H->sid;
        post_cb(F1, CB_GameLobbyJoinRequested, &r, sizeof(r));
        snprintf(want, sizeof(want), "joined 76561190000000002 %llu slot 2", (unsigned long long)lob2);
        ok = wait_status(F1, want, 5000);
        check(ok, "an invite accepted in the overlay while the game runs (callback 333) joins the lobby");
    }

    /* ---- call results only through callbacks, and only through polling */
    {
        cmd(F1, "LEAVE");
        run_ms(200);
        g_callResultsVisible = 0;
        char j2[64]; snprintf(j2, sizeof(j2), "JOIN %llu", (unsigned long long)H->c->lobby);
        cmd(F1, j2);
        ok = wait_status(F1, "joined ", 3000);
        check(ok, "joining works when only the LobbyEnter callback arrives (no call result)");
        g_callResultsVisible = 1;
        cmd(F1, "LEAVE");
        run_ms(200);
        g_postResultCallbacks = 0;
        cmd(F1, j2);
        ok = wait_status(F1, "joined ", 3000);
        check(ok, "joining works when only the call result arrives (no callback)");
        g_postResultCallbacks = 1;
    }

    /* ---- lobbies that are not ours or not our version */
    {
        Lobby *x = &g_lobbies[g_nl++]; memset(x, 0, sizeof(*x));
        x->id = ++g_lobbySeq; x->owner = 76561190000000099ull; x->mem[0] = x->owner; x->n = 1; x->max = 4; x->alive = 1;
        lobby_set(x, "mlcoop", "2");
        Lobby *y = &g_lobbies[g_nl++]; memset(y, 0, sizeof(*y));
        y->id = ++g_lobbySeq; y->owner = 76561190000000098ull; y->mem[0] = y->owner; y->n = 1; y->max = 4; y->alive = 1;
        Lobby *z = &g_lobbies[g_nl++]; memset(z, 0, sizeof(*z));
        z->id = ++g_lobbySeq; z->owner = 76561190000000097ull; z->mem[0] = z->owner; z->n = 1; z->max = 4; z->alive = 1;
        lobby_set(z, "mlcoop", "1"); lobby_set(z, "mlcoop_build", "16999999");
        char j[64];
        snprintf(j, sizeof(j), "JOIN %llu", (unsigned long long)x->id); cmd(F4, j);
        ok = wait_status_has(F4, "note the host uses co-op version 2 and you have version 1", 3000);
        check(ok && status_starts(F4, "idle ") && !lobby_has(x, F4->sid), "a lobby with another co-op version is refused in plain words and left");
        snprintf(j, sizeof(j), "JOIN %llu", (unsigned long long)y->id); cmd(F4, j);
        ok = wait_status_has(F4, "note that Steam lobby is not a Manor Lords co-op game", 3000);
        check(ok && !lobby_has(y, F4->sid), "a lobby without the co-op key is refused and left");
        snprintf(j, sizeof(j), "JOIN %llu", (unsigned long long)z->id); cmd(F4, j);
        ok = wait_status_has(F4, "note the host runs another version of the game (build 16999999, yours is 17000001)", 3000);
        check(ok, "a lobby from another game build is refused in plain words");
        cmd(F4, "JOIN 123");
        ok = wait_status_has(F4, "note could not join the host's game: the lobby does not exist any more", 3000);
        check(ok, "a lobby that does not exist: plain words, idle");
    }

    /* ---- fail closed: no Steam, a missing export, a fault inside */
    {
        Node *A = node_new("No Steam", 76561190000000010ull); A->steamRunning = 0; node_start(A);
        Node *B = node_new("Old DLL", 76561190000000011ull); B->missingExport = 1; node_start(B);
        Node *C = node_new("Crashy", 76561190000000012ull); C->crash = 1; node_start(C);
        run_ms(1000);
        check(status_starts(A, "off 0 waiting for the game to start Steam") || status_starts(A, "off 0 the game has not started Steam"), "no Steam yet: 'off' with a plain reason while it waits");
        run_ms(61000);
        check(status_starts(A, "off 0 the game has not started Steam (was it started outside Steam?)") && A->c->off, "no Steam after 60 s: off for good");
        check(status_starts(B, "off 0 steam api mismatch: SteamAPI_SteamNetworkingMessages_SteamAPI_v002 is missing") && B->c->off, "a missing export: 'off steam api mismatch ...'");
        check(status_starts(C, "off ") && strstr(C->c->offReason, "internal fault 0xC0000005 during opening Steam") != NULL, "an access violation inside: caught, 'off internal fault ...', no crash");
        size_t l0 = 0, l1 = 0, s0 = 0, s1 = 0;
        wchar_t lp[MAX_PATH], sp[MAX_PATH];
        lpath(B, L"coop_steam.log", lp); lpath(B, L"steam_status.txt", sp);
        free(read_all(lp, &l0)); free(read_all(sp, &s0));
        for (int i = 0; i < 1000; i++) { g_now += 16; g_cur = B; coop_tick_safe(B->c); }
        free(read_all(lp, &l1)); free(read_all(sp, &s1));
        check(B->c->off && l0 == l1 && s0 == s1, "once off, every tick returns at once (nothing logged or written in 1000 ticks)");
    }

    /* ---- the callback object itself */
    check(g_sizeMismatch == 0, "the size getter in vtable slot 2 matched the struct size for every callback and call result (%d mismatches)", g_sizeMismatch);
    check(g_slot0Calls > 0 && g_slot1Calls > 0, "callbacks worked through both vtable slots (%d via slot 0, %d via slot 1)", g_slot0Calls, g_slot1Calls);

    /* ---- the files a DLL may touch */
    {
        int bad = 0;
        for (int i = 0; i < g_nn; i++) {
            WIN32_FIND_DATAW fd; wchar_t pat[MAX_PATH]; wjoin(pat, g_nodes[i]->link, L"*");
            HANDLE h = FindFirstFileW(pat, &fd);
            if (h == INVALID_HANDLE_VALUE) continue;
            do { if (fd.cFileName[0] != L'.' && !link_leaf_ok(fd.cFileName)) { bad++; printf("      unexpected file %ls\n", fd.cFileName); } } while (FindNextFileW(h, &fd));
            FindClose(h);
        }
        check(bad == 0, "only the allowed file names exist in the link folders");
    }

    printf("\nRESULT: %d passed, %d failed\n", g_pass, g_fail);
    rm_tree(g_root);
    printf("temporary folder removed: %s\n", GetFileAttributesW(g_root) == INVALID_FILE_ATTRIBUTES ? "yes" : "NO");
    return g_fail ? 1 : 0;
}
