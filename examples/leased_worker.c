/* examples/leased_worker.c - a worker that holds a job across a commit.
 *
 * examples/worker.c takes a message with DEQUEUE inside the transaction that
 * records the result. That is the right shape when the work is a row: one
 * commit, no outbox, no duplicates. It is the wrong shape when the work takes
 * a minute, because the transaction would have to stay open for that minute.
 *
 * A lease is the other shape. CLAIM takes a message and commits immediately,
 * holding it until a deadline the worker chose; the work then happens outside
 * any transaction; ACK finishes it, in the same commit as the result. If the
 * worker dies in the middle, nothing has to notice - the deadline passes and
 * the message is claimable again, with no sweeper and no write.
 *
 * Two things this file is really about:
 *
 *   - **the ticket, not the deadline, is what keeps it honest.** ACK carries
 *     the position and the token CLAIM returned. A lapsed lease is not by
 *     itself a refusal: if nobody took the message, the late ACK is accepted.
 *     If somebody did, the reclaim raised the token, so the late ACK is
 *     refused and the work is not counted twice. The run below shows both.
 *
 *   - **leases are decided when the file is made.** cyboudb_create_with_options
 *     asks for the capability; a database created without it refuses CLAIM,
 *     and stays readable by builds that predate leases.
 *
 * Build (Linux):   sh build.sh --leased-worker-example
 *                  ./build/leased_worker_example
 * Build (Windows): build.bat --leased-worker-example
 *                  build\leased_worker_example.exe
 *
 * SPDX-License-Identifier: Apache-2.0
 * Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
 */
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "cyboudb.h"

void *cyboudb_test_mem_alloc(size_t size) { return malloc(size); }
void cyboudb_test_mem_free(void *ptr, size_t size) { (void)size; free(ptr); }

#define DB_PATH "build/leased_worker_example.cdb"

static int fail(cyboudb_db *db, const char *what) {
    fprintf(stderr, "leased worker: %s failed: %s\n", what,
            db ? cyboudb_errmsg(db) : "no handle");
    return 1;
}

/* Wait out a deadline without a portable sleep. A worker would be doing its
   job here; this only has to let the clock move. */
static void spin(double seconds) {
    clock_t until = clock() + (clock_t)(seconds * CLOCKS_PER_SEC);
    while (clock() < until) { /* deliberately busy */ }
}

/* Take one message, returning its payload and the ticket that finishes it.
   The claim commits on its own: that is what lets the work outlive it. */
static int claim_one(cyboudb_db *db, const char *sql, char *payload,
                     size_t cap, uint64_t *position, uint64_t *token,
                     int *took) {
    cyboudb_stmt *st = NULL;
    uint64_t len = 0;
    int rc;

    *took = 0;
    if (cyboudb_prepare(db, sql, &st) != CybouDB_OK) return fail(db, "prepare CLAIM");

    rc = cyboudb_step(st);
    if (rc == CybouDB_DONE) {           /* nothing claimable: not an error */
        cyboudb_finalize(st);
        return 0;
    }
    if (rc != CybouDB_ROW ||
        cyboudb_message(st, payload, cap - 1, &len) != CybouDB_OK ||
        cyboudb_claim_ticket(st, position, token) != CybouDB_OK) {
        cyboudb_finalize(st);
        return fail(db, "CLAIM");
    }
    payload[len] = 0;
    cyboudb_finalize(st);
    *took = 1;
    return 0;
}

