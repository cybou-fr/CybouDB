/* tests/page_resolve_test.c - the engine's page address, in encrypted mode
 *
 * db_page_resolve is what the 128 page-address sites will reach when the
 * database is encrypted: it looks in the cache, and on a miss reads the page,
 * finds its entry in the seal directory, opens it, and hands back the frame.
 *
 * The context it works from is built here by hand, field by field, because the
 * engine cannot yet make one - docs/ENCRYPTED_ENGINE.md, step 3. That is the
 * point of testing it now: the resolver is finished and checkable before the
 * open path that will fill that context exists, so the port lands on something
 * that already works.
 *
 * Build (Linux):   sh build.sh --crypto-tests && ./build/page_resolve_test
 * Build (Windows): build.bat --crypto-tests && build\page_resolve_test.exe
 *
 * SPDX-License-Identifier: Apache-2.0
 * Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#define PAGE 4096

/* include/cyboudb.inc holds these; the test needs the same numbers to build a
   context the assembly will read. */
#define DB_HANDLE       0
#define DB_BASE         8
#define DB_GENERATION   40
#define RUN_SIZE        16
#define DIRTY_RUNS_MAX  32
#define DB_RUNS         248
#define DB_CACHE        (DB_RUNS + DIRTY_RUNS_MAX * RUN_SIZE)
#define DB_SEAL_KEY     (DB_CACHE + 8)
#define DB_UUID         (DB_SEAL_KEY + 32)
#define DB_SEAL_EPOCH   (DB_UUID + 16)
#define DB_SEAL_DIR     (DB_SEAL_EPOCH + 8)
#define DB_SEAL_LEAVES  (DB_SEAL_DIR + 8)
#define DB_ENC_ERROR    (DB_SEAL_LEAVES + 8)
#define DB_SIZE_BYTES       4096

#define SENTRY_SIZE 48
#define SENTRY_GENERATION 40
#define ENTRIES_PER_LEAF 83

#define P_LEAF     1
#define P_FIRST    100        /* the first page the leaf covers is 100 */
#define TOTAL      110

#define E_SEAL  42
#define E_STATE 22

#ifdef _WIN32
typedef const wchar_t *vfs_path;
#define VFS_PATH(x) L##x
#else
typedef const char *vfs_path;
#define VFS_PATH(x) x
#endif

int64_t vfs_create_truncate(vfs_path path, uint64_t *reason);
int64_t vfs_open_rw(vfs_path path, uint64_t *reason);
int64_t vfs_write_at(int64_t h, const void *buf, uint64_t bytes,
                     uint64_t offset);
int64_t vfs_read_at(int64_t h, void *buf, uint64_t bytes, uint64_t offset);
int64_t vfs_sync_file(int64_t h);
void vfs_close(int64_t h);

int os_random(uint8_t *out, uint64_t bytes);
uint32_t crc32c(const uint8_t *buf, uint64_t len);

uint64_t cyboudb_pcache_bytes(uint64_t frames);
int cyboudb_pcache_init(uint8_t *mem, uint64_t bytes, uint64_t frames);
void cyboudb_pcache_stats(const uint8_t *cache, uint64_t *out);

void cyboudb_seal_leaf_init(uint8_t *page, uint64_t index, uint64_t generation,
                            uint64_t epoch);
uint8_t *cyboudb_seal_entry(uint8_t *leaf, uint64_t page_number);

struct pseal_args {
    const uint8_t *key;
    uint8_t *page;
    uint8_t *entry;
    const uint8_t *uuid;
    uint64_t page_no, generation, page_type, epoch;
};
int cyboudb_page_seal(const struct pseal_args *args);

uint8_t *db_page_resolve(uint8_t *ctx, uint64_t page);
uint8_t *db_page_for_write(uint8_t *ctx, uint64_t page, uint64_t page_type);
int db_pages_flush(uint8_t *ctx);
uint64_t db_context_bytes(void);
uint64_t cyboudb_pcache_dirty_at(const uint8_t *cache, uint64_t slot);
uint64_t cyboudb_pcache_type_at(const uint8_t *cache, uint64_t slot);
uint64_t cyboudb_pcache_frames(const uint8_t *cache);

static int checks, failures;

static void check(const char *what, int ok) {
    checks++;
    if (ok) printf("ok   %s\n", what);
    else { failures++; printf("FAIL %s\n", what); }
}

static void wr64(uint8_t *p, int off, uint64_t v) { memcpy(p + off, &v, 8); }
static uint64_t rd64(const uint8_t *p, int off) {
    uint64_t v; memcpy(&v, p + off, 8); return v;
}

