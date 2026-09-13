/* tests/queue_api_test.c - a queue through the C ABI.
 *
 * The statements reach the engine through the same sql_execute_batch the
 * command line and the console use, so what is worth testing here is not that
 * they work - it is the one thing this caller does differently. A DEQUEUE
 * answers with a message, and a message is not a row: a queue holds bytes and
 * no schema to say how to read them, so there is no column to present it as.
 *
 * The vocabulary is the one a step already has. ROW when a message came back,
 * DONE when the queue was empty, and cyboudb_message for the bytes. Stepping
 * again asks again, because a queue is not a result set that runs out.
 *
 * Usage: queue_api_test <database created with create-large>
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

int main(int argc, char **argv) {
    cyboudb_db *db = NULL;
    cyboudb_stmt *st = NULL;
    char buf[8192];
    uint64_t len = 0;
    int rc;

    if (argc < 2) {
        fprintf(stderr, "usage: queue_api_test <database>\n");
        return 2;
    }
    setvbuf(stdout, NULL, _IONBF, 0);
    if (cyboudb_open(argv[1], CybouDB_OPEN_READWRITE, &db) != CybouDB_OK) {
        fprintf(stderr, "open failed\n");
        return 2;
    }

    check("a queue", cyboudb_exec(db, "CREATE QUEUE api_q") == CybouDB_OK);
    check("two messages",
          cyboudb_exec(db, "ENQUEUE INTO api_q VALUES ('alpha')") == CybouDB_OK &&
          cyboudb_exec(db, "ENQUEUE INTO api_q VALUES ('beta')") == CybouDB_OK);

    check("a prepared DEQUEUE",
          cyboudb_prepare(db, "DEQUEUE FROM api_q", &st) == CybouDB_OK &&
          st != NULL);
    if (!st) return 2;

    check("which has no result columns, because a message is not a row",
          cyboudb_column_count(st) == 0);

    rc = cyboudb_step(st);
    check("the first step answers ROW", rc == CybouDB_ROW);
    check("and hands back what went in first",
          cyboudb_message(st, buf, sizeof buf, &len) == CybouDB_OK &&
          len == 5 && memcmp(buf, "alpha", 5) == 0);

    rc = cyboudb_step(st);
    check("the second step answers ROW", rc == CybouDB_ROW);
    check("with the second message",
          cyboudb_message(st, buf, sizeof buf, &len) == CybouDB_OK &&
          len == 4 && memcmp(buf, "beta", 4) == 0);

    rc = cyboudb_step(st);
    check("and an empty queue answers DONE", rc == CybouDB_DONE);
    check("with nothing to read",
          cyboudb_message(st, buf, sizeof buf, &len) == CybouDB_MISUSE);

    /* A queue is not a result set that runs out. */
    check("another message",
          cyboudb_exec(db, "ENQUEUE INTO api_q VALUES ('gamma')") == CybouDB_OK);
    rc = cyboudb_step(st);
    check("stepping the same statement again asks again", rc == CybouDB_ROW);
    check("and takes it",
          cyboudb_message(st, buf, sizeof buf, &len) == CybouDB_OK &&
          len == 5 && memcmp(buf, "gamma", 5) == 0);

    /* A buffer that cannot hold the message is refused rather than filled. */
    check("a message longer than a slot",
          cyboudb_exec(db, "ENQUEUE INTO api_q VALUES ("
                           "'0123456789012345678901234567890123456789')")
          == CybouDB_OK);
    check("is taken", cyboudb_step(st) == CybouDB_ROW);
    {
        char small[8];
        memset(small, '!', sizeof small);
        check("into a buffer too small: refused",
              cyboudb_message(st, small, sizeof small, &len) == CybouDB_MISUSE);
        check("and the buffer untouched", small[0] == '!');
        check("while a big enough one still gets it",
              cyboudb_message(st, buf, sizeof buf, &len) == CybouDB_OK &&
              len == 40 && buf[0] == '0' && buf[39] == '9');
    }

    check("finalize", cyboudb_finalize(st) == CybouDB_OK);

    /* What the other statements do through this caller, since they reach the
       engine through the one implementation the CLI uses. */
    check("enqueue and dequeue through exec, which returns no message",
          cyboudb_exec(db, "ENQUEUE INTO api_q VALUES ('through exec')")
          == CybouDB_OK);
    check("a queue that is dropped takes its pages with it",
          cyboudb_exec(db, "DROP QUEUE api_q") == CybouDB_OK);
    check("and is gone",
          cyboudb_exec(db, "DEQUEUE FROM api_q") != CybouDB_OK);

    check("close", cyboudb_close(db) == CybouDB_OK);

    printf("queue API suite: %d passed, %d failed\n", checks - failures,
           failures);
    return failures ? 1 : 0;
}
