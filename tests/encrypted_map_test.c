/* The allocation map of an encrypted database, reached through the resolver.
 *
 * This is the first module of the ordinary engine driven against a sealed
 * file. db_bitmap_validate walks every leaf of a candidate's map, and in an
 * encrypted database every one of those leaves arrives through the seal tree:
 * read, authenticated, decrypted, and handed back as a frame. A leaf that
 * does not authenticate has no address at all, and what this test is about is
 * that the allocator refuses rather than reading whatever was there. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define PAGE 4096

#define SB_TOTAL_PAGES     16
#define SB_ALLOC_PAGES     24
#define SB_BITMAP_ROOT     48

#define DB_HANDLE       0
#define DB_SIZE         16
#define DB_PAGES        24
#define DB_ALLOC        32
#define DB_SB_PAGE      48
#define DB_SB_PTR       56
#define DB_WRITABLE     72
#define DB_MODE         88
#define DB_COW_FLOOR    96
#define DB_FEATURES     104
#define DB_BITMAP       112
#define DB_CACHE        760
#define DB_SEAL_LEAVES  (DB_CACHE + 8 + 32 + 16 + 8 + 8)
#define DB_ENC_ERROR    (DB_SEAL_LEAVES + 8)
#define CTX_BYTES       4096

#define FEATURES_DEFAULT   0x1FFFE
#define FEATURE_ENCRYPTION 131072u
#define MAP_LEAF_PAGES     ((4092 - 64) * 4)
#define EK_BYTES 1184
#define DK_BYTES 2400
#define E_SEAL 42

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
int64_t vfs_size(int64_t h);
int64_t vfs_sync_file(int64_t h);
void vfs_close(int64_t h);
int os_random(uint8_t *out, uint64_t bytes);

void cyboudb_mlkem_keygen(uint8_t *ek, uint8_t *dk, const uint8_t *d,
                          const uint8_t *z);
uint64_t cyboudb_pcache_bytes(uint64_t frames);
uint64_t db_context_bytes(void);
int db_encrypted_attach(uint8_t *ctx, const uint8_t *dk, uint8_t *cache_mem,
                        uint64_t cache_bytes, uint64_t frames);
int db_bitmap_validate(uint8_t *ctx, const uint8_t *superblock);

struct ecreate_args {
    int64_t handle;
    const uint8_t *ek;
    const uint8_t *uuid;
    uint64_t pages, generation, epoch;
};
int cyboudb_encrypted_create(const struct ecreate_args *args);

/* core/bitmap.asm reaches the catalog. It has nothing to say about a map that
   was just created, and linking it would pull most of the engine into a test
   about one module. The reclamation guard and the allocator come from the
   platform layer, which is linked. */
int db_catalog_validate(uint8_t *c, const uint8_t *s) {
    (void)c; (void)s; return 1;
}
int catalog_entry_in(uint8_t *c, uint64_t page) {
    (void)c; (void)page; return 0;
}

static int checks, failures;
static void check(const char *what, int ok) {
    checks++;
    if (ok) printf("ok   %s\n", what);
    else { failures++; printf("FAIL %s\n", what); }
}
static uint64_t rd64(const uint8_t *p, int off) {
    uint64_t v; memcpy(&v, p + off, 8); return v;
}
static void wr64(uint8_t *p, int off, uint64_t v) {
    memcpy(p + off, &v, 8);
}

static uint8_t ek[EK_BYTES], dk[DK_BYTES];
static uint8_t ctx[CTX_BYTES], sb[PAGE], page_buf[PAGE];
static uint8_t uuid[16];
static uint8_t *cache_mem, *cache_raw;
static uint64_t cache_bytes;

/* What a key-bearing db_open will have to do, in the order it will do it:
   attach with the private key, then take from the authenticated superblock
   the fields the rest of the engine reads out of the context. */
static int attach(int64_t h) {
    int rc;
    memset(ctx, 0, sizeof ctx);
    wr64(ctx, DB_HANDLE, (uint64_t)h);
    rc = db_encrypted_attach(ctx, dk, cache_mem, cache_bytes, 64);
    if (rc) return rc;
    vfs_read_at(h, sb, PAGE, rd64(ctx, DB_SB_PAGE) * PAGE);
    wr64(ctx, DB_SIZE, (uint64_t)vfs_size(h));
    wr64(ctx, DB_PAGES, rd64(sb, SB_TOTAL_PAGES));
    wr64(ctx, DB_ALLOC, rd64(sb, SB_ALLOC_PAGES));
    wr64(ctx, DB_BITMAP, rd64(sb, SB_BITMAP_ROOT));
    wr64(ctx, DB_COW_FLOOR, rd64(sb, SB_ALLOC_PAGES));
    wr64(ctx, DB_FEATURES, FEATURES_DEFAULT | FEATURE_ENCRYPTION);
    wr64(ctx, DB_WRITABLE, 1);
    wr64(ctx, DB_MODE, 1);
    wr64(ctx, DB_SB_PTR, (uint64_t)(uintptr_t)sb);
    return 0;
}