int main(void) {
    cyboudb_db *db = NULL;
    cyboudb_create_options opts;
    char payload[256], sql[512];
    uint64_t position = 0, token = 0;
    uint64_t stolen_position = 0, stolen_token = 0;
    int took, done = 0;

    remove(DB_PATH);

    /* A database that allows leases. Without the flag this is cyboudb_create,
       and CLAIM below would be refused - which is the point of the flag. */
    memset(&opts, 0, sizeof opts);
    opts.struct_size = (uint32_t)sizeof opts;
    opts.flags = CybouDB_CREATE_QUEUE_LEASES;
    if (cyboudb_create_with_options(DB_PATH, 4000, &opts, &db) != CybouDB_OK)
        return fail(db, "create");

    if (cyboudb_exec(db, "CREATE TABLE results (note TEXT)") != CybouDB_OK ||
        cyboudb_exec(db, "CREATE QUEUE inbox") != CybouDB_OK)
        return fail(db, "schema");

    if (cyboudb_exec(db, "ENQUEUE INTO inbox VALUES ('alpha')") != CybouDB_OK ||
        cyboudb_exec(db, "ENQUEUE INTO inbox VALUES ('beta')") != CybouDB_OK ||
        cyboudb_exec(db, "ENQUEUE INTO inbox VALUES ('gamma')") != CybouDB_OK)
        return fail(db, "enqueue");
    printf("three jobs queued\n");

    /* --- 1. the ordinary path: claim, work, acknowledge ------------------- */
    if (claim_one(db, "CLAIM FROM inbox FOR 30000", payload, sizeof payload,
                  &position, &token, &took) != 0) return 1;
    if (!took) return fail(db, "expected a message");
    printf("claimed '%s' at %" PRIu64 " with token %" PRIu64 "\n",
           payload, position, token);

    /* The work happens here, with no transaction open. It can take as long as
       the lease allows, and the database is not waiting on it. */
    spin(0.05);

    /* The result and the acknowledgement commit together: either the job is
       recorded and finished, or it is neither. */
    if (cyboudb_exec(db, "BEGIN") != CybouDB_OK) return fail(db, "BEGIN");
    snprintf(sql, sizeof sql, "INSERT INTO results VALUES ('%s')", payload);
    if (cyboudb_exec(db, sql) != CybouDB_OK) return fail(db, "INSERT");
    snprintf(sql, sizeof sql, "ACK FROM inbox AT %" PRIu64 " TOKEN %" PRIu64,
             position, token);
    if (cyboudb_exec(db, sql) != CybouDB_OK) return fail(db, "ACK");
    if (cyboudb_exec(db, "COMMIT") != CybouDB_OK) return fail(db, "COMMIT");
    printf("acknowledged '%s'\n", payload);
    done++;

    /* --- 2. work that cannot be done: hand it back ------------------------ */
    if (claim_one(db, "CLAIM FROM inbox FOR 30000", payload, sizeof payload,
                  &position, &token, &took) != 0) return 1;
    if (!took) return fail(db, "expected a second message");
    printf("claimed '%s', and it cannot be processed\n", payload);

    snprintf(sql, sizeof sql, "NACK FROM inbox AT %" PRIu64 " TOKEN %" PRIu64,
             position, token);
    if (cyboudb_exec(db, sql) != CybouDB_OK) return fail(db, "NACK");
    printf("handed back - claimable again immediately, not after a timeout\n");

    /* Handing back raises the token, so the ticket that gave it back cannot
       be used to acknowledge it afterwards. */
    snprintf(sql, sizeof sql, "ACK FROM inbox AT %" PRIu64 " TOKEN %" PRIu64,
             position, token);
    if (cyboudb_exec(db, sql) == CybouDB_OK)
        return fail(db, "a returned message should not accept its old ticket");
    printf("and its old ticket is refused: %s\n", cyboudb_errmsg(db));

    /* --- 3. a lease that lapses, twice, with different answers ------------ */
    /* A short lease, then a worker that takes too long. */
    if (claim_one(db, "CLAIM FROM inbox FOR 30", payload, sizeof payload,
                  &position, &token, &took) != 0) return 1;
    if (!took) return fail(db, "expected a third message");
    printf("claimed '%s' for 30ms, then took longer\n", payload);
    spin(0.20);

    /* Nobody else has run, so nothing reclaimed it: the late ACK is accepted.
       The deadline decides when it could have been taken, not whether this
       worker still owns it. */
    snprintf(sql, sizeof sql, "ACK FROM inbox AT %" PRIu64 " TOKEN %" PRIu64,
             position, token);
    if (cyboudb_exec(db, sql) != CybouDB_OK)
        return fail(db, "a lapsed lease nobody reclaimed should still finish");
    printf("acknowledged late, because nobody had taken it\n");
    done++;

    /* Now the other half, on the last message: let the lease lapse and let a
       second worker take it, which is what raises the token. */
    if (claim_one(db, "CLAIM FROM inbox FOR 30", payload, sizeof payload,
                  &position, &token, &took) != 0) return 1;
    if (!took) return fail(db, "expected the last message");
    printf("claimed '%s' for 30ms, and this time somebody else got there\n",
           payload);
    spin(0.20);

    if (claim_one(db, "CLAIM FROM inbox FOR 30000", payload, sizeof payload,
                  &stolen_position, &stolen_token, &took) != 0) return 1;
    if (!took || stolen_position != position)
        return fail(db, "the lapsed message should have been claimable");
    printf("a second worker claimed it with token %" PRIu64 "\n", stolen_token);

    snprintf(sql, sizeof sql, "ACK FROM inbox AT %" PRIu64 " TOKEN %" PRIu64,
             position, token);
    if (cyboudb_exec(db, sql) == CybouDB_OK)
        return fail(db, "the first worker should not be able to finish it");
    printf("the first worker's ACK is refused: %s\n", cyboudb_errmsg(db));

    /* The second worker holds it, and can extend while it works. */
    snprintf(sql, sizeof sql,
             "RENEW FROM inbox AT %" PRIu64 " TOKEN %" PRIu64 " FOR 30000",
             stolen_position, stolen_token);
    if (cyboudb_exec(db, sql) != CybouDB_OK) return fail(db, "RENEW");
    snprintf(sql, sizeof sql, "ACK FROM inbox AT %" PRIu64 " TOKEN %" PRIu64,
             stolen_position, stolen_token);
    if (cyboudb_exec(db, sql) != CybouDB_OK) return fail(db, "second ACK");
    printf("renewed, then finished by the worker that actually held it\n");
    done++;

    if (cyboudb_close(db) != CybouDB_OK) return fail(NULL, "close");
    printf("%d jobs finished, each exactly once\n", done);
    return done == 3 ? 0 : 1;
}
