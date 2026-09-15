/* tests/encrypted_file_test.c - a real encrypted file, end to end
 *
 * Everything before this was a primitive with a suite of its own. This is the
 * first time they are asked to be a file: a header, a crypto root, a key slot
 * sealed to an ML-KEM public key, a seal directory with a keyed tree over it,
 * an authenticated superblock, and a payload page - written with positioned
 * I/O, closed, reopened, and opened again with nothing but a private key.
 *
 * What this is NOT, said plainly so a green suite is not mistaken for a
 * finished step 7:
 *
 *   - it is not the engine. The engine's superblock, allocation map, catalog
 *     and commit path are not here; this file writes the crypto-owned pages
 *     and a stand-in superblock that carries the seal tree root.
 *   - there is no commit, and therefore no crash matrix. That is step 8.
 *   - nothing here goes through cyboudb_open, and the CLI cannot make one of
 *     these files. No .cdb in the world gets the encryption bit from this.
 *
 * What it is: proof that the chain composes, and a place for the gaps between
 * the pieces to show up - which is the only reason to build it before the
 * engine rather than after.
 *
 * Build (Linux):   sh build.sh --crypto-tests && ./build/encrypted_file_test
 * Build (Windows): build.bat --crypto-tests && build\encrypted_file_test.exe
 *
 * SPDX-License-Identifier: Apache-2.0
 * Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#define PAGE 4096

/* --- the layout this file uses -------------------------------------------
   Page numbers, fixed for the test. The real geometry comes from
   cyboudb_seal_geometry and is checked against it below, so a change there
   does not quietly stop being what this file assumes. */
#define P_HEADER      0
#define P_SUPERBLOCK  1
#define P_CRYPTO_ROOT 3
#define P_KEY_SLOTS   4
#define P_SEAL_LEAF   5
#define P_SEAL_NODE   6
#define P_PAYLOAD     7
#define TOTAL_PAGES   8

/* The plaintext header. Not the engine's - the engine's is 128 bytes of
   fields this test has no business writing - but the same shape where it
   matters: a magic, the file's identity, and the feature bits a reader that
   does not understand encryption must refuse on. */
#define EHDR_MAGIC     0
#define EHDR_VERSION   4
#define EHDR_FLAGS     8
#define EHDR_UUID      16
#define EHDR_CRC       4092
#define EHDR_MAGIC_VALUE 0x51534341u          /* 'ACSQ' */
#define FLAG_ENCRYPTION  131072u

/* The stand-in superblock: a generation, the seal tree root MAC, and a tag
   over both. */
#define SB_GENERATION  8
#define SB_TREE_ROOT   64                     /* 16 bytes */
#define SB_TAG         96                     /* 16 bytes */
#define SB_TAG_FROM    0
#define SB_TAG_TO      96

#define KDF_METADATA_KEK 1
#define KDF_PAGE_SEAL    2
#define KDF_SEAL_TREE    3

#define EK_BYTES 1184
#define DK_BYTES 2400
#define KSLOT_SIZE 1176
#define SENTRY_SIZE 40
#define MAC_SIZE 16
#define KPAGE_SLOTS 64
#define SLEAF_ENTRIES 64
#define SNODE_CHILDREN 64

#define E_KEY  38
#define E_SEAL 42

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
int cyboudb_kem_open_root(uint8_t *root_out, const uint8_t *slot,
                          const uint8_t *dk, const uint8_t *aad,
                          uint64_t aad_len);
void cyboudb_keypage_init(uint8_t *page, uint64_t index, uint64_t generation);
int cyboudb_keypage_add(uint8_t *page, const uint8_t *slot);
const uint8_t *cyboudb_keypage_find(const uint8_t *page, uint64_t key_id);
int cyboudb_keypage_validate(const uint8_t *page);

int cyboudb_crypto_root_init(uint8_t *page, uint64_t seal_epoch,
                             uint64_t dir_first, uint64_t dir_pages,
                             uint64_t tree_root, uint64_t total_pages);
int cyboudb_crypto_root_validate(const uint8_t *page);

int cyboudb_kdf(uint8_t *out, uint64_t out_len, uint64_t purpose,
                const uint8_t *root, const uint8_t *context,
                uint64_t context_len);

