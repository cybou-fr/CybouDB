/* tests/stream_api_test.c - a stream through the C ABI.
 *
 * The statements reach the engine through the same sql_execute_batch the
 * command line and the console use, so what is worth testing here is not that
 * they work - it is the one thing this caller does differently. A READ answers
 * with a record, and a record is not a row: a stream holds bytes and no schema
 * to say how to read them, so there is no column to present it as.
 *
 * The vocabulary is the one a DEQUEUE already established. ROW when a record
 * came back, DONE when the reader has seen everything, and cyboudb_message for
 * the bytes. Stepping again asks again, because a stream a reader has caught
 * up with is not a result set that has run out - something may be appended.
 *
 * Usage: stream_api_test <database created with create-large>
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
    cyboudb_stmt *other = NULL;
    char buf[8192];
    uint64_t len = 0;
    int rc;

    if (argc < 2) {
        fprintf(stderr, "usage: stream_api_test <database>\n");
        return 2;
    }
    setvbuf(stdout, NULL, _IONBF, 0);
    if (cyboudb_open(argv[1], CybouDB_OPEN_READWRITE, &db) != CybouDB_OK) {
        fprintf(stderr, "open failed\n");
        return 2;
    }

    check("a stream", cyboudb_exec(db, "CREATE STREAM api_s") == CybouDB_OK);
    check("two records",
          cyboudb_exec(db, "APPEND TO api_s VALUES ('alpha')") == CybouDB_OK &&
          cyboudb_exec(db, "APPEND TO api_s VALUES ('beta')") == CybouDB_OK);
    check("and two readers",
          cyboudb_exec(db, "CREATE CURSOR one ON api_s") == CybouDB_OK &&
          cyboudb_exec(db, "CREATE CURSOR two ON api_s") == CybouDB_OK);

    check("a prepared READ",
          cyboudb_prepare(db, "READ FROM api_s AS one", &st) == CybouDB_OK &&
          st != NULL);
    if (!st) return 2;

    check("which has no result columns, because a record is not a row",
          cyboudb_column_count(st) == 0);

    rc = cyboudb_step(st);
    check("the first step answers ROW", rc == CybouDB_ROW);
    check("and hands back the oldest record",
          cyboudb_message(st, buf, sizeof buf, &len) == CybouDB_OK &&
          len == 5 && memcmp(buf, "alpha", 5) == 0);

    rc = cyboudb_step(st);
    check("the second step answers ROW", rc == CybouDB_ROW);
    check("with the next one",
          cyboudb_message(st, buf, sizeof buf, &len) == CybouDB_OK &&
          len == 4 && memcmp(buf, "beta", 4) == 0);

    rc = cyboudb_step(st);
    check("a reader that has seen everything answers DONE",
          rc == CybouDB_DONE);
    check("with nothing to read",
          cyboudb_message(st, buf, sizeof buf, &len) == CybouDB_MISUSE);

    /* Nothing was removed: the other reader still gets both. */
    check("a second prepared READ, for the other reader",
          cyboudb_prepare(db, "READ FROM api_s AS two", &other) == CybouDB_OK &&
          other != NULL);
    if (!other) return 2;
    check("which is given the first record, still there",
          cyboudb_step(other) == CybouDB_ROW &&
          cyboudb_message(other, buf, sizeof buf, &len) == CybouDB_OK &&
          len == 5 && memcmp(buf, "alpha", 5) == 0);
    check("finalize the second", cyboudb_finalize(other) == CybouDB_OK);

    /* A stream a reader has caught up with is not a result set that ran out. */
    check("another record",
          cyboudb_exec(db, "APPEND TO api_s VALUES ('gamma')") == CybouDB_OK);
    rc = cyboudb_step(st);
    check("stepping the same statement again asks again", rc == CybouDB_ROW);
    check("and is given it",
          cyboudb_message(st, buf, sizeof buf, &len) == CybouDB_OK &&
          len == 5 && memcmp(buf, "gamma", 5) == 0);

    /* A buffer that cannot hold the record is refused rather than filled. */
    check("a record longer than a slot",
          cyboudb_exec(db, "APPEND TO api_s VALUES ("
                           "'0123456789012345678901234567890123456789')")
          == CybouDB_OK);
    check("is read", cyboudb_step(st) == CybouDB_ROW);
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

    /* The rest of the statements, through the one implementation the CLI
       uses. The reader named `two` is still behind, which is what makes the
       trim refusal something this caller can see. */
    check("a trim that would pass a reader is refused",
          cyboudb_exec(db, "TRIM STREAM api_s BEFORE 3") != CybouDB_OK);
    check("dropping that reader",
          cyboudb_exec(db, "DROP CURSOR two ON api_s") == CybouDB_OK);
    check("after which the trim goes through",
          cyboudb_exec(db, "TRIM STREAM api_s BEFORE 3") == CybouDB_OK);
    check("a reader the stream does not have is refused",
          cyboudb_exec(db, "READ FROM api_s AS nobody") != CybouDB_OK);
    check("a stream that is dropped takes its pages with it",
          cyboudb_exec(db, "DROP STREAM api_s") == CybouDB_OK);
    check("and is gone",
          cyboudb_exec(db, "READ FROM api_s AS one") != CybouDB_OK);

    check("close", cyboudb_close(db) == CybouDB_OK);

    printf("stream API suite: %d passed, %d failed\n", checks - failures,
           failures);
    return failures ? 1 : 0;
}
