/* tests/encrypted_commit_test.c - a crash at every point of an encrypted commit
 *
 * docs/ENCRYPTED_FORMAT.md, Decision 6b. A commit publishes a generation and,
 * in an encrypted file, the only evidence that the generation's pages are what
 * they claim to be. Those have to become durable in the right order, or the
 * file gets published while the evidence for it is still in a write cache.
 *
 * The invariant, and the whole point of this file:
 *
 *     for every prefix of the commit's writes, a reader sees the old
 *     generation whole or the new generation whole - never a mix
 *
 * The test runs every prefix. It then runs the same commit with the superblock
 * moved ahead of the barrier and demands that a prefix exists which publishes
 * a generation whose seal tree is not on the disk: the ordering is what
 * produces the invariant, and a test that cannot show the wrong order failing
 * has not shown the right one working.
 *
 * Crashes are simulated by stopping the write sequence, which is what a crash
 * does to a sequence of writes that have not been made durable. What this
 * cannot simulate is a disk reordering writes that no barrier separates - so
 * the barrier is where the sequence is cut, not an assumption the test makes.
 *
 * Build (Linux):   sh build.sh --crypto-tests && ./build/encrypted_commit_test
 * Build (Windows): build.bat --crypto-tests && build\encrypted_commit_test.exe
 *
 * SPDX-License-Identifier: Apache-2.0
 * Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#define PAGE 4096

#define P_HEADER       0
#define P_SB_A         1
#define P_SB_B         2
#define P_LEAF_A       3
#define P_LEAF_B       4
#define P_NODE_A       5
#define P_NODE_B       6
#define P_PAYLOAD_OLD  7
#define P_PAYLOAD_NEW  8
#define TOTAL_PAGES    9

#define SB_MAGIC       0
#define SB_GENERATION  8
#define SB_PAYLOAD     16          /* which page holds the payload */
#define SB_LEAF        24          /* which copy of the leaf is this one's */
#define SB_NODE        32
#define SB_TREE_ROOT   64
#define SB_TAG         96
#define SB_TAG_TO      96
#define SB_MAGIC_VALUE 0x42535145u

#define MAC_SIZE 16
#define SNODE_CHILDREN 64
#define KDF_METADATA_KEK 1
#define KDF_PAGE_SEAL    2
#define KDF_SEAL_TREE    3

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

int cyboudb_kdf(uint8_t *out, uint64_t out_len, uint64_t purpose,
                const uint8_t *root, const uint8_t *context,
                uint64_t context_len);
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
static uint32_t rd32(const uint8_t *p, int off) {
    uint32_t v; memcpy(&v, p + off, 4); return v;
}

static uint8_t root_key[32], metadata_key[32], page_key[32], tree_key[32];
static uint8_t uuid[16];
static const uint64_t EPOCH = 1;

static void superblock_tag(uint8_t *out, const uint8_t *sb) {
    uint8_t ctx[232];
    cyboudb_kmac256_init(ctx, metadata_key, 32,
                         (const uint8_t *)"CybouDB/0.7/superblock", 22);
    cyboudb_kmac256_update(ctx, sb, SB_TAG_TO);
    cyboudb_kmac256_final(ctx, out, MAC_SIZE);
}

/* One write of the commit: a page, and the bytes that go into it. */
typedef struct { uint64_t page; const uint8_t *bytes; const char *what; } write_op;

/* Build a generation: seal the payload into a leaf, node it, and make the
   superblock that publishes it. */
static void build_generation(uint64_t generation, uint64_t payload_page,
                             uint64_t leaf_page, uint64_t node_page,
                             const char *content,
                             uint8_t *payload, uint8_t *leaf, uint8_t *node,
                             uint8_t *sb) {
    struct pseal_args a;
    uint8_t leaf_mac[MAC_SIZE], node_mac[MAC_SIZE];
    unsigned i;

    memset(payload, 0, PAGE);
    strcpy((char *)payload, content);
    for (i = 256; i < PAGE; i++) payload[i] = (uint8_t)(i + generation);

    cyboudb_seal_leaf_init(leaf, 0, generation, EPOCH);
    a.key = page_key;
    a.page = payload;
    a.entry = cyboudb_seal_entry(leaf, payload_page);
    a.uuid = uuid;
    a.page_no = payload_page;
    a.generation = generation;
    a.page_type = 1;
    a.epoch = EPOCH;
    cyboudb_page_seal(&a);
    wr32(leaf, 4092, crc32c(leaf, 4092));

    cyboudb_seal_leaf_mac(leaf_mac, tree_key, leaf);
    cyboudb_seal_node_init(node, 0, 1, generation, EPOCH);
    cyboudb_seal_node_set_child(node, 0, leaf_mac);
    cyboudb_seal_node_mac(node_mac, tree_key, node);

    memset(sb, 0, PAGE);
    wr32(sb, SB_MAGIC, SB_MAGIC_VALUE);
    wr64(sb, SB_GENERATION, generation);
    wr64(sb, SB_PAYLOAD, payload_page);
    wr64(sb, SB_LEAF, leaf_page);
    wr64(sb, SB_NODE, node_page);
    memcpy(sb + SB_TREE_ROOT, node_mac, MAC_SIZE);
    superblock_tag(sb + SB_TAG, sb);
}