void cyboudb_seal_geometry(uint64_t *out, uint64_t total_pages);
void cyboudb_seal_leaf_init(uint8_t *page, uint64_t index, uint64_t generation,
                            uint64_t epoch);
void cyboudb_seal_node_init(uint8_t *page, uint64_t index, uint64_t level,
                            uint64_t generation, uint64_t epoch);
uint8_t *cyboudb_seal_entry(uint8_t *leaf, uint64_t page_number);
void cyboudb_seal_leaf_mac(uint8_t *out, const uint8_t *key,
                           const uint8_t *page);
void cyboudb_seal_node_mac(uint8_t *out, const uint8_t *key,
                           const uint8_t *page);
int cyboudb_seal_node_set_child(uint8_t *node, uint64_t slot,
                                const uint8_t *mac);
int cyboudb_seal_leaf_verify(const uint8_t *key, const uint8_t *page,
                             const uint8_t *expected);
int cyboudb_seal_node_verify(const uint8_t *key, const uint8_t *page,
                             const uint8_t *expected);

struct pseal_args {
    const uint8_t *key;
    uint8_t *page;
    uint8_t *entry;
    const uint8_t *uuid;
    uint64_t page_no, generation, page_type, epoch;
};
int cyboudb_page_seal(const struct pseal_args *args);
int cyboudb_page_open(const struct pseal_args *args);

int cyboudb_kmac256_init(uint8_t *ctx, const uint8_t *key, uint64_t key_len,
                         const uint8_t *custom, uint64_t custom_len);
void cyboudb_kmac256_update(uint8_t *ctx, const uint8_t *in, uint64_t len);
void cyboudb_kmac256_final(uint8_t *ctx, uint8_t *out, uint64_t out_len);

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

/* The superblock's own tag. The seal tree root is only worth anything because
   the superblock that carries it is authenticated - otherwise an adversary
   rewrites the root along with everything under it. */
static void superblock_tag(uint8_t *out, const uint8_t *metadata_key,
                           const uint8_t *sb) {
    uint8_t ctx[232];
    cyboudb_kmac256_init(ctx, metadata_key, 32,
                         (const uint8_t *)"CybouDB/0.7/superblock", 22);
    cyboudb_kmac256_update(ctx, sb + SB_TAG_FROM, SB_TAG_TO - SB_TAG_FROM);
    cyboudb_kmac256_final(ctx, out, MAC_SIZE);
}

/* The marker the payload carries. If this ever appears in the file, the whole
   exercise has failed - which is the one check here that cannot be argued
   with. */
static const char MARKER[] = "PLAINTEXT-MARKER-payroll-4815162342";

static uint8_t header[PAGE], sb[PAGE], croot[PAGE], kslots[PAGE];
static uint8_t leaf[PAGE], node[PAGE], payload[PAGE];
static uint8_t ek[EK_BYTES], dk[DK_BYTES], dk_other[DK_BYTES];
static uint8_t slot[KSLOT_SIZE];

