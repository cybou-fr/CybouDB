/* tests/prepared_rerun_test.c - a prepared mutation, executed more than once.
 *
 * `cyboudb_reset` exists so that a prepared statement can be run again, and the
 * header says so. That makes the bound plan a thing execution may read and must
 * not change - and for a long time it changed it.
 *
 * An INSERT carrying a TEXT, BLOB or VECTOR literal keeps a pointer to the
 * literal's bytes in its batch. Materialising the cell wrote that cell's extent
 * root over the pointer, which is correct exactly once: the second execution
 * read a page id as an address and the process died inside db_var_write_chain.
 * An INT-only INSERT was unaffected, which is why nothing caught it - no test
 * re-ran a prepared mutation after executing one.
 *
 * So this file is about the class rather than the crash. Every mutating
 * statement that can be prepared is executed, reset and executed again, and
 * what is checked is not that it survives but that the rows it wrote the second
 * time are the rows it wrote the first time. A plan that quietly produced
 * different bytes on its second run would be worse than one that crashed.
 *
 * Usage: prepared_rerun_test <database created with create-large>
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

/* Run a prepared statement `times` times, resetting between. */
static int run_times(cyboudb_db *db, const char *sql, int times, int expect) {
    cyboudb_stmt *st = NULL;
    int i, rc, ok = 1;
    if (cyboudb_prepare(db, sql, &st) != CybouDB_OK || !st) return 0;
    for (i = 0; i < times; i++) {
        rc = cyboudb_step(st);
        if (rc != expect) ok = 0;
        if (cyboudb_reset(st) != CybouDB_OK) ok = 0;
    }
    cyboudb_finalize(st);
    (void)db;
    return ok;
}

static long long count(cyboudb_db *db, const char *sql) {
    cyboudb_stmt *st = NULL;
    long long n = -1;
    if (cyboudb_prepare(db, sql, &st) != CybouDB_OK) return -1;
    if (cyboudb_step(st) == CybouDB_ROW) n = cyboudb_column_int64(st, 0);
    cyboudb_finalize(st);
    return n;
}

/* Every row's TEXT cell, checked against what the statement wrote. A second
   execution that produced a different string - or an unreadable one - is the
   failure this is for, and it would not show up as a crash. */
static int every_text_is(cyboudb_db *db, const char *sql, const char *want,
                         int rows) {
    cyboudb_stmt *st = NULL;
    char buf[512];
    int seen = 0, ok = 1;
    uint64_t len = 0;
    size_t want_len = strlen(want);
    if (cyboudb_prepare(db, sql, &st) != CybouDB_OK) return 0;
    while (cyboudb_step(st) == CybouDB_ROW) {
        seen++;
        if (cyboudb_column_bytes(st, 0, buf, sizeof buf, &len) != CybouDB_OK
            || len != want_len || memcmp(buf, want, want_len) != 0) {
            ok = 0;
        }
    }
    cyboudb_finalize(st);
    return ok && seen == rows;
}

