/* coop_report.h - lane 61: REPORT <stamp>, the player's "Make Bug Report" button.
 *
 * The mod writes the job (patch_report_job.txt in this DLL's I/O folder, UTF-8, one item a line, fields split by tabs):
 *   open 1|0                     open the reports folder in Explorer when done (0: the test switch dev_report_noopen.txt)
 *   zip 1|0                      make the zip (0: keep the folder only; the mechanism test reads the copies)
 *   name <from> <to>             a Steam display name and the slot name that replaces it in every copy
 *   steamlog <source> <name> <cap>      (lane 62) the Steam piece's log, and
 *   steamstatus <source> <name> <cap>   its status file: copied like a file, with the Steam names taken out by the
 *                                shape of the line first (coop_scrub.h, scrub_steam)
 *   file <source> <name> <cap> [<start>]   a file to copy (scrubbed, coop_scrub.h) under <name>, from byte <start> on
 *                                (default 0); past <cap> bytes its start (a quarter of <cap>, at most 1 MB) and its end
 *                                are kept, the middle is left out
 * and sends "REPORT <stamp>" (<stamp>: letters, digits, '-' and '_' only). Every path written is built here from this
 * DLL's own folder (the mod folder), never taken from the job: <mod>\link\reports\report_<stamp>\ gets the copies, then
 * Windows' own tar.exe (System32, Windows 10 1803 and later) makes <mod>\link\reports\report_<stamp>.zip of that folder,
 * started with CREATE_NO_WINDOW (no console window), and the folder is removed. Without tar, or when it fails or takes
 * longer than 120 s, the folder stays (the player sends the folder's files) and a partial zip is removed.
 * The copying, tar and Explorer run on the report's own thread: the game thread only reads the job and starts it.
 * Nothing goes over the network. The status file has one line: REPORT idle | running report_<stamp> |
 * done report_<stamp>.zip <files> [opened] | folder report_<stamp> <files> <why> [opened] | refused report_<stamp> <why>
 * (refused - <why> when the command had no usable name).
 */

#define REP_MAX_FILES 40          /* (lane 62: 24 before; a job beyond this drops its last files, so the mod lists the Steam piece's files first) */
#define REP_HEAD_MAX  (1024u * 1024u)
#define REP_CHUNK     (1024u * 1024u)
typedef struct { wchar_t src[MAX_PATH]; char dst[64]; ULONGLONG cap, start; int kind; } rep_file;    /* start: bytes before it are left out; kind: 0, SCRUB_STEAM_LOG or SCRUB_STEAM_STATUS */
static struct {
    volatile LONG state;          /* 0 idle, 1 running, 2 finished (result says how), 3 refused */
    LONG shown;                   /* the state the status file was last written for */
    char stamp[48], result[240];
    int open, zip, nfiles, copied;
    rep_file f[REP_MAX_FILES];
    wchar_t reports[MAX_PATH], dir[MAX_PATH], zipPath[MAX_PATH];
    HANDLE thread;
    unsigned jobs;
} RP;

static int rep_name_ok(const char *s, size_t max)
{
    size_t i, n = strlen(s);
    if (n == 0 || n >= max || s[0] == '.') return 0;
    for (i = 0; i < n; i++) {
        char c = s[i];
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-' || c == '.')) return 0;
    }
    return strstr(s, "..") == NULL;
}

static void rep_refuse(const char *stamp, const char *why)
{
    /* the report's name first (the mod matches its own job by it); "-" when the command had no usable name */
    _snprintf(RP.result, sizeof(RP.result) - 1, "refused %s%s %s", stamp ? "report_" : "-", stamp ? stamp : "", why);
    RP.result[sizeof(RP.result) - 1] = 0;
    InterlockedExchange(&RP.state, 3);
    log_line("REPORT %s", RP.result);
    g_dirty = 1;
}

