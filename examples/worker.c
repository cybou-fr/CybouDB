/* examples/worker.c - a worker loop with no broker under it.
 *
 * A job arrives on a queue, a worker takes it, records the result in a table
 * and writes a line to an audit stream. In a service built on a database and
 * a broker, those are two systems and two commits: taking the message and
 * recording the result cannot be made atomic, which is what the outbox pattern
 * works around at the cost of duplicates.
 *
 * Here they are one commit, so the loop below is the whole of it. If the
 * process dies anywhere inside the transaction, the message is still on the
 * queue and no result was recorded; if the commit returns, the message is gone
 * and the result is durable. There is no third outcome.
 *
 * What that does not cover is work outside the file - a call to another
 * service, an email, a payment. See docs/QUEUE.md: doing the outside work
 * before the commit gives at-least-once, after it gives at-most-once, and no
 * single database can give you more than that on its own.
 *
 * Build (Linux):   sh build.sh --worker-example && ./build/worker_example
 * Build (Windows): build.bat --worker-example && build\worker_example.exe
 *
 * SPDX-License-Identifier: Apache-2.0
 * Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
 */
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "cyboudb.h"

void *cyboudb_test_mem_alloc(size_t size) { return malloc(size); }
void cyboudb_test_mem_free(void *ptr, size_t size) { (void)size; free(ptr); }

#define DB_PATH "build/worker_example.cdb"

static int fail(const char *what) {
    fprintf(stderr, "worker: %s failed\n", what);
    return 1;
}

/* Take one job, do it, record it - or leave the queue exactly as it was. */
static int process_one(cyboudb_db *db, int *did_work) {
    cyboudb_stmt *take = NULL;
    char payload[256];
    char sql[512];
    uint64_t len = 0;
    int rc;

    *did_work = 0;
    if (cyboudb_exec(db, "BEGIN") != CybouDB_OK) return fail("BEGIN");

    if (cyboudb_prepare(db, "DEQUEUE FROM inbox", &take) != CybouDB_OK) {
        cyboudb_exec(db, "ROLLBACK");
        return fail("prepare DEQUEUE");
    }
    rc = cyboudb_step(take);
    if (rc == CybouDB_DONE) {           /* nothing waiting: not an error */
        cyboudb_finalize(take);
        cyboudb_exec(db, "ROLLBACK");
        return 0;
    }
    if (rc != CybouDB_ROW ||
        cyboudb_message(take, payload, sizeof payload - 1, &len)
            != CybouDB_OK) {
        cyboudb_finalize(take);
        cyboudb_exec(db, "ROLLBACK");
        return fail("DEQUEUE");
    }
    cyboudb_finalize(take);
    payload[len] = 0;

    /* The "work" - here, just deciding what to record. Anything that can fail
       belongs before the commit, so that failing means the message stays. */
    snprintf(sql, sizeof sql,
             "INSERT INTO results VALUES (%" PRIu64 ", '%s')", len, payload);
    if (cyboudb_exec(db, sql) != CybouDB_OK) {
        cyboudb_exec(db, "ROLLBACK");
        return fail("INSERT");
    }
    snprintf(sql, sizeof sql, "APPEND TO audit VALUES ('done: %s')", payload);
    if (cyboudb_exec(db, sql) != CybouDB_OK) {
        cyboudb_exec(db, "ROLLBACK");
        return fail("APPEND");
    }

    if (cyboudb_exec(db, "COMMIT") != CybouDB_OK) return fail("COMMIT");
    printf("  processed %s\n", payload);
    *did_work = 1;
    return 0;
}

int main(void) {
    cyboudb_db *db = NULL;
    cyboudb_stmt *st = NULL;
    char record[256];
    uint64_t len = 0;
    int did_work, processed = 0;

    remove(DB_PATH);
    if (cyboudb_create(DB_PATH, 4000, &db) != CybouDB_OK)
        return fail("create");

    if (cyboudb_exec(db, "CREATE TABLE results (size INT64, note TEXT)")
            != CybouDB_OK ||
        cyboudb_exec(db, "CREATE QUEUE inbox") != CybouDB_OK ||
        cyboudb_exec(db, "CREATE STREAM audit") != CybouDB_OK ||
        cyboudb_exec(db, "CREATE CURSOR reporting ON audit") != CybouDB_OK)
        return fail("schema");

    printf("queueing three jobs\n");
    if (cyboudb_exec(db, "ENQUEUE INTO inbox VALUES ('alpha')") != CybouDB_OK ||
        cyboudb_exec(db, "ENQUEUE INTO inbox VALUES ('beta')") != CybouDB_OK ||
        cyboudb_exec(db, "ENQUEUE INTO inbox VALUES ('gamma')") != CybouDB_OK)
        return fail("enqueue");

    printf("working\n");
    for (;;) {
        if (process_one(db, &did_work) != 0) return 1;
        if (!did_work) break;
        processed++;
    }
    printf("queue drained after %d jobs\n", processed);

    /* The audit stream is still there to read, by a reader of its own, at its
       own pace. Nothing the worker did consumed it. */
    printf("what the reporting reader sees\n");
    if (cyboudb_prepare(db, "READ FROM audit AS reporting", &st) != CybouDB_OK)
        return fail("prepare READ");
    while (cyboudb_step(st) == CybouDB_ROW) {
        if (cyboudb_message(st, record, sizeof record - 1, &len) != CybouDB_OK)
            return fail("message");
        record[len] = 0;
        printf("  %s\n", record);
    }
    cyboudb_finalize(st);

    if (cyboudb_close(db) != CybouDB_OK) return fail("close");
    printf("ok\n");
    return processed == 3 ? 0 : 1;
}
