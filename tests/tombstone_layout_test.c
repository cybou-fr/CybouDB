/* tests/tombstone_layout_test.c - what the tombstone reservation costs a leaf.
 *
 * Capacity and the bitmap that sizes it are each other's input, so the leaf
 * arithmetic solves them together (docs/TOMBSTONES.md). Nothing in the CLI
 * reports capacity, and the pages a table occupies are dominated by the
 * allocation map, so the only honest way to check the fixed point is to ask
 * the engine for it.
 *
 * Usage: tombstone_layout_test <tombstone database> <create-large database>
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

extern uint64_t db_pax_capacity(void *ctx, void *schema);
extern void *catalog_find_table(void *ctx, const char *name, uint64_t len,
                               uint64_t *out_id);

#define DB_FEATURES_OFFSET 104
#define FEATURE_TOMBSTONES 4096

static int failures = 0, checks = 0;

static void check(const char *what, int ok, const char *detail) {
    checks++;
    if (ok) {
        printf("ok   %s\n", what);
    } else {
        failures++;
        printf("FAIL %s%s%s\n", what, detail ? ": " : "", detail ? detail : "");
    }
}

/* Create one table and report the rows a leaf of it holds. */
static uint64_t capacity_of(const char *path, const char *create, const char *table,
                            uint64_t *out_features) {
    cyboudb_db *db = NULL;
    unsigned char *ctx;
    uint64_t id = 0, capacity;
    void *schema;

    if (cyboudb_open(path, CybouDB_OPEN_READWRITE, &db) != CybouDB_OK) return 0;
    ctx = (unsigned char *)db;
    if (out_features) memcpy(out_features, ctx + DB_FEATURES_OFFSET, sizeof *out_features);
    if (cyboudb_exec(db, create) != CybouDB_OK) { cyboudb_close(db); return 0; }
    schema = catalog_find_table(ctx, table, strlen(table), &id);
    capacity = schema ? db_pax_capacity(ctx, schema) : 0;
    cyboudb_close(db);
    return capacity;
}

int main(int argc, char **argv) {
    uint64_t tomb_feat = 0, plain_feat = 0;
    uint64_t narrow_tomb, narrow_plain, wide_tomb, wide_plain;
    char detail[160];

    if (argc < 3) {
        fprintf(stderr, "usage: tombstone_layout_test <tombstone db> <plain db>\n");
        return 2;
    }
    setvbuf(stdout, NULL, _IONBF, 0);

    /* A single BOOL column packs a leaf tightly enough that the bitmap has to
       displace rows. */
    narrow_tomb = capacity_of(argv[1], "CREATE TABLE narrow (x BOOL)", "narrow", &tomb_feat);
    narrow_plain = capacity_of(argv[2], "CREATE TABLE narrow (x BOOL)", "narrow", &plain_feat);

    check("tombstone database carries the bit", (tomb_feat & FEATURE_TOMBSTONES) != 0, NULL);
    check("plain database does not", (plain_feat & FEATURE_TOMBSTONES) == 0, NULL);
    check("both report a capacity", narrow_tomb > 0 && narrow_plain > 0, NULL);

    sprintf(detail, "%llu with the reservation, %llu without",
            (unsigned long long)narrow_tomb, (unsigned long long)narrow_plain);
    check("a tight leaf holds fewer rows", narrow_tomb < narrow_plain, detail);

    /* A leaf still holds whole 64-row groups, and the fixed point is a fixed
       point: asking twice has to give the same answer, or a leaf written now
       would not be readable by the same arithmetic later. */
    check("capacity stays whole groups", narrow_tomb % 64 == 0, detail);
    check("the fixed point is stable",
          capacity_of(argv[1], "CREATE TABLE narrow2 (x BOOL)", "narrow2", NULL)
              == narrow_tomb, detail);

    /* The seven-column benchmark schema leaves more slack than the bitmap
       needs, so it pays nothing. */
    wide_tomb = capacity_of(argv[1],
        "CREATE TABLE wide (id INT64, category INT32, score INT32, amount INT64,"
        " active BOOL, weight FLOAT32, tag INT32)", "wide", NULL);
    wide_plain = capacity_of(argv[2],
        "CREATE TABLE wide (id INT64, category INT32, score INT32, amount INT64,"
        " active BOOL, weight FLOAT32, tag INT32)", "wide", NULL);
    sprintf(detail, "%llu with the reservation, %llu without",
            (unsigned long long)wide_tomb, (unsigned long long)wide_plain);
    check("a leaf with slack pays nothing", wide_tomb == wide_plain && wide_tomb > 0, detail);

    printf("tombstone layout suite: %d passed, %d failed\n", checks - failures, failures);
    return failures ? 1 : 0;
}
