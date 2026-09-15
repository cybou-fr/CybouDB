/* tests/seal_dir_test.c - the seal directory, and the replay it exists to stop
 *
 * The centre of this file is one scenario, and everything else supports it.
 * An adversary who restores an old page AND its old seal entry presents a pair
 * the AEAD accepts, because the pair is genuine - it is last week's. The
 * question the seal tree has to answer is not "is this entry well formed" but
 * "is this entry the one that was published", and only a parent can answer it.
 * So the test rewrites an entry, puts the old bytes back, and demands that the
 * leaf stop matching what its parent says it should be.
 *
 * Build (Linux):   sh build.sh --crypto-tests && ./build/seal_dir_test
 * Build (Windows): build.bat --crypto-tests && build\seal_dir_test.exe
 *
 * SPDX-License-Identifier: Apache-2.0
 * Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
 */
#include <stdio.h>
#include <string.h>
#include <stdint.h>

#define PAGE_SIZE 4096

/* include/crypto.inc holds the same numbers. */
#define SLEAF_MAGIC        0
#define SLEAF_VERSION      4
#define SLEAF_INDEX        8
#define SLEAF_FIRST_PAGE   16
#define SLEAF_GENERATION   24
#define SLEAF_SEAL_EPOCH   32
#define SLEAF_RESERVED     40
#define SLEAF_ENTRIES      64
#define SLEAF_RESERVED_TAIL 4064
#define SLEAF_CRC          4092

#define SNODE_LEVEL        16
#define SNODE_GENERATION   24
#define SNODE_CHILD_COUNT  40
#define SNODE_RESERVED     48
#define SNODE_CHILDREN     64
#define SNODE_RESERVED_TAIL 4080
#define SNODE_CRC          4092

#define SENTRY_NONCE 0
#define SENTRY_TAG   24
#define SENTRY_SIZE  48

#define ENTRIES_PER_LEAF  83
#define CHILDREN_PER_NODE 251
#define MAC_SIZE          16

#define SGEO_LEAVES 0
#define SGEO_NODES  1
#define SGEO_DEPTH  2
#define SGEO_PAGES  3
#define SLAYOUT_OFFSET 0
#define SLAYOUT_COUNT  1

#define SEAL_OK         0
#define SEAL_E_MAGIC    1
#define SEAL_E_VERSION  2
#define SEAL_E_CRC      3
#define SEAL_E_RESERVED 4
#define SEAL_E_FIELDS   5
#define SEAL_E_MAC      6

void cyboudb_seal_geometry(uint64_t *out, uint64_t total_pages);
int cyboudb_seal_level(uint64_t *out, uint64_t total_pages, uint64_t level);
void cyboudb_seal_leaf_init(uint8_t *page, uint64_t leaf_index,
                            uint64_t generation, uint64_t seal_epoch);
void cyboudb_seal_node_init(uint8_t *page, uint64_t node_index, uint64_t level,
                            uint64_t generation, uint64_t seal_epoch);
uint8_t *cyboudb_seal_entry(uint8_t *leaf_page, uint64_t page_number);
void cyboudb_seal_leaf_mac(uint8_t *out, const uint8_t *key,
                           const uint8_t *page);
void cyboudb_seal_node_mac(uint8_t *out, const uint8_t *key,
                           const uint8_t *page);
int cyboudb_seal_node_set_child(uint8_t *node_page, uint64_t slot,
                                const uint8_t *mac);
int cyboudb_seal_leaf_verify(const uint8_t *key, const uint8_t *page,
                             const uint8_t *expected);
int cyboudb_seal_node_verify(const uint8_t *key, const uint8_t *page,
                             const uint8_t *expected);
int cyboudb_seal_leaf_validate(const uint8_t *page);
int cyboudb_seal_node_validate(const uint8_t *page);

uint32_t crc32c(const uint8_t *buf, uint64_t len);