/* What a reader sees. Returns the generation it recovered, 0 if the file has
   no valid superblock at all, and -1 if it recovered a generation whose
   evidence is not there - the hybrid this whole design exists to forbid. */
static long recover(int64_t h, char *content_out) {
    static uint8_t sb[2][PAGE], leaf[PAGE], node[PAGE], payload[PAGE];
    uint8_t want[MAC_SIZE];
    int valid[2];
    int pick = -1;
    int i;

    for (i = 0; i < 2; i++) {
        valid[i] = 0;
        if (vfs_read_at(h, sb[i], PAGE, (uint64_t)(P_SB_A + i) * PAGE) != PAGE)
            continue;
        if (rd32(sb[i], SB_MAGIC) != SB_MAGIC_VALUE) continue;
        superblock_tag(want, sb[i]);
        if (memcmp(want, sb[i] + SB_TAG, MAC_SIZE) != 0) continue;
        valid[i] = 1;
    }

    if (valid[0] && valid[1])
        pick = rd64(sb[0], SB_GENERATION) >= rd64(sb[1], SB_GENERATION) ? 0 : 1;
    else if (valid[0]) pick = 0;
    else if (valid[1]) pick = 1;
    else return 0;

    /* Everything below here is the reader believing the superblock and then
       checking whether the file backs it up. A file that cannot back it up is
       the failure this test is looking for. */
    {
        uint8_t *chosen = sb[pick];
        uint64_t generation = rd64(chosen, SB_GENERATION);
        struct pseal_args a;

        if (vfs_read_at(h, node, PAGE, rd64(chosen, SB_NODE) * PAGE) != PAGE)
            return -1;
        if (cyboudb_seal_node_verify(tree_key, node,
                                     chosen + SB_TREE_ROOT) != 0)
            return -1;

        if (vfs_read_at(h, leaf, PAGE, rd64(chosen, SB_LEAF) * PAGE) != PAGE)
            return -1;
        if (cyboudb_seal_leaf_verify(tree_key, leaf, node + SNODE_CHILDREN) != 0)
            return -1;

        if (vfs_read_at(h, payload, PAGE, rd64(chosen, SB_PAYLOAD) * PAGE)
            != PAGE)
            return -1;

        a.key = page_key;
        a.page = payload;
        a.entry = cyboudb_seal_entry(leaf, rd64(chosen, SB_PAYLOAD));
        a.uuid = uuid;
        a.page_no = rd64(chosen, SB_PAYLOAD);
        a.generation = generation;
        a.page_type = 1;
        a.epoch = EPOCH;
        if (a.entry == NULL) return -1;
        if (cyboudb_page_open(&a) != 0) return -1;

        if (content_out) {
            memcpy(content_out, payload, 64);
            content_out[63] = 0;
        }
        return (long)generation;
    }
}

static uint8_t header[PAGE];
static uint8_t payload_old[PAGE], leaf_old[PAGE], node_old[PAGE], sb_old[PAGE];
static uint8_t payload_new[PAGE], leaf_new[PAGE], node_new[PAGE], sb_new[PAGE];

static const char OLD_CONTENT[] = "generation seven, the committed one";
static const char NEW_CONTENT[] = "generation eight, the one being written";

/* Lay down the starting file: generation 7, published in superblock A. */
static void write_starting_file(int64_t h) {
    static const uint8_t zero[PAGE];
    unsigned p;
    for (p = 0; p < TOTAL_PAGES; p++)
        vfs_write_at(h, zero, PAGE, (uint64_t)p * PAGE);
    vfs_write_at(h, header, PAGE, (uint64_t)P_HEADER * PAGE);
    vfs_write_at(h, payload_old, PAGE, (uint64_t)P_PAYLOAD_OLD * PAGE);
    vfs_write_at(h, leaf_old, PAGE, (uint64_t)P_LEAF_A * PAGE);
    vfs_write_at(h, node_old, PAGE, (uint64_t)P_NODE_A * PAGE);
    vfs_write_at(h, sb_old, PAGE, (uint64_t)P_SB_A * PAGE);
    vfs_sync_file(h);
}