int main(int argc, char **argv) {
    cyboudb_db *db = NULL;
    cyboudb_stmt *st = NULL;
    int i;

    if (argc < 2) {
        fprintf(stderr, "usage: prepared_rerun_test <database>\n");
        return 2;
    }
    setvbuf(stdout, NULL, _IONBF, 0);
    if (cyboudb_open(argv[1], CybouDB_OPEN_READWRITE, &db) != CybouDB_OK) {
        fprintf(stderr, "open failed\n");
        return 2;
    }

    check("a table of each kind a cell can be",
          cyboudb_exec(db, "CREATE TABLE ints (a INT64, b INT64)") == CybouDB_OK &&
          cyboudb_exec(db, "CREATE TABLE texts (a INT64, t TEXT)") == CybouDB_OK &&
          cyboudb_exec(db, "CREATE TABLE blobs (a INT64, t BLOB)") == CybouDB_OK &&
          cyboudb_exec(db, "CREATE TABLE vecs (a INT64, e VECTOR(FLOAT32, 3))")
              == CybouDB_OK &&
          cyboudb_exec(db, "CREATE TABLE nulls (a INT64, t TEXT)") == CybouDB_OK &&
          cyboudb_exec(db, "CREATE TABLE empties (a INT64, t TEXT)") == CybouDB_OK &&
          cyboudb_exec(db, "CREATE TABLE multi (a INT64, t TEXT)") == CybouDB_OK);

    /* --- the four cell kinds, three executions each ----------------------- */
    check("INT64 cells: three executions",
          run_times(db, "INSERT INTO ints VALUES (1, 2)", 3, CybouDB_DONE));
    check("and three rows are there", count(db, "SELECT COUNT(*) FROM ints") == 3);

    check("TEXT cells: three executions",
          run_times(db, "INSERT INTO texts VALUES (1, 'hello')", 3,
                    CybouDB_DONE));
    check("and three rows are there",
          count(db, "SELECT COUNT(*) FROM texts") == 3);
    check("each of them readable, and each of them the same string",
          every_text_is(db, "SELECT t FROM texts", "hello", 3));

    check("BLOB cells: three executions",
          run_times(db, "INSERT INTO blobs VALUES (1, X'41424344')", 3,
                    CybouDB_DONE));
    check("and three rows are there",
          count(db, "SELECT COUNT(*) FROM blobs") == 3);
    check("each of them the same four bytes",
          every_text_is(db, "SELECT t FROM blobs", "ABCD", 3));

    check("VECTOR cells: three executions",
          run_times(db, "INSERT INTO vecs VALUES (1, [1.0, 2.0, 3.0])", 3,
                    CybouDB_DONE));
    check("and three rows are there", count(db, "SELECT COUNT(*) FROM vecs") == 3);
    {
        float out[3];
        uint64_t dims = 0;
        int good = 0, seen = 0;
        if (cyboudb_prepare(db, "SELECT e FROM vecs", &st) == CybouDB_OK) {
            while (cyboudb_step(st) == CybouDB_ROW) {
                seen++;
                if (cyboudb_column_vector_f32(st, 0, out, 3, &dims)
                        == CybouDB_OK && dims == 3 &&
                    out[0] == 1.0f && out[1] == 2.0f && out[2] == 3.0f) good++;
            }
            cyboudb_finalize(st);
        }
        check("each of them the same three floats", seen == 3 && good == 3);
    }

    /* --- the shapes around a varlen cell ---------------------------------- */
    check("a NULL varlen cell: three executions",
          run_times(db, "INSERT INTO nulls VALUES (1, NULL)", 3, CybouDB_DONE));
    check("and three rows are there",
          count(db, "SELECT COUNT(*) FROM nulls") == 3);

    check("an empty varlen cell: three executions",
          run_times(db, "INSERT INTO empties VALUES (1, '')", 3, CybouDB_DONE));
    check("and three rows are there",
          count(db, "SELECT COUNT(*) FROM empties") == 3);
    check("each of them still empty",
          every_text_is(db, "SELECT t FROM empties", "", 3));

    check("a multi-row INSERT of varlen cells: three executions",
          run_times(db, "INSERT INTO multi VALUES (1, 'aaa'), (2, 'aaa'), "
                        "(3, 'aaa')", 3, CybouDB_DONE));
    check("and nine rows are there",
          count(db, "SELECT COUNT(*) FROM multi") == 9);
    check("every one of them readable",
          every_text_is(db, "SELECT t FROM multi", "aaa", 9));

    /* --- inside a transaction, and after a rollback ------------------------ */
    check("in an explicit transaction: three executions",
          cyboudb_exec(db, "BEGIN") == CybouDB_OK &&
          run_times(db, "INSERT INTO texts VALUES (2, 'inside')", 3,
                    CybouDB_DONE) &&
          cyboudb_exec(db, "COMMIT") == CybouDB_OK);
    check("which added three more rows",
          count(db, "SELECT COUNT(*) FROM texts") == 6);

    /* A rolled back execution must leave the plan usable: the pointers it
       carried are the binder's, and a rollback does not give them back. */
    check("a prepared statement survives a rollback of its own work",
          cyboudb_prepare(db, "INSERT INTO texts VALUES (3, 'undone')", &st)
              == CybouDB_OK);
    if (st) {
        check("begin, step, rollback",
              cyboudb_exec(db, "BEGIN") == CybouDB_OK &&
              cyboudb_step(st) == CybouDB_DONE &&
              cyboudb_reset(st) == CybouDB_OK &&
              cyboudb_exec(db, "ROLLBACK") == CybouDB_OK);
        check("the row is not there",
              count(db, "SELECT COUNT(*) FROM texts") == 6);
        check("and the same statement runs again afterwards",
              cyboudb_step(st) == CybouDB_DONE);
        cyboudb_reset(st);
        cyboudb_finalize(st);
        check("adding the row this time",
              count(db, "SELECT COUNT(*) FROM texts") == 7);
    }

    /* --- the other prepared mutations ------------------------------------- */
    check("a queue and a stream to mutate",
          cyboudb_exec(db, "CREATE QUEUE q") == CybouDB_OK &&
          cyboudb_exec(db, "CREATE STREAM s") == CybouDB_OK &&
          cyboudb_exec(db, "CREATE CURSOR c ON s") == CybouDB_OK);

    check("ENQUEUE: three executions",
          run_times(db, "ENQUEUE INTO q VALUES ('message')", 3, CybouDB_DONE));
    check("APPEND: three executions",
          run_times(db, "APPEND TO s VALUES ('record')", 3, CybouDB_DONE));

    {
        char buf[256];
        uint64_t len = 0;
        int good = 0;
        if (cyboudb_prepare(db, "DEQUEUE FROM q", &st) == CybouDB_OK) {
            for (i = 0; i < 3; i++) {
                if (cyboudb_step(st) == CybouDB_ROW &&
                    cyboudb_message(st, buf, sizeof buf, &len) == CybouDB_OK &&
                    len == 7 && memcmp(buf, "message", 7) == 0) good++;
                cyboudb_reset(st);
            }
            cyboudb_finalize(st);
        }
        check("all three messages come back whole", good == 3);

        good = 0;
        if (cyboudb_prepare(db, "READ FROM s AS c", &st) == CybouDB_OK) {
            for (i = 0; i < 3; i++) {
                if (cyboudb_step(st) == CybouDB_ROW &&
                    cyboudb_message(st, buf, sizeof buf, &len) == CybouDB_OK &&
                    len == 6 && memcmp(buf, "record", 6) == 0) good++;
                cyboudb_reset(st);
            }
            cyboudb_finalize(st);
        }
        check("and all three records", good == 3);
    }

    check("UPDATE: three executions",
          run_times(db, "UPDATE ints SET b = 9 WHERE a = 1", 3, CybouDB_DONE));
    check("DELETE: three executions leave nothing behind",
          run_times(db, "DELETE FROM ints WHERE b = 9", 3, CybouDB_DONE) &&
          count(db, "SELECT COUNT(*) FROM ints") == 0);

    /* --- a plan whose table changed shape between two executions ---------- */
    /* The binder caches the address of the schema page, and copy-on-write
       moves that page whenever the catalog is written. An UPDATE that trusted
       the cached address read the row count the table had at prepare time and
       sized its scratch from it: the statement still reported success and
       still changed rows, just not all of the ones it matched. A wrong answer
       that says DONE is worse than a crash, so it is worth its own case. */
    check("a table to grow under a prepared statement",
          cyboudb_exec(db, "CREATE TABLE grow (a INT64, b INT64)") == CybouDB_OK);
    for (i = 0; i < 5; i++) {
        if (cyboudb_exec(db, "INSERT INTO grow VALUES (2, 0)") != CybouDB_OK)
            break;
    }
    check("five rows in it", count(db, "SELECT COUNT(*) FROM grow") == 5);
    check("a prepared UPDATE over it",
          cyboudb_prepare(db, "UPDATE grow SET b = 9 WHERE a = 2", &st)
              == CybouDB_OK);
    if (st) {
        check("which runs once", cyboudb_step(st) == CybouDB_DONE &&
              cyboudb_reset(st) == CybouDB_OK);
        check("and changed all five",
              count(db, "SELECT COUNT(*) FROM grow WHERE b = 9") == 5);
        for (i = 0; i < 200; i++) {
            if (cyboudb_exec(db, "INSERT INTO grow VALUES (2, 0)") != CybouDB_OK)
                break;
        }
        check("two hundred more rows arrive",
              count(db, "SELECT COUNT(*) FROM grow") == 205);
        check("the same statement runs again",
              cyboudb_step(st) == CybouDB_DONE);
        cyboudb_reset(st);
        cyboudb_finalize(st);
        check("and changed every row it matched, not the number the table "
              "had when it was prepared",
              count(db, "SELECT COUNT(*) FROM grow WHERE b = 9") == 205);
    }

    check("the file is still coherent", cyboudb_close(db) == CybouDB_OK);

    printf("prepared re-run suite: %d passed, %d failed\n", checks - failures,
           failures);
    return failures ? 1 : 0;
}
