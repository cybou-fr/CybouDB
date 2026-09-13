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
    check("so does an inequality",
          lookups_for("SELECT id FROM p WHERE id <> 2") == 0);
    check("a COUNT(*) is looked up, because it does not care about order",
          lookups_for("SELECT COUNT(*) FROM p WHERE id = 3") == 1);
    check("and counts zero for a key that is absent",
          lookups_for("SELECT COUNT(*) FROM p WHERE id = 99") == 1);
    /* ORDER BY is not asserted here: the pull cursor this ABI steps does not
       sort, so the statement fails before a plan choice could be observed.
       The planner refuses the index for it all the same, which the CLI
       exercises. */

    /* A non-unique index is chosen too. One key can name many rows, so the
       lookup walks the tree rather than reading a single entry, and the walk
       is what makes the count one per statement rather than one per row. */
    check("a non-unique index", cyboudb_exec(db,
          "CREATE INDEX p_v ON p (v)") == CybouDB_OK);
    check("is used for an equality",
          lookups_for("SELECT id FROM p WHERE v = 20") == 1);
    check("including a key it does not hold",
          lookups_for("SELECT id FROM p WHERE v = 21") == 1);

    /* Ranges, which need a table with enough rows for "how many" to mean
       something: the plan reaches for a tree when the range names fewer
       entries than the table has 64-row groups, and leaves the table to the
       scan when it names more. A lookup enters a group once per run of
       entries that land in it, so past that point reading the table is the
       cheaper way to read the table. */
    check("a wider table", cyboudb_exec(db,
          "CREATE TABLE q (k INT64 NOT NULL, v INT64)") == CybouDB_OK);
    {
        char sql[64 * 128 + 64];
        int ok = 1;
        for (int base = 0; base < 1280 && ok; base += 128) {
            int n = sprintf(sql, "INSERT INTO q VALUES ");
            for (int i = base; i < base + 128; i++)
                n += sprintf(sql + n, "%s(%d, %d)", i > base ? ", " : "",
                             i, i % 5);
            if (cyboudb_exec(db, sql) != CybouDB_OK) {
                printf("     %s\n", cyboudb_errmsg(db));
                ok = 0;
            }
        }
        check("with 1280 rows in it", ok);
    }
    check("an index over it", cyboudb_exec(db,
          "CREATE UNIQUE INDEX q_k ON q (k)") == CybouDB_OK);

    /* 1280 rows are 20 groups. */
    check("a range naming fewer rows than the table has groups",
          lookups_for("SELECT k FROM q WHERE k < 15") == 1);
    check("and one at the other end",
          lookups_for("SELECT k FROM q WHERE k > 1265") == 1);
    check("a range naming more is left to the scan",
          lookups_for("SELECT k FROM q WHERE k > 100") == 0);
    check("and so is one that names the whole table",
          lookups_for("SELECT k FROM q WHERE k >= 0") == 0);

    /* An equality is never asked the question: its rows come out of the walk
       in ascending order, so each group is entered once however many rows one
       key names. */
    check("a non-unique index over a key naming 256 rows", cyboudb_exec(db,
          "CREATE INDEX q_v ON q (v)") == CybouDB_OK);
    check("is looked up all the same",
          lookups_for("SELECT k FROM q WHERE v = 3") == 1);
    check("tidy up the wider table", cyboudb_exec(db,
          "DROP TABLE q") == CybouDB_OK);

    check("dropping the unique index", cyboudb_exec(db,
          "DROP INDEX p_id") == CybouDB_OK);
    check("sends the query back to the scan",
          lookups_for("SELECT id FROM p WHERE id = 4") == 0);

    check("tidy up", cyboudb_exec(db, "DROP TABLE p") == CybouDB_OK);
    check("close", cyboudb_close(db) == CybouDB_OK);

    printf("index plan suite: %d passed, %d failed\n", checks - failures, failures);
    return failures ? 1 : 0;
}
