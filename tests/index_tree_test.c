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
#define IDX_ENTRIES 64
#define IDX_MAX_ENTRIES 251u

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

/* Every leaf, left to right: the entries a scan of the whole index sees.
   There is no sibling chain to follow - a leaf keeps no pointer to the next
   one, because copy-on-write would leave that pointer naming a retired page -
   so this descends, which is what a range scan does too. */
static int visit(void *ctx, uint64_t page, entry_t *out, uint64_t max,
                 uint64_t *seen, int depth, int *out_height) {
    unsigned char *node = db_index_node_addr(ctx, page);
    uint32_t count = u32(node, IDX_COUNT);

    if (u32(node, 0) != IDX_MAGIC_VALUE) return 0;
    if (u32(node, IDX_LEVEL) == 0) {
        if (depth > *out_height) *out_height = depth;
        for (uint32_t i = 0; i < count; i++) {
            if (*seen >= max) return 0;
            out[*seen].key = (int64_t)u64(node, IDX_ENTRIES + i * 16);
            out[*seen].row = u64(node, IDX_ENTRIES + i * 16 + 8);
            (*seen)++;
        }
        return 1;
    }
    for (uint32_t i = 0; i < count; i++) {
        uint64_t child = u64(node, IDX_ENTRIES + i * 16 + 8);
        if (!visit(ctx, child, out, max, seen, depth + 1, out_height)) return 0;
        node = db_index_node_addr(ctx, page);   /* recursion does not move it */
    }
    return 1;
}