int main(void) {
    vfs_path path = VFS_PATH("build/encrypted_commit_test.cdb");
    uint8_t ctx8[8];
    int64_t h;
    unsigned prefix;
    int order;

    printf("CybouDB encrypted commit test\n\n");

    check("randomness, and a root key",
          os_random(root_key, 32) == 0 && os_random(uuid, 16) == 0);
    memcpy(ctx8, &EPOCH, 8);
    cyboudb_kdf(metadata_key, 32, KDF_METADATA_KEK, root_key, NULL, 0);
    cyboudb_kdf(page_key, 32, KDF_PAGE_SEAL, root_key, ctx8, 8);
    cyboudb_kdf(tree_key, 32, KDF_SEAL_TREE, root_key, ctx8, 8);

    memset(header, 0, PAGE);
    memcpy(header + 16, uuid, 16);

    build_generation(7, P_PAYLOAD_OLD, P_LEAF_A, P_NODE_A, OLD_CONTENT,
                     payload_old, leaf_old, node_old, sb_old);
    build_generation(8, P_PAYLOAD_NEW, P_LEAF_B, P_NODE_B, NEW_CONTENT,
                     payload_new, leaf_new, node_new, sb_new);

    /* The file as it stands before the commit. */
    h = vfs_create_truncate(path, 0);
    check("the starting file writes", h != -1);
    write_starting_file(h);
    {
        char content[64];
        check("and a reader sees generation seven",
              recover(h, content) == 7 &&
              strcmp(content, OLD_CONTENT) == 0);
    }
    vfs_close(h);

    /* --- the fault matrix -----------------------------------------------------
       Two orders. The first is Decision 6b's; the second moves the superblock
       ahead of the barrier, which is what a commit looks like when nobody
       thought about ordering. */
    for (order = 0; order < 2; order++) {
        write_op correct[] = {
            { P_PAYLOAD_NEW, payload_new, "the new payload" },
            { P_LEAF_B,      leaf_new,    "the leaf that covers it" },
            { P_NODE_B,      node_new,    "the node above the leaf" },
            { P_SB_B,        sb_new,      "the superblock that publishes it" },
        };
        write_op wrong[] = {
            { P_SB_B,        sb_new,      "the superblock, published first" },
            { P_PAYLOAD_NEW, payload_new, "the new payload" },
            { P_LEAF_B,      leaf_new,    "the leaf that covers it" },
            { P_NODE_B,      node_new,    "the node above the leaf" },
        };
        write_op *ops = order == 0 ? correct : wrong;
        int hybrids = 0, sevens = 0, eights = 0;

        for (prefix = 0; prefix <= 4; prefix++) {
            unsigned k;
            long got;
            char content[64];

            h = vfs_create_truncate(path, 0);
            write_starting_file(h);

            /* The commit, interrupted after `prefix` writes. */
            for (k = 0; k < prefix; k++)
                vfs_write_at(h, ops[k].bytes, PAGE, ops[k].page * PAGE);
            vfs_close(h);

            /* What a reader makes of the wreckage. */
            h = vfs_open_rw(path, 0);
            got = recover(h, content);
            vfs_close(h);

            if (got == -1) hybrids++;
            else if (got == 7) {
                sevens++;
                if (strcmp(content, OLD_CONTENT) != 0) hybrids++;
            } else if (got == 8) {
                eights++;
                if (strcmp(content, NEW_CONTENT) != 0) hybrids++;
            } else {
                hybrids++;          /* no valid superblock at all */
            }
        }

        if (order == 0) {
            char what[128];
            snprintf(what, sizeof what,
                     "in the order Decision 6b gives, every one of the five "
                     "crash points recovers whole (%d old, %d new)",
                     sevens, eights);
            check(what, hybrids == 0 && sevens + eights == 5);
            check("and both outcomes actually occur - the test is not just "
                  "watching the old generation survive",
                  sevens > 0 && eights > 0);
        } else {
            check("with the superblock written before the barrier, a crash "
                  "point exists that publishes a generation whose evidence is "
                  "not on the disk",
                  hybrids > 0);
        }
    }

    /* --- a torn superblock ----------------------------------------------------
       A publication interrupted inside the page itself. The tag covers the
       generation and the tree root together, so a tear inside that range does
       not verify and the reader falls back to the other copy.

       A tear OUTSIDE that range is harmless here, and the first version of
       this test asserted otherwise and failed: it zeroed the last two
       kilobytes, which this superblock does not use, and then demanded a
       fallback that would have been wrong to make. The new generation's pages
       were durable before the superblock was written, so publishing it is the
       correct outcome.

       That is a requirement on the engine, not a curiosity about this
       stand-in: **the tag must cover every byte of the superblock a reader
       will use.** A field living past the tagged range would be a field a torn
       write can change invisibly. */
    {
        static uint8_t half[PAGE];
        char content[64];
        long got;

        h = vfs_create_truncate(path, 0);
        write_starting_file(h);
        vfs_write_at(h, payload_new, PAGE, (uint64_t)P_PAYLOAD_NEW * PAGE);
        vfs_write_at(h, leaf_new, PAGE, (uint64_t)P_LEAF_B * PAGE);
        vfs_write_at(h, node_new, PAGE, (uint64_t)P_NODE_B * PAGE);
        vfs_sync_file(h);

        memcpy(half, sb_new, PAGE);
        memset(half + 2048, 0, 2048);           /* the unused tail never landed */
        vfs_write_at(h, half, PAGE, (uint64_t)P_SB_B * PAGE);
        vfs_close(h);

        h = vfs_open_rw(path, 0);
        got = recover(h, content);
        vfs_close(h);
        check("a tear outside what the tag covers publishes anyway, because "
              "nothing outside it is read",
              got == 8 && strcmp(content, NEW_CONTENT) == 0);
    }

    /* And the same tear in the first half, where the generation lives. */
    {
        static uint8_t half[PAGE];
        char content[64];
        long got;

        h = vfs_create_truncate(path, 0);
        write_starting_file(h);
        vfs_write_at(h, payload_new, PAGE, (uint64_t)P_PAYLOAD_NEW * PAGE);
        vfs_write_at(h, leaf_new, PAGE, (uint64_t)P_LEAF_B * PAGE);
        vfs_write_at(h, node_new, PAGE, (uint64_t)P_NODE_B * PAGE);
        vfs_sync_file(h);

        memcpy(half, sb_new, PAGE);
        memset(half, 0, 64);                    /* the head never landed */
        vfs_write_at(h, half, PAGE, (uint64_t)P_SB_B * PAGE);
        vfs_close(h);

        h = vfs_open_rw(path, 0);
        got = recover(h, content);
        vfs_close(h);
        check("while a tear inside the tagged range publishes nothing",
              got == 7 && strcmp(content, OLD_CONTENT) == 0);
    }

    /* --- the old generation is still openable after the new one lands --------
       Which is what makes a rollback to it possible at all, and is the reason
       the seal directory keeps two copies rather than one. */
    {
        char content[64];
        h = vfs_create_truncate(path, 0);
        write_starting_file(h);
        vfs_write_at(h, payload_new, PAGE, (uint64_t)P_PAYLOAD_NEW * PAGE);
        vfs_write_at(h, leaf_new, PAGE, (uint64_t)P_LEAF_B * PAGE);
        vfs_write_at(h, node_new, PAGE, (uint64_t)P_NODE_B * PAGE);
        vfs_sync_file(h);
        vfs_write_at(h, sb_new, PAGE, (uint64_t)P_SB_B * PAGE);
        vfs_sync_file(h);
        check("after a complete commit the reader sees generation eight",
              recover(h, content) == 8 && strcmp(content, NEW_CONTENT) == 0);

        /* Destroying the newer superblock leaves the older generation intact -
           the rollback-by-destruction that ENCRYPTION.md refuses to claim it
           can prevent, behaving exactly as documented. */
        {
            static uint8_t rubble[PAGE];
            memset(rubble, 0xFF, PAGE);
            vfs_write_at(h, rubble, PAGE, (uint64_t)P_SB_B * PAGE);
            check("and destroying it falls back to seven, whole",
                  recover(h, content) == 7 &&
                  strcmp(content, OLD_CONTENT) == 0);
        }
        vfs_close(h);
    }

#ifdef _WIN32
    _wremove(path);
#else
    remove(path);
#endif

    printf("\nencrypted commit suite: %d checks, %d failed\n",
           checks, failures);
    return failures ? 1 : 0;
}
