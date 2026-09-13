/* tests/cross_primitive_test.c - one transaction over all of them.
 *
 * This is the thing the whole engine is for. A table, a queue and a stream
 * live in one file, under one allocation map, behind one pair of superblocks,
 * and a commit is one commit: a row written, a message taken and a record
 * appended either all happened or none of them did.
 *
 * That is what a service otherwise builds out of a database and a broker and
 * cannot make atomic - the outbox pattern exists because those are two
 * systems. Here they are one, so the test is not that each primitive works,
 * which their own suites cover, but that the boundary between them is not a
 * boundary at all.
 *
 * The cases are the ones that would expose a seam: a rollback has to put the
 * dequeued message back while also undoing the row and the record; a commit
 * has to make all of it durable together; and a statement that fails in the
 * middle must not leave half of it standing.
 *
 * Usage: cross_primitive_test <database created with create-large>
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

/* How many rows the table has, through a prepared SELECT COUNT(*). */
static long long rows(cyboudb_db *db) {
    cyboudb_stmt *st = NULL;
    long long n = -1;
    if (cyboudb_prepare(db, "SELECT COUNT(*) FROM jobs", &st) != CybouDB_OK)
        return -1;
    if (cyboudb_step(st) == CybouDB_ROW)
        n = cyboudb_column_int64(st, 0);
    cyboudb_finalize(st);
    return n;
}

/* Whether the queue still holds anything, asked the only way a queue can be
   asked: by taking, inside a transaction that is then rolled back. */
static int queue_has_message(cyboudb_db *db) {
    cyboudb_stmt *st = NULL;
    int answer = 0;
    if (cyboudb_exec(db, "BEGIN") != CybouDB_OK)
        return -1;
    if (cyboudb_prepare(db, "DEQUEUE FROM inbox", &st) == CybouDB_OK) {
        answer = cyboudb_step(st) == CybouDB_ROW;
        cyboudb_finalize(st);
    }
    cyboudb_exec(db, "ROLLBACK");
    return answer;
}

/* The record a named reader would be given next, or NULL - likewise asked
   without keeping the answer. */
static int stream_has_record(cyboudb_db *db, const char *reader) {
    cyboudb_stmt *st = NULL;
    char sql[128];
    int answer = 0;
    snprintf(sql, sizeof sql, "READ FROM audit AS %s", reader);
    if (cyboudb_exec(db, "BEGIN") != CybouDB_OK)
        return -1;
    if (cyboudb_prepare(db, sql, &st) == CybouDB_OK) {
        answer = cyboudb_step(st) == CybouDB_ROW;
        cyboudb_finalize(st);
    }
    cyboudb_exec(db, "ROLLBACK");
    return answer;
}