static uint8_t ctx[DB_SIZE_BYTES];
static uint8_t leaf[PAGE], scratch[PAGE];
static uint8_t seal_key[32], uuid[16];
static const uint64_t GENERATION = 12, EPOCH = 3;

/* Page n carries a sentence naming itself, so a resolver that returns the
   wrong page is caught by content and not only by an address. */
static void page_content(uint8_t *out, uint64_t page) {
    memset(out, 0, PAGE);
    snprintf((char *)out, 64, "this is page %llu", (unsigned long long)page);
    {
        unsigned i;
        for (i = 128; i < PAGE; i++) out[i] = (uint8_t)(i + page);
    }
}

int main(void) {
    if (db_context_bytes() > DB_SIZE_BYTES) {
        printf("FAIL the context outgrew what this test allocates\n");
        return 1;
    }

    vfs_path path = VFS_PATH("build/page_resolve_test.cdb");
    uint8_t *cache_mem, *cache_raw;
    uint64_t cache_bytes;
    int64_t h;
    unsigned i;

    printf("CybouDB encrypted page resolve test\n\n");

    check("randomness for a key and an identity",
          os_random(seal_key, 32) == 0 && os_random(uuid, 16) == 0);

    /* --- a file: one seal leaf and ten sealed pages -------------------------- */
    h = vfs_create_truncate(path, 0);
    check("the file opens", h != -1);
    if (h == -1) return 1;

    cyboudb_seal_leaf_init(leaf, 1, GENERATION, EPOCH);   /* leaf 1: pages 100.. */
    for (i = 0; i < 10; i++) {
        struct pseal_args a;
        page_content(scratch, P_FIRST + i);
        a.key = seal_key;
        a.page = scratch;
        a.entry = cyboudb_seal_entry(leaf, P_FIRST + i);
        a.uuid = uuid;
        a.page_no = P_FIRST + i;
        a.generation = GENERATION;
        a.page_type = (uint64_t)(i % 5) + 1;
        a.epoch = EPOCH;
        if (cyboudb_page_seal(&a) != 0) { printf("seal failed\n"); return 1; }
        vfs_write_at(h, scratch, PAGE, (uint64_t)(P_FIRST + i) * PAGE);
    }
    vfs_write_at(h, leaf, PAGE, (uint64_t)P_LEAF * PAGE);
    vfs_sync_file(h);
    vfs_close(h);
    check("ten pages sealed and written, with their entries in one leaf", 1);

    /* --- the context the engine will one day fill in ------------------------- */
    h = vfs_open_rw(path, 0);
    cache_bytes = cyboudb_pcache_bytes(16);
    cache_raw = malloc((size_t)cache_bytes + PAGE);
    cache_mem = (uint8_t *)(((uintptr_t)cache_raw + PAGE - 1) &
                            ~(uintptr_t)(PAGE - 1));
    cyboudb_pcache_init(cache_mem, cache_bytes, 16);

    memset(ctx, 0, sizeof ctx);
    wr64(ctx, DB_HANDLE, (uint64_t)h);
    wr64(ctx, DB_GENERATION, GENERATION);
    wr64(ctx, DB_CACHE, (uint64_t)(uintptr_t)cache_mem);
    memcpy(ctx + DB_SEAL_KEY, seal_key, 32);
    memcpy(ctx + DB_UUID, uuid, 16);
    wr64(ctx, DB_SEAL_EPOCH, EPOCH);
    wr64(ctx, DB_SEAL_DIR, 0);      /* leaf n lives at page n: leaf 1 at page 1 */
    wr64(ctx, DB_SEAL_LEAVES, 2);

    /* --- a miss, and what comes back ---------------------------------------- */
    {
        uint8_t *frame = db_page_resolve(ctx, P_FIRST + 3);
        char want[64];
        snprintf(want, sizeof want, "this is page %d", P_FIRST + 3);
        check("a page nobody has asked for resolves", frame != NULL);
        check("and the plaintext is that page", frame != NULL &&
              strcmp((char *)frame, want) == 0);
        check("and nothing is recorded as an error",
              rd64(ctx, DB_ENC_ERROR) == 0);
    }

    /* --- and again, from the cache ------------------------------------------- */
    {
        uint64_t before[3], after[3];
        uint8_t *first, *second;
        cyboudb_pcache_stats(cache_mem, before);
        first = db_page_resolve(ctx, P_FIRST + 3);
        second = db_page_resolve(ctx, P_FIRST + 3);
        cyboudb_pcache_stats(cache_mem, after);
        check("asking twice gives the same frame", first == second);
        check("and the second time is a cache hit, not a second decrypt",
              after[0] > before[0]);
    }

    /* --- every page, and each is its own -------------------------------------- */
    {
        int ok = 1;
        for (i = 0; i < 10; i++) {
            uint8_t *frame = db_page_resolve(ctx, P_FIRST + i);
            char want[64];
            snprintf(want, sizeof want, "this is page %d", P_FIRST + i);
            if (!frame || strcmp((char *)frame, want) != 0) ok = 0;
        }
        check("all ten resolve, each to its own contents", ok);
    }

    /* --- a page that was never sealed ----------------------------------------- */
    {
        uint8_t *frame = db_page_resolve(ctx, P_FIRST + 50);
        check("a page with no entry does not resolve", frame == NULL);
        check("and says why", rd64(ctx, DB_ENC_ERROR) == E_SEAL);
    }

    /* --- a page altered on the disk under the engine --------------------------
       The cache is emptied first, and that is not a convenience: a page the
       engine has already decrypted is not read again, so altering the disk
       underneath a cached page changes nothing a reader sees. The first
       version of this check did not empty the cache, watched the page resolve
       from memory, and would have reported a tamper check that was not
       testing anything. */
    cyboudb_pcache_init(cache_mem, cache_bytes, 16);
    {
        uint8_t *frame;
        vfs_read_at(h, scratch, PAGE, (uint64_t)(P_FIRST + 7) * PAGE);
        scratch[2000] ^= 0x01;
        vfs_write_at(h, scratch, PAGE, (uint64_t)(P_FIRST + 7) * PAGE);

        frame = db_page_resolve(ctx, P_FIRST + 7);
        check("a page altered on disk does not resolve", frame == NULL);
        check("and is reported as a seal failure",
              rd64(ctx, DB_ENC_ERROR) == E_SEAL);

        /* And it is not left in the cache looking like a page that verified -
           the check that matters most here, because a frame holding
           unverified bytes would be handed out by every later lookup without
           going near the tag again. */
        frame = db_page_resolve(ctx, P_FIRST + 7);
        check("and does not become a cache hit on the next attempt",
              frame == NULL);
    }

    /* --- the same page, put back as it was ------------------------------------ */
    {
        uint8_t *frame;
        vfs_read_at(h, scratch, PAGE, (uint64_t)(P_FIRST + 7) * PAGE);
        scratch[2000] ^= 0x01;
        vfs_write_at(h, scratch, PAGE, (uint64_t)(P_FIRST + 7) * PAGE);
        frame = db_page_resolve(ctx, P_FIRST + 7);
        check("and resolves again once the page is what it was", frame != NULL);
    }

    /* --- a generation the page was not sealed under ---------------------------- */
    /*  Moving the database on does not hide a page any more: the generation a
        page was sealed under is stored in its entry, which is the whole reason
        a commit that leaves a page alone leaves it readable. What must still
        fail is an entry claiming a generation the tag was not built over. */
    {
        uint8_t *frame;
        uint8_t *e;

        wr64(ctx, DB_GENERATION, GENERATION + 1);
        cyboudb_pcache_init(cache_mem, cache_bytes, 16);   /* a cold cache */
        frame = db_page_resolve(ctx, P_FIRST + 1);
        check("a later generation still reads a page it did not rewrite",
              frame != NULL);
        wr64(ctx, DB_GENERATION, GENERATION);

        e = cyboudb_seal_entry(leaf, P_FIRST + 1);
        e[SENTRY_GENERATION] ^= 0x01;
        vfs_write_at(h, leaf, PAGE, (uint64_t)P_LEAF * PAGE);
        cyboudb_pcache_init(cache_mem, cache_bytes, 16);
        check("an entry moved to another generation does not resolve",
              db_page_resolve(ctx, P_FIRST + 1) == NULL);

        e[SENTRY_GENERATION] ^= 0x01;
        vfs_write_at(h, leaf, PAGE, (uint64_t)P_LEAF * PAGE);
        cyboudb_pcache_init(cache_mem, cache_bytes, 16);
        check("and resolves again once the entry is what it was",
              db_page_resolve(ctx, P_FIRST + 1) != NULL);
    }

    /* --- and one sealed under another epoch's key ------------------------------ */
    {
        uint8_t *frame;
        ctx[DB_SEAL_KEY] ^= 0x01;
        cyboudb_pcache_init(cache_mem, cache_bytes, 16);
        frame = db_page_resolve(ctx, P_FIRST + 1);
        check("nor does one under another key", frame == NULL);
        ctx[DB_SEAL_KEY] ^= 0x01;
        cyboudb_pcache_init(cache_mem, cache_bytes, 16);
        check("while the right key still resolves it",
              db_page_resolve(ctx, P_FIRST + 1) != NULL);
    }

    /* --- writing, and the first two steps of a commit -----------------------
       db_page_for_write hands back the same frame a read would and marks it,
       db_pages_flush seals every marked frame under the current generation,
       writes it, and puts its nonce and tag into the leaf that covers it.

       A page may only be dirtied if this generation allocated it - copy on
       write is what makes that true, and it is what makes writing a frame
       back in place safe. Here that is respected by writing to pages 105 to
       107 as though they were freshly allocated for generation 13. */
    {
        uint8_t *frame;
        int ok = 1;

        cyboudb_pcache_init(cache_mem, cache_bytes, 16);
        wr64(ctx, DB_GENERATION, GENERATION);

        frame = db_page_for_write(ctx, P_FIRST + 5, 2);
        check("a page opens for writing", frame != NULL);
        if (frame) strcpy((char *)frame, "rewritten by the engine");

        {
            uint64_t slot, dirty = 0, typed = 0;
            for (slot = 0; slot < cyboudb_pcache_frames(cache_mem); slot++) {
                if (cyboudb_pcache_dirty_at(cache_mem, slot) != UINT64_MAX) {
                    dirty++;
                    if (cyboudb_pcache_type_at(cache_mem, slot) == 2) typed++;
                }
            }
            check("and the cache knows exactly one frame is dirty", dirty == 1);
            check("and remembers what kind of page it is", typed == 1);
        }

        check("the flush seals and writes it", db_pages_flush(ctx) == 0);

        {
            uint64_t slot, dirty = 0;
            for (slot = 0; slot < cyboudb_pcache_frames(cache_mem); slot++)
                if (cyboudb_pcache_dirty_at(cache_mem, slot) != UINT64_MAX)
                    dirty++;
            check("and nothing is left dirty behind it", dirty == 0);
        }

        /* The page on disk is now the new one, sealed. A cold read has to get
           it back - which is the whole round trip: plaintext into a frame,
           sealed out to the file, and read back as plaintext again. */
        cyboudb_pcache_init(cache_mem, cache_bytes, 16);
        frame = db_page_resolve(ctx, P_FIRST + 5);
        check("and a cold read brings back what was written",
              frame != NULL &&
              strcmp((char *)frame, "rewritten by the engine") == 0);

        /* Its neighbours are untouched, which is what says the leaf's other
           entries survived the read-modify-write. */
        for (i = 0; i < 10; i++) {
            char want[64];
            if (i == 5 || i == 7) continue;
            snprintf(want, sizeof want, "this is page %d", P_FIRST + i);
            frame = db_page_resolve(ctx, P_FIRST + i);
            if (!frame || strcmp((char *)frame, want) != 0) ok = 0;
        }
        check("while every other page in that leaf still opens", ok);
    }

    /* --- several pages, and the leaf written once --------------------------- */
    {
        uint8_t *frame;
        int ok = 1;
        cyboudb_pcache_init(cache_mem, cache_bytes, 16);

        for (i = 0; i < 4; i++) {
            char line[64];
            frame = db_page_for_write(ctx, P_FIRST + i, (uint64_t)(i + 1));
            if (!frame) { ok = 0; continue; }
            snprintf(line, sizeof line, "page %d, second generation", P_FIRST + i);
            memset(frame, 0, PAGE);
            strcpy((char *)frame, line);
        }
        check("four pages open for writing", ok);
        check("and flush together", db_pages_flush(ctx) == 0);

        cyboudb_pcache_init(cache_mem, cache_bytes, 16);
        ok = 1;
        for (i = 0; i < 4; i++) {
            char want[64];
            snprintf(want, sizeof want, "page %d, second generation", P_FIRST + i);
            frame = db_page_resolve(ctx, P_FIRST + i);
            if (!frame || strcmp((char *)frame, want) != 0) ok = 0;
        }
        check("and all four come back", ok);
    }


    vfs_close(h);
    free(cache_raw);
#ifdef _WIN32
    _wremove(path);
#else
    remove(path);
#endif

    printf("\npage resolve suite: %d checks, %d failed\n", checks, failures);
    return failures ? 1 : 0;
}