static int walk_leaves(void *ctx, uint64_t root, entry_t *out, uint64_t max,
                       uint64_t *out_count, int *out_height) {
    uint64_t seen = 0;
    int height = 0;
    if (!visit(ctx, root, out, max, &seen, 1, &height)) return 0;
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
    if (slot >= u32(node, IDX_COUNT)) return 0;  /* past everything it holds */
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

/* --- incremental insert ----------------------------------------------- */

extern int db_index_insert(void *ctx, uint64_t owner, uint64_t root,
                           int64_t key, uint64_t row, uint64_t *out_root);
extern int db_index_insert_unique(void *ctx, uint64_t owner, uint64_t root,
                                  int64_t key, uint64_t row, uint64_t *out_root);

#define CYBOUDB_E_VALUE 32              /* include/constants.inc */

/* Every structural claim a node makes, checked against what is under it:
   the level its parent says, a count within bounds, entries in order, and an
   internal entry whose key_end is the largest key beneath that child. Returns
   the leaf entries found, or -1. */
static int64_t audit(void *ctx, uint64_t page, int level, int64_t *low,
                     int64_t *high) {
    unsigned char *node = db_index_node_addr(ctx, page);
    uint32_t count = u32(node, IDX_COUNT);
    int64_t total = 0;

    if (u32(node, 0) != IDX_MAGIC_VALUE) return -1;
    if ((int)u32(node, IDX_LEVEL) != level) return -1;
    if (count == 0 || count > IDX_MAX_ENTRIES) return -1;

    if (level == 0) {
        for (uint32_t i = 0; i < count; i++) {
            int64_t key = (int64_t)u64(node, IDX_ENTRIES + i * 16);
            if (i == 0) *low = key;
            else if (key < *high) return -1;
            *high = key;
        }
        return count;
    }
    for (uint32_t i = 0; i < count; i++) {
        int64_t end = (int64_t)u64(node, IDX_ENTRIES + i * 16);
        uint64_t child = u64(node, IDX_ENTRIES + i * 16 + 8);
        int64_t sub_low = 0, sub_high = 0;
        int64_t under = audit(ctx, child, level - 1, &sub_low, &sub_high);
        if (under < 0) return -1;
        if (sub_high != end) return -1;             /* key_end is the largest */
        if (i == 0) *low = sub_low;
        else if (sub_low < *high) return -1;        /* children do not overlap */
        *high = sub_high;
        total += under;
        node = db_index_node_addr(ctx, page);
    }
    return total;
}

static int tree_ok(void *ctx, uint64_t root, uint64_t expect) {
    unsigned char *node = db_index_node_addr(ctx, root);
    int64_t low = 0, high = 0;
    int64_t total = audit(ctx, root, (int)u32(node, IDX_LEVEL), &low, &high);
    return total >= 0 && (uint64_t)total == expect;
}

/* Insert `count` keys in the order `step` walks them, then require that every
   one of them is found at the row it was given. */
static void insert_case(void *ctx, const char *what, uint64_t count,
                        uint64_t step, int expect_level) {
    uint64_t root = 0, next = 0;
    int ok = 1;
    char label[128];

    for (uint64_t i = 0; i < count; i++) {
        uint64_t k = (i * step) % count;
        int64_t key = (int64_t)(k * 2) - (int64_t)count;   /* keys straddle zero */
        int rc = db_index_insert(ctx, 11, root, key, k, &next);
        if (rc != 0 || next == 0) { ok = 0; break; }
        root = next;
    }
    snprintf(label, sizeof label, "%s: %llu inserts", what,
             (unsigned long long)count);
    check(label, ok);

    snprintf(label, sizeof label, "%s: the tree holds together", what);
    check(label, tree_ok(ctx, root, count));

    if (expect_level >= 0) {
        snprintf(label, sizeof label, "%s: the root sits at level %d", what,
                 expect_level);
        check(label, (int)u32(db_index_node_addr(ctx, root), IDX_LEVEL) ==
              expect_level);
    }

    ok = 1;
    for (uint64_t i = 0; i < count && ok; i++) {
        int64_t key = (int64_t)(i * 2) - (int64_t)count, found = 0;
        uint64_t row = ~0ull;
        if (!key_at(ctx, root, key, &found, &row)) ok = 0;
        else if (found != key || row != i) ok = 0;
    }
    snprintf(label, sizeof label, "%s: every key found at its row", what);
    check(label, ok);

    ok = 1;
    for (uint64_t i = 0; i + 1 < count && ok; i++) {
        int64_t key = (int64_t)(i * 2) - (int64_t)count, found = 0;
        if (!key_at(ctx, root, key + 1, &found, NULL)) ok = 0;
        else if (found != key + 2) ok = 0;
    }
    snprintf(label, sizeof label, "%s: a missing key positions on the next", what);
    check(label, ok);

    /* An insert copies the path it descends, and nothing reclaims those copies
       while the transaction is open. Each case starts from a clean file. */
    db_rollback(ctx);
}

static void insert_suite(void *ctx) {
    uint64_t root = 0, next = 0;

    check("inserting into an empty index makes a root",
          db_index_insert(ctx, 11, 0, 42, 7, &root) == 0 && root != 0);
    {
        int64_t found = 0;
        uint64_t row = 0;
        check("and the entry is in it",
              key_at(ctx, root, 42, &found, &row) && found == 42 && row == 7);
    }

    /* Ascending is the shape an INSERT into a table produces, since a row's
       position only ever grows; the others are what an index over an
       unclustered column sees. */
    insert_case(ctx, "ascending", 3000, 1, 1);
    insert_case(ctx, "descending", 3000, 2999, 1);
    insert_case(ctx, "scattered", 3000, 1009, 1);
    insert_case(ctx, "one full leaf plus one", IDX_MAX_ENTRIES + 1, 1, 1);
    /* Inserting into a tree that is already three levels deep. Building it
       costs one page per 251 entries where inserting costs the height per
       entry, so this reaches the depth without paying for it. */
    {
        entry_t *entries = malloc(sizeof(entry_t) * 63002);
        uint64_t built = 0;
        int ok = 1;
        for (uint64_t i = 0; i < 63002; i++) {
            entries[i].key = (int64_t)(i * 4) - 63002;
            entries[i].row = i;
        }
        check("a three-level tree to insert into",
              db_index_build(ctx, 11, entries, 63002, &built) == 0 &&
              (int)u32(db_index_node_addr(ctx, built), IDX_LEVEL) == 2);
        for (uint64_t i = 0; i < 300 && ok; i++) {
            if (db_index_insert(ctx, 11, built, (int64_t)(i * 4) - 63000,
                                63002 + i, &next) != 0) ok = 0;
            built = next;
        }
        check("300 inserts into it", ok);
        check("it still holds together", tree_ok(ctx, built, 63302));
        check("its root did not move level",
              (int)u32(db_index_node_addr(ctx, built), IDX_LEVEL) == 2);
        ok = 1;
        for (uint64_t i = 0; i < 300 && ok; i++) {
            int64_t key = (int64_t)(i * 4) - 63000, found = 0;
            uint64_t row = 0;
            if (!key_at(ctx, built, key, &found, &row)) ok = 0;
            else if (found != key || row != 63002 + i) ok = 0;
        }
        check("and every inserted key is found in it", ok);
        free(entries);
        db_rollback(ctx);
    }

    /* Duplicates: allowed, ordered by the row they name, and refused by a
       unique index without leaving the tree changed. */
    root = 0;
    for (int i = 0; i < 5; i++) {
        check("duplicate key accepted",
              db_index_insert(ctx, 11, root, 5, (uint64_t)i, &next) == 0);
        root = next;
    }
    check("five entries under one key", tree_ok(ctx, root, 5));

    check("unique index takes the first",
          db_index_insert_unique(ctx, 11, 0, 5, 0, &root) == 0 && root != 0);
    next = 0;
    check("unique index refuses the second",
          db_index_insert_unique(ctx, 11, root, 5, 1, &next) == CYBOUDB_E_VALUE);

    /* A refusal happens after the path has been copied, and a copy retires
       the page it came from, so the caller discards the transaction rather
       than reusing the tree it handed in - the same contract a refused commit
       has. Build it again and the different key goes in. */
    db_rollback(ctx);
    check("after a rollback the index takes the first again",
          db_index_insert_unique(ctx, 11, 0, 5, 0, &root) == 0 && root != 0);
    check("and a different key is accepted",
          db_index_insert_unique(ctx, 11, root, 6, 1, &next) == 0);
    check("leaving both in the tree", tree_ok(ctx, next, 2));
    db_rollback(ctx);
}

/* --- delete ------------------------------------------------------------ */

extern int db_index_delete(void *ctx, uint64_t owner, uint64_t root,
                           int64_t key, uint64_t row, uint64_t *out_root);

#define CYBOUDB_E_NOTFOUND 28           /* include/constants.inc */

/* Build a tree of `count` entries, then remove them in the order `step` walks
   them, auditing the structure as it shrinks. */
static void delete_case(void *ctx, const char *what, uint64_t count,
                        uint64_t step) {
    entry_t *entries = malloc(sizeof(entry_t) * (size_t)count);
    uint64_t root = 0, next = 0;
    int ok = 1;
    char label[128];

    for (uint64_t i = 0; i < count; i++) {
        entries[i].key = (int64_t)(i * 2) - (int64_t)count;
        entries[i].row = i;
    }
    if (db_index_build(ctx, 11, entries, count, &root) != 0) ok = 0;

    for (uint64_t n = 0; n < count && ok; n++) {
        uint64_t i = (n * step) % count;
        if (db_index_delete(ctx, 11, root, entries[i].key, entries[i].row,
                            &next) != 0) { ok = 0; break; }
        root = next;
        /* Auditing every step is what makes a wrong key_end after a removal
           visible at the removal rather than thousands of entries later. */
        if (n % 97 == 0 && root && !tree_ok(ctx, root, count - n - 1)) ok = 0;
    }
    snprintf(label, sizeof label, "%s: %llu deletes", what,
             (unsigned long long)count);
    check(label, ok);

    snprintf(label, sizeof label, "%s: the last one empties the tree", what);
    check(label, root == 0);

    free(entries);
    db_rollback(ctx);
}

static void delete_suite(void *ctx) {
    entry_t *entries = malloc(sizeof(entry_t) * 4000);
    uint64_t root = 0, next = 0;
    int ok = 1;

    for (uint64_t i = 0; i < 4000; i++) {
        entries[i].key = (int64_t)(i * 2) - 4000;
        entries[i].row = i;
    }
    check("a tree to delete from",
          db_index_build(ctx, 11, entries, 4000, &root) == 0 && root != 0);

    /* A key the tree never held, and a key it holds under another row. */
    check("deleting a key that is not there",
          db_index_delete(ctx, 11, root, 1, 0, &next) == CYBOUDB_E_NOTFOUND);
    check("deleting the right key at the wrong row",
          db_index_delete(ctx, 11, root, entries[10].key, 999, &next)
          == CYBOUDB_E_NOTFOUND);
    check("a refused delete stages nothing", tree_ok(ctx, root, 4000));

    check("one entry removed",
          db_index_delete(ctx, 11, root, entries[10].key, 10, &next) == 0);
    root = next;
    check("and the tree holds one fewer", tree_ok(ctx, root, 3999));
    {
        int64_t found = 0;
        check("the key it named is gone",
              key_at(ctx, root, entries[10].key, &found, NULL) &&
              found == entries[11].key);
    }
    ok = 1;
    for (uint64_t i = 0; i < 4000 && ok; i++) {
        int64_t found = 0;
        uint64_t row = 0;
        if (i == 10) continue;
        if (!key_at(ctx, root, entries[i].key, &found, &row)) ok = 0;
        else if (found != entries[i].key || row != i) ok = 0;
    }
    check("every other key is where it was", ok);
    db_rollback(ctx);

    /* Emptying a tree, in the three orders that stress different sides of it:
       from the front, which empties leaves left to right; from the back, which
       keeps trimming the last one; and scattered. */
    delete_case(ctx, "front to back", 3000, 1);
    delete_case(ctx, "back to front", 3000, 2999);
    delete_case(ctx, "scattered", 3000, 1009);

    /* A root that has to lose a level. A bulk build of 63002 entries leaves
       252 leaves, so the level above holds 251 of them in its first node and
       one in its second, and the root names just those two. Removing the one
       entry under the second collapses the root into the first - one delete
       rather than sixty thousand. */
    {
        entry_t *deep = malloc(sizeof(entry_t) * 63002);
        uint64_t deep_root = 0;
        for (uint64_t i = 0; i < 63002; i++) {
            deep[i].key = (int64_t)i - 31501;
            deep[i].row = i;
        }
        check("a three-level tree to shrink",
              db_index_build(ctx, 11, deep, 63002, &deep_root) == 0 &&
              (int)u32(db_index_node_addr(ctx, deep_root), IDX_LEVEL) == 2);
        check("its last entry removed",
              db_index_delete(ctx, 11, deep_root, deep[63001].key,
                              deep[63001].row, &next) == 0);
        deep_root = next;
        check("the root came down a level",
              (int)u32(db_index_node_addr(ctx, deep_root), IDX_LEVEL) == 1);
        check("and what is left is still a tree",
              tree_ok(ctx, deep_root, 63001));
        ok = 1;
        for (uint64_t i = 0; i < 63001 && ok; i += 137) {
            int64_t found = 0;
            uint64_t row = 0;
            if (!key_at(ctx, deep_root, deep[i].key, &found, &row)) ok = 0;
            else if (found != deep[i].key || row != deep[i].row) ok = 0;
        }
        check("every surviving key is still found", ok);
        check("and the one that went is not",
              !key_at(ctx, deep_root, deep[63001].key, NULL, NULL));
        free(deep);
        db_rollback(ctx);
    }

    /* Insert and delete against each other: the tree has to stay correct
       while it is both growing and shrinking. */
    root = 0;
    ok = 1;
    for (uint64_t i = 0; i < 2000 && ok; i++) {
        if (db_index_insert(ctx, 11, root, (int64_t)i, i, &next) != 0) ok = 0;
        root = next;
        if (i >= 3) {
            if (db_index_delete(ctx, 11, root, (int64_t)(i - 3), i - 3,
                                &next) != 0) ok = 0;
            root = next;
        }
    }
    check("inserting and deleting at once", ok);
    check("leaves exactly what is outstanding", tree_ok(ctx, root, 3));
    db_rollback(ctx);

    free(entries);
}

/* --- the index as a catalog entry -------------------------------------- */

extern int db_catalog_put_index(void *ctx, uint64_t index_id, void *page);
extern int db_catalog_set_index_root(void *ctx, uint64_t index_id,
                                     uint64_t root, uint64_t rows);
extern int db_catalog_get(void *ctx, uint64_t id, uint64_t *out_page);
extern int db_catalog_drop(void *ctx, uint64_t id);
extern unsigned long long index_lookups;
extern int db_commit(void *ctx);
extern int db_index_retire_tree(void *ctx, uint64_t root);
extern void *catalog_find_index(void *ctx, const char *name, uint64_t len,
                                uint64_t *out_id);
extern void *catalog_find_table(void *ctx, const char *name, uint64_t len,
                                uint64_t *out_id);

#define CAT_TYPE_OFF   32
#define CAT_INDEX_TYPE 3
#define IDX_ROOT_OFF   40
#define IDX_COLUMN_OFF 48
#define IDX_FLAGS_OFF  52
#define IDX_ROWS_OFF   56
#define IDX_NAME_OFF   64
#define IDX_TABLE_OFF  96

/* The page image a caller hands to db_catalog_put_index: what the index is,
   with the header left to the catalog to stamp. */
static void index_image(unsigned char *page, const char *name, uint32_t column,
                        uint32_t flags, uint64_t table) {
    memset(page, 0, 4096);
    memcpy(page + IDX_COLUMN_OFF, &column, sizeof column);
    memcpy(page + IDX_FLAGS_OFF, &flags, sizeof flags);
    memcpy(page + IDX_TABLE_OFF, &table, sizeof table);
    strncpy((char *)page + IDX_NAME_OFF, name, 31);
}

static void catalog_suite(void *ctx, const char *path) {
    static unsigned char image[4096];
    cyboudb_db *db = NULL;
    entry_t *entries = malloc(sizeof(entry_t) * 4000);
    uint64_t root = 0, page = 0;
    unsigned char *mapped;

    for (uint64_t i = 0; i < 4000; i++) {
        entries[i].key = (int64_t)(i * 3) - 4000;
        entries[i].row = i;
    }


    /* A real table, because open proves that the table an index names exists,
       is a table, has that column and that the column is a type this version
       orders - a made-up id is exactly what that check is there to refuse. */
    {
        uint64_t table_id = 0;
        check("a table to index",
              cyboudb_exec((cyboudb_db *)ctx,
                           "CREATE TABLE idx_host (a INT64, b INT64)")
              == CybouDB_OK);
        check("found", catalog_find_table(ctx, "idx_host", 8, &table_id) != 0);
        index_image(image, "idx_on_a", 1, 0, table_id);
    }
    check("an index goes into the catalog",
          db_catalog_put_index(ctx, 900001, image) == 0);
    check("and is found there",
          db_catalog_get(ctx, 900001, &page) == 0 && page != 0);
    mapped = db_index_node_addr(ctx, page);
    check("as an index page", u32(mapped, CAT_TYPE_OFF) == CAT_INDEX_TYPE);
    check("naming its table", u64(mapped, IDX_TABLE_OFF) != 0);
    check("and its column", u32(mapped, IDX_COLUMN_OFF) == 1);

    check("an empty index commits", db_commit(ctx) == CybouDB_OK);

    check("a tree for it", db_index_build(ctx, 900001, entries, 4000, &root) == 0);
    check("published as its root",
          db_catalog_set_index_root(ctx, 900001, root, 4000) == 0);
    check("and that commits too", db_commit(ctx) == CybouDB_OK);

    check("close", cyboudb_close((cyboudb_db *)ctx) == CybouDB_OK);
    check("it opens again", cyboudb_open(path, CybouDB_OPEN_READWRITE, &db)
          == CybouDB_OK);
    if (!db) { free(entries); return; }
    ctx = db;

    check("the index is still there",
          db_catalog_get(ctx, 900001, &page) == 0 && page != 0);
    mapped = db_index_node_addr(ctx, page);
    check("with the tree it was given",
          u64(mapped, IDX_ROOT_OFF) != 0 && u64(mapped, IDX_ROWS_OFF) == 4000);
    check("and the column it was created with",
          u32(mapped, IDX_COLUMN_OFF) == 1 && u64(mapped, IDX_TABLE_OFF) != 0);
    {
        uint64_t stored = u64(mapped, IDX_ROOT_OFF);
        int ok = 1;
        for (uint64_t i = 0; i < 4000 && ok; i += 37) {
            int64_t found = 0;
            uint64_t row = 0;
            if (!key_at(ctx, stored, entries[i].key, &found, &row)) ok = 0;
            else if (found != entries[i].key || row != i) ok = 0;
        }
        check("and every key it was built from", ok);
        check("which is the tree the page counts", tree_ok(ctx, stored, 4000));
    }

    /* A count that disagrees with the leaves is exactly what validation is
       for, and the commit is where it has to be caught. */
    {
        uint64_t bogus = 0;
        check("rebuilt for the miscount",
              db_index_build(ctx, 900001, entries, 4000, &bogus) == 0);
        check("published with a count it does not have",
              db_catalog_set_index_root(ctx, 900001, bogus, 3999) == 0);
        check("and the commit refuses it", db_commit(ctx) != CybouDB_OK);
        db_rollback(ctx);
    }

    /* The ABI runs statements through its own dispatch, and a second copy of
       what a statement does is a second place to forget part of it. This one
       had forgotten the indexes: rows went into the table and none of them
       into the tree over it. */
    {
        uint64_t tbl = 0, page2 = 0;
        unsigned char *ip;
        check("a table with an index on it",
              cyboudb_exec((cyboudb_db *)ctx,
                           "CREATE TABLE api_t (a INT64, b INT64)") == CybouDB_OK);
        check("indexed",
              cyboudb_exec((cyboudb_db *)ctx,
                           "CREATE INDEX api_idx ON api_t (b)") == CybouDB_OK);
        check("a row through the ABI",
              cyboudb_exec((cyboudb_db *)ctx,
                           "INSERT INTO api_t VALUES (1, 11)") == CybouDB_OK);
        check("another", cyboudb_exec((cyboudb_db *)ctx,
                           "INSERT INTO api_t VALUES (2, 22)") == CybouDB_OK);
        check("found the index", catalog_find_index(ctx, "api_idx", 7, &tbl) != 0);
        check("which the index knows about",
              db_catalog_get(ctx, tbl, &page2) == 0);
        ip = db_index_node_addr(ctx, page2);
        check("both of them", u64(ip, IDX_ROWS_OFF) == 2);

        check("dropping the table through the ABI",
              cyboudb_exec((cyboudb_db *)ctx, "DROP TABLE api_t") == CybouDB_OK);
        check("takes the index with it",
              catalog_find_index(ctx, "api_idx", 7, &tbl) == 0);
    }

    /* A real DROP INDEX gives the tree back before dropping the entry; doing
       it by hand means doing that by hand too. */
    {
        uint64_t page3 = 0;
        db_catalog_get(ctx, 900001, &page3);
        db_index_retire_tree(ctx, u64(db_index_node_addr(ctx, page3), IDX_ROOT_OFF));
    }
    check("dropping the index", db_catalog_drop(ctx, 900001) == 0);
    check("commits", db_commit(ctx) == CybouDB_OK);
    check("and it is gone", db_catalog_get(ctx, 900001, &page) != 0);

    free(entries);
    cyboudb_close((cyboudb_db *)ctx);
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

    insert_suite(ctx);
    delete_suite(ctx);

    check("rollback", db_rollback(ctx) == CybouDB_OK);

    /* Everything above works on staged pages that are rolled back. This last
       part publishes, which is where the catalog and the tree meet. */
    catalog_suite(ctx, argv[1]);

    printf("index tree suite: %d passed, %d failed\n", checks - failures, failures);
    return failures ? 1 : 0;
}
