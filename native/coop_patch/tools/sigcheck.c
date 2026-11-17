/* sigcheck.c - offline check of every coop_patch signature against the game executable FILE (never the running game).
 *
 * Reads the PE headers and the raw bytes of .text from disk, then runs the same scan and site evaluation as the DLL
 * (coop_scan.h). Checks, per signature: exactly one hit; RVA equals the RVA written in sigs5.txt / native4_sigs.txt;
 * for patches: the bytes at the patch offset equal the "original bytes" of sigs5.txt, the call target is the unique
 * entry hit (P2 -> TriggerSquadRetreat, P3a/P3b -> reformSquad), the patch lies inside one aligned 8-byte block.
 * Also prints the time one scan pass takes (the DLL does the same pass on its first tick, on the game thread).
 *
 * Usage: sigcheck.exe [path to ManorLords-Win64-Shipping.exe]     exit code 0 = everything holds
 *        (no path: %ML_TEST_ROOT%\_ml_test\...\ManorLords-Win64-Shipping.exe; neither: the usage, exit code 2)
 */
#define WIN32_LEAN_AND_MEAN
#ifndef _CRT_SECURE_NO_WARNINGS
#define _CRT_SECURE_NO_WARNINGS
#endif
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include "../coop_scan.h"

/* Without an argument: the lead's TEST copy of the game under ML_TEST_ROOT (an environment variable; build.cmd test
 * reads it from tools\dev\local.env), never the real install: two lanes once ran this check without an argument and so
 * read the real install's file (read only, but against the rule). The real install's file is checked only when its
 * path is given on purpose. Neither given: the usage is printed and nothing is read. */
#define TEST_COPY_EXE "\\_ml_test\\ManorLords\\Binaries\\Win64\\ManorLords-Win64-Shipping.exe"

static int read_at(FILE *f, long long off, void *buf, size_t n)
{
    if (_fseeki64(f, off, SEEK_SET) != 0) return 0;
    return fread(buf, 1, n, f) == n;
}

typedef struct { const uint8_t *text; uint32_t rva; } file_ctx;
static const uint8_t *file_at(uint32_t rva, void *ctx)
{
    const file_ctx *c = (const file_ctx *)ctx;
    return c->text + (rva - c->rva);
}

