/* tests/package_consumer.c - an application that has only the published package.
 *
 * Everything else in tests/ is built inside the repository, where the whole
 * source tree is on the include path and any header can be reached by accident.
 * This one is copied into a directory of its own along with exactly what a
 * release ships - `cyboudb.h` and the static library - and compiled there.
 *
 * What it catches is the case where the repository builds and the package does
 * not: a public header that includes a private one, a symbol the library needs
 * and does not export, a type that only exists in an internal `.inc`. None of
 * that shows up until someone outside the tree tries to link, and by then it is
 * in a release.
 *
 * So it deliberately uses only documented API, and does something end to end
 * rather than calling one function: make a database, write to every kind of
 * object in it, read the values back, and close it.
 *
 * It earned its place on its first run. `--c-tests` and `--lib` write the same
 * `build/cyboudb.lib`, and only the second is shippable: the first is built
 * with allocation injection and needs `cyboudb_test_mem_alloc` from whichever
 * test links it. Package whichever happened to be built last and the library
 * does not link for anybody. Build `--lib` immediately before packaging; this
 * is the check that says you did.
 *
 * SPDX-License-Identifier: Apache-2.0
 * Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
 */
#include <stdio.h>
#include <string.h>
#include "cyboudb.h"

#define FAIL(what) do { printf("FAIL %s\n", what); return 1; } while (0)

int main(void) {
    cyboudb_db *db = NULL;
    cyboudb_stmt *st = NULL;
    char buf[256];
    uint64_t len = 0;
    long long rows = -1;

    printf("CybouDB %s (%d.%d.%d)\n", CybouDB_VERSION,
           CybouDB_VERSION_MAJOR, CybouDB_VERSION_MINOR,
           CybouDB_VERSION_PATCH);

    remove("consumer.cdb");
    if (cyboudb_create("consumer.cdb", 512, &db) != CybouDB_OK || !db)
        FAIL("cyboudb_create");

    if (cyboudb_exec(db, "CREATE TABLE t (id INT64, note TEXT)") != CybouDB_OK)
        FAIL("CREATE TABLE");
    if (cyboudb_exec(db, "CREATE INDEX t_id ON t (id)") != CybouDB_OK)
        FAIL("CREATE INDEX");
    if (cyboudb_exec(db, "CREATE QUEUE q") != CybouDB_OK)
        FAIL("CREATE QUEUE");
    if (cyboudb_exec(db, "CREATE STREAM s") != CybouDB_OK)
        FAIL("CREATE STREAM");
    if (cyboudb_exec(db, "CREATE CURSOR c ON s") != CybouDB_OK)
        FAIL("CREATE CURSOR");

    /* One transaction over all of them, which is the thing worth shipping. */
    if (cyboudb_exec(db, "BEGIN") != CybouDB_OK) FAIL("BEGIN");
    if (cyboudb_exec(db, "ENQUEUE INTO q VALUES ('job')") != CybouDB_OK)
        FAIL("ENQUEUE");
    if (cyboudb_exec(db, "INSERT INTO t VALUES (1, 'hello')") != CybouDB_OK)
        FAIL("INSERT");
    if (cyboudb_exec(db, "APPEND TO s VALUES ('event')") != CybouDB_OK)
        FAIL("APPEND");
    if (cyboudb_exec(db, "COMMIT") != CybouDB_OK) FAIL("COMMIT");

    if (cyboudb_prepare(db, "SELECT COUNT(*) FROM t", &st) != CybouDB_OK)
        FAIL("prepare SELECT");
    if (cyboudb_step(st) != CybouDB_ROW) FAIL("step SELECT");
    rows = (long long)cyboudb_column_int64(st, 0);
    cyboudb_finalize(st);
    if (rows != 1) FAIL("row count");

    if (cyboudb_prepare(db, "SELECT note FROM t WHERE id = 1", &st)
            != CybouDB_OK) FAIL("prepare index lookup");
    if (cyboudb_step(st) != CybouDB_ROW) FAIL("step index lookup");
    if (cyboudb_column_bytes(st, 0, buf, sizeof buf, &len) != CybouDB_OK
        || len != 5 || memcmp(buf, "hello", 5) != 0) FAIL("TEXT value");
    cyboudb_finalize(st);

    if (cyboudb_prepare(db, "DEQUEUE FROM q", &st) != CybouDB_OK)
        FAIL("prepare DEQUEUE");
    if (cyboudb_step(st) != CybouDB_ROW) FAIL("step DEQUEUE");
    if (cyboudb_message(st, buf, sizeof buf, &len) != CybouDB_OK
        || len != 3 || memcmp(buf, "job", 3) != 0) FAIL("message");
    cyboudb_finalize(st);

    if (cyboudb_prepare(db, "READ FROM s AS c", &st) != CybouDB_OK)
        FAIL("prepare READ");
    if (cyboudb_step(st) != CybouDB_ROW) FAIL("step READ");
    if (cyboudb_message(st, buf, sizeof buf, &len) != CybouDB_OK
        || len != 5 || memcmp(buf, "event", 5) != 0) FAIL("record");
    cyboudb_finalize(st);

    if (cyboudb_close(db) != CybouDB_OK) FAIL("close");
    remove("consumer.cdb");

    printf("ok   an application built against only the published package\n");
    return 0;
}