/* write all of buf; 0 on a failed write */
static int rep_write(HANDLE o, const char *buf, size_t n)
{
    DWORD wr;
    while (n) {
        DWORD part = n > 0x40000000u ? 0x40000000u : (DWORD)n;
        if (!WriteFile(o, buf, part, &wr, NULL) || wr == 0) return 0;
        buf += wr; n -= wr;
    }
    return 1;
}

/* copy [from, to) of h to o, scrubbed, in whole lines of at most REP_CHUNK bytes (a longer line is cut in pieces) */
static int rep_copy_range(HANDLE h, HANDLE o, ULONGLONG from, ULONGLONG to, char *in, char *out, char *mid, int kind)
{
    ULONGLONG pos = from;
    size_t carry = 0;
    LARGE_INTEGER li;
    li.QuadPart = (LONGLONG)from;
    if (!SetFilePointerEx(h, li, NULL, FILE_BEGIN)) return 0;
    while (pos < to || carry) {
        DWORD want = (DWORD)(REP_CHUNK - carry), got = 0;
        size_t have, cut, w;
        if (pos >= to) want = 0;
        else if ((ULONGLONG)want > to - pos) want = (DWORD)(to - pos);
        if (want && !ReadFile(h, in + carry, want, &got, NULL)) return 0;
        pos += got;
        have = carry + got;
        if (have == 0) break;
        cut = have;
        if (pos < to && got) {             /* more to come: stop after the last whole line */
            size_t k = have;
            while (k > 0 && in[k - 1] != '\n') k--;
            if (k > 0) cut = k;
        }
        if (kind) {                        /* (lane 62) a file of the Steam piece: its names go by the shape of the line first */
            size_t m = scrub_steam(in, cut, mid, REP_CHUNK * 2, kind);
            w = scrub_buf(mid, m, out, REP_CHUNK * 4);
        } else w = scrub_buf(in, cut, out, REP_CHUNK * 4);
        if (!rep_write(o, out, w)) return 0;
        carry = have - cut;
        if (carry) memmove(in, in + cut, carry);
        if (want && !got) break;           /* the file ended early (it got shorter while read): what was read is written */
    }
    return 1;
}

static int rep_copy(const rep_file *rf, char *in, char *out, char *mid)
{
    wchar_t dst[MAX_PATH], wname[64];
    HANDLE h, o;
    LARGE_INTEGER sz;
    ULONGLONG size, head, tail, base;
    int ok = 1;
    if (!MultiByteToWideChar(CP_UTF8, 0, rf->dst, -1, wname, 64)) return 0;
    _snwprintf(dst, MAX_PATH - 1, L"%s%s", RP.dir, wname); dst[MAX_PATH - 1] = 0;
    h = CreateFileW(rf->src, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) return 0;
    if (!GetFileSizeEx(h, &sz)) { CloseHandle(h); return 0; }
    o = CreateFileW(dst, GENERIC_WRITE, 0, NULL, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, NULL);
    if (o == INVALID_HANDLE_VALUE) { CloseHandle(h); return 0; }
    size = (ULONGLONG)sz.QuadPart;
    base = rf->start < size ? rf->start : size;          /* (an earlier run's lines above this run's, when they could not be moved) */
    if (rf->cap == 0 || size - base <= rf->cap) ok = rep_copy_range(h, o, base, size, in, out, mid, rf->kind);
    else {
        char note[200];
        int n;
        ULONGLONG from;
        head = rf->cap / 4; if (head > REP_HEAD_MAX) head = REP_HEAD_MAX;
        tail = rf->cap - head;
        ok = rep_copy_range(h, o, base, base + head, in, out, mid, rf->kind);
        head += base;
        /* the end starts at a whole line: the first newline at or after (size - tail) */
        from = size - tail;
        {
            LARGE_INTEGER li; DWORD got = 0; DWORD k;
            li.QuadPart = (LONGLONG)from;
            if (SetFilePointerEx(h, li, NULL, FILE_BEGIN) && ReadFile(h, in, 65536, &got, NULL)) {
                for (k = 0; k < got; k++) if (in[k] == '\n') { from += k + 1; break; }
            }
        }
        n = _snprintf(note, sizeof(note) - 1, "\r\n... %.1f MB of this file are left out here (the bug report keeps its start and its end) ...\r\n",
                      (double)(from - head) / 1048576.0);
        if (ok && n > 0) ok = rep_write(o, note, (size_t)n);
        if (ok) ok = rep_copy_range(h, o, from, size, in, out, mid, rf->kind);
    }
    CloseHandle(h);
    CloseHandle(o);
    if (!ok) DeleteFileW(dst);
    return ok;
}

