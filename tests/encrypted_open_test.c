/* tests/encrypted_open_test.c - the engine preparing itself to read a file
 *
 * db_encrypted_attach walks the chain an encrypted open has to walk: header,
 * superblock, crypto root, key slot, decapsulate, derive, and only then verify
 * the superblock's tag with the key that just came out of the file. Everything
 * before that last step was believed on a checksum, which says the disk did
 * not lie and says nothing about whether anybody did.
 *
 * The file here carries the engine's own header and superblock layouts - the
 * ones in include/format.inc - rather than a stand-in, because attach reads
 * those fields by their real offsets. What it still does not do is go through
 * cyboudb_open; that is the next step of the port.
 *
 * Build (Linux):   sh build.sh --crypto-tests && ./build/encrypted_open_test
 * Build (Windows): build.bat --crypto-tests && build\encrypted_open_test.exe
 *
 * SPDX-License-Identifier: Apache-2.0
 * Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#define PAGE 4096

/* include/format.inc */
#define HDR_MAGIC          0
#define HDR_HEADER_SIZE    4
#define HDR_VERSION        8
#define HDR_PAGE_SIZE      12
#define HDR_FLAGS_INCOMPAT 16
#define HDR_SB_PAGE_A      32
#define HDR_UUID           48
#define HDR_CRC            124
#define HDR_MAGIC_VALUE    0x51534341u
#define FEATURE_ENCRYPTION 131072u

#define SB_MAGIC           0
#define SB_SIZE            4
#define SB_GENERATION      8
#define SB_TOTAL_PAGES     16
#define SB_FEATURE_ROOT    56
#define SB_SEAL_ROOT       64
#define SB_SEAL_TAG        104
#define SB_SEAL_TAG_SIZE   16
#define SB_CRC             124
#define SB_MAGIC_VALUE     0x53515341u

/* include/cyboudb.inc */
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
#define CTX_BYTES       (DB_ENC_ERROR + 8)

#define P_HEADER  0
#define P_SB      1
#define P_CROOT   3
#define P_SLOTS   4
#define P_LEAF    5        /* where the directory starts: leaf 0 */
#define P_LEAF1   6        /* leaf 1, which is the one covering page 100 */
#define P_PAYLOAD 100
#define TOTAL     200

#define EK_BYTES 1184
#define DK_BYTES 2400
#define KSLOT_SIZE 1176
#define MAC_SIZE 16

#define E_STATE       22
#define E_KEY         38
#define E_CRYPTO_ROOT 39
#define E_CRYPTO_CRC  40
#define E_SEAL        42

#define KDF_METADATA_KEK 1
#define KDF_PAGE_SEAL    2

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
int64_t vfs_sync_file(int64_t h);
void vfs_close(int64_t h);

int os_random(uint8_t *out, uint64_t bytes);
uint32_t crc32c(const uint8_t *buf, uint64_t len);

void cyboudb_mlkem_keygen(uint8_t *ek, uint8_t *dk, const uint8_t *d,
                          const uint8_t *z);
uint64_t cyboudb_kem_key_id(uint8_t *out, const uint8_t *ek);
int cyboudb_kem_seal_root(uint8_t *slot, const uint8_t *ek,
                          const uint8_t *root_key, uint64_t key_id,
                          const uint8_t *aad, uint64_t aad_len);
void cyboudb_keypage_init(uint8_t *page, uint64_t index, uint64_t generation);
int cyboudb_keypage_add(uint8_t *page, const uint8_t *slot);
int cyboudb_crypto_root_init(uint8_t *page, uint64_t seal_epoch,
                             uint64_t dir_first, uint64_t dir_pages,
                             uint64_t tree_root, uint64_t total_pages);
int cyboudb_kdf(uint8_t *out, uint64_t out_len, uint64_t purpose,
                const uint8_t *root, const uint8_t *context,
                uint64_t context_len);
void cyboudb_seal_leaf_init(uint8_t *page, uint64_t index, uint64_t generation,
                            uint64_t epoch);
