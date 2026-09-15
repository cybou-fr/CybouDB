/* Opening an encrypted database as a database.
 *
 * db_open produces a context the whole engine reads. This checks that
 * db_open_encrypted produces the same one for a sealed file: the page counts,
 * the allocation map root, the catalog root, the capability bits and a
 * superblock pointer, arrived at with a private key rather than a checksum.
 *
 * It links the real engine, not stubs. What it is really asking is whether an
 * encrypted database is a database yet. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define PAGE 4096

#define SB_TOTAL_PAGES     16
#define SB_ALLOC_PAGES     24
#define SB_BITMAP_ROOT     48
#define SB_FEATURE_ROOT    56
#define SB_SEAL_TAG        104
#define SB_CRC             124

#define DB_HANDLE       0
#define DB_BASE         8
#define DB_SIZE         16
#define DB_PAGES        24
#define DB_ALLOC        32
#define DB_GENERATION   40
#define DB_SB_PAGE      48
#define DB_SB_PTR       56
#define DB_ROOT         64
#define DB_WRITABLE     72
#define DB_MODE         88
#define DB_FEATURES     104
#define DB_BITMAP       112
#define DB_DAMAGED      184
#define DB_CACHE        760
#define DB_SEAL_KEY     (DB_CACHE + 8)
#define DB_UUID         (DB_SEAL_KEY + 32)
#define DB_SEAL_EPOCH   (DB_UUID + 16)

#define CAT_TYPE        32
#define CAT_COUNT       36
#define CAT_PAGE_ID     8
#define CAT_TABLE_NAME  64
#define CAT_COLUMNS     96
#define CAT_SCHEMA      2
#define CAT_COL_SIZE    32
#define CAT_INT64       2

#define FEATURE_ENCRYPTION 131072u
#define MAP_LEAF_PAGES     ((4092 - 64) * 4)
#define EK_BYTES 1184
#define DK_BYTES 2400

#define CybouDB_OK          0
#define E_SUPERBLOCK 12
#define E_NEEDS_KEY  43
#define E_KEY        38
#define VERIFY_INTEGRITY 2
#define E_DAMAGED    36

#ifdef _WIN32
#include <wchar.h>
typedef const wchar_t *vfs_path;
#define VFS_PATH(x) L##x
#else
typedef const char *vfs_path;
#define VFS_PATH(x) x
#endif

int64_t vfs_create_truncate(vfs_path path, uint64_t *reason);
int64_t vfs_open_rw(vfs_path path, uint64_t *reason);
int64_t vfs_read_at(int64_t h, void *buf, uint64_t bytes, uint64_t offset);
int64_t vfs_write_at(int64_t h, const void *buf, uint64_t bytes,
                     uint64_t offset);
int64_t vfs_sync_file(int64_t h);
void vfs_close(int64_t h);
int os_random(uint8_t *out, uint64_t bytes);
uint32_t crc32c(const uint8_t *buf, uint64_t len);

void cyboudb_mlkem_keygen(uint8_t *ek, uint8_t *dk, const uint8_t *d,
                          const uint8_t *z);
uint64_t cyboudb_pcache_bytes(uint64_t frames);
uint64_t db_context_bytes(void);
uint8_t *db_page_resolve(uint8_t *ctx, uint64_t page);
uint8_t *db_page_new(uint8_t *ctx, uint64_t page, uint64_t page_type);
int db_encrypted_commit(uint8_t *ctx);
int db_catalog_put(uint8_t *ctx, uint64_t id, const void *image);
int db_catalog_get(uint8_t *ctx, uint64_t id, uint64_t *page);
uint8_t *db_catalog_page(uint8_t *ctx, uint64_t id);
int db_catalog_validate(uint8_t *ctx, const uint8_t *superblock);
void db_close(uint8_t *ctx);
int db_open(vfs_path path, uint8_t *ctx, uint64_t writable, uint64_t verify);

struct eopen_args {
    vfs_path path;
    uint8_t *ctx;
    const uint8_t *dk;
    uint8_t *cache;
    uint64_t cache_bytes, frames, writable, verify;
};
int db_open_encrypted(const struct eopen_args *args);

struct ecreate_args {
    int64_t handle;
    const uint8_t *ek;
    const uint8_t *uuid;
    uint64_t pages, generation, epoch;
};
int cyboudb_encrypted_create(const struct ecreate_args *args);

static int checks, failures;
static int check(const char *what, int ok) {
    checks++;
    if (ok) printf("ok   %s\n", what);
    else { failures++; printf("FAIL %s\n", what); }
    return ok;
}
static uint64_t rd64(const uint8_t *p, int off) {
    uint64_t v; memcpy(&v, p + off, 8); return v;
}
static void wr32(uint8_t *p, int off, uint32_t v) {
    memcpy(p + off, &v, 4);
}

static uint8_t ek[EK_BYTES], dk[DK_BYTES], ek2[EK_BYTES], dk2[DK_BYTES];
static uint8_t uuid[16], page_buf[PAGE];
static uint8_t *ctx, *cache_mem, *cache_raw;
static uint64_t cache_bytes;

int main(void) {
    vfs_path path = VFS_PATH("build/encrypted_open_db_test.cdb");
    struct ecreate_args cargs;
    struct eopen_args oargs;
    int64_t h;
    uint64_t pages = 30000, map_k, first_usable;
    int rc_probe;

    setvbuf(stdout, NULL, _IONBF, 0);
    printf("CybouDB encrypted open test\n\n");
    map_k = (pages + MAP_LEAF_PAGES - 1) / MAP_LEAF_PAGES;
    ctx = malloc((size_t)db_context_bytes());

    {
        uint8_t seed[64];
        os_random(seed, 64);
        cyboudb_mlkem_keygen(ek, dk, seed, seed + 32);
        seed[0] ^= 0x01;
        cyboudb_mlkem_keygen(ek2, dk2, seed, seed + 32);
        os_random(uuid, 16);
    }
    cache_bytes = cyboudb_pcache_bytes(64);
    cache_raw = malloc((size_t)cache_bytes + PAGE);
    cache_mem = (uint8_t *)(((uintptr_t)cache_raw + PAGE - 1) &
                            ~(uintptr_t)(PAGE - 1));

    h = vfs_create_truncate(path, 0);
    check("a file to write into", h != -1);
    if (h == -1) return 1;
    cargs.handle = h; cargs.ek = ek; cargs.uuid = uuid;
    cargs.pages = pages; cargs.generation = 1; cargs.epoch = 1;
    check("an encrypted database, created",
          cyboudb_encrypted_create(&cargs) == 0);
    vfs_read_at(h, page_buf, PAGE, PAGE);
    first_usable = rd64(page_buf, SB_ALLOC_PAGES);
    vfs_close(h);

    /* --- the ordinary open, without a key ----------------------------------- */
    check("db_open refuses it, by name, for want of a key",
          db_open(path, ctx, 0, 0) == E_NEEDS_KEY);

    /* --- and with one -------------------------------------------------------- */
    oargs.path = path; oargs.ctx = ctx; oargs.dk = dk;
    oargs.cache = cache_mem; oargs.cache_bytes = cache_bytes;
    oargs.frames = 64; oargs.writable = 1; oargs.verify = 0;
    check("db_open_encrypted opens it with the private key",
          db_open_encrypted(&oargs) == CybouDB_OK);
    check("and the context says what the database is",
          rd64(ctx, DB_PAGES) == pages &&
          rd64(ctx, DB_ALLOC) == first_usable &&
          rd64(ctx, DB_GENERATION) == 1 &&
          rd64(ctx, DB_BITMAP) == 3 &&
          rd64(ctx, DB_ROOT) == 0);
    check("and that it is a COW database with the full capability set",
          rd64(ctx, DB_MODE) == 1 &&
          (rd64(ctx, DB_FEATURES) & FEATURE_ENCRYPTION) != 0);
    check("and carries the superblock it authenticated",
          rd64(ctx, DB_SB_PTR) != 0 &&
          rd64(ctx, DB_SB_PAGE) == 1);
    check("and the seal epoch and the cache the resolver needs",
          rd64(ctx, DB_SEAL_EPOCH) == 1 && rd64(ctx, DB_CACHE) != 0);

    /* No mapping, on purpose: a module still reading through DB_BASE must
       fault at the point of use rather than read ciphertext and believe it. */
    check("and no mapping, so an unconverted reader faults instead of guessing",
          rd64(ctx, DB_BASE) == 0);

    /* The map validated during the open. Reading it again proves the resolver
       is what the engine above is now reading through. */
    {
        uint8_t *frame = db_page_resolve(ctx, 3);
        check("the allocation map resolves through the open context",
              frame != NULL);
        frame = db_page_resolve(ctx, 3 + map_k);
        check("and so does the copy beside it", frame != NULL);
    }

    db_close(ctx);
    check("closing lets go of the key and the cache",
          rd64(ctx, DB_CACHE) == 0 && rd64(ctx, DB_SEAL_KEY) == 0 &&
          rd64(ctx, DB_HANDLE) == (uint64_t)-1);

    /* --- the wrong key ------------------------------------------------------- */
    oargs.dk = dk2;
    check("another private key does not open it",
          db_open_encrypted(&oargs) == E_KEY);
    check("and leaves nothing behind", rd64(ctx, DB_CACHE) == 0);
    oargs.dk = dk;

    /* --- a map leaf somebody rewrote ----------------------------------------
       The key still opens the database: the superblock and the seal-tree root
       are untouched. The map is what fails, and an open that cannot stand
       behind the allocation state is not an open. */
    {
        h = vfs_open_rw(path, 0);
        vfs_read_at(h, page_buf, PAGE, 3 * PAGE);
        page_buf[100] ^= 0x01;
        vfs_write_at(h, page_buf, PAGE, 3 * PAGE);
        vfs_sync_file(h);
        vfs_close(h);
        check("a rewritten map leaf makes the open fail",
              db_open_encrypted(&oargs) == E_SUPERBLOCK);
        h = vfs_open_rw(path, 0);
        page_buf[100] ^= 0x01;
        vfs_write_at(h, page_buf, PAGE, 3 * PAGE);
        vfs_sync_file(h);
        vfs_close(h);
        check("and putting it back opens it again",
              db_open_encrypted(&oargs) == CybouDB_OK);
        db_close(ctx);
    }

    /* --- a generation published through the open context --------------------
       A fresh database has generation one in both superblock copies, so
       forging one of them proves nothing about which is newer. Publishing a
       second generation into copy B gives the two copies something to be
       newer than. */
    {
        uint8_t *frame;
        check("the database opens for writing", db_open_encrypted(&oargs) == 0);
        frame = db_page_new(ctx, first_usable, 1);
        check("a page of it opens for writing", frame != NULL);
        if (frame) {
            memset(frame, 0, PAGE);
            strcpy((char *)frame, "written through an opened encrypted handle");
        }
        check("and the generation commits into the copy that was not live",
              db_encrypted_commit(ctx) == 0 &&
              rd64(ctx, DB_GENERATION) == 2 && rd64(ctx, DB_SB_PAGE) == 2);
        db_close(ctx);

        check("and reopening finds generation two and reads the page back",
              db_open_encrypted(&oargs) == 0 &&
              rd64(ctx, DB_GENERATION) == 2 && rd64(ctx, DB_SB_PAGE) == 2);
        frame = db_page_resolve(ctx, first_usable);
        check("through the seal tree, as plaintext",
              frame != NULL &&
              strcmp((char *)frame,
                     "written through an opened encrypted handle") == 0);
        db_close(ctx);
    }

    /* --- a table in the catalog of a sealed database -------------------------
       The catalog allocates a page, copies the directory, stamps the new page
       with the page number it is at and publishes a new root - all of it
       through the resolver, none of it through a mapping that is not there.
       Stamping is the interesting part: a catalog page carries its own id,
       and an address in a cache says nothing about which page it is. */
    {
        static uint8_t image[PAGE];
        uint64_t table_page = 0;
        uint8_t *cat;

        check("the database opens again", db_open_encrypted(&oargs) == 0);
        memset(image, 0, PAGE);
        {
            uint32_t columns = 2, type = CAT_INT64;
            memcpy(image + CAT_COUNT, &columns, 4);
            memcpy(image + CAT_COLUMNS, &type, 4);
            memcpy(image + CAT_COLUMNS + CAT_COL_SIZE, &type, 4);
            strcpy((char *)image + CAT_COLUMNS + 8, "a");
            strcpy((char *)image + CAT_COLUMNS + CAT_COL_SIZE + 8, "b");
        }
        strcpy((char *)image + CAT_TABLE_NAME, "sealed_table");
        check("a schema goes into the catalog of an encrypted database",
              db_catalog_put(ctx, 4242, image) == 0);
        check("and is found there",
              db_catalog_get(ctx, 4242, &table_page) == 0 && table_page != 0);
        cat = db_catalog_page(ctx, 4242);
        check("as a schema page carrying the name it was given",
              cat != NULL &&
              strcmp((char *)cat + CAT_TABLE_NAME, "sealed_table") == 0);
        check("and stamped with the page it is actually at, not an address",
              cat != NULL && rd64(cat, CAT_PAGE_ID) == table_page);
        check("the map still validates with a page handed out of it",
              db_bitmap_validate(ctx, (const uint8_t *)(uintptr_t)
                                 rd64(ctx, DB_SB_PTR)) == 1);
        check("and the generation publishes",
              db_encrypted_commit(ctx) == 0);
        db_close(ctx);

        rc_probe = db_open_encrypted(&oargs);
        if (rc_probe) printf("     [probe] reopen rc=%d\n", rc_probe);
        if (check("a reopen finds the table through the seal tree",
                  rc_probe == 0)) {
            cat = db_catalog_page(ctx, 4242);
            check("with its name intact",
                  cat != NULL &&
                  strcmp((char *)cat + CAT_TABLE_NAME, "sealed_table") == 0);
            db_close(ctx);
        }
    }

    /* --- a superblock somebody rewrote --------------------------------------
       The CRC is repaired, so nothing without a key can tell. The newest
       generation is forged and the one before it is whole behind it: the open
       succeeds, from the copy that still authenticates, and records what it
       could not stand behind. */
    {
        uint64_t live, live_gen;
        check("the database is open to be asked which copy is live",
              db_open_encrypted(&oargs) == 0);
        live = rd64(ctx, DB_SB_PAGE);
        live_gen = rd64(ctx, DB_GENERATION);
        db_close(ctx);

        h = vfs_open_rw(path, 0);
        vfs_read_at(h, page_buf, PAGE, live * PAGE);
        page_buf[SB_SEAL_TAG] ^= 0x40;
        wr32(page_buf, SB_CRC, crc32c(page_buf, SB_CRC));
        vfs_write_at(h, page_buf, PAGE, live * PAGE);
        vfs_sync_file(h);
        vfs_close(h);
        check("a forged newest generation falls back to the one before it",
              db_open_encrypted(&oargs) == CybouDB_OK &&
              rd64(ctx, DB_SB_PAGE) != live &&
              rd64(ctx, DB_GENERATION) < live_gen);
        check("and the fallback is recorded as damage",
              rd64(ctx, DB_DAMAGED) == live_gen);
        db_close(ctx);

        /* Recovering is success; being asked about integrity is a different
           question, and it now gets a different answer. docs/RECOVERY.md. */
        oargs.verify = VERIFY_INTEGRITY;
        check("an open asking about integrity is told what recovery papered "
              "over",
              db_open_encrypted(&oargs) == E_DAMAGED);
        oargs.verify = 0;
    }

    free(cache_raw);
    free(ctx);
#ifdef _WIN32
    _wremove(path);
#else
    remove("build/encrypted_open_db_test.cdb");
#endif
    printf("\nencrypted open suite: %d checks, %d failed\n", checks, failures);
    return failures ? 1 : 0;
}