static int rep_zip_ok(void)
{
    HANDLE h = CreateFileW(RP.zipPath, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    char sig[4] = { 0 };
    DWORD got = 0;
    LARGE_INTEGER sz;
    int ok;
    if (h == INVALID_HANDLE_VALUE) return 0;
    ok = GetFileSizeEx(h, &sz) && sz.QuadPart > 100 && ReadFile(h, sig, 4, &got, NULL) && got == 4 && memcmp(sig, "PK\x03\x04", 4) == 0;
    CloseHandle(h);
    return ok;
}

/* Windows' own tar.exe, never one from PATH; no console window. 0 = zip made; else the reason in why */
static int rep_tar(char *why, size_t whylen)
{
    wchar_t tar[MAX_PATH], cmdline[2 * MAX_PATH];
    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    DWORD code = 1, w;
    UINT n = GetSystemDirectoryW(tar, MAX_PATH - 10);
    if (n == 0 || n >= MAX_PATH - 10) { _snprintf(why, whylen, "no system folder"); return 1; }
    wcscat(tar, L"\\tar.exe");
    if (GetFileAttributesW(tar) == INVALID_FILE_ATTRIBUTES) { _snprintf(why, whylen, "this Windows has no tar.exe"); return 1; }
    /* run in the reports folder with relative names: no path (and so no user name) on the command line */
    _snwprintf(cmdline, 2 * MAX_PATH - 1, L"\"%s\" -a -c -f \"report_%S.zip\" \"report_%S\"", tar, RP.stamp, RP.stamp);
    cmdline[2 * MAX_PATH - 1] = 0;
    memset(&si, 0, sizeof(si)); si.cb = sizeof(si); si.dwFlags = STARTF_USESHOWWINDOW; si.wShowWindow = SW_HIDE;
    memset(&pi, 0, sizeof(pi));
    if (!CreateProcessW(tar, cmdline, NULL, NULL, FALSE, CREATE_NO_WINDOW, NULL, RP.reports, &si, &pi)) {
        _snprintf(why, whylen, "tar.exe did not start (error %lu)", GetLastError());
        return 1;
    }
    w = WaitForSingleObject(pi.hProcess, 120000);
    if (w != WAIT_OBJECT_0) { TerminateProcess(pi.hProcess, 1); WaitForSingleObject(pi.hProcess, 5000); _snprintf(why, whylen, "tar.exe took longer than 120 s"); }
    else GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hThread); CloseHandle(pi.hProcess);
    if (w != WAIT_OBJECT_0) return 1;
    if (code != 0) { _snprintf(why, whylen, "tar.exe ended with code %lu", code); return 1; }
    if (!rep_zip_ok()) { _snprintf(why, whylen, "tar.exe made no readable zip"); return 1; }
    return 0;
}

/* Explorer with the zip (or the folder) selected; Explorer is a window program, no console */
static int rep_open(const wchar_t *what)
{
    wchar_t exe[MAX_PATH], cmdline[2 * MAX_PATH];
    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    UINT n = GetWindowsDirectoryW(exe, MAX_PATH - 16);
    if (n == 0 || n >= MAX_PATH - 16) return 0;
    wcscat(exe, L"\\explorer.exe");
    _snwprintf(cmdline, 2 * MAX_PATH - 1, L"explorer.exe /select,\"%s\"", what);
    cmdline[2 * MAX_PATH - 1] = 0;
    memset(&si, 0, sizeof(si)); si.cb = sizeof(si);
    memset(&pi, 0, sizeof(pi));
    if (!CreateProcessW(exe, cmdline, NULL, NULL, FALSE, 0, NULL, NULL, &si, &pi)) return 0;
    CloseHandle(pi.hThread); CloseHandle(pi.hProcess);
    return 1;
}

