/* tests/index_probe.c - what one statement costs, from inside the process.
 *
 * The benchmark times whole processes, and roughly fourteen milliseconds of
 * every number there is opening the file. This runs statements with the clock
 * inside, and prints how many index nodes validation looked at per statement -
 * which is the difference between a commit that proves the path a transaction
 * touched and one that proves the whole index.
 *
 * Usage: index_probe <database> <first id to insert>
 *
 * SPDX-License-Identifier: Apache-2.0
 * Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
 */
#include "cyboudb.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/* One statement is below the clock's resolution, so the loop is what makes
   the number mean anything. */
#define ROUNDS 200

void *cyboudb_test_mem_alloc(size_t size) { return malloc(size); }
void cyboudb_test_mem_free(void *ptr, size_t size) { (void)size; free(ptr); }

extern unsigned long long index_nodes_walked;
extern unsigned long long catalog_pages_validated;
extern unsigned long long pax_leaves_validated;
extern unsigned long long pages_flushed;
extern unsigned long long index_child_reads;
extern int db_commit(void *ctx);

int main(int argc, char **argv) {
    cyboudb_db *db = NULL;
    char sql[128];
    unsigned long long before, pages_before, leaves_before, flushed_before, reads_before;
    clock_t start;
    double ms;
    int first, i;

    if (argc < 3) {
        fprintf(stderr, "usage: index_probe <database> <first id>\n");
        return 2;
    }
    if (cyboudb_open(argv[1], CybouDB_OPEN_READWRITE, &db) != CybouDB_OK) {
        fprintf(stderr, "open failed\n");
        return 2;
    }
    first = atoi(argv[2]);

    before = index_nodes_walked;
    pages_before = catalog_pages_validated;
    leaves_before = pax_leaves_validated;
    flushed_before = pages_flushed;
    reads_before = index_child_reads;
    start = clock();
    for (i = 0; i < ROUNDS; i++) {
        /* Distinct keys: two hundred rows under one key pile into one leaf and
           split it again and again, which measures a pathology rather than a
           workload. */
        snprintf(sql, sizeof sql, "INSERT INTO t VALUES (%d, %d)",
                 first + i, first + i);
        if (cyboudb_exec(db, sql) != CybouDB_OK) {
            fprintf(stderr, "exec failed: %s\n", cyboudb_errmsg(db));
            return 2;
        }
        if (db_commit(db) != CybouDB_OK) {
            fprintf(stderr, "commit failed\n");
            return 2;
        }
    }
    ms = (double)(clock() - start) * 1000.0 / CLOCKS_PER_SEC / ROUNDS;
    printf("%.3f ms per INSERT, %.1f index nodes, %.1f catalog pages, "
           "%.1f table graphs, %.0f flushed, %.0f child reads\n", ms,
           (double)(index_nodes_walked - before) / ROUNDS,
           (double)(catalog_pages_validated - pages_before) / ROUNDS,
           (double)(pax_leaves_validated - leaves_before) / ROUNDS,
           (double)(pages_flushed - flushed_before) / ROUNDS,
           (double)(index_child_reads - reads_before) / ROUNDS);
    cyboudb_close(db);
    return 0;
}