uint8_t *cyboudb_seal_entry(uint8_t *leaf, uint64_t page_number);
struct pseal_args {
    const uint8_t *key; uint8_t *page; uint8_t *entry; const uint8_t *uuid;
    uint64_t page_no, generation, page_type, epoch;
};
int cyboudb_page_seal(const struct pseal_args *args);
int cyboudb_kmac256_init(uint8_t *ctx, const uint8_t *key, uint64_t key_len,
                         const uint8_t *custom, uint64_t custom_len);
void cyboudb_kmac256_update(uint8_t *ctx, const uint8_t *in, uint64_t len);
void cyboudb_kmac256_final(uint8_t *ctx, uint8_t *out, uint64_t out_len);

uint64_t cyboudb_pcache_bytes(uint64_t frames);
uint8_t *db_page_resolve(uint8_t *ctx, uint64_t page);
int db_encrypted_attach(uint8_t *ctx, const uint8_t *dk, uint8_t *cache_mem,
                        uint64_t cache_bytes, uint64_t frames);

static int checks, failures;

static void check(const char *what, int ok) {
    checks++;
    if (ok) printf("ok   %s\n", what);
    else { failures++; printf("FAIL %s\n", what); }
}

static void wr32(uint8_t *p, int off, uint32_t v) { memcpy(p + off, &v, 4); }
static void wr64(uint8_t *p, int off, uint64_t v) { memcpy(p + off, &v, 8); }
static uint64_t rd64(const uint8_t *p, int off) {
    uint64_t v; memcpy(&v, p + off, 8); return v;
}

static uint8_t header[PAGE], sb[PAGE], croot[PAGE], slots[PAGE], leaf[PAGE];
static uint8_t payload[PAGE], ctx[CTX_BYTES];
static uint8_t ek[EK_BYTES], dk[DK_BYTES], ek2[EK_BYTES], dk2[DK_BYTES];
static uint8_t slot[KSLOT_SIZE];
static uint8_t root_key[32], metadata_key[32], page_key[32], uuid[16];
static const uint64_t GENERATION = 21, EPOCH = 4;
static const char PAYLOAD_TEXT[] = "the engine opened this by itself";

static void superblock_tag(uint8_t *out, const uint8_t *key, const uint8_t *page) {
    uint8_t kctx[232];
    cyboudb_kmac256_init(kctx, key, 32,
                         (const uint8_t *)"CybouDB/0.7/superblock", 22);
    cyboudb_kmac256_update(kctx, page, SB_SEAL_TAG);
    cyboudb_kmac256_final(kctx, out, SB_SEAL_TAG_SIZE);
}