static DWORD WINAPI rep_thread(void *arg)
{
    char *in = (char *)malloc(REP_CHUNK), *out = (char *)malloc(REP_CHUNK * 4), *mid = (char *)malloc(REP_CHUNK * 2);
    char why[160] = "";
    int i, zipped = 0, opened = 0;
    (void)arg;
    RP.copied = 0;
    if (in && out && mid) for (i = 0; i < RP.nfiles; i++) if (rep_copy(&RP.f[i], in, out, mid)) RP.copied++;
    free(in); free(out); free(mid);
    if (!RP.zip) _snprintf(why, sizeof(why) - 1, "no zip asked");
    else if (rep_tar(why, sizeof(why) - 1) == 0) zipped = 1;
    else DeleteFileW(RP.zipPath);                          /* a partial zip */
    if (zipped) {                                          /* the folder's copies were zipped: only the files written here go */
        wchar_t p[MAX_PATH], wname[64];
        for (i = 0; i < RP.nfiles; i++) {
            if (!MultiByteToWideChar(CP_UTF8, 0, RP.f[i].dst, -1, wname, 64)) continue;
            _snwprintf(p, MAX_PATH - 1, L"%s%s", RP.dir, wname); p[MAX_PATH - 1] = 0;
            DeleteFileW(p);
        }
        RemoveDirectoryW(RP.dir);
    }
    if (RP.open) opened = rep_open(zipped ? RP.zipPath : RP.dir);
    if (zipped) _snprintf(RP.result, sizeof(RP.result) - 1, "done report_%s.zip %d%s", RP.stamp, RP.copied, opened ? " opened" : "");
    else _snprintf(RP.result, sizeof(RP.result) - 1, "folder report_%s %d %s%s", RP.stamp, RP.copied, why, opened ? " opened" : "");
    RP.result[sizeof(RP.result) - 1] = 0;
    InterlockedExchange(&RP.state, 2);
    return 0;
}