int main(void) {
    vfs_path path = VFS_PATH("build/encrypted_file_test.cdb");
    uint8_t root_key[32], uuid[16], seed[64];
    uint8_t metadata_key[32], page_key[32], tree_key[32];
    uint8_t aad[24], leaf_mac[MAC_SIZE], node_mac[MAC_SIZE];
    uint64_t key_id = 0, epoch = 1, generation = 7, geo[4];
    int64_t h;
    unsigned i;

    printf("CybouDB encrypted file test\n\n");

    /* ---------------------------------------------------------------- create */
    check("the operating system gives us randomness",
          os_random(root_key, 32) == 0 && os_random(uuid, 16) == 0 &&
          os_random(seed, 64) == 0);

    {
        static uint8_t ek2[EK_BYTES];
        cyboudb_mlkem_keygen(ek, dk, seed, seed + 32);
        seed[0] ^= 0x01;
        cyboudb_mlkem_keygen(ek2, dk_other, seed, seed + 32);
        seed[0] ^= 0x01;
        cyboudb_kem_key_id((uint8_t *)&key_id, ek);
        check("a key pair, and a second one that must never open this file",
              key_id != 0);
    }

    /* The geometry this file assumes is the geometry the engine computes. */
    cyboudb_seal_geometry(geo, TOTAL_PAGES);
    check("one leaf and one node cover a file this small",
          geo[0] == 1 && geo[1] == 1 && geo[2] == 1);

    /* The header is plaintext on purpose: a reader that does not understand
       the encryption bit has to be able to read far enough to refuse. */
    memset(header, 0, PAGE);
    wr32(header, EHDR_MAGIC, EHDR_MAGIC_VALUE);
    wr32(header, EHDR_VERSION, 1);
    wr32(header, EHDR_FLAGS, FLAG_ENCRYPTION);
    memcpy(header + EHDR_UUID, uuid, 16);
    wr32(header, EHDR_CRC, crc32c(header, EHDR_CRC));

    /* The crypto root, and the key slot page it points at. */
    check("the crypto root writes",
          cyboudb_crypto_root_init(croot, epoch, P_SEAL_LEAF, 1, P_SEAL_NODE,
                                   TOTAL_PAGES) == 0);
    wr64(croot, 4016, P_KEY_SLOTS);             /* CROOT_KEM_ROOT */
    wr32(croot, 4092, crc32c(croot, 4092));
    check("and validates with the key slot page it points at",
          cyboudb_crypto_root_validate(croot) == 0);

    memcpy(aad, uuid, 16);
    memcpy(aad + 16, &key_id, 8);

    cyboudb_keypage_init(kslots, 0, generation);
    check("the root key seals to the public key and goes in a slot",
          cyboudb_kem_seal_root(slot, ek, root_key, key_id, aad, 24) == 0 &&
          cyboudb_keypage_add(kslots, slot) == 0 &&
          cyboudb_keypage_validate(kslots) == 0);

    /* Every key below the root. */
    {
        uint8_t ctx8[8];
        memcpy(ctx8, &epoch, 8);
        check("the hierarchy derives",
              cyboudb_kdf(metadata_key, 32, KDF_METADATA_KEK, root_key,
                          NULL, 0) == 0 &&
              cyboudb_kdf(page_key, 32, KDF_PAGE_SEAL, root_key, ctx8, 8) == 0 &&
              cyboudb_kdf(tree_key, 32, KDF_SEAL_TREE, root_key, ctx8, 8) == 0);
    }

    /* The payload, sealed, with its nonce and tag going to the directory. */
    memset(payload, 0, PAGE);
    memcpy(payload, MARKER, sizeof MARKER);
    for (i = 200; i < PAGE; i++) payload[i] = (uint8_t)(i * 3 + 1);

    cyboudb_seal_leaf_init(leaf, 0, generation, epoch);
    {
        struct pseal_args a;
        a.key = page_key;
        a.page = payload;
        a.entry = cyboudb_seal_entry(leaf, P_PAYLOAD);
        a.uuid = uuid;
        a.page_no = P_PAYLOAD;
        a.generation = generation;
        a.page_type = 1;
        a.epoch = epoch;
        check("the payload page has an entry in the directory", a.entry != NULL);
        check("and seals into it", cyboudb_page_seal(&a) == 0);
        check("and the page in memory is no longer the plaintext",
              memcmp(payload, MARKER, sizeof MARKER) != 0);
    }
    wr32(leaf, 4092, crc32c(leaf, 4092));

    /* The tree over the directory, and the superblock over the tree. */
    cyboudb_seal_leaf_mac(leaf_mac, tree_key, leaf);
    cyboudb_seal_node_init(node, 0, 1, generation, epoch);
    cyboudb_seal_node_set_child(node, 0, leaf_mac);
    cyboudb_seal_node_mac(node_mac, tree_key, node);

    memset(sb, 0, PAGE);
    wr64(sb, SB_GENERATION, generation);
    memcpy(sb + SB_TREE_ROOT, node_mac, MAC_SIZE);
    superblock_tag(sb + SB_TAG, metadata_key, sb);

    /* ------------------------------------------------------------ write it out */
    h = vfs_create_truncate(path, 0);
    check("the file opens for writing", h != -1);
    if (h == -1) return 1;

    check("every page writes at its own offset",
          vfs_write_at(h, header, PAGE, (uint64_t)P_HEADER * PAGE) == PAGE &&
          vfs_write_at(h, sb, PAGE, (uint64_t)P_SUPERBLOCK * PAGE) == PAGE &&
          vfs_write_at(h, croot, PAGE, (uint64_t)P_CRYPTO_ROOT * PAGE) == PAGE &&
          vfs_write_at(h, kslots, PAGE, (uint64_t)P_KEY_SLOTS * PAGE) == PAGE &&
          vfs_write_at(h, leaf, PAGE, (uint64_t)P_SEAL_LEAF * PAGE) == PAGE &&
          vfs_write_at(h, node, PAGE, (uint64_t)P_SEAL_NODE * PAGE) == PAGE &&
          vfs_write_at(h, payload, PAGE, (uint64_t)P_PAYLOAD * PAGE) == PAGE);
    check("and the file reaches the disk", vfs_sync_file(h) == 0);
    vfs_close(h);

    /* Everything the writer knew is now forgotten, which is the point of
       reopening rather than asserting against what is still in memory. */
    memset(root_key, 0, sizeof root_key);
    memset(metadata_key, 0, sizeof metadata_key);
    memset(page_key, 0, sizeof page_key);
    memset(tree_key, 0, sizeof tree_key);
    memset(payload, 0, sizeof payload);
    memset(leaf, 0, sizeof leaf);
    memset(node, 0, sizeof node);
    memset(croot, 0, sizeof croot);
    memset(kslots, 0, sizeof kslots);
    memset(sb, 0, sizeof sb);

    /* --------------------------------------------- nothing readable on disk */
    {
        static uint8_t whole[TOTAL_PAGES * PAGE];
        size_t n, found = 0;
        h = vfs_open_rw(path, 0);
        vfs_read_at(h, whole, sizeof whole, 0);
        for (n = 0; n + sizeof MARKER <= sizeof whole; n++)
            if (memcmp(whole + n, MARKER, sizeof MARKER - 1) == 0) found++;
        check("the marker does not appear anywhere in the file", found == 0);

        /* And the uuid does, because the header is plaintext by design - a
           reader that cannot decrypt still has to identify and refuse. */
        found = 0;
        for (n = 0; n + 16 <= sizeof whole; n++)
            if (memcmp(whole + n, uuid, 16) == 0) found++;
        check("while the file's identity is readable, as a header must be",
              found >= 1);
        vfs_close(h);
    }

    /* ---------------------------------------------------------------- reopen */
    h = vfs_open_rw(path, 0);
    check("the file reopens", h != -1);

    check("the header says it needs a feature, and which",
          vfs_read_at(h, header, PAGE, 0) == PAGE &&
          (*(uint32_t *)(header + EHDR_FLAGS) & FLAG_ENCRYPTION) != 0);

    check("the crypto root reads and validates",
          vfs_read_at(h, croot, PAGE, (uint64_t)P_CRYPTO_ROOT * PAGE) == PAGE &&
          cyboudb_crypto_root_validate(croot) == 0);

    check("and points at the key slot page",
          rd64(croot, 4016) == P_KEY_SLOTS &&
          vfs_read_at(h, kslots, PAGE, (uint64_t)P_KEY_SLOTS * PAGE) == PAGE &&
          cyboudb_keypage_validate(kslots) == 0);

    {
        const uint8_t *found_slot = cyboudb_keypage_find(kslots, key_id);
        check("the slot for this key is on the page", found_slot != NULL);

        memcpy(aad, header + EHDR_UUID, 16);
        memcpy(aad + 16, &key_id, 8);

        check("the private key opens the root",
              cyboudb_kem_open_root(root_key, found_slot, dk, aad, 24) == 0);
        {
            uint8_t zero[32];
            memset(zero, 0, 32);
            check("and the root is a key rather than zeroes",
                  memcmp(root_key, zero, 32) != 0);
        }

        {
            uint8_t other_root[32], zero[32];
            memset(zero, 0, 32);
            check("while the other key pair gets CybouDB_E_KEY and zeroes",
                  cyboudb_kem_open_root(other_root, found_slot, dk_other,
                                        aad, 24) == E_KEY &&
                  memcmp(other_root, zero, 32) == 0);
        }
    }

    {
        uint8_t ctx8[8];
        uint64_t got_epoch = rd64(croot, 8);      /* CROOT_SEAL_EPOCH */
        memcpy(ctx8, &got_epoch, 8);
        cyboudb_kdf(metadata_key, 32, KDF_METADATA_KEK, root_key, NULL, 0);
        cyboudb_kdf(page_key, 32, KDF_PAGE_SEAL, root_key, ctx8, 8);
        cyboudb_kdf(tree_key, 32, KDF_SEAL_TREE, root_key, ctx8, 8);
        check("the epoch in the file is the epoch the keys derive from",
              got_epoch == epoch);
    }

    /* --------------------------------------------------- the chain of trust */
    check("the superblock reads",
          vfs_read_at(h, sb, PAGE, (uint64_t)P_SUPERBLOCK * PAGE) == PAGE);
    {
        uint8_t want[MAC_SIZE];
        superblock_tag(want, metadata_key, sb);
        check("and authenticates under the key we just recovered",
              memcmp(want, sb + SB_TAG, MAC_SIZE) == 0);
    }

    check("the seal tree node reads",
          vfs_read_at(h, node, PAGE, (uint64_t)P_SEAL_NODE * PAGE) == PAGE);
    check("and is the node the superblock published",
          cyboudb_seal_node_verify(tree_key, node, sb + SB_TREE_ROOT) == 0);

    check("the seal leaf reads",
          vfs_read_at(h, leaf, PAGE, (uint64_t)P_SEAL_LEAF * PAGE) == PAGE);
    check("and is the leaf the node published",
          cyboudb_seal_leaf_verify(tree_key, leaf,
                                   node + SNODE_CHILDREN) == 0);

    /* ------------------------------------------------------- and the payload */
    {
        struct pseal_args a;
        check("the payload page reads",
              vfs_read_at(h, payload, PAGE, (uint64_t)P_PAYLOAD * PAGE) == PAGE);
        a.key = page_key;
        a.page = payload;
        a.entry = cyboudb_seal_entry(leaf, P_PAYLOAD);
        a.uuid = header + EHDR_UUID;
        a.page_no = P_PAYLOAD;
        a.generation = rd64(sb, SB_GENERATION);
        a.page_type = 1;
        a.epoch = epoch;
        check("and opens with the nonce and tag the directory kept",
              cyboudb_page_open(&a) == 0);
        check("and is the page that was written",
              memcmp(payload, MARKER, sizeof MARKER) == 0);
    }

    /* ------------------------------------------------------ and what refuses */
    {
        static uint8_t torn[PAGE];
        struct pseal_args a;
        vfs_read_at(h, torn, PAGE, (uint64_t)P_PAYLOAD * PAGE);
        torn[1000] ^= 0x01;
        a.key = page_key; a.page = torn;
        a.entry = cyboudb_seal_entry(leaf, P_PAYLOAD);
        a.uuid = header + EHDR_UUID;
        a.page_no = P_PAYLOAD; a.generation = rd64(sb, SB_GENERATION);
        a.page_type = 1; a.epoch = epoch;
        check("a payload page altered on disk is refused",
              cyboudb_page_open(&a) == E_SEAL);
    }

    /* The replay the seal tree exists for, now at the level of a file: an
       entry put back the way it was before the page was rewritten. */
    {
        static uint8_t old_leaf[PAGE];
        uint8_t *entry;
        memcpy(old_leaf, leaf, PAGE);
        entry = cyboudb_seal_entry(old_leaf, P_PAYLOAD);
        entry[0] ^= 0x01;                 /* any other published entry */
        wr32(old_leaf, 4092, crc32c(old_leaf, 4092));
        check("a leaf carrying a different entry is not the leaf the node "
              "published",
              cyboudb_seal_leaf_verify(tree_key, old_leaf,
                                       node + SNODE_CHILDREN) != 0);
    }

    vfs_close(h);
#ifdef _WIN32
    _wremove(path);
#else
    remove(path);
#endif

    printf("\nencrypted file suite: %d checks, %d failed\n", checks, failures);
    return failures ? 1 : 0;
}
