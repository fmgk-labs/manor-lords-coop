/* coop_scrub.h - lane 61: what leaves this PC in a bug report carries no Windows user name, no Steam name and no whole
 * Steam id. One rule set for the DLL's own log lines (log_line) and for every file the bug report copies (coop_report.h):
 *   a folder name after "\Users\" or "/Users/" (any case) that is followed by another separator   -> <user>
 *   the Windows user name (USERNAME, and the last folder of USERPROFILE) right after a separator    -> <user>
 *   names the mod hands over with a report job (Steam display names, 3 bytes or longer), anywhere    -> their slot name
 *   a Steam id (7656119 and 10 more digits, not inside a longer number)                              -> <id..> and its last 4 digits
 * Names are compared without case for A-Z only (other UTF-8 bytes as they are). The Lua side (coop.lua, scrub) has the
 * same rules for the mod's own log. Included before log_line. */

#define SCRUB_MAX_NAMES 24
typedef struct { char from[160]; char to[40]; size_t n; int path; } scrub_name;
static scrub_name g_scrub[SCRUB_MAX_NAMES];
static int g_scrub_n, g_scrub_base;     /* base: the user names from the environment (a job's names come after them) */

static int sc_lower(int c) { return (c >= 'A' && c <= 'Z') ? c + 32 : c; }
static int sc_sep(int c) { return c == '\\' || c == '/'; }
static int sc_digit(int c) { return c >= '0' && c <= '9'; }
static int sc_eq(const char *a, const char *b, size_t n)
{
    size_t i;
    for (i = 0; i < n; i++) if (sc_lower((unsigned char)a[i]) != sc_lower((unsigned char)b[i])) return 0;
    return 1;
}

/* path = 1: only right after a \ or / (a user name: a short one would hit ordinary words); 0: anywhere */
static void scrub_add(const char *from, const char *to, int path)
{
    size_t n = strlen(from);
    int k;
    if (n < (path ? 1u : 3u) || n >= sizeof(g_scrub[0].from) || strlen(to) >= sizeof(g_scrub[0].to) || g_scrub_n >= SCRUB_MAX_NAMES) return;
    if (strcmp(from, to) == 0) return;
    for (k = 0; k < g_scrub_n; k++) if (g_scrub[k].n == n && g_scrub[k].path == path && sc_eq(g_scrub[k].from, from, n)) return;
    memcpy(g_scrub[g_scrub_n].from, from, n + 1);
    strcpy(g_scrub[g_scrub_n].to, to);
    g_scrub[g_scrub_n].n = n;
    g_scrub[g_scrub_n].path = path;
    g_scrub_n++;
}

static void scrub_add_w(const wchar_t *from, const char *to, int path)
{
    char u[sizeof(g_scrub[0].from)];
    if (!from || !from[0]) return;
    if (WideCharToMultiByte(CP_UTF8, 0, from, -1, u, (int)sizeof(u), NULL, NULL) <= 0) return;
    scrub_add(u, to, path);
}

/* the Windows user name from the environment (USERNAME, and the last folder of USERPROFILE: they can differ) */
static void scrub_init_env(void)
{
    wchar_t w[MAX_PATH], *leaf;
    DWORD n;
    g_scrub_n = 0;
    n = GetEnvironmentVariableW(L"USERNAME", w, MAX_PATH);
    if (n > 0 && n < MAX_PATH) scrub_add_w(w, "<user>", 1);
    n = GetEnvironmentVariableW(L"USERPROFILE", w, MAX_PATH);
    if (n > 0 && n < MAX_PATH) {
        size_t len = wcslen(w);
        while (len && (w[len - 1] == L'\\' || w[len - 1] == L'/')) w[--len] = 0;
        leaf = wcsrchr(w, L'\\');
        if (leaf) scrub_add_w(leaf + 1, "<user>", 1);
    }
    g_scrub_base = g_scrub_n;
}

/* in[0..n) -> out (at most cap bytes; what does not fit is cut). Returns the bytes written. */
static size_t scrub_buf(const char *in, size_t n, char *out, size_t cap)
{
    size_t i = 0, o = 0, j, m;
    int k;
#define SC_PUT(p, len) do { size_t l_ = (len); if (o + l_ > cap) l_ = cap - o; memcpy(out + o, (p), l_); o += l_; } while (0)
    while (i < n && o < cap) {
        unsigned char c = (unsigned char)in[i];
        if (sc_sep(c) && i + 7 < n && sc_eq(in + i + 1, "users", 5) && sc_sep((unsigned char)in[i + 6])) {
            /* \Users\<name>\ : the folder after Users, when another separator follows it */
            j = i + 7;
            while (j < n && !sc_sep((unsigned char)in[j]) && in[j] != '\r' && in[j] != '\n' && in[j] != '"' && in[j] != '\'' && j - (i + 7) < 260) j++;
            if (j < n && j > i + 7 && sc_sep((unsigned char)in[j])) {
                SC_PUT(in + i, 7); SC_PUT("<user>", 6);
                i = j;
                continue;
            }
        }
        for (k = 0; k < g_scrub_n; k++) {
            const scrub_name *s = &g_scrub[k];
            size_t at = s->path ? i + 1 : i;
            if (s->path && !sc_sep(c)) continue;
            if (at + s->n <= n && sc_eq(in + at, s->from, s->n)) {
                if (s->path) SC_PUT(in + i, 1);
                SC_PUT(s->to, strlen(s->to));
                i = at + s->n;
                break;
            }
        }
        if (k < g_scrub_n) continue;
        if (c == '7' && i + 17 <= n && (i == 0 || !sc_digit((unsigned char)in[i - 1])) && memcmp(in + i, "7656119", 7) == 0 &&
            (i + 17 == n || !sc_digit((unsigned char)in[i + 17]))) {
            for (m = 7; m < 17 && sc_digit((unsigned char)in[i + m]); m++) {}
            if (m == 17) {
                SC_PUT("<id..", 5); SC_PUT(in + i + 13, 4); SC_PUT(">", 1);
                i += 17;
                continue;
            }
        }
        out[o++] = (char)c;
        i++;
    }
#undef SC_PUT
    return o;
}