#define SHCTX_SIZE 232
int cyboudb_kmac256_init(uint8_t *ctx, const uint8_t *key, uint64_t key_len,
                         const uint8_t *custom, uint64_t custom_len);
void cyboudb_kmac256_update(uint8_t *ctx, const uint8_t *in, uint64_t len);
void cyboudb_kmac256_final(uint8_t *ctx, uint8_t *out, uint64_t out_len);

/* The construction spelled out here rather than trusted: KMAC256 keyed with
   the seal tree key, customized by the page kind, over the covered bytes.
   Written separately from the assembly so a change to either - a dropped
   label, a shifted range - shows up as a disagreement rather than as two
   matching mistakes.

   It was a hand-rolled prefix MAC until KMAC replaced it. What that change
   bought is visible one file over: tests/kmac_test.c checks the construction
   against OpenSSL and against NIST's own sample, which is not something a
   construction of ours could ever have. */
static void expected_mac(uint8_t *out, const uint8_t *key, const char *label,
                         const uint8_t *page, int from, int to) {
    uint8_t ctx[SHCTX_SIZE];
    cyboudb_kmac256_init(ctx, key, 32, (const uint8_t *)label, strlen(label));
    cyboudb_kmac256_update(ctx, page + from, (uint64_t)(to - from));
    cyboudb_kmac256_final(ctx, out, MAC_SIZE);
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
static void wr64(uint8_t *p, int off, uint64_t v) { memcpy(p + off, &v, 8); }
static void wr32(uint8_t *p, int off, uint32_t v) { memcpy(p + off, &v, 4); }

static void repair_crc(uint8_t *page) {
    wr32(page, SLEAF_CRC, crc32c(page, SLEAF_CRC));
}

int main(void) {
    static uint8_t leaf[PAGE_SIZE], node[PAGE_SIZE], scratch[PAGE_SIZE];
    uint8_t key[32], other_key[32];
    uint8_t mac[MAC_SIZE], mac2[MAC_SIZE], published[MAC_SIZE];
    uint64_t geo[4];
    unsigned i;

    printf("CybouDB seal directory test\n\n");

    for (i = 0; i < 32; i++) key[i] = (uint8_t)(i * 5 + 3);
    memcpy(other_key, key, 32);
    other_key[0] ^= 0x40;

    /* --- the geometry, against the table in docs/ENCRYPTED_FORMAT.md --------
       Not a re-derivation of the code's arithmetic in the test's own words:
       these four rows are printed in the design document, and if the code and
       the document ever disagree this is where it shows. */
    {
        struct { uint64_t pages, leaves, nodes, depth, both; } row[] = {
            {      1000,     13,   1, 1,     28 },
            {     60000,    723,   4, 2,   1454 },
            {   1048576,  12634,  52, 2,  25372 },
            {   6300000,  75904, 306, 3, 152420 },
        };
        unsigned r, ok = 1;
        for (r = 0; r < 4; r++) {
            cyboudb_seal_geometry(geo, row[r].pages);
            if (geo[SGEO_LEAVES] != row[r].leaves ||
                geo[SGEO_NODES]  != row[r].nodes  ||
                geo[SGEO_DEPTH]  != row[r].depth  ||
                geo[SGEO_PAGES]  != row[r].both) ok = 0;
        }
        check("the four rows of the overhead table come out of the code", ok);

        cyboudb_seal_geometry(geo, 1);
        check("one page still needs a leaf and a root",
              geo[SGEO_LEAVES] == 1 && geo[SGEO_NODES] == 1 &&
              geo[SGEO_DEPTH] == 1 && geo[SGEO_PAGES] == 4);
        cyboudb_seal_geometry(geo, ENTRIES_PER_LEAF);
        check("and exactly one leaf's worth of pages need one leaf",
              geo[SGEO_LEAVES] == 1);
        cyboudb_seal_geometry(geo, ENTRIES_PER_LEAF + 1);
        check("while one more page needs two", geo[SGEO_LEAVES] == 2);

        {
            uint64_t level[2];
            check("level zero locates all leaves",
                  cyboudb_seal_level(level, 6300000, 0) == SEAL_OK &&
                  level[SLAYOUT_OFFSET] == 0 &&
                  level[SLAYOUT_COUNT] == 75904);
            check("level one follows the leaves",
                  cyboudb_seal_level(level, 6300000, 1) == SEAL_OK &&
                  level[SLAYOUT_OFFSET] == 75904 &&
                  level[SLAYOUT_COUNT] == 303);
            check("level two follows level one",
                  cyboudb_seal_level(level, 6300000, 2) == SEAL_OK &&
                  level[SLAYOUT_OFFSET] == 76207 &&
                  level[SLAYOUT_COUNT] == 2);
            check("the root is the final page of either copy",
                  cyboudb_seal_level(level, 6300000, 3) == SEAL_OK &&
                  level[SLAYOUT_OFFSET] == 76209 &&
                  level[SLAYOUT_COUNT] == 1);
            check("and a level above the root is refused",
                  cyboudb_seal_level(level, 6300000, 4) == SEAL_E_FIELDS);
            check("zero protected pages have no seal-tree layout",
                  cyboudb_seal_level(level, 0, 0) == SEAL_E_FIELDS);
            check("20,833 pages end at a single level-one root",
                  cyboudb_seal_level(level, 20833, 1) == SEAL_OK &&
                  level[SLAYOUT_COUNT] == 1 &&
                  cyboudb_seal_level(level, 20833, 2) == SEAL_E_FIELDS);
            check("and one more page introduces a level-two root",
                  cyboudb_seal_level(level, 20834, 1) == SEAL_OK &&
                  level[SLAYOUT_COUNT] == 2 &&
                  cyboudb_seal_level(level, 20834, 2) == SEAL_OK &&
                  level[SLAYOUT_COUNT] == 1);
        }
    }

    /* --- a leaf, and which pages it speaks for ------------------------------ */
    cyboudb_seal_leaf_init(leaf, 8, 7, 3);
    check("a freshly written leaf validates",
          cyboudb_seal_leaf_validate(leaf) == SEAL_OK);
    check("and says which pages it covers",
          rd64(leaf, SLEAF_INDEX) == 8 &&
          rd64(leaf, SLEAF_FIRST_PAGE) == 8 * ENTRIES_PER_LEAF &&
          rd64(leaf, SLEAF_GENERATION) == 7 &&
          rd64(leaf, SLEAF_SEAL_EPOCH) == 3);
    check("the first and last page of its range have entries",
          cyboudb_seal_entry(leaf, 8 * ENTRIES_PER_LEAF) ==
              leaf + SLEAF_ENTRIES &&
          cyboudb_seal_entry(leaf, 9 * ENTRIES_PER_LEAF - 1) ==
              leaf + SLEAF_ENTRIES + (ENTRIES_PER_LEAF - 1) * SENTRY_SIZE);
    check("and a page on either side has none - the caller reached for the "
          "wrong leaf",
          cyboudb_seal_entry(leaf, 8 * ENTRIES_PER_LEAF - 1) == NULL &&
          cyboudb_seal_entry(leaf, 9 * ENTRIES_PER_LEAF) == NULL);

    /* --- what the MAC covers ------------------------------------------------ */
    {
        uint8_t *entry = cyboudb_seal_entry(leaf,
                                            8 * ENTRIES_PER_LEAF + 17);
        for (i = 0; i < SENTRY_SIZE; i++) entry[i] = (uint8_t)(i + 1);
        repair_crc(leaf);
        cyboudb_seal_leaf_mac(mac, key, leaf);

        cyboudb_seal_leaf_mac(mac2, key, leaf);
        check("the same leaf and key give the same MAC twice",
              memcmp(mac, mac2, MAC_SIZE) == 0);
        cyboudb_seal_leaf_mac(mac2, other_key, leaf);
        check("and another key gives another MAC",
              memcmp(mac, mac2, MAC_SIZE) != 0);

        entry[3] ^= 0x01;
        repair_crc(leaf);
        cyboudb_seal_leaf_mac(mac2, key, leaf);
        check("one bit of one nonce changes the leaf's MAC",
              memcmp(mac, mac2, MAC_SIZE) != 0);
        entry[3] ^= 0x01;
        repair_crc(leaf);

        /* The identity fields are inside the MAC, which is what stops a leaf
           from being presented as a different leaf, generation or epoch. */
        wr64(leaf, SLEAF_INDEX, 9);
        wr64(leaf, SLEAF_FIRST_PAGE, 9 * ENTRIES_PER_LEAF);
        repair_crc(leaf);
        cyboudb_seal_leaf_mac(mac2, key, leaf);
        check("and so does the leaf's own index", memcmp(mac, mac2, MAC_SIZE) != 0);
        wr64(leaf, SLEAF_INDEX, 8);
        wr64(leaf, SLEAF_FIRST_PAGE, 8 * ENTRIES_PER_LEAF);

        wr64(leaf, SLEAF_GENERATION, 8);
        repair_crc(leaf);
        cyboudb_seal_leaf_mac(mac2, key, leaf);
        check("and the generation that published it",
              memcmp(mac, mac2, MAC_SIZE) != 0);
        wr64(leaf, SLEAF_GENERATION, 7);

        wr64(leaf, SLEAF_SEAL_EPOCH, 4);
        repair_crc(leaf);
        cyboudb_seal_leaf_mac(mac2, key, leaf);
        check("and the epoch its entries were made under",
              memcmp(mac, mac2, MAC_SIZE) != 0);
        wr64(leaf, SLEAF_SEAL_EPOCH, 3);
        repair_crc(leaf);

        cyboudb_seal_leaf_mac(mac2, key, leaf);
        check("putting every field back gives the MAC back",
              memcmp(mac, mac2, MAC_SIZE) == 0);

        /* A leaf read as a node must not produce the same MAC: the label is
           what separates them, and without it a page of one kind could be
           presented as a page of the other. */
        cyboudb_seal_node_mac(mac2, key, leaf);
        check("the same bytes MAC'd as a node are a different MAC",
              memcmp(mac, mac2, MAC_SIZE) != 0);

        /* And the label is what makes that true, rather than the two covered
           ranges happening to differ in length. Recomputing both MACs here,
           from the construction as it is written down, is what pins the label
           in place: swap the two label strings in the assembly and these two
           checks fail, where every other check in this file still passes. */
        expected_mac(mac2, key, "CybouDB/0.7/seal-leaf", leaf, 8, 4064);
        check("a leaf's MAC is the key, the leaf label, and bytes 8 to 4064",
              memcmp(mac, mac2, MAC_SIZE) == 0);
        {
            uint8_t node_side[MAC_SIZE];
            cyboudb_seal_node_init(node, 1, 1, 7, 3);
            cyboudb_seal_node_mac(node_side, key, node);
            expected_mac(mac2, key, "CybouDB/0.7/seal-node", node, 8, 4080);
            check("and a node's is the node label, and bytes 8 to 4080",
                  memcmp(node_side, mac2, MAC_SIZE) == 0);
        }

        check("a leaf verifies against its own MAC",
              cyboudb_seal_leaf_verify(key, leaf, mac) == SEAL_OK);
        check("and not against another key's",
              cyboudb_seal_leaf_verify(other_key, leaf, mac) == SEAL_E_MAC);
    }

    /* --- THE SCENARIO: an old page and its old entry, both genuine ----------
       Generation 7 published one entry. Generation 8 rewrote that page and
       with it the entry. An adversary restores the old page - which the AEAD
       will accept, since it was validly sealed - and the old entry with it, so
       the nonce and tag match the ciphertext perfectly. Nothing about the pair
       is forged. It is simply not what the current superblock published, and
       that is what the parent is for. */
    {
        uint8_t old_entry[SENTRY_SIZE];
        uint8_t *entry;

        cyboudb_seal_leaf_init(leaf, 8, 7, 3);
        entry = cyboudb_seal_entry(leaf, 8 * ENTRIES_PER_LEAF + 17);
        for (i = 0; i < SENTRY_SIZE; i++) entry[i] = (uint8_t)(0xA0 + i);
        memcpy(old_entry, entry, SENTRY_SIZE);
        repair_crc(leaf);

        /* generation 8 rewrites the page, and the node publishes the leaf */
        wr64(leaf, SLEAF_GENERATION, 8);
        for (i = 0; i < SENTRY_SIZE; i++) entry[i] = (uint8_t)(0x50 + i);
        repair_crc(leaf);
        cyboudb_seal_leaf_mac(published, key, leaf);

        cyboudb_seal_node_init(node, 0, 1, 8, 3);
        check("the node accepts the leaf's MAC",
              cyboudb_seal_node_set_child(node, 8, published) == 0 &&
              cyboudb_seal_node_validate(node) == SEAL_OK);
        check("and counts it", rd64(node, SNODE_CHILD_COUNT) == 9);

        /* the restoration */
        memcpy(entry, old_entry, SENTRY_SIZE);
        repair_crc(leaf);
        check("the restored entry is a perfectly well formed leaf",
              cyboudb_seal_leaf_validate(leaf) == SEAL_OK);
        check("and yet it is not the leaf the parent published",
              cyboudb_seal_leaf_verify(key, leaf,
                                       node + SNODE_CHILDREN + 8 * MAC_SIZE)
                  == SEAL_E_MAC);

        /* Restoring the whole old leaf, generation field and all, does not
           help either: the entry array is then last week's, and so is the MAC
           it produces. */
        wr64(leaf, SLEAF_GENERATION, 7);
        repair_crc(leaf);
        check("nor does restoring the whole leaf as it stood last generation",
              cyboudb_seal_leaf_verify(key, leaf,
                                       node + SNODE_CHILDREN + 8 * MAC_SIZE)
                  == SEAL_E_MAC);

        /* And putting the published bytes back is accepted again, so the
           refusals above are about the content and not about the test having
           broken something permanently. */
        wr64(leaf, SLEAF_GENERATION, 8);
        for (i = 0; i < SENTRY_SIZE; i++) entry[i] = (uint8_t)(0x50 + i);
        repair_crc(leaf);
        check("while the leaf the parent did publish still verifies",
              cyboudb_seal_leaf_verify(key, leaf,
                                       node + SNODE_CHILDREN + 8 * MAC_SIZE)
                  == SEAL_OK);
    }

    /* --- a node, and the level above it -------------------------------------- */
    {
        uint8_t root[PAGE_SIZE], node_mac[MAC_SIZE];

        cyboudb_seal_node_mac(node_mac, key, node);
        cyboudb_seal_node_init(root, 0, 2, 8, 3);
        cyboudb_seal_node_set_child(root, 0, node_mac);
        check("a node verifies against the MAC its parent holds",
              cyboudb_seal_node_verify(key, node, root + SNODE_CHILDREN) ==
                  SEAL_OK);

        /* Changing one child MAC inside the node changes the node's own MAC,
           which is the whole point of the level: a tampered leaf reference
           cannot hide behind an untouched parent. */
        node[SNODE_CHILDREN + 8 * MAC_SIZE] ^= 0x01;
        repair_crc(node);
        check("and not once one of its children has been rewritten",
              cyboudb_seal_node_verify(key, node, root + SNODE_CHILDREN) ==
                  SEAL_E_MAC);
        node[SNODE_CHILDREN + 8 * MAC_SIZE] ^= 0x01;
        repair_crc(node);
        check("with the child put back, the node verifies again",
              cyboudb_seal_node_verify(key, node, root + SNODE_CHILDREN) ==
                  SEAL_OK);
    }

    /* --- structural refusals, which are damage and not forgery -------------- */
    cyboudb_seal_leaf_init(leaf, 8, 7, 3);
    memcpy(scratch, leaf, PAGE_SIZE);

    wr32(leaf, SLEAF_MAGIC, 0x11223344);
    repair_crc(leaf);
    check("a page that is not a seal leaf says so",
          cyboudb_seal_leaf_validate(leaf) == SEAL_E_MAGIC);

    memcpy(leaf, scratch, PAGE_SIZE);
    wr32(leaf, SLEAF_VERSION, 2);
    repair_crc(leaf);
    check("a seal leaf from a later build is refused by version",
          cyboudb_seal_leaf_validate(leaf) == SEAL_E_VERSION);

    memcpy(leaf, scratch, PAGE_SIZE);
    leaf[2000] ^= 0x01;
    check("a damaged leaf is damage",
          cyboudb_seal_leaf_validate(leaf) == SEAL_E_CRC);

    memcpy(leaf, scratch, PAGE_SIZE);
    wr64(leaf, SLEAF_FIRST_PAGE, 8 * ENTRIES_PER_LEAF + 1);
    repair_crc(leaf);
    check("a leaf whose first page does not follow from its index is refused",
          cyboudb_seal_leaf_validate(leaf) == SEAL_E_FIELDS);

    memcpy(leaf, scratch, PAGE_SIZE);
    leaf[SLEAF_RESERVED + 17] = 0x01;
    repair_crc(leaf);
    check("and one with a non-zero reserved field",
          cyboudb_seal_leaf_validate(leaf) == SEAL_E_RESERVED);

    memcpy(leaf, scratch, PAGE_SIZE);
    leaf[SLEAF_RESERVED_TAIL + 27] = 0x01;
    repair_crc(leaf);
    check("and the last reserved byte before the CRC",
          cyboudb_seal_leaf_validate(leaf) == SEAL_E_RESERVED);

    cyboudb_seal_node_init(node, 3, 1, 8, 3);
    memcpy(scratch, node, PAGE_SIZE);
    check("a freshly written node validates",
          cyboudb_seal_node_validate(node) == SEAL_OK);

    wr64(node, SNODE_LEVEL, 0);
    repair_crc(node);
    check("a node at level zero is refused - that level holds leaves",
          cyboudb_seal_node_validate(node) == SEAL_E_FIELDS);

    memcpy(node, scratch, PAGE_SIZE);
    wr64(node, SNODE_CHILD_COUNT, CHILDREN_PER_NODE + 1);
    repair_crc(node);
    check("and a child count past the end of the slots",
          cyboudb_seal_node_validate(node) == SEAL_E_FIELDS);

    memcpy(node, scratch, PAGE_SIZE);
    for (i = 0; i < MAC_SIZE; i++) mac[i] = (uint8_t)(i + 9);
    cyboudb_seal_node_set_child(node, 0, mac);
    cyboudb_seal_node_set_child(node, 1, mac);
    wr64(node, SNODE_CHILD_COUNT, 1);
    repair_crc(node);
    check("a child left past the count is refused, not quietly ignored",
          cyboudb_seal_node_validate(node) == SEAL_E_FIELDS);

    memcpy(node, scratch, PAGE_SIZE);
    check("a slot past the last one is refused rather than written",
          cyboudb_seal_node_set_child(node, CHILDREN_PER_NODE, mac) ==
              SEAL_E_FIELDS &&
          cyboudb_seal_node_validate(node) == SEAL_OK);

    memcpy(node, scratch, PAGE_SIZE);
    node[SNODE_RESERVED + 3] = 0x01;
    repair_crc(node);
    check("and a node with a non-zero reserved field",
          cyboudb_seal_node_validate(node) == SEAL_E_RESERVED);

    printf("\nseal directory suite: %d checks, %d failed\n", checks, failures);
    return failures ? 1 : 0;
}
