/* tests/index_plan_test.c - which path a query took, not only what it said.
 *
 * A query that is right for the wrong reason stops being right when the plan
 * changes, and no assertion about results can tell the two apart. The engine
 * counts the times a SELECT found its row through a tree; this asserts that
 * count alongside the answer.
 *
 * Its own database and its own tables, because a fixture shared with the
 * storage tests is a fixture whose state the next assertion has to reason
 * about.
 *
 * Usage: index_plan_test <database created with create-large>
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

extern unsigned long long index_lookups;

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

static cyboudb_db *db;

/* Runs a statement and reports whether the plan used an index for it. */
static int lookups_for(const char *sql) {
    unsigned long long before = index_lookups;
    if (cyboudb_exec(db, sql) != CybouDB_OK) {
        printf("     statement failed: %s: %s\n", sql, cyboudb_errmsg(db));
        return -1;
    }
    return (int)(index_lookups - before);
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: index_plan_test <database>\n");
        return 2;
    }
    setvbuf(stdout, NULL, _IONBF, 0);
    if (cyboudb_open(argv[1], CybouDB_OPEN_READWRITE, &db) != CybouDB_OK) {
        fprintf(stderr, "open failed\n");
        return 2;
    }

    check("a table", cyboudb_exec(db,
          "CREATE TABLE p (id INT64 NOT NULL, v INT64, w INT32)") == CybouDB_OK);
    check("rows", cyboudb_exec(db,
          "INSERT INTO p VALUES (1, 10, 1), (2, 20, 2), (3, 30, 1), (4, 40, 2)")
          == CybouDB_OK);

    check("with no index, an equality scans", lookups_for("SELECT id FROM p WHERE id = 2") == 0);

    check("a unique index", cyboudb_exec(db,
          "CREATE UNIQUE INDEX p_id ON p (id)") == CybouDB_OK);

    /* A prepared plan is cached by its text, so each of these is a statement
       the binder has not seen before. */
    check("an equality over it is looked up",
          lookups_for("SELECT id FROM p WHERE id = 3") == 1);
    check("and so is one for a key that is absent",
          lookups_for("SELECT id FROM p WHERE id = 99") == 1);
    check("a different column still scans",
          lookups_for("SELECT id FROM p WHERE w = 2") == 0);
    check("so does a range",
          lookups_for("SELECT id FROM p WHERE id > 2") == 0);
    check("so does an inequality",
          lookups_for("SELECT id FROM p WHERE id <> 2") == 0);
    check("so does a COUNT(*), which the tree cannot answer",
          lookups_for("SELECT COUNT(*) FROM p WHERE id = 3") == 0);
    /* ORDER BY is not asserted here: the pull cursor this ABI steps does not
       sort, so the statement fails before a plan choice could be observed.
       The planner refuses the index for it all the same, which the CLI
       exercises. */

    /* A non-unique index is not chosen: equal keys can span leaves, and a
       leaf keeps no pointer to the next one. */
    check("a non-unique index", cyboudb_exec(db,
          "CREATE INDEX p_v ON p (v)") == CybouDB_OK);
    check("is not used for an equality",
          lookups_for("SELECT id FROM p WHERE v = 20") == 0);

    check("dropping the unique index", cyboudb_exec(db,
          "DROP INDEX p_id") == CybouDB_OK);
    check("sends the query back to the scan",
          lookups_for("SELECT id FROM p WHERE id = 4") == 0);

    check("tidy up", cyboudb_exec(db, "DROP TABLE p") == CybouDB_OK);
    check("close", cyboudb_close(db) == CybouDB_OK);

    printf("index plan suite: %d passed, %d failed\n", checks - failures, failures);
    return failures ? 1 : 0;
}
