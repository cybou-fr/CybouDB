/* tests/commit_guard_test.c - the typed graph is proved before it is durable.
 *
 * Appends inside a transaction no longer walk the catalog graph one at a time:
 * current_valid remembers that this writer proved it, and db_pax_check_new
 * falls back to a header check on the root it was handed. What makes that
 * safe is the validation db_commit already did before publishing anything -
 * db_bitmap_validate, which walks the typed graph through db_catalog_validate
 * as well as the allocation state. This is the test that pins that boundary,
 * because it is now the only one between a staged page and a durable one. It
 * stages a mutation, damages a page the transaction staged, and requires the
 * commit to refuse.
 *
 * It reaches past the public API on purpose - nothing in cyboudb.h can
 * corrupt a staged page - so it lives in its own binary rather than in the
 * C API suite, and works on a database of its own.
 *
 * Usage: commit_guard_test <database created with create-large>
 *
 * SPDX-License-Identifier: Apache-2.0
 * Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
 */
#include "cyboudb.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* The static library is built for the C test target, which routes the API's
   allocations through these hooks. */
void *cyboudb_test_mem_alloc(size_t size) { return malloc(size); }
void cyboudb_test_mem_free(void *ptr, size_t size) { (void)size; free(ptr); }

extern int db_commit(void *ctx);
extern int db_rollback(void *ctx);
extern int db_pax_insert(void *ctx, uint64_t table_id, void *batch);
extern void *catalog_find_table(void *ctx, const char *name, uint64_t len,
                               uint64_t *out_id);
extern unsigned int crc32c(const void *buffer, uint64_t length);

/* include/cyboudb.inc */
#define DB_BASE_OFFSET   8
#define DB_ROOT_OFFSET   80
#define PAGE_SHIFT       12
#define CAT_DATA_ROOT_OFFSET 40     /* include/pax.inc, within a schema page */
#define CAT_TABLE_ROWS_OFFSET 48
#define CAT_CRC_OFFSET   4092       /* include/catalog.inc */

typedef struct {
    uint64_t rows;
    uint64_t *values;
    unsigned char *nulls;
    uint64_t *var_lengths;
    uint64_t flags;
} batch_t;

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

static uint64_t field(const unsigned char *ctx, int off) {
    uint64_t v;
    memcpy(&v, ctx + off, sizeof v);
    return v;
}

/* Stage one append without committing, and report the mapped catalog root
   the transaction now stands on. */
static int stage_append(void *ctx, uint64_t table_id, int base_row) {
    static uint64_t values[8 * 2];
    static unsigned char nulls[8 * 2];
    batch_t batch;
    int i;
    for (i = 0; i < 8; i++) {
        values[i * 2] = (uint64_t)(base_row + i);
        values[i * 2 + 1] = (uint64_t)((base_row + i) % 97);
    }
    memset(nulls, 0, sizeof nulls);
    batch.rows = 8;
    batch.values = values;
    batch.nulls = nulls;
    batch.var_lengths = NULL;
    batch.flags = 0;
    return db_pax_insert(ctx, table_id, &batch);
}