int main(int argc, char **argv)
{
    static char test_copy[MAX_PATH];
    const char *root = getenv("ML_TEST_ROOT");
    const char *path = NULL;
    FILE *f;
    IMAGE_DOS_HEADER dos;
    IMAGE_NT_HEADERS64 nt;
    IMAGE_SECTION_HEADER sec[96];
    uint8_t *text = NULL;
    uint32_t text_rva = 0, text_raw = 0, text_len = 0;
    sig_pat pats[SIG_COUNT];
    sig_hit hits[SIG_COUNT];
    int i, k, fails = 0;
    LARGE_INTEGER fq, t0, t1;

    if (argc > 1) path = argv[1];
    else if (root && root[0]) {
        int n = snprintf(test_copy, sizeof(test_copy), "%s%s", root, TEST_COPY_EXE);
        if (n < 0 || n >= (int)sizeof(test_copy)) { printf("ML_TEST_ROOT is too long\n"); return 2; }
        path = test_copy;
    } else {
        printf("usage: sigcheck.exe <path to ManorLords-Win64-Shipping.exe>\n"
               "   or set ML_TEST_ROOT (the folder holding the test copy _ml_test; see tools\\dev\\local.env.example)\n");
        return 2;
    }
    f = fopen(path, "rb");
    if (!f) { printf("cannot open %s\n", path); return 2; }
    if (!read_at(f, 0, &dos, sizeof(dos)) || dos.e_magic != IMAGE_DOS_SIGNATURE) { printf("no DOS header\n"); return 2; }
    if (!read_at(f, dos.e_lfanew, &nt, sizeof(nt)) || nt.Signature != IMAGE_NT_SIGNATURE || nt.OptionalHeader.Magic != IMAGE_NT_OPTIONAL_HDR64_MAGIC) { printf("not PE32+\n"); return 2; }
    if (nt.FileHeader.NumberOfSections > 96) { printf("too many sections\n"); return 2; }
    if (!read_at(f, dos.e_lfanew + 4 + (long long)sizeof(IMAGE_FILE_HEADER) + nt.FileHeader.SizeOfOptionalHeader, sec,
                 sizeof(IMAGE_SECTION_HEADER) * nt.FileHeader.NumberOfSections)) { printf("no section table\n"); return 2; }
    printf("file: %s\n", path);
    printf("PE TimeDateStamp %08X  SizeOfImage %X  CheckSum %X\n", nt.FileHeader.TimeDateStamp, nt.OptionalHeader.SizeOfImage, nt.OptionalHeader.CheckSum);
    if (nt.FileHeader.TimeDateStamp == KNOWN_TIMESTAMP && nt.OptionalHeader.SizeOfImage == KNOWN_IMAGESIZE)
        printf("=> same build as the copy the report was made from (6836C1BA / 9DFD000)\n");
    else
        printf("=> DIFFERENT build from the report's copy (known 6836C1BA / 9DFD000)\n");
    for (i = 0; i < nt.FileHeader.NumberOfSections; i++) {
        if (memcmp(sec[i].Name, ".text\0\0\0", 8) == 0) {
            text_rva = sec[i].VirtualAddress;
            text_raw = sec[i].PointerToRawData;
            text_len = sec[i].Misc.VirtualSize < sec[i].SizeOfRawData ? sec[i].Misc.VirtualSize : sec[i].SizeOfRawData;
        }
    }
    if (!text_len) { printf("no .text\n"); return 2; }
    printf(".text: rva %X..%X (raw offset %X, %u bytes scanned)\n\n", text_rva, text_rva + text_len, text_raw, text_len);
    text = (uint8_t *)malloc(text_len);
    if (!text || !read_at(f, text_raw, text, text_len)) { printf("cannot read .text\n"); return 2; }
    fclose(f);

    for (k = 0; k < SIG_COUNT; k++) if (sig_parse(&SIGS[k], &pats[k]) != 0) { printf("bad pattern %s\n", SIGS[k].name); return 2; }
    QueryPerformanceFrequency(&fq);
    /* timing: the DLL's own pass (its 6 signatures) and the full pass (all 14) */
    QueryPerformanceCounter(&t0);
    scan_text(text, text_rva, text_len, SIGS, pats, S_DLL_COUNT, hits);
    QueryPerformanceCounter(&t1);
    printf("scan pass, the DLL's %d signatures: %.0f ms\n", (int)S_DLL_COUNT, (double)(t1.QuadPart - t0.QuadPart) * 1000.0 / (double)fq.QuadPart);
    QueryPerformanceCounter(&t0);
    scan_text(text, text_rva, text_len, SIGS, pats, SIG_COUNT, hits);
    QueryPerformanceCounter(&t1);
    printf("scan pass, all %d signatures:     %.0f ms\n\n", SIG_COUNT, (double)(t1.QuadPart - t0.QuadPart) * 1000.0 / (double)fq.QuadPart);

    printf("%-12s %-4s %-8s %-8s %-5s %-10s %-11s %-11s %-12s %-6s %s\n", "name", "dll", "hits", "rva", "rva=", "patch_rva", "bytes_now", "orig(sigs5)", "call_target", "qword", "result");
    for (k = 0; k < SIG_COUNT; k++) {
        const sig_def *d = &SIGS[k];
        const sig_hit *h = &hits[k];
        int ok = 1;
        char now[24] = "-", ref[24] = "-", tgt[24] = "-", qw[8] = "-", prva[16] = "-";
        if (h->hits != 1) ok = 0;
        if (h->rva != d->ref_rva) ok = 0;
        if (d->kind == K_SITE && h->hits == 1) {        /* TOTALS sites: never written; the call must reach its entry */
            uint32_t pr = h->rva + (uint32_t)d->patch_off, target;
            snprintf(prva, sizeof(prva), "%X", pr);
            if (!goods_call_target(text + (pr - text_rva), pr, &target)) { ok = 0; snprintf(tgt, sizeof(tgt), "no call"); }
            else {
                snprintf(tgt, sizeof(tgt), "%X%s", target, target == hits[d->call_target].rva && hits[d->call_target].hits == 1 ? "" : "!");
                if (target != hits[d->call_target].rva || hits[d->call_target].hits != 1) ok = 0;
            }
        }
        if ((d->kind == K_FIXED || d->kind == K_CALL) && h->hits == 1) {
            uint32_t pr = h->rva + (uint32_t)d->patch_off;
            const uint8_t *pp = text + (pr - text_rva);
            site_eval e;
            int n = 0, m = 0;
            snprintf(prva, sizeof(prva), "%X", pr);
            for (i = 0; i < d->patch_len; i++) n += snprintf(now + n, sizeof(now) - (size_t)n, "%02X", pp[i]);
            for (i = 0; i < d->patch_len; i++) m += snprintf(ref + m, sizeof(ref) - (size_t)m, "%02X", d->orig[i]);
            if (memcmp(pp, d->orig, (size_t)d->patch_len) != 0) ok = 0;            /* exact sigs5 "original bytes" */
            snprintf(qw, sizeof(qw), "%s", ((pr & ~7u) == ((pr + (uint32_t)d->patch_len - 1) & ~7u)) ? "one" : "CROSS");
            if (qw[0] == 'C') ok = 0;
            if (d->kind == K_CALL) {
                int32_t rel; uint32_t target;
                memcpy(&rel, pp + 1, 4);
                target = (uint32_t)((int64_t)pr + 5 + rel);
                snprintf(tgt, sizeof(tgt), "%X%s", target, target == hits[d->call_target].rva && hits[d->call_target].hits == 1 ? "" : "!");
                if (pp[0] != 0xE8 || target != hits[d->call_target].rva || hits[d->call_target].hits != 1) ok = 0;
            }
            /* and the DLL's own evaluation must say "off" (unpatched, all checks passed) */
            eval_site(d, h, hits, pp, pr, &e);
            if (e.state != ST_OFF) { ok = 0; printf("  (eval: %s %s)\n", e.state == ST_ON ? "on" : "unavailable", e.why); }
        }
        if (!ok) fails++;
        printf("%-12s %-4s %-8d %-8X %-5s %-10s %-11s %-11s %-12s %-6s %s\n", d->name, d->used_by_dll ? "yes" : "no", h->hits, h->rva,
               h->rva == d->ref_rva ? "yes" : "NO", prva, now, ref, tgt, qw, ok ? "PASS" : "FAIL");
    }
    {   /* GOODS: the same check the DLL makes before it writes a hook (coop_scan.h goods_check) */
        char why[160] = "";
        int ok = hits[S_RECOUNT].hits == 1 && hits[S_REFRESH].hits == 1 && hits[S_ADDINV].hits == 1 &&
                 goods_check(hits, text + (hits[S_RECOUNT].rva - text_rva), text + (hits[S_REFRESH].rva - text_rva), text + (hits[S_ADDINV].rva - text_rva),
                             hits[S_RECOUNT].rva, hits[S_REFRESH].rva, why, sizeof(why));
        if (!ok && !why[0]) snprintf(why, sizeof(why), "an entry signature does not have exactly one hit");
        printf("\nGOODS (hooks at RECOUNT and REFRESH; ADDINV's calls at +45h and +64h must reach them): %s %s\n", ok ? "PASS" : "FAIL", why);
        if (!ok) fails++;
    }
    {   /* TOTALS: the same check the DLL makes before it writes its hook (coop_scan.h totals_check) */
        char why[160] = "";
        file_ctx ctx;
        int ok;
        ctx.text = text; ctx.rva = text_rva;
        ok = totals_check(hits, file_at, &ctx, hits[S_ADDLIST].rva, why, sizeof(why));
        printf("TOTALS (hook at ADDLIST; NOTIFY found; TS1-TS6 each call ADDLIST): %s %s\n", ok ? "PASS" : "FAIL", why);
        if (!ok) fails++;
    }
    {   /* HOLD (lane 31): the same check the DLL makes before it writes its seven entry hooks and the store site */
        char why[160] = "";
        file_ctx ctx;
        uint32_t grow = 0;
        int ok;
        ctx.text = text; ctx.rva = text_rva;
        ok = hold_check(hits, file_at, &ctx, &grow, why, sizeof(why));
        printf("HOLD (hooks at HAPPR HORDER HSUPPL HWADD HWSUB HPADD HPREM HPRMALL, the store HWMON; body offsets; grow helper %X): %s %s\n", grow, ok ? "PASS" : "FAIL", why);
        if (!ok) fails++;
    }
    printf("\n%d of %d signatures hold%s\n", SIG_COUNT - fails, SIG_COUNT, fails ? "" : " (all)");
    free(text);
    return fails ? 1 : 0;
}