static void build_file(int64_t h) {
    uint8_t seed[64], aad[24], ctx8[8];
    uint64_t key_id = 0;
    struct pseal_args a;

    os_random(seed, 64);
    os_random(root_key, 32);
    os_random(uuid, 16);
    cyboudb_mlkem_keygen(ek, dk, seed, seed + 32);
    seed[0] ^= 0x01;
    cyboudb_mlkem_keygen(ek2, dk2, seed, seed + 32);
    cyboudb_kem_key_id((uint8_t *)&key_id, ek);

    memcpy(ctx8, &EPOCH, 8);
    cyboudb_kdf(metadata_key, 32, KDF_METADATA_KEK, root_key, NULL, 0);
    cyboudb_kdf(page_key, 32, KDF_PAGE_SEAL, root_key, ctx8, 8);

    memset(header, 0, PAGE);
    wr32(header, HDR_MAGIC, HDR_MAGIC_VALUE);
    wr32(header, HDR_HEADER_SIZE, 128);
    wr32(header, HDR_VERSION, 1);
    wr32(header, HDR_PAGE_SIZE, PAGE);
    wr64(header, HDR_FLAGS_INCOMPAT, FEATURE_ENCRYPTION);
    wr64(header, HDR_SB_PAGE_A, P_SB);
    memcpy(header + HDR_UUID, uuid, 16);
    wr32(header, HDR_CRC, crc32c(header, HDR_CRC));

    cyboudb_crypto_root_init(croot, EPOCH, P_LEAF, 2, P_LEAF, TOTAL);
    wr64(croot, 4016, P_SLOTS);                  /* CROOT_KEM_ROOT */
    wr32(croot, 4092, crc32c(croot, 4092));

    memcpy(aad, uuid, 16);
    memcpy(aad + 16, &key_id, 8);
    cyboudb_keypage_init(slots, 0, GENERATION);
    cyboudb_kem_seal_root(slot, ek, root_key, key_id, aad, 24);
    cyboudb_keypage_add(slots, slot);

    memset(payload, 0, PAGE);
    strcpy((char *)payload, PAYLOAD_TEXT);
    cyboudb_seal_leaf_init(leaf, 1, GENERATION, EPOCH);
    a.key = page_key; a.page = payload;
    a.entry = cyboudb_seal_entry(leaf, P_PAYLOAD);
    a.uuid = uuid; a.page_no = P_PAYLOAD; a.generation = GENERATION;
    a.page_type = 1; a.epoch = EPOCH;
    cyboudb_page_seal(&a);
    wr32(leaf, 4092, crc32c(leaf, 4092));

    memset(sb, 0, PAGE);
    wr32(sb, SB_MAGIC, SB_MAGIC_VALUE);
    wr32(sb, SB_SIZE, 128);
    wr64(sb, SB_GENERATION, GENERATION);
    wr64(sb, SB_TOTAL_PAGES, TOTAL);
    wr64(sb, SB_FEATURE_ROOT, P_CROOT);
    superblock_tag(sb + SB_SEAL_TAG, metadata_key, sb);
    wr32(sb, SB_CRC, crc32c(sb, SB_CRC));

    vfs_write_at(h, header, PAGE, (uint64_t)P_HEADER * PAGE);
    vfs_write_at(h, sb, PAGE, (uint64_t)P_SB * PAGE);
    vfs_write_at(h, croot, PAGE, (uint64_t)P_CROOT * PAGE);
    vfs_write_at(h, slots, PAGE, (uint64_t)P_SLOTS * PAGE);
    vfs_write_at(h, leaf, PAGE, (uint64_t)P_LEAF1 * PAGE);
    vfs_write_at(h, payload, PAGE, (uint64_t)P_PAYLOAD * PAGE);
    vfs_sync_file(h);
}

static void fresh_context(int64_t h) {
    memset(ctx, 0, sizeof ctx);
    wr64(ctx, DB_HANDLE, (uint64_t)h);
    wr64(ctx, DB_SB_PAGE, P_SB);
}

