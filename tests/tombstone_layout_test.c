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
extern int db_pax_mark_dead(void *ctx, uint64_t table_id, void *group);
extern int db_commit(void *ctx);
extern int db_rollback(void *ctx);
extern unsigned int crc32c(const void *buffer, uint64_t length);
extern void *catalog_find_table(void *ctx, const char *name, uint64_t len,
                               uint64_t *out_id);

#define DB_FEATURES_OFFSET 104
#define FEATURE_TOMBSTONES 4096
#define DB_BASE_OFFSET     8        /* include/cyboudb.inc */
#define CAT_DATA_ROOT      40       /* include/pax.inc */
#define PAX_ROWS           32
#define PAX_CAPACITY       40
#define PAX_DEAD           48
#define PAX_DIRECTORY      64
#define PAX_DIR_MAGIC      0x44515341
#define PAGE_SHIFT         12

/* include/pax.inc */
typedef struct { uint64_t start; uint64_t mask; } span_t;
typedef struct { span_t *spans; uint64_t count; uint64_t mode; } group_t;

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

static uint64_t field64(const unsigned char *p, int off) {
    uint64_t v; memcpy(&v, p + off, sizeof v); return v;
}
static uint32_t field32(const unsigned char *p, int off) {
    uint32_t v; memcpy(&v, p + off, sizeof v); return v;
}

/* A table's data root may be a directory; the leaf is below it. */
static unsigned char *first_leaf(unsigned char *base, uint64_t root) {
    unsigned char *page = base + (root << PAGE_SHIFT);
    while (field32(page, 0) == PAX_DIR_MAGIC) {
        page = base + (field64(page, PAX_DIRECTORY) << PAGE_SHIFT);
    }
    return page;
}

