/* tests/encrypted_create_test.c - the engine writes one, and opens it again
 *
 * cyboudb_encrypted_create writes a complete encrypted database - header,
 * superblocks, crypto root, key slots, seal directory, seal tree - sealed to a
 * public key it is handed. db_encrypted_attach opens it with the matching
 * private key and nothing else.
 *
 * Between them this is the first file in the project that no build can read
 * without a key, made by the engine rather than by a test fixture.
 *
 * Build (Linux):   sh build.sh --crypto-tests && ./build/encrypted_create_test
 * Build (Windows): build.bat --crypto-tests && build\encrypted_create_test.exe
 *
 * SPDX-License-Identifier: Apache-2.0
 * Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#define PAGE 4096

#define HDR_MAGIC          0
#define HDR_FLAGS_INCOMPAT 16
#define HDR_UUID           48
#define HDR_CRC            124
#define MAGIC_VALUE        0x4C515341u
#define FEATURE_ENCRYPTION 131072u

#define SB_GENERATION      8
#define SB_TOTAL_PAGES     16
#define SB_ALLOC_PAGES     24
#define SB_FEATURE_ROOT    56
#define SB_SEAL_TAG        64
#define SB_CRC             124

#define CROOT_SEAL_EPOCH     8
#define CROOT_SEAL_DIR_FIRST 24
#define CROOT_KEM_ROOT       4016

#define DB_HANDLE       0
#define DB_GENERATION   40
#define DB_SB_PAGE      48
#define DB_CACHE        760
#define DB_SEAL_KEY     (DB_CACHE + 8)
#define DB_UUID         (DB_SEAL_KEY + 32)
#define DB_SEAL_EPOCH   (DB_UUID + 16)
#define DB_SEAL_DIR     (DB_SEAL_EPOCH + 8)
#define DB_SEAL_LEAVES  (DB_SEAL_DIR + 8)
#define DB_ENC_ERROR    (DB_SEAL_LEAVES + 8)
#define DB_META_KEY     (DB_ENC_ERROR + 8)
#define DB_TREE_KEY     (DB_META_KEY + 32)
#define CTX_BYTES       1024

#define EK_BYTES 1184
#define DK_BYTES 2400
#define E_KEY 38
#define E_COW_PAGES 25

#ifdef _WIN32
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
void vfs_close(int64_t h);
int os_random(uint8_t *out, uint64_t bytes);
uint32_t crc32c(const uint8_t *buf, uint64_t len);

void cyboudb_mlkem_keygen(uint8_t *ek, uint8_t *dk, const uint8_t *d,
                          const uint8_t *z);
void cyboudb_seal_geometry(uint64_t *out, uint64_t total_pages);
uint64_t cyboudb_pcache_bytes(uint64_t frames);
uint8_t *db_page_resolve(uint8_t *ctx, uint64_t page);
uint8_t *db_page_for_write(uint8_t *ctx, uint64_t page, uint64_t page_type);
uint8_t *db_page_new(uint8_t *ctx, uint64_t page, uint64_t page_type);
int db_pages_flush(uint8_t *ctx);
uint64_t db_context_bytes(void);
int db_encrypted_commit(uint8_t *ctx);
int db_encrypted_attach(uint8_t *ctx, const uint8_t *dk, uint8_t *cache_mem,
                        uint64_t cache_bytes, uint64_t frames);

struct ecreate_args {
    int64_t handle;
    const uint8_t *ek;
    const uint8_t *uuid;
    uint64_t pages, generation, epoch;
};
int cyboudb_encrypted_create(const struct ecreate_args *args);

static int checks, failures;

static void check(const char *what, int ok) {
    checks++;
    if (ok) printf("ok   %s\n", what);
    else { failures++; printf("FAIL %s\n", what); }
}

static uint64_t rd64(const uint8_t *p, int off) {
    uint64_t v; memcpy(&v, p + off, 8); return v;
}
static uint32_t rd32(const uint8_t *p, int off) {
    uint32_t v; memcpy(&v, p + off, 4); return v;
}

static uint8_t ek[EK_BYTES], dk[DK_BYTES], ek2[EK_BYTES], dk2[DK_BYTES];
static uint8_t ctx[CTX_BYTES], page[PAGE];
static uint8_t uuid[16];

int main(void) {
    if (db_context_bytes() > CTX_BYTES) {
        printf("FAIL the context outgrew what this test allocates\n");
        return 1;
    }

    vfs_path path = VFS_PATH("build/encrypted_create_test.cdb");
    struct ecreate_args args;
    uint8_t *cache_mem, *cache_raw;
    uint64_t cache_bytes, geo[4];
    int64_t h;

    printf("CybouDB encrypted create test\n\n");

    {
        uint8_t seed[64];
        os_random(seed, 64);
        cyboudb_mlkem_keygen(ek, dk, seed, seed + 32);
        seed[0] ^= 0x01;
        cyboudb_mlkem_keygen(ek2, dk2, seed, seed + 32);
        os_random(uuid, 16);
    }

    /* --- the engine writes one ---------------------------------------------- */
    h = vfs_create_truncate(path, 0);
    check("a file to write into", h != -1);
    if (h == -1) return 1;

    args.handle = h;
    args.ek = ek;
    args.uuid = uuid;
    args.pages = 1000;
    args.generation = 1;
    args.epoch = 1;
    check("the engine creates an encrypted database",
          cyboudb_encrypted_create(&args) == 0);
    vfs_close(h);

    /* --- what it wrote, from the outside ------------------------------------ */
    h = vfs_open_rw(path, 0);
    vfs_read_at(h, page, PAGE, 0);
    check("the header carries the encryption bit",
          rd32(page, HDR_MAGIC) == MAGIC_VALUE &&
          (rd64(page, HDR_FLAGS_INCOMPAT) & FEATURE_ENCRYPTION) != 0);
    check("and the identity it was given",
          memcmp(page + HDR_UUID, uuid, 16) == 0);
    check("and its own checksum",
          rd32(page, HDR_CRC) == crc32c(page, HDR_CRC));

    cyboudb_seal_geometry(geo, 1000);
    vfs_read_at(h, page, PAGE, 3 * PAGE);
    check("the crypto root says where the directory is and how big",
          rd64(page, CROOT_SEAL_DIR_FIRST) == 5 &&
          rd64(page, CROOT_KEM_ROOT) == 4);

    vfs_read_at(h, page, PAGE, 1 * PAGE);
    check("the superblock publishes the first usable page past the metadata",
          rd64(page, SB_ALLOC_PAGES) == 5 + geo[0] + geo[1]);
    check("and names the crypto root", rd64(page, SB_FEATURE_ROOT) == 3);
    {
        uint8_t zero[16];
        memset(zero, 0, 16);
        check("and carries a tag rather than sixteen zero bytes",
              memcmp(page + SB_SEAL_TAG, zero, 16) != 0);
    }

    /* --- and the engine opens it again --------------------------------------- */
    cache_bytes = cyboudb_pcache_bytes(32);
    cache_raw = malloc((size_t)cache_bytes + PAGE);
    cache_mem = (uint8_t *)(((uintptr_t)cache_raw + PAGE - 1) &
                            ~(uintptr_t)(PAGE - 1));

    memset(ctx, 0, sizeof ctx);
    memcpy(ctx + DB_HANDLE, &h, 8);
    {
        uint64_t sb = 1;
        memcpy(ctx + DB_SB_PAGE, &sb, 8);
    }
    check("the private key opens what the engine wrote",
          db_encrypted_attach(ctx, dk, cache_mem, cache_bytes, 32) == 0);
    check("and the context knows the epoch and the directory",
          rd64(ctx, DB_SEAL_EPOCH) == 1 && rd64(ctx, DB_SEAL_DIR) == 5);

    {
        memset(ctx, 0, sizeof ctx);
        memcpy(ctx + DB_HANDLE, &h, 8);
        {
            uint64_t sb = 1;
            memcpy(ctx + DB_SB_PAGE, &sb, 8);
        }
        check("while the other key pair does not",
              db_encrypted_attach(ctx, dk2, cache_mem, cache_bytes, 32) == E_KEY);
    }

    /* --- a page written into it, and read back after a reopen ---------------- */
    {
        uint8_t *frame;
        uint64_t first_usable = 5 + geo[0] + geo[1];

        memset(ctx, 0, sizeof ctx);
        memcpy(ctx + DB_HANDLE, &h, 8);
        {
            uint64_t sb = 1;
            memcpy(ctx + DB_SB_PAGE, &sb, 8);
        }
        db_encrypted_attach(ctx, dk, cache_mem, cache_bytes, 32);

        /* The first page a fresh database allocates has never been sealed,
           so it is asked for as new rather than for writing: there is nothing
           at that page number to open, and trying would fail a tag check
           against bytes nobody wrote. */
        frame = db_page_new(ctx, first_usable, 1);
        check("a page of the new database opens for writing", frame != NULL);
        if (frame) {
            memset(frame, 0, PAGE);
            strcpy((char *)frame, "written into a database the engine made");
        }
        /* And the generation is published: the leaves the flush wrote are
           covered by a node, the node reaches the disk before anything claims
           it exists, and only then does a superblock name it. */
        check("and the generation is committed",
              db_encrypted_commit(ctx) == 0);
        check("which published into the copy that was not live and moved on",
              rd64(ctx, DB_GENERATION) == 2 && rd64(ctx, DB_SB_PAGE) == 2);
        vfs_close(h);

        /* The superblock the commit wrote, read as a stranger would: a real
           generation in a real copy, not an in-memory claim. */
        h = vfs_open_rw(path, 0);
        vfs_read_at(h, page, PAGE, 2 * PAGE);
        check("the second superblock carries the new generation",
              rd64(page, SB_GENERATION) == 2 &&
              rd32(page, SB_CRC) == crc32c(page, SB_CRC));
        vfs_close(h);

        /* Reopen from nothing: a new handle, a new context, the same key. */
        h = vfs_open_rw(path, 0);
        memset(ctx, 0, sizeof ctx);
        memcpy(ctx + DB_HANDLE, &h, 8);
        {
            uint64_t sb = 2;              /* the copy the commit published into */
            memcpy(ctx + DB_SB_PAGE, &sb, 8);
        }
        check("the file opens again with the key",
              db_encrypted_attach(ctx, dk, cache_mem, cache_bytes, 32) == 0);
        frame = db_page_resolve(ctx, first_usable);
        check("and the page written before the close is there",
              frame != NULL &&
              strcmp((char *)frame, "written into a database the engine made")
                  == 0);

        /* And it is not there in plaintext. */
        {
            uint8_t disk[PAGE];
            vfs_read_at(h, disk, PAGE, first_usable * PAGE);
            check("but not as plaintext on the disk",
                  memcmp(disk, "written into", 12) != 0);
        }
    }
    vfs_close(h);

    /* --- a file too large for one level of tree ------------------------------- */
    {
        int64_t big = vfs_create_truncate(VFS_PATH("build/too_big.cdb"), 0);
        args.handle = big;
        args.pages = 30000;             /* past 251 leaves */
        check("a file needing two levels of tree is refused, not half written",
              cyboudb_encrypted_create(&args) == E_COW_PAGES);
        vfs_close(big);
#ifdef _WIN32
        _wremove(VFS_PATH("build/too_big.cdb"));
#else
        remove("build/too_big.cdb");
#endif
    }

    free(cache_raw);
#ifdef _WIN32
    _wremove(path);
#else
    remove(path);
#endif

    printf("\nencrypted create suite: %d checks, %d failed\n", checks, failures);
    return failures ? 1 : 0;
}
