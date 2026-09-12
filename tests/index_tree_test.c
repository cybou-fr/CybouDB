/* tests/index_tree_test.c - the B+tree a secondary index is made of.
 *
 * Nothing in SQL reaches this code yet: no creator emits
 * CybouDB_FEATURE_INDEX, so no file can carry a tree. What the storage layer
 * can already do is build one and descend it, and that is what this pins,
 * through the internal entry points rather than through a statement.
 *
 * The tree is built into staged copy-on-write pages and rolled back at the
 * end, so the database it runs against is unchanged by it - which is also the
 * cheapest proof that a tree costs nothing until something publishes its root.
 *
 * Usage: index_tree_test <database created with create-large>
 *
 * SPDX-License-Identifier: Apache-2.0
 * Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
 */
#include "cyboudb.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

void *cyboudb_test_mem_alloc(size_t size) { return malloc(size); }
void cyboudb_test_mem_free(void *ptr, size_t size) { (void)size; free(ptr); }

extern int db_rollback(void *ctx);
extern int db_index_build(void *ctx, uint64_t owner, const void *entries,
                          uint64_t count, uint64_t *out_root);
extern int db_index_search(void *ctx, uint64_t root, int64_t key,
                           uint64_t *out_leaf, uint64_t *out_slot);
extern void *db_index_node_addr(void *ctx, uint64_t page);

/* include/index.inc */
#define IDX_MAGIC_VALUE 0x49515341u
#define IDX_LEVEL   32
#define IDX_COUNT   36
#define IDX_NEXT    40
#define IDX_ENTRIES 64
#define IDX_MAX_ENTRIES 251

typedef struct { int64_t key; uint64_t row; } entry_t;

static int failures = 0;
static int checks = 0;

static void check(const char *what, int ok) {
    checks++;
    if (ok) {
        printf("ok   %s\n", what);
    } else {
        failures++;
        printf("FAIL %s\n", what);
    }
}

static uint32_t u32(const void *page, uint64_t off) {
    uint32_t v;
    memcpy(&v, (const unsigned char *)page + off, sizeof v);
    return v;
}

static uint64_t u64(const void *page, uint64_t off) {
    uint64_t v;
    memcpy(&v, (const unsigned char *)page + off, sizeof v);
    return v;
}

/* Every leaf, in chain order: the entries a scan of the whole index sees. */
static int walk_leaves(void *ctx, uint64_t root, entry_t *out, uint64_t max,
                       uint64_t *out_count, int *out_height) {
    unsigned char *node = db_index_node_addr(ctx, root);
    uint64_t page = root, seen = 0;
    int height = 1;

    while (u32(node, IDX_LEVEL) != 0) {
        page = u64(node, IDX_ENTRIES);      /* leftmost child */
        node = db_index_node_addr(ctx, page);
        height++;
    }
    for (;;) {
        uint32_t count = u32(node, IDX_COUNT);
        if (u32(node, 0) != IDX_MAGIC_VALUE) return 0;
        for (uint32_t i = 0; i < count; i++) {
            if (seen >= max) return 0;
            out[seen].key = (int64_t)u64(node, IDX_ENTRIES + i * 16);
            out[seen].row = u64(node, IDX_ENTRIES + i * 16 + 8);
            seen++;
        }
        page = u64(node, IDX_NEXT);
        if (!page) break;
        node = db_index_node_addr(ctx, page);
    }
    *out_count = seen;
    *out_height = height;
    return 1;
}

/* Where a key lands: 1 when the descent positioned on an entry, with the key
   and row it found written out. Zero keys are ordinary keys here, so found
   cannot be encoded in the returned key. */
static int key_at(void *ctx, uint64_t root, int64_t key, int64_t *out_key,
                  uint64_t *out_row) {
    uint64_t leaf = 0, slot = 0;
    unsigned char *node;
    if (db_index_search(ctx, root, key, &leaf, &slot) != 0 || !leaf) return 0;
    node = db_index_node_addr(ctx, leaf);
    if (slot >= u32(node, IDX_COUNT)) {         /* past this leaf's last entry */
        uint64_t next = u64(node, IDX_NEXT);
        if (!next) return 0;
        node = db_index_node_addr(ctx, next);
        slot = 0;
        if (u32(node, IDX_COUNT) == 0) return 0;
    }
    if (out_key) *out_key = (int64_t)u64(node, IDX_ENTRIES + slot * 16);
    if (out_row) *out_row = u64(node, IDX_ENTRIES + slot * 16 + 8);
    return 1;
}

