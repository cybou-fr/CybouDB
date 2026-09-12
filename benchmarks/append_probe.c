/* benchmarks/append_probe.c - why an append costs more the longer a
 * transaction has been open.
 *
 * Appending rows inside one uncommitted transaction is quadratic: the same
 * 90,000 rows cost 1,004 ms in one transaction and 293 ms in nine. This probe
 * attributes that to a single call. It appends fixed chunks through the
 * internal batch API without committing, and after each one times the two
 * things db_pax_insert does before it touches any data:
 *
 *   db_catalog_get      resolve the table's schema page, which revalidates
 *                       the whole typed graph against a synthetic superblock
 *                       standing at the staged generation
 *   db_bitmap_headroom  how many pages are left, for comparison: it is O(1)
 *                       and stays flat, so the clock and the loop are not
 *                       what is growing
 *
 * Pass a nonzero fourth argument to force the scalar CRC-32C. If the cost is
 * checksum work, that multiplies it by roughly eighty; if it is anything
 * else, it does not move. That is the measurement that identifies the term
 * rather than merely locating it.
 *
 * Usage:  append_probe <database> [chunks] [commit_every] [scalar_crc]
 *
 * The database must already exist and have room; the probe creates its own
 * table. Reported per sampled chunk: microseconds in the append, nanoseconds
 * in each of the two calls, and the pages allocated so far.
 *
 * SPDX-License-Identifier: Apache-2.0
 * Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
 */
#include "cyboudb.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern uint64_t os_monotonic_ns(void);
extern int db_pax_insert(void *ctx, uint64_t table_id, void *batch);
extern int db_catalog_get(void *ctx, uint64_t table_id, uint64_t *out_page);
extern uint64_t db_bitmap_headroom(void *ctx);
extern int db_commit(void *ctx);
extern int crc32c_force_scalar;
extern void *catalog_find_table(void *ctx, const char *name, uint64_t len,
                               uint64_t *out_id);

/* include/pax.inc: the row-major batch the internal append consumes. */
typedef struct {
    uint64_t rows;
    uint64_t *values;
    unsigned char *nulls;
    uint64_t *var_lengths;
    uint64_t flags;
} batch_t;

#define COLS  2
#define CHUNK 279               /* what a predicated DELETE stages at a time */
#define DB_ALLOC_OFFSET 32      /* include/cyboudb.inc: DB_ALLOC */

int main(int argc, char **argv) {
    cyboudb_db *db = NULL;
    unsigned char *ctx;
    uint64_t table_id = 0, page = 0, base_pages = 0;
    uint64_t values[CHUNK * COLS];
    unsigned char nulls[CHUNK * COLS];
    batch_t batch;
    int chunks = argc > 2 ? atoi(argv[2]) : 300;
    int commit_every = argc > 3 ? atoi(argv[3]) : 0;
    int i, c;

    if (argc < 2) {
        fprintf(stderr,
                "usage: append_probe <database> [chunks] [commit_every] [scalar_crc]\n");
        return 2;
    }
    setvbuf(stdout, NULL, _IONBF, 0);

    if (cyboudb_open(argv[1], CybouDB_OPEN_READWRITE, &db) != CybouDB_OK) {
        fprintf(stderr, "open failed\n");
        return 2;
    }
    ctx = (unsigned char *)db;  /* DB_H_CTX sits at offset 0 of the handle */
    crc32c_force_scalar = argc > 4 ? atoi(argv[4]) : 0;

    if (cyboudb_exec(db, "CREATE TABLE probe_t (a INT64, b INT32)") != CybouDB_OK) {
        fprintf(stderr, "create failed: %s\n", cyboudb_errmsg(db));
        return 2;
    }
    if (!catalog_find_table(ctx, "probe_t", 7, &table_id)) {
        fprintf(stderr, "table not found\n");
        return 2;
    }
    memcpy(&base_pages, ctx + DB_ALLOC_OFFSET, sizeof base_pages);

    memset(nulls, 0, sizeof nulls);
    batch.rows = CHUNK;
    batch.values = values;
    batch.nulls = nulls;
    batch.var_lengths = NULL;
    batch.flags = 0;

    printf("%6s %11s %16s %14s %12s\n",
           "chunk", "append_us", "catalog_get_ns", "headroom_ns", "pages_staged");
    for (c = 0; c < chunks; c++) {
        uint64_t t0, t1, t2, t3, t4, staged = 0;

        for (i = 0; i < CHUNK; i++) {
            values[i * COLS] = (uint64_t)(c * CHUNK + i);
            values[i * COLS + 1] = (uint64_t)((c * CHUNK + i) % 97);
        }

        t0 = os_monotonic_ns();
        if (db_pax_insert(ctx, table_id, &batch)) {
            fprintf(stderr, "append failed at chunk %d\n", c);
            return 2;
        }
        t1 = os_monotonic_ns();

        t2 = os_monotonic_ns();
        db_catalog_get(ctx, table_id, &page);
        t3 = os_monotonic_ns();
        db_bitmap_headroom(ctx);
        t4 = os_monotonic_ns();

        memcpy(&staged, ctx + DB_ALLOC_OFFSET, sizeof staged);
        if (c % 20 == 0 || c == chunks - 1) {
            printf("%6d %11.1f %16llu %14llu %12llu\n", c, (t1 - t0) / 1000.0,
                   (unsigned long long)(t3 - t2), (unsigned long long)(t4 - t3),
                   (unsigned long long)(staged - base_pages));
        }
        if (commit_every && (c % commit_every) == commit_every - 1) {
            db_commit(ctx);
            memcpy(&base_pages, ctx + DB_ALLOC_OFFSET, sizeof base_pages);
        }
    }
    db_commit(ctx);
    cyboudb_close(db);
    return 0;
}