/* Reseal a leaf so that only the damage under test is wrong with it. */
static void reseal(unsigned char *leaf, uint64_t run_pages) {
    uint64_t crc_at = (run_pages << PAGE_SHIFT) - 4;
    unsigned int crc = crc32c(leaf, crc_at);
    memcpy(leaf + crc_at, &crc, sizeof crc);
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

    /* Marking. Nothing reads the bits yet, so what this establishes is that
       the primitive writes them where the leaf says they go, that the header
       count it leaves behind agrees with them, and that a file carrying both
       still opens - which is the validation refusing to accept a leaf whose
       count and bitmap disagree. */
    {
        cyboudb_db *db = NULL;
        unsigned char *ctx;
        uint64_t id = 0;
        span_t span;
        group_t group;
        int rc;

        if (cyboudb_open(argv[1], CybouDB_OPEN_READWRITE, &db) != CybouDB_OK) {
            printf("FAIL reopen for marking\n");
            return 1;
        }
        ctx = (unsigned char *)db;
        check("seed table", cyboudb_exec(db,
            "CREATE TABLE marked (id INT32, v INT64)") == CybouDB_OK, NULL);
        check("seed rows", cyboudb_exec(db,
            "INSERT INTO marked VALUES (0,0),(1,10),(2,20),(3,30),(4,40),"
            "(5,50),(6,60),(7,70)") == CybouDB_OK, NULL);
        check("locate table", catalog_find_table(ctx, "marked", 6, &id) != NULL, NULL);

        /* Rows 1, 3 and 6 of the first leaf. */
        span.start = 0;
        span.mask = (1ull << 1) | (1ull << 3) | (1ull << 6);
        group.spans = &span;
        group.count = 1;
        group.mode = 0;                 /* db_pax_mark_dead sets it */
        rc = db_pax_mark_dead(ctx, id, &group);
        sprintf(detail, "rc=%d", rc);
        check("mark three rows", rc == 0, detail);
        check("commit the marks", db_commit(ctx) == CybouDB_OK, NULL);

        /* Marking the same rows again is not an error and does not double the
           count: the bits are already set, and the count is recomputed from
           them rather than added to. */
        rc = db_pax_mark_dead(ctx, id, &group);
        sprintf(detail, "rc=%d", rc);
        check("mark them again", rc == 0, detail);
        check("commit again", db_commit(ctx) == CybouDB_OK, NULL);

        check("table still reads", cyboudb_exec(db,
            "SELECT id, v FROM marked") == CybouDB_OK, NULL);
        check("still writable", cyboudb_exec(db,
            "INSERT INTO marked VALUES (8, 80)") == CybouDB_OK, NULL);
        check("drop", cyboudb_exec(db, "DROP TABLE marked") == CybouDB_OK, NULL);
        check("close", cyboudb_close(db) == CybouDB_OK, NULL);
    }

    /* A marked row is invisible to a reader. The mask is intersected with the
       predicate's selection, so it has to hold for a plain scan, for a
       predicate, and for COUNT(*) - including the count that would otherwise
       take a leaf whole from the zone map without reading it. */
    {
        cyboudb_db *db = NULL;
        cyboudb_stmt *stmt = NULL;
        unsigned char *ctx;
        uint64_t id = 0;
        span_t span;
        group_t group;
        int64_t seen[8];
        int rows, i;

        if (cyboudb_open(argv[1], CybouDB_OPEN_READWRITE, &db) != CybouDB_OK) {
            printf("FAIL reopen for visibility\n");
            return 1;
        }
        ctx = (unsigned char *)db;
        check("visible-case table", cyboudb_exec(db,
            "CREATE TABLE seen (id INT32, v INT64)") == CybouDB_OK, NULL);
        check("visible-case rows", cyboudb_exec(db,
            "INSERT INTO seen VALUES (0,0),(1,10),(2,20),(3,30),(4,40),(5,50)")
            == CybouDB_OK, NULL);
        check("visible-case located", catalog_find_table(ctx, "seen", 4, &id) != NULL, NULL);

        /* Rows 1 and 4 of the leaf. */
        span.start = 0;
        span.mask = (1ull << 1) | (1ull << 4);
        group.spans = &span;
        group.count = 1;
        group.mode = 0;
        check("mark two rows", db_pax_mark_dead(ctx, id, &group) == 0, NULL);
        check("commit the marks", db_commit(ctx) == CybouDB_OK, NULL);

        rows = 0;
        check("prepare a plain scan", cyboudb_prepare(db, "SELECT id, v FROM seen", &stmt)
              == CybouDB_OK, NULL);
        while (cyboudb_step(stmt) == CybouDB_ROW && rows < 8) {
            seen[rows++] = cyboudb_column_int64(stmt, 0);
        }
        cyboudb_finalize(stmt);
        sprintf(detail, "%d rows came back", rows);
        check("a scan skips the marked rows", rows == 4, detail);
        {
            int ok = 1;
            for (i = 0; i < rows; i++) {
                if (seen[i] == 1 || seen[i] == 4) ok = 0;
            }
            check("and returns none of them", ok, NULL);
            check("while keeping the rest",
                  rows == 4 && seen[0] == 0 && seen[1] == 2 &&
                  seen[2] == 3 && seen[3] == 5, NULL);
        }

        check("prepare a count", cyboudb_prepare(db, "SELECT COUNT(*) FROM seen", &stmt)
              == CybouDB_OK, NULL);
        check("count steps", cyboudb_step(stmt) == CybouDB_ROW, NULL);
        {
            int64_t n = cyboudb_column_int64(stmt, 0);
            sprintf(detail, "count returned %lld", (long long)n);
            check("COUNT(*) counts the living", n == 4, detail);
        }
        cyboudb_finalize(stmt);

        check("prepare a predicate", cyboudb_prepare(db,
            "SELECT id FROM seen WHERE id >= 1", &stmt) == CybouDB_OK, NULL);
        rows = 0;
        while (cyboudb_step(stmt) == CybouDB_ROW && rows < 8) {
            seen[rows++] = cyboudb_column_int64(stmt, 0);
        }
        cyboudb_finalize(stmt);
        sprintf(detail, "%d rows matched", rows);
        check("a predicate sees only the living",
              rows == 3 && seen[0] == 2 && seen[1] == 3 && seen[2] == 5, detail);

        /* Rows appended after a mark are alive, and land past the dead ones. */
        check("insert after marking", cyboudb_exec(db,
            "INSERT INTO seen VALUES (6, 60)") == CybouDB_OK, NULL);
        check("prepare a second count", cyboudb_prepare(db,
            "SELECT COUNT(*) FROM seen", &stmt) == CybouDB_OK, NULL);
        check("second count steps", cyboudb_step(stmt) == CybouDB_ROW, NULL);
        {
            int64_t n = cyboudb_column_int64(stmt, 0);
            sprintf(detail, "count returned %lld", (long long)n);
            check("the new row is alive", n == 5, detail);
        }
        cyboudb_finalize(stmt);

        check("drop seen", cyboudb_exec(db, "DROP TABLE seen") == CybouDB_OK, NULL);
        check("close after visibility", cyboudb_close(db) == CybouDB_OK, NULL);
    }

    /* Validation has to refuse a leaf whose count and bitmap disagree, and one
       that marks a row it does not hold. Both are resealed, so the checksum
       cannot be what catches them - only the tombstone rules can. */
    {
        cyboudb_db *db = NULL;
        unsigned char *ctx, *schema, *leaf;
        uint64_t id = 0, base;
        span_t span;
        group_t group;
        int rc;

        if (cyboudb_open(argv[1], CybouDB_OPEN_READWRITE, &db) != CybouDB_OK) {
            printf("FAIL reopen for the negative cases\n");
            return 1;
        }
        ctx = (unsigned char *)db;
        check("damaged-case table", cyboudb_exec(db,
            "CREATE TABLE damaged (id INT32, v INT64)") == CybouDB_OK, NULL);
        check("damaged-case rows", cyboudb_exec(db,
            "INSERT INTO damaged VALUES (0,0),(1,10),(2,20),(3,30)") == CybouDB_OK, NULL);
        check("damaged-case located", catalog_find_table(ctx, "damaged", 7, &id) != NULL, NULL);

        span.start = 0;
        span.mask = 1ull << 2;
        group.spans = &span;
        group.count = 1;
        group.mode = 0;
        check("mark one row", db_pax_mark_dead(ctx, id, &group) == 0, NULL);

        /* The count now says one; make the header claim two and reseal. */
        base = field64(ctx, DB_BASE_OFFSET);
        schema = (unsigned char *)catalog_find_table(ctx, "damaged", 7, &id);
        leaf = first_leaf((unsigned char *)(uintptr_t)base, field64(schema, CAT_DATA_ROOT));
        {
            uint32_t dead = field32(leaf, PAX_DEAD) + 1;
            memcpy(leaf + PAX_DEAD, &dead, sizeof dead);
            reseal(leaf, 1);
        }
        rc = db_commit(ctx);
        sprintf(detail, "rc=%d", rc);
        check("a count the bitmap does not support is refused", rc != CybouDB_OK, detail);
        check("rollback after it", db_rollback(ctx) == CybouDB_OK, NULL);

        /* And a row the leaf does not hold, marked and resealed. */
        check("mark again", db_pax_mark_dead(ctx, id, &group) == 0, NULL);
        base = field64(ctx, DB_BASE_OFFSET);
        schema = (unsigned char *)catalog_find_table(ctx, "damaged", 7, &id);
        leaf = first_leaf((unsigned char *)(uintptr_t)base, field64(schema, CAT_DATA_ROOT));
        {
            uint32_t rows = field32(leaf, PAX_ROWS);
            uint32_t capacity = field32(leaf, PAX_CAPACITY);
            uint64_t bytes = (capacity + 7) / 8;
            unsigned char *bitmap = leaf + ((1u << PAGE_SHIFT) - 4) - bytes;
            uint32_t dead = field32(leaf, PAX_DEAD) + 1;
            bitmap[rows >> 3] |= (unsigned char)(1u << (rows & 7));  /* one past the rows */
            memcpy(leaf + PAX_DEAD, &dead, sizeof dead);             /* keep the count true */
            reseal(leaf, 1);
        }
        rc = db_commit(ctx);
        sprintf(detail, "rc=%d", rc);
        check("a row the leaf does not hold is refused", rc != CybouDB_OK, detail);
        check("rollback after that", db_rollback(ctx) == CybouDB_OK, NULL);

        check("table survives both refusals", cyboudb_exec(db,
            "SELECT id, v FROM damaged") == CybouDB_OK, NULL);
        check("drop damaged", cyboudb_exec(db, "DROP TABLE damaged") == CybouDB_OK, NULL);
        check("close after the negative cases", cyboudb_close(db) == CybouDB_OK, NULL);
    }

    printf("tombstone layout suite: %d passed, %d failed\n", checks - failures, failures);
    return failures ? 1 : 0;
}