static int build_case(void *ctx, uint64_t count, int expect_height) {
    entry_t *entries = malloc(sizeof(entry_t) * (size_t)count);
    entry_t *seen = malloc(sizeof(entry_t) * (size_t)count);
    uint64_t root = 0, produced = 0;
    int height = 0, ok = 1;
    char label[96];

    for (uint64_t i = 0; i < count; i++) {
        /* Keys straddle zero and skip one in three, so a lookup for a missing
           key has somewhere to land and a negative key has to sort. */
        entries[i].key = (int64_t)(i * 3) - (int64_t)count;
        entries[i].row = i;
    }

    snprintf(label, sizeof label, "%llu entries build", (unsigned long long)count);
    check(label, db_index_build(ctx, 7, entries, count, &root) == 0 && root != 0);

    snprintf(label, sizeof label, "%llu entries come back in order",
             (unsigned long long)count);
    if (!walk_leaves(ctx, root, seen, count, &produced, &height) ||
        produced != count) {
        ok = 0;
    } else {
        for (uint64_t i = 0; i < count && ok; i++) {
            if (seen[i].key != entries[i].key || seen[i].row != entries[i].row) ok = 0;
        }
    }
    check(label, ok);

    snprintf(label, sizeof label, "%llu entries reach height %d",
             (unsigned long long)count, expect_height);
    check(label, height == expect_height);

    /* Every key present is found at its own row, and the key between two
       present ones lands on the next one up - which is what a range scan
       starts from. */
    ok = 1;
    for (uint64_t i = 0; i < count && ok; i++) {
        int64_t found = 0;
        uint64_t row = ~0ull;
        if (!key_at(ctx, root, entries[i].key, &found, &row)) ok = 0;
        else if (found != entries[i].key || row != entries[i].row) ok = 0;
    }
    snprintf(label, sizeof label, "%llu entries each found at its row",
             (unsigned long long)count);
    check(label, ok);

    ok = 1;
    for (uint64_t i = 0; i + 1 < count && ok; i++) {
        int64_t found = 0;
        if (!key_at(ctx, root, entries[i].key + 1, &found, NULL)) ok = 0;
        else if (found != entries[i + 1].key) ok = 0;
    }
    snprintf(label, sizeof label, "%llu entries position a missing key",
             (unsigned long long)count);
    check(label, ok);

    snprintf(label, sizeof label, "%llu entries: below the first key is the first",
             (unsigned long long)count);
    {
        int64_t found = 0;
        check(label, key_at(ctx, root, entries[0].key - 1, &found, NULL) &&
              found == entries[0].key);
    }

    snprintf(label, sizeof label, "%llu entries: past the last key is nothing",
             (unsigned long long)count);
    check(label, key_at(ctx, root, entries[count - 1].key + 1, NULL, NULL) == 0);

    free(entries);
    free(seen);
    return 0;
}

int main(int argc, char **argv) {
    cyboudb_db *db = NULL;
    void *ctx;
    uint64_t root = 99;

    if (argc < 2) {
        fprintf(stderr, "usage: index_tree_test <database>\n");
        return 2;
    }
    setvbuf(stdout, NULL, _IONBF, 0);

    if (cyboudb_open(argv[1], CybouDB_OPEN_READWRITE, &db) != CybouDB_OK) {
        fprintf(stderr, "open failed\n");
        return 2;
    }
    ctx = db;                       /* DB_H_CTX sits at offset 0 */

    check("an empty index has no root",
          db_index_build(ctx, 7, NULL, 0, &root) == 0 && root == 0);

    build_case(ctx, 1, 1);                      /* one leaf, which is the root */
    build_case(ctx, IDX_MAX_ENTRIES, 1);        /* exactly one full leaf */
    build_case(ctx, IDX_MAX_ENTRIES + 1, 2);    /* one over: a level appears */
    build_case(ctx, 4000, 2);
    build_case(ctx, IDX_MAX_ENTRIES * IDX_MAX_ENTRIES + 1, 3);

    check("rollback", db_rollback(ctx) == CybouDB_OK);
    check("close", cyboudb_close(db) == CybouDB_OK);

    printf("index tree suite: %d passed, %d failed\n", checks - failures, failures);
    return failures ? 1 : 0;
}