int main(int argc, char **argv) {
    cyboudb_db *db = NULL;
    unsigned char *ctx;
    uint64_t table_id = 0, root, base, data_root;
    unsigned char *page;
    unsigned char *schema;
    unsigned char saved;
    int rc;

    if (argc < 2) {
        fprintf(stderr, "usage: commit_guard_test <database>\n");
        return 2;
    }
    setvbuf(stdout, NULL, _IONBF, 0);

    if (cyboudb_open(argv[1], CybouDB_OPEN_READWRITE, &db) != CybouDB_OK) {
        fprintf(stderr, "open failed\n");
        return 2;
    }
    ctx = (unsigned char *)db;      /* DB_H_CTX sits at offset 0 */

    if (cyboudb_exec(db, "CREATE TABLE guard_t (a INT64, b INT32)") != CybouDB_OK) {
        fprintf(stderr, "create failed: %s\n", cyboudb_errmsg(db));
        return 2;
    }
    if (!catalog_find_table(ctx, "guard_t", 7, &table_id)) {
        fprintf(stderr, "table not found\n");
        return 2;
    }

    /* A clean transaction commits. Several appends, so the run is the one the
       change made cheap rather than a single-append special case. */
    check("staged append", stage_append(ctx, table_id, 0) == 0);
    check("second staged append", stage_append(ctx, table_id, 8) == 0);
    check("third staged append", stage_append(ctx, table_id, 16) == 0);
    check("clean transaction commits", db_commit(ctx) == CybouDB_OK);

    /* A page the transaction staged, corrupted underneath it. Nothing
       between the append and the publication looks at that page any more, so
       the commit is the only thing left that can refuse - and it has to. */
    check("append before corrupting the catalog root", stage_append(ctx, table_id, 24) == 0);
    base = field(ctx, DB_BASE_OFFSET);
    root = field(ctx, DB_ROOT_OFFSET);
    check("transaction stands on a staged catalog root", root != 0);
    page = (unsigned char *)(uintptr_t)base + (root << PAGE_SHIFT);

    saved = page[64];
    page[64] ^= 0xFF;               /* the first directory entry */
    rc = db_commit(ctx);
    check("commit refuses a corrupted catalog root", rc != CybouDB_OK);
    page[64] = saved;
    check("rollback after the refusal", db_rollback(ctx) == CybouDB_OK);

    /* The same for a leaf rather than a catalog page. Both of these are
       reported by the allocation check, which runs first at commit and
       verifies the checksum of every page standing at the staged generation;
       what they establish is that the boundary holds, not which check holds
       it. */
    check("append before corrupting a leaf", stage_append(ctx, table_id, 32) == 0);
    schema = (unsigned char *)catalog_find_table(ctx, "guard_t", 7, &table_id);
    check("schema page located", schema != NULL);
    data_root = field(schema, CAT_DATA_ROOT_OFFSET);
    check("table has a staged data root", data_root != 0);
    base = field(ctx, DB_BASE_OFFSET);
    page = (unsigned char *)(uintptr_t)base + (data_root << PAGE_SHIFT);

    saved = page[128];
    page[128] ^= 0xFF;              /* payload, covered by the page checksum */
    rc = db_commit(ctx);
    check("commit refuses a corrupted staged leaf", rc != CybouDB_OK);
    page[128] = saved;
    check("rollback after the second refusal", db_rollback(ctx) == CybouDB_OK);

    /* Damage that keeps its checksum consistent is the case that needs the
       typed walk rather than the page checks: a row count that no longer
       matches the leaves the table actually has is structurally wrong and
       bitwise intact. */
    check("append before rewriting the row count", stage_append(ctx, table_id, 40) == 0);
    schema = (unsigned char *)catalog_find_table(ctx, "guard_t", 7, &table_id);
    check("schema page located again", schema != NULL);
    {
        uint64_t rows;
        unsigned int crc;
        memcpy(&rows, schema + CAT_TABLE_ROWS_OFFSET, sizeof rows);
        rows += 1000;                       /* more rows than the leaves hold */
        memcpy(schema + CAT_TABLE_ROWS_OFFSET, &rows, sizeof rows);
        crc = crc32c(schema, CAT_CRC_OFFSET);
        memcpy(schema + CAT_CRC_OFFSET, &crc, sizeof crc);
    }
    rc = db_commit(ctx);
    check("commit refuses a resealed but inconsistent graph", rc != CybouDB_OK);
    check("rollback after the third refusal", db_rollback(ctx) == CybouDB_OK);

    /* Either refusal must leave the database usable rather than half
       published. */
    check("table still readable", cyboudb_exec(db, "SELECT a, b FROM guard_t") == CybouDB_OK);
    check("still writable", cyboudb_exec(db, "INSERT INTO guard_t VALUES (99, 1)") == CybouDB_OK);
    check("drop", cyboudb_exec(db, "DROP TABLE guard_t") == CybouDB_OK);
    check("close", cyboudb_close(db) == CybouDB_OK);

    printf("commit guard suite: %d passed, %d failed\n", checks - failures, failures);
    return failures ? 1 : 0;
}