int main(void) {
    vfs_path path = VFS_PATH("build/encrypted_map_test.cdb");
    struct ecreate_args args;
    int64_t h;
    uint64_t pages = 30000, map_k;

    printf("CybouDB encrypted allocation map test\n\n");
    if (db_context_bytes() > CTX_BYTES) {
        printf("FAIL the context outgrew what this test allocates\n");
        return 1;
    }
    map_k = (pages + MAP_LEAF_PAGES - 1) / MAP_LEAF_PAGES;

    {
        uint8_t seed[64];
        os_random(seed, 64);
        cyboudb_mlkem_keygen(ek, dk, seed, seed + 32);
        os_random(uuid, 16);
    }
    cache_bytes = cyboudb_pcache_bytes(64);
    cache_raw = malloc((size_t)cache_bytes + PAGE);
    cache_mem = (uint8_t *)(((uintptr_t)cache_raw + PAGE - 1) &
                            ~(uintptr_t)(PAGE - 1));

    h = vfs_create_truncate(path, 0);
    check("a file to write into", h != -1);
    if (h == -1) return 1;
    args.handle = h; args.ek = ek; args.uuid = uuid;
    args.pages = pages; args.generation = 1; args.epoch = 1;
    check("an encrypted database with two map leaves per copy",
          cyboudb_encrypted_create(&args) == 0 && map_k == 2);
    vfs_close(h);

    /* --- the map, validated end to end -------------------------------------- */
    h = vfs_open_rw(path, 0);
    check("the private key opens it", attach(h) == 0);
    check("and the whole allocation map validates through the seal tree",
          db_bitmap_validate(ctx, sb) == 1);
    check("without the handle being poisoned on the way",
          rd64(ctx, DB_MODE) == 1);
    vfs_close(h);

    /* --- one leaf of it, rewritten ------------------------------------------
       The CRC is not even repaired: it does not have to be. The leaf is
       ciphertext under a tag the seal tree publishes, so changing one byte of
       it makes it a page with no address, and the allocator has to answer
       "no" rather than whatever those bytes said. */
    {
        h = vfs_open_rw(path, 0);
        vfs_read_at(h, page_buf, PAGE, 3 * PAGE);
        page_buf[100] ^= 0x01;
        vfs_write_at(h, page_buf, PAGE, 3 * PAGE);
        vfs_sync_file(h);
        check("a rewritten map leaf still lets the key in", attach(h) == 0);
        check("but the map does not validate",
              db_bitmap_validate(ctx, sb) == 0);
        check("and the resolver says why",
              rd64(ctx, DB_ENC_ERROR) == E_SEAL);
        page_buf[100] ^= 0x01;
        vfs_write_at(h, page_buf, PAGE, 3 * PAGE);
        vfs_sync_file(h);
        check("and putting it back makes the database whole again",
              attach(h) == 0 && db_bitmap_validate(ctx, sb) == 1);
        vfs_close(h);
    }

    /* --- the copy the other superblock owns ---------------------------------
       Copy B is a complete map of the same generation here, because a fresh
       database publishes generation one into both. Damaging it does not stop
       copy A from validating: they are separate pages under separate entries. */
    {
        h = vfs_open_rw(path, 0);
        vfs_read_at(h, page_buf, PAGE, (3 + map_k) * PAGE);
        page_buf[200] ^= 0x01;
        vfs_write_at(h, page_buf, PAGE, (3 + map_k) * PAGE);
        vfs_sync_file(h);
        check("damaging the other copy leaves this one valid",
              attach(h) == 0 && db_bitmap_validate(ctx, sb) == 1);
        vfs_close(h);
    }

    free(cache_raw);
#ifdef _WIN32
    _wremove(path);
#else
    remove("build/encrypted_map_test.cdb");
#endif
    printf("\nencrypted map suite: %d checks, %d failed\n", checks, failures);
    return failures ? 1 : 0;
}
