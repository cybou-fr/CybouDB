/* benchmarks/delete_bench.c - one timed DELETE against an already seeded table.
 *
 * A DELETE cannot be timed the way the SELECT harness times a plan. It runs
 * once and the state it ran against is gone, so there is nothing to repeat and
 * nothing to average inside one process. What this harness does instead is
 * keep everything that is not the statement outside the measured region: the
 * database is opened, the statement is parsed and bound, and only the step
 * that executes it falls between the two clock reads.
 *
 * The statement runs inside an explicit transaction, which is the only way to
 * see the rewrite on its own: autocommit would put a flush of the whole
 * mapping inside the same measurement, and on a large file that flush is the
 * larger number by far. The commit is timed separately and reported as its
 * own field.
 *
 * Repetition is the runner's job: it restores a fresh copy of the seeded
 * database before each run, which is far too expensive to sit inside a
 * measurement.
 *
 * Usage:  delete_bench <database> <sql> [count-sql]
 * Output: one "key=value" line per field on stdout.
 *
 *   rc         step status, 0 on success
 *   exec_ns    nanoseconds spent in the DELETE itself, commit excluded
 *   commit_ns  nanoseconds spent committing what it staged
 *   rows       rows the table held before the statement ran
 *
 * SPDX-License-Identifier: Apache-2.0
 * Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
 */
#include "cyboudb.h"
#include <stdio.h>
#include <string.h>

extern uint64_t os_monotonic_ns(void);

static int64_t table_rows(cyboudb_db *db, const char *sql) {
    cyboudb_stmt *stmt = NULL;
    int64_t rows = -1;
    if (cyboudb_prepare(db, sql, &stmt) != CybouDB_OK) return -1;
    if (cyboudb_step(stmt) == CybouDB_ROW) rows = cyboudb_column_int64(stmt, 0);
    cyboudb_finalize(stmt);
    return rows;
}

int main(int argc, char **argv) {
    cyboudb_db *db = NULL;
    cyboudb_stmt *stmt = NULL;
    uint64_t t0, t1, t2, t3;
    int rc, commit_rc;
    int64_t before;

    if (argc < 3) {
        fprintf(stderr, "usage: delete_bench <database> <sql> [count-sql]\n");
        return 2;
    }

    if (cyboudb_open(argv[1], CybouDB_OPEN_READWRITE, &db) != CybouDB_OK) {
        fprintf(stderr, "open failed\n");
        return 2;
    }

    before = table_rows(db, argc > 3 ? argv[3] : "SELECT COUNT(*) FROM events");

    if (cyboudb_exec(db, "BEGIN") != CybouDB_OK) {
        fprintf(stderr, "begin failed: %s\n", cyboudb_errmsg(db));
        cyboudb_close(db);
        return 2;
    }
    if (cyboudb_prepare(db, argv[2], &stmt) != CybouDB_OK) {
        fprintf(stderr, "prepare failed: %s\n", cyboudb_errmsg(db));
        cyboudb_close(db);
        return 2;
    }

    /* The statement is bound and a transaction is open; what falls between
       the two reads is the scan, the predicate kernels and the rewrite. */
    t0 = os_monotonic_ns();
    rc = cyboudb_step(stmt);
    t1 = os_monotonic_ns();
    cyboudb_finalize(stmt);

    t2 = os_monotonic_ns();
    commit_rc = cyboudb_exec(db, "COMMIT");
    t3 = os_monotonic_ns();

    printf("rc=%d\n", rc == CybouDB_DONE ? 0 : rc);
    printf("commit_rc=%d\n", commit_rc);
    printf("exec_ns=%llu\n", (unsigned long long)(t1 - t0));
    printf("commit_ns=%llu\n", (unsigned long long)(t3 - t2));
    printf("rows=%lld\n", (long long)before);
    if (rc != CybouDB_DONE || commit_rc != CybouDB_OK) {
        printf("err=%s\n", cyboudb_errmsg(db));
    }

    cyboudb_close(db);
    return (rc == CybouDB_DONE && commit_rc == CybouDB_OK) ? 0 : 1;
}