/* REPORT <stamp>: read the job, check it, start the report's thread */
static void report_cmd(int argc, char **argv)
{
    wchar_t job[MAX_PATH], link[MAX_PATH];
    FILE *f;
    char line[1600];
    /* first: while a report is being made nothing changes (not even a refusal's state: a second job would start beside it) */
    if (RP.state == 1) { log_line("REPORT %.48s refused: report_%s is still being made", argc > 1 ? argv[1] : "-", RP.stamp); return; }
    if (argc != 2 || !rep_name_ok(argv[1], sizeof(RP.stamp))) { rep_refuse(NULL, "needs REPORT <stamp> (letters, digits, - and _)"); return; }
    if (RP.thread) { CloseHandle(RP.thread); RP.thread = NULL; }
    strcpy(RP.stamp, argv[1]);
    RP.open = 1; RP.zip = 1; RP.nfiles = 0; RP.copied = 0;
    g_scrub_n = g_scrub_base;                              /* the last job's names go */
    join_path(job, g_dir, L"patch_report_job.txt");
    f = _wfopen(job, L"rb");
    if (!f) { rep_refuse(RP.stamp, "no patch_report_job.txt"); return; }
    while (fgets(line, sizeof(line), f)) {
        char *a, *b, *c;
        trim(line);
        if (!line[0] || line[0] == '#') continue;
        if (strncmp(line, "open ", 5) == 0) { RP.open = atoi(line + 5) != 0; continue; }
        if (strncmp(line, "zip ", 4) == 0) { RP.zip = atoi(line + 4) != 0; continue; }
        a = strchr(line, ' ');
        if (!a) continue;
        *a++ = 0;
        b = strchr(a, '\t');
        if (_stricmp(line, "name") == 0 && b) { *b++ = 0; scrub_add(a, b, 0); continue; }
        if ((_stricmp(line, "file") == 0 || _stricmp(line, "steamlog") == 0 || _stricmp(line, "steamstatus") == 0) && b) {
            rep_file *rf;
            char *d = NULL;
            int kind = _stricmp(line, "steamlog") == 0 ? SCRUB_STEAM_LOG : _stricmp(line, "steamstatus") == 0 ? SCRUB_STEAM_STATUS : 0;
            *b++ = 0;
            c = strchr(b, '\t');
            if (c) { *c++ = 0; d = strchr(c, '\t'); if (d) *d++ = 0; }
            if (!rep_name_ok(b, sizeof(RP.f[0].dst))) { fclose(f); rep_refuse(RP.stamp, "a file name in the job is not a plain name"); return; }
            if (RP.nfiles >= REP_MAX_FILES) continue;
            rf = &RP.f[RP.nfiles];
            if (!MultiByteToWideChar(CP_UTF8, 0, a, -1, rf->src, MAX_PATH)) continue;
            strcpy(rf->dst, b);
            rf->cap = c ? _strtoui64(c, NULL, 10) : 0;
            rf->start = d ? _strtoui64(d, NULL, 10) : 0;
            rf->kind = kind;
            RP.nfiles++;
        }
    }
    fclose(f);
    /* <mod>\link\reports\report_<stamp>\ : built here, never from the job */
    join_path(link, g_moddir, L"link\\");
    CreateDirectoryW(link, NULL);
    join_path(RP.reports, link, L"reports\\");
    CreateDirectoryW(RP.reports, NULL);
    _snwprintf(RP.dir, MAX_PATH - 1, L"%sreport_%S\\", RP.reports, RP.stamp); RP.dir[MAX_PATH - 1] = 0;
    _snwprintf(RP.zipPath, MAX_PATH - 1, L"%sreport_%S.zip", RP.reports, RP.stamp); RP.zipPath[MAX_PATH - 1] = 0;
    if (GetFileAttributesW(RP.zipPath) != INVALID_FILE_ATTRIBUTES || !CreateDirectoryW(RP.dir, NULL)) { rep_refuse(RP.stamp, "a report of that name is there already"); return; }
    InterlockedExchange(&RP.state, 1);
    RP.shown = -1;
    RP.jobs++;
    RP.thread = CreateThread(NULL, 0, rep_thread, NULL, 0, NULL);
    if (!RP.thread) { RemoveDirectoryW(RP.dir); rep_refuse(RP.stamp, "no thread"); return; }
    log_line("REPORT %s: %d file(s) asked, zip %s, open %s", RP.stamp, RP.nfiles, RP.zip ? "yes" : "no", RP.open ? "yes" : "no");
    g_dirty = 1;
}

/* game thread, every tick: a finished report is written down once */
static void report_tick(void)
{
    LONG st = RP.state;
    if (st == RP.shown) return;
    RP.shown = st;
    g_dirty = 1;
    if (st == 2) {
        if (RP.thread) { CloseHandle(RP.thread); RP.thread = NULL; }
        log_line("REPORT %s", RP.result);
    }
}

static int report_status(char *buf, size_t len)
{
    LONG st = RP.state;
    if (st == 0) return _snprintf(buf, len, "REPORT idle\r\n");
    if (st == 1) return _snprintf(buf, len, "REPORT running report_%s\r\n", RP.stamp);
    return _snprintf(buf, len, "REPORT %s\r\n", RP.result);
}

/* at the first tick: the mod's link folder and its sessions and reports folders (the mod's Lua cannot make a folder
 * without a console window). Inside this DLL's own folder only. */
static void report_dirs(void)
{
    wchar_t p[MAX_PATH];
    join_path(p, g_moddir, L"link"); CreateDirectoryW(p, NULL);
    join_path(p, g_moddir, L"link\\sessions"); CreateDirectoryW(p, NULL);
    join_path(p, g_moddir, L"link\\reports"); CreateDirectoryW(p, NULL);
}