int main(void) {
    vfs_path path = VFS_PATH("build/encrypted_open_test.cdb");
    uint8_t *cache_mem, *cache_raw;
    uint64_t cache_bytes;
    int64_t h;

    printf("CybouDB encrypted open test\n\n");

    h = vfs_create_truncate(path, 0);
    check("a file to open", h != -1);
    if (h == -1) return 1;
    build_file(h);
    vfs_close(h);

    cache_bytes = cyboudb_pcache_bytes(16);
    cache_raw = malloc((size_t)cache_bytes + PAGE);
    cache_mem = (uint8_t *)(((uintptr_t)cache_raw + PAGE - 1) &
                            ~(uintptr_t)(PAGE - 1));

    /* --- the whole chain, with the right key --------------------------------- */
    h = vfs_open_rw(path, 0);
    fresh_context(h);
    check("the engine attaches to the file with a private key",
          db_encrypted_attach(ctx, dk, cache_mem, cache_bytes, 16) == 0);

    check("and has learned the file's identity",
          memcmp(ctx + DB_UUID, uuid, 16) == 0);
    check("and which generation is live", rd64(ctx, DB_GENERATION) == GENERATION);
    check("and which seal epoch the pages are under",
          rd64(ctx, DB_SEAL_EPOCH) == EPOCH);
    check("and where the seal directory starts",
          rd64(ctx, DB_SEAL_DIR) == P_LEAF);
    check("and holds the page seal key, derived rather than stored",
          memcmp(ctx + DB_SEAL_KEY, page_key, 32) == 0);
    check("and the cache is live, which is what the page macro branches on",
          rd64(ctx, DB_CACHE) != 0);

    /* And with all of that, a page comes back as plaintext. */
    {
        uint8_t *frame = db_page_resolve(ctx, P_PAYLOAD);
        check("a page resolves through the context the engine built",
              frame != NULL && strcmp((char *)frame, PAYLOAD_TEXT) == 0);
    }
    vfs_close(h);

    /* --- the other key pair ---------------------------------------------------- */
    h = vfs_open_rw(path, 0);
    fresh_context(h);
    check("another private key does not open this file",
          db_encrypted_attach(ctx, dk2, cache_mem, cache_bytes, 16) == E_KEY);
    check("and the cache is not left live after a refusal",
          rd64(ctx, DB_CACHE) == 0);
    vfs_close(h);

    /* --- a superblock somebody rewrote ------------------------------------------
       The CRC is repaired, so a checksum cannot tell. Only the tag can, and
       only after a key has been recovered - which is the whole argument for
       checking it at step 6 rather than trusting the page at step 2. */
    {
        uint8_t forged[PAGE];
        h = vfs_open_rw(path, 0);
        vfs_read_at(h, forged, PAGE, (uint64_t)P_SB * PAGE);
        wr64(forged, SB_GENERATION, GENERATION + 5);
        wr32(forged, SB_CRC, crc32c(forged, SB_CRC));
        vfs_write_at(h, forged, PAGE, (uint64_t)P_SB * PAGE);
        vfs_sync_file(h);

        fresh_context(h);
        check("a superblock rewritten with a repaired checksum is refused",
              db_encrypted_attach(ctx, dk, cache_mem, cache_bytes, 16) == E_SEAL);

        /* put it back */
        vfs_write_at(h, sb, PAGE, (uint64_t)P_SB * PAGE);
        vfs_sync_file(h);
        fresh_context(h);
        check("and the real superblock still attaches",
              db_encrypted_attach(ctx, dk, cache_mem, cache_bytes, 16) == 0);
        vfs_close(h);
    }

    /* --- a crypto root that contradicts itself ---------------------------------- */
    {
        uint8_t broken[PAGE];
        h = vfs_open_rw(path, 0);
        vfs_read_at(h, broken, PAGE, (uint64_t)P_CROOT * PAGE);
        wr64(broken, 24, 0);                     /* CROOT_SEAL_DIR_FIRST */
        wr32(broken, 4092, crc32c(broken, 4092));
        vfs_write_at(h, broken, PAGE, (uint64_t)P_CROOT * PAGE);
        fresh_context(h);
        check("a crypto root with impossible geometry is refused as metadata",
              db_encrypted_attach(ctx, dk, cache_mem, cache_bytes, 16) ==
                  E_CRYPTO_ROOT);
        vfs_write_at(h, croot, PAGE, (uint64_t)P_CROOT * PAGE);
        vfs_close(h);
    }

    /* --- a file that is not encrypted at all ------------------------------------- */
    {
        uint8_t plain_header[PAGE];
        h = vfs_open_rw(path, 0);
        memcpy(plain_header, header, PAGE);
        wr64(plain_header, HDR_FLAGS_INCOMPAT, 0);
        wr32(plain_header, HDR_CRC, crc32c(plain_header, HDR_CRC));
        vfs_write_at(h, plain_header, PAGE, 0);
        fresh_context(h);
        check("a file without the encryption bit is not something to attach to",
              db_encrypted_attach(ctx, dk, cache_mem, cache_bytes, 16) == E_STATE);
        vfs_write_at(h, header, PAGE, 0);
        vfs_close(h);
    }

    free(cache_raw);
#ifdef _WIN32
    _wremove(path);
#else
    remove(path);
#endif

    printf("\nencrypted open suite: %d checks, %d failed\n", checks, failures);
    return failures ? 1 : 0;
}