int main(int argc, char **argv) {
    cyboudb_db *db = NULL;
    cyboudb_stmt *st = NULL;
    char buf[256];
    uint64_t len = 0;

    if (argc < 2) {
        fprintf(stderr, "usage: cross_primitive_test <database>\n");
        return 2;
    }
    setvbuf(stdout, NULL, _IONBF, 0);
    if (cyboudb_open(argv[1], CybouDB_OPEN_READWRITE, &db) != CybouDB_OK) {
        fprintf(stderr, "open failed\n");
        return 2;
    }

    check("a table, a queue and a stream in one file",
          cyboudb_exec(db, "CREATE TABLE jobs (id INT64, note TEXT)")
              == CybouDB_OK &&
          cyboudb_exec(db, "CREATE QUEUE inbox") == CybouDB_OK &&
          cyboudb_exec(db, "CREATE STREAM audit") == CybouDB_OK);
    check("an index on the table, so a commit has that to carry too",
          cyboudb_exec(db, "CREATE INDEX jobs_id ON jobs (id)") == CybouDB_OK);
    check("a reader on the stream",
          cyboudb_exec(db, "CREATE CURSOR tail ON audit") == CybouDB_OK);
    check("and one message waiting",
          cyboudb_exec(db, "ENQUEUE INTO inbox VALUES ('first')") == CybouDB_OK);

    check("nothing in the table yet", rows(db) == 0);
    check("a message in the queue", queue_has_message(db) == 1);
    check("nothing in the stream", stream_has_record(db, "tail") == 0);

    /* --- all of it, undone ------------------------------------------------ */
    check("a transaction", cyboudb_exec(db, "BEGIN") == CybouDB_OK);
    check("takes the message",
          cyboudb_prepare(db, "DEQUEUE FROM inbox", &st) == CybouDB_OK &&
          cyboudb_step(st) == CybouDB_ROW &&
          cyboudb_message(st, buf, sizeof buf, &len) == CybouDB_OK &&
          len == 5 && memcmp(buf, "first", 5) == 0);
    cyboudb_finalize(st);
    check("writes the row it was for",
          cyboudb_exec(db, "INSERT INTO jobs VALUES (1, 'done')")
              == CybouDB_OK);
    check("and says so in the stream",
          cyboudb_exec(db, "APPEND TO audit VALUES ('job 1 done')")
              == CybouDB_OK);
    check("then takes it all back",
          cyboudb_exec(db, "ROLLBACK") == CybouDB_OK);

    check("the row is not there", rows(db) == 0);
    check("the message is back in the queue", queue_has_message(db) == 1);
    check("and the stream never heard of it",
          stream_has_record(db, "tail") == 0);

    /* --- all of it, kept -------------------------------------------------- */
    check("the same transaction again", cyboudb_exec(db, "BEGIN")
          == CybouDB_OK);
    check("takes the same message, because it was put back",
          cyboudb_prepare(db, "DEQUEUE FROM inbox", &st) == CybouDB_OK &&
          cyboudb_step(st) == CybouDB_ROW &&
          cyboudb_message(st, buf, sizeof buf, &len) == CybouDB_OK &&
          len == 5 && memcmp(buf, "first", 5) == 0);
    cyboudb_finalize(st);
    check("writes the row",
          cyboudb_exec(db, "INSERT INTO jobs VALUES (1, 'done')")
              == CybouDB_OK);
    check("appends the record",
          cyboudb_exec(db, "APPEND TO audit VALUES ('job 1 done')")
              == CybouDB_OK);
    check("and commits once, for all three",
          cyboudb_exec(db, "COMMIT") == CybouDB_OK);

    check("the row is there", rows(db) == 1);
    check("found through the index it also had to maintain",
          cyboudb_prepare(db, "SELECT id FROM jobs WHERE id = 1", &st)
              == CybouDB_OK &&
          cyboudb_step(st) == CybouDB_ROW &&
          cyboudb_column_int64(st, 0) == 1);
    cyboudb_finalize(st);
    check("the queue is empty", queue_has_message(db) == 0);
    check("and the reader has the record",
          stream_has_record(db, "tail") == 1);

    /* --- and it is still true after the file is closed -------------------- */
    check("close", cyboudb_close(db) == CybouDB_OK);
    check("reopen",
          cyboudb_open(argv[1], CybouDB_OPEN_READWRITE, &db) == CybouDB_OK);
    if (!db) return 2;
    check("the row survived", rows(db) == 1);
    check("the queue is still empty", queue_has_message(db) == 0);
    check("and the record is still waiting for its reader",
          stream_has_record(db, "tail") == 1);

    /* --- a statement that fails in the middle ----------------------------- */
    /* The seam a half-applied transaction would show. The INSERT names a
       table that is not there, so it fails after the queue and the stream
       have already been written to in this transaction. */
    check("a transaction that will not finish",
          cyboudb_exec(db, "BEGIN") == CybouDB_OK);
    check("enqueues",
          cyboudb_exec(db, "ENQUEUE INTO inbox VALUES ('second')")
              == CybouDB_OK);
    check("appends",
          cyboudb_exec(db, "APPEND TO audit VALUES ('about to fail')")
              == CybouDB_OK);
    check("and then asks for a table that does not exist",
          cyboudb_exec(db, "INSERT INTO nosuch VALUES (1, 'x')")
              != CybouDB_OK);
    check("so the caller takes it all back",
          cyboudb_exec(db, "ROLLBACK") == CybouDB_OK);
    check("leaving no message", queue_has_message(db) == 0);
    check("and the reader no further along than the commit left it",
          stream_has_record(db, "tail") == 1);

    check("close again", cyboudb_close(db) == CybouDB_OK);

    /* --- and the library can make a database of its own ------------------- */
    /* Until cyboudb_create existed, a caller of the library had to run the
       command line first to get a file to open, which is a strange thing to
       ask of an embedded engine. */
    {
        char made[1024];
        cyboudb_db *fresh = NULL;
        snprintf(made, sizeof made, "%s.created", argv[1]);
        remove(made);
        check("the library creates a database",
              cyboudb_create(made, 4000, &fresh) == CybouDB_OK && fresh != NULL);
        check("with every kind of object in it",
              cyboudb_exec(fresh, "CREATE TABLE t (a INT64)") == CybouDB_OK &&
              cyboudb_exec(fresh, "CREATE INDEX t_a ON t (a)") == CybouDB_OK &&
              cyboudb_exec(fresh, "CREATE QUEUE q") == CybouDB_OK &&
              cyboudb_exec(fresh, "CREATE STREAM s") == CybouDB_OK);
        check("and it is open read-write",
              cyboudb_exec(fresh, "INSERT INTO t VALUES (1)") == CybouDB_OK);
        check("closing it", cyboudb_close(fresh) == CybouDB_OK);

        fresh = NULL;
        check("a second create at the same path is refused rather than "
              "quietly replacing it",
              cyboudb_create(made, 4000, &fresh) != CybouDB_OK &&
              fresh == NULL);
        check("and what was there is still there",
              cyboudb_open(made, CybouDB_OPEN_READWRITE, &fresh)
                  == CybouDB_OK &&
              cyboudb_exec(fresh, "INSERT INTO t VALUES (2)") == CybouDB_OK);
        cyboudb_close(fresh);

        check("a create with nowhere to put the handle is refused",
              cyboudb_create(made, 4000, NULL) == CybouDB_MISUSE);
        check("and one with no path", cyboudb_create(NULL, 4000, &fresh)
              == CybouDB_MISUSE);
        remove(made);
    }

    printf("cross-primitive suite: %d passed, %d failed\n", checks - failures,
           failures);
    return failures ? 1 : 0;
}
