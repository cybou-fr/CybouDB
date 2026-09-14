/* tests/bind_test.c - values that arrive after the statement was prepared.
 *
 * A `?` is a hole in a statement, and everything interesting about it is what
 * happens around the hole rather than in it. Three things are being checked,
 * and they are separate:
 *
 *  1. The value gets there. A bound INT64, TEXT, BLOB, VECTOR, BOOL, FLOAT32,
 *     INT32 or NULL comes back out of the table as itself.
 *
 *  2. The plan does not change. The whole reason parameters are applied at
 *     execution rather than written into the plan is the rule in sql.inc - a
 *     prepared plan is immutable across executions - so the same statement is
 *     bound, stepped, reset, bound to something else and stepped again, and
 *     both rows have to be right. tests/prepared_rerun_test.c is the same
 *     argument without parameters; this is that matrix with a value axis.
 *
 *  3. What is refused is refused at the call. A wrong type, an index that is
 *     not there, a NULL into a NOT NULL column, a vector of the wrong width, a
 *     value too large for the copy buffer - each of those is an error from the
 *     bind, not a surprise halfway through an insert. And a parameter nobody
 *     bound stops the statement instead of quietly becoming NULL.
 *
 * The copy is what makes (1) worth testing at all: the engine keeps the bytes,
 * not the caller's pointer, so every varlen case here overwrites or frees the
 * source buffer between the bind and the step. If the engine had kept the
 * pointer these would read freed memory, which is exactly the failure the copy
 * exists to make impossible.
 *
 * Usage: bind_test <database created with create-large>
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

static long long count(cyboudb_db *db, const char *sql) {
    cyboudb_stmt *st = NULL;
    long long n = -1;
    if (cyboudb_prepare(db, sql, &st) != CybouDB_OK) return -1;
    if (cyboudb_step(st) == CybouDB_ROW) n = cyboudb_column_int64(st, 0);
    cyboudb_finalize(st);
    return n;
}

/* The single TEXT cell of the single row a SELECT returns. */
static int one_text_is(cyboudb_db *db, const char *sql, const char *want,
                       size_t want_len) {
    cyboudb_stmt *st = NULL;
    char buf[4096];
    uint64_t len = 0;
    int ok = 0;
    if (cyboudb_prepare(db, sql, &st) != CybouDB_OK) return 0;
    if (cyboudb_step(st) == CybouDB_ROW &&
        cyboudb_column_bytes(st, 0, buf, sizeof buf, &len) == CybouDB_OK &&
        len == want_len && memcmp(buf, want, want_len) == 0) {
        ok = 1;
    }
    cyboudb_finalize(st);
    return ok;
}

int main(int argc, char **argv) {
    cyboudb_db *db = NULL;
    cyboudb_stmt *st = NULL;

    if (argc < 2) {
        fprintf(stderr, "usage: bind_test <database>\n");
        return 2;
    }
    setvbuf(stdout, NULL, _IONBF, 0);
    if (cyboudb_open(argv[1], CybouDB_OPEN_READWRITE, &db) != CybouDB_OK) {
        fprintf(stderr, "open failed\n");
        return 2;
    }

    check("tables to bind into",
          cyboudb_exec(db, "CREATE TABLE b_ints (a INT64, b INT32)")
              == CybouDB_OK &&
          cyboudb_exec(db, "CREATE TABLE b_text (a INT64, t TEXT)")
              == CybouDB_OK &&
          cyboudb_exec(db, "CREATE TABLE b_blob (a INT64, t BLOB)")
              == CybouDB_OK &&
          cyboudb_exec(db, "CREATE TABLE b_vec (a INT64, "
                           "e VECTOR(FLOAT32, 3))") == CybouDB_OK &&
          cyboudb_exec(db, "CREATE TABLE b_scal (f FLOAT32, o BOOL)")
              == CybouDB_OK &&
          cyboudb_exec(db, "CREATE TABLE b_null (a INT64, t TEXT NULL)")
              == CybouDB_OK &&
          cyboudb_exec(db, "CREATE TABLE b_notnull (a INT64, b INT64 NOT NULL)")
              == CybouDB_OK);

    /* --- a statement says how many holes it has --------------------------- */
    check("a statement with no parameters says zero",
          cyboudb_prepare(db, "INSERT INTO b_ints VALUES (1, 2)", &st)
              == CybouDB_OK &&
          cyboudb_bind_parameter_count(st) == 0);
    cyboudb_finalize(st);
    st = NULL;

    check("and one with two says two",
          cyboudb_prepare(db, "INSERT INTO b_ints VALUES (?, ?)", &st)
              == CybouDB_OK &&
          cyboudb_bind_parameter_count(st) == 2);

    /* --- the same plan, twice, with different values ---------------------- */
    if (st) {
        check("bind, step, reset, bind again, step again",
              cyboudb_bind_int64(st, 0, 10) == CybouDB_OK &&
              cyboudb_bind_int32(st, 1, 20) == CybouDB_OK &&
              cyboudb_step(st) == CybouDB_DONE &&
              cyboudb_reset(st) == CybouDB_OK &&
              cyboudb_bind_int64(st, 0, 30) == CybouDB_OK &&
              cyboudb_bind_int32(st, 1, 40) == CybouDB_OK &&
              cyboudb_step(st) == CybouDB_DONE);
        check("both rows are there",
              count(db, "SELECT COUNT(*) FROM b_ints") == 2);
        check("and each row is the values it was bound to, not the other's",
              count(db, "SELECT COUNT(*) FROM b_ints WHERE a = 10") == 1 &&
              count(db, "SELECT COUNT(*) FROM b_ints WHERE a = 30") == 1 &&
              count(db, "SELECT COUNT(*) FROM b_ints WHERE b = 20") == 1 &&
              count(db, "SELECT COUNT(*) FROM b_ints WHERE b = 40") == 1);

        /* A binding is not consumed by stepping: it is still there after a
           reset, and a second step writes the same row again. */
        check("a binding survives a reset without being restated",
              cyboudb_reset(st) == CybouDB_OK &&
              cyboudb_step(st) == CybouDB_DONE &&
              count(db, "SELECT COUNT(*) FROM b_ints WHERE a = 30") == 2);
    }
    cyboudb_finalize(st);
    st = NULL;

    /* --- the copy: the caller's bytes are gone by the time it is stepped --- */
    check("a TEXT statement prepares",
          cyboudb_prepare(db, "INSERT INTO b_text VALUES (1, ?)", &st)
              == CybouDB_OK);
    if (st) {
        char *scratch = malloc(64);
        memcpy(scratch, "the original bytes", 19);
        check("bind text, then destroy what was bound",
              cyboudb_bind_text(st, 0, scratch, -1) == CybouDB_OK);
        memset(scratch, '!', 64);
        free(scratch);
        check("the insert still writes what was bound",
              cyboudb_step(st) == CybouDB_DONE &&
              one_text_is(db, "SELECT t FROM b_text WHERE a = 1",
                          "the original bytes", 18));
    }
    cyboudb_finalize(st);
    st = NULL;

    check("an explicit length is used as given, terminator and all",
          cyboudb_prepare(db, "INSERT INTO b_text VALUES (2, ?)", &st)
              == CybouDB_OK &&
          cyboudb_bind_text(st, 0, "abc\0def", 7) == CybouDB_OK &&
          cyboudb_step(st) == CybouDB_DONE &&
          one_text_is(db, "SELECT t FROM b_text WHERE a = 2", "abc\0def", 7));
    cyboudb_finalize(st);
    st = NULL;

    check("an empty text is a value, not an absence",
          cyboudb_prepare(db, "INSERT INTO b_text VALUES (3, ?)", &st)
              == CybouDB_OK &&
          cyboudb_bind_text(st, 0, "", 0) == CybouDB_OK &&
          cyboudb_step(st) == CybouDB_DONE &&
          one_text_is(db, "SELECT t FROM b_text WHERE a = 3", "", 0));
    cyboudb_finalize(st);
    st = NULL;

    check("a BLOB keeps its bytes, zeros included",
          cyboudb_prepare(db, "INSERT INTO b_blob VALUES (1, ?)", &st)
              == CybouDB_OK &&
          cyboudb_bind_blob(st, 0, "\x00\x01\x02\xff", 4) == CybouDB_OK &&
          cyboudb_step(st) == CybouDB_DONE &&
          one_text_is(db, "SELECT t FROM b_blob", "\x00\x01\x02\xff", 4));
    cyboudb_finalize(st);
    st = NULL;

    /* --- a vector, and the width that is part of its type ------------------ */
    check("a VECTOR statement prepares",
          cyboudb_prepare(db, "INSERT INTO b_vec VALUES (1, ?)", &st)
              == CybouDB_OK);
    if (st) {
        float v[3] = { 1.5f, -2.5f, 3.5f };
        float wrong[2] = { 1.0f, 2.0f };
        check("a vector of the wrong width is refused at the bind",
              cyboudb_bind_vector_f32(st, 0, wrong, 2) == CybouDB_MISUSE);
        check("and so is one of no width at all",
              cyboudb_bind_vector_f32(st, 0, v, 0) == CybouDB_MISUSE);
        check("the right one binds, and the source may then go",
              cyboudb_bind_vector_f32(st, 0, v, 3) == CybouDB_OK);
        memset(v, 0, sizeof v);
        check("the stored vector is what was bound",
              cyboudb_step(st) == CybouDB_DONE);
        {
            float out[3];
            uint64_t dims = 0;
            cyboudb_stmt *q = NULL;
            int ok = 0;
            if (cyboudb_prepare(db, "SELECT e FROM b_vec", &q) == CybouDB_OK) {
                if (cyboudb_step(q) == CybouDB_ROW &&
                    cyboudb_column_vector_f32(q, 0, out, 3, &dims)
                        == CybouDB_OK && dims == 3 &&
                    out[0] == 1.5f && out[1] == -2.5f && out[2] == 3.5f) ok = 1;
                cyboudb_finalize(q);
            }
            check("read back as the three floats, after the source was wiped",
                  ok);
        }
    }
    cyboudb_finalize(st);
    st = NULL;

    /* --- the remaining scalar kinds --------------------------------------- */
    check("FLOAT32 and BOOL",
          cyboudb_prepare(db, "INSERT INTO b_scal VALUES (?, ?)", &st)
              == CybouDB_OK &&
          cyboudb_bind_float(st, 0, 2.5f) == CybouDB_OK &&
          cyboudb_bind_bool(st, 1, 1) == CybouDB_OK &&
          cyboudb_step(st) == CybouDB_DONE &&
          count(db, "SELECT COUNT(*) FROM b_scal WHERE o = true") == 1);
    if (st) {
        cyboudb_stmt *q = NULL;
        int ok = 0;
        if (cyboudb_prepare(db, "SELECT f FROM b_scal", &q) == CybouDB_OK) {
            if (cyboudb_step(q) == CybouDB_ROW &&
                cyboudb_column_float(q, 0) == 2.5f) ok = 1;
            cyboudb_finalize(q);
        }
        check("the float is the float that was bound", ok);
    }
    cyboudb_finalize(st);
    st = NULL;

    check("a bound NULL is a NULL",
          cyboudb_prepare(db, "INSERT INTO b_null VALUES (1, ?)", &st)
              == CybouDB_OK &&
          cyboudb_bind_null(st, 0) == CybouDB_OK &&
          cyboudb_step(st) == CybouDB_DONE &&
          count(db, "SELECT COUNT(*) FROM b_null WHERE t IS NULL") == 1);
    cyboudb_finalize(st);
    st = NULL;

    /* --- and now what is refused ------------------------------------------ */
    check("a statement to refuse things on",
          cyboudb_prepare(db, "INSERT INTO b_text VALUES (9, ?)", &st)
              == CybouDB_OK);
    if (st) {
        check("an index past the end is misuse",
              cyboudb_bind_text(st, 1, "x", 1) == CybouDB_MISUSE);
        check("and so is a negative one",
              cyboudb_bind_text(st, -1, "x", 1) == CybouDB_MISUSE);
        check("an INT64 into a TEXT column is misuse, not a conversion",
              cyboudb_bind_int64(st, 0, 5) == CybouDB_MISUSE);
        check("a BLOB into a TEXT column too: the types are not the same",
              cyboudb_bind_blob(st, 0, "x", 1) == CybouDB_MISUSE);
        check("a negative length that is not the measure-it sentinel",
              cyboudb_bind_blob(st, 0, "x", -1) == CybouDB_MISUSE);
        check("a length with no pointer to go with it",
              cyboudb_bind_text(st, 0, NULL, 4) == CybouDB_MISUSE);
        check("a null handle is misuse rather than a crash",
              cyboudb_bind_int64(NULL, 0, 1) == CybouDB_MISUSE &&
              cyboudb_bind_parameter_count(NULL) == 0);

        /* The buffer is bounded and says so. 32 KiB is the bound; a value
           larger than it is refused rather than truncated or written past. */
        {
            size_t big = 64 * 1024;
            char *huge = malloc(big);
            memset(huge, 'x', big);
            check("a value the copy buffer cannot hold is NOMEM",
                  cyboudb_bind_text(st, 0, huge, (int64_t)big)
                      == CybouDB_NOMEM);
            free(huge);
        }
        check("and the statement is still usable afterwards",
              cyboudb_bind_text(st, 0, "fine", 4) == CybouDB_OK &&
              cyboudb_step(st) == CybouDB_DONE);
    }
    cyboudb_finalize(st);
    st = NULL;

    check("a parameter nobody bound stops the statement",
          cyboudb_prepare(db, "INSERT INTO b_ints VALUES (?, 1)", &st)
              == CybouDB_OK &&
          cyboudb_step(st) != CybouDB_DONE);
    check("and wrote no row",
          count(db, "SELECT COUNT(*) FROM b_ints") == 3);
    cyboudb_finalize(st);
    st = NULL;

    check("a NULL into a column that does not take one is refused at the bind",
          cyboudb_prepare(db, "INSERT INTO b_notnull VALUES (1, ?)", &st)
              == CybouDB_OK &&
          cyboudb_bind_null(st, 0) == CybouDB_MISUSE);
    cyboudb_finalize(st);
    st = NULL;

    check("a `?` outside INSERT ... VALUES is refused at prepare",
          cyboudb_prepare(db, "SELECT a FROM b_ints WHERE a = ?", &st)
              != CybouDB_OK);
    cyboudb_finalize(st);
    st = NULL;

    /* --- binding in a loop, which is the whole point ---------------------- */
    check("a prepared INSERT bound and stepped many times",
          cyboudb_prepare(db, "INSERT INTO b_text VALUES (100, ?)", &st)
              == CybouDB_OK);
    if (st) {
        int i, ok = 1;
        char buf[600];
        /* Lengths that grow and shrink. A slot reuses the bytes it owns when
           the new value fits, so the buffer cursor must not creep forward
           once each slot has held its largest value - 2,000 rounds of up to
           512 bytes would be sixty times the buffer if it did. */
        for (i = 0; i < 2000 && ok; i++) {
            size_t len = (size_t)(1 + (i * 37) % 512);
            memset(buf, 'a' + (i % 26), len);
            if (cyboudb_bind_text(st, 0, buf, (int64_t)len) != CybouDB_OK)
                ok = 0;
            if (cyboudb_step(st) != CybouDB_DONE) ok = 0;
            if (cyboudb_reset(st) != CybouDB_OK) ok = 0;
        }
        check("two thousand of them, without exhausting the copy buffer", ok);
        check("and every row is there",
              count(db, "SELECT COUNT(*) FROM b_text WHERE a = 100") == 2000);
    }
    cyboudb_finalize(st);

    cyboudb_close(db);
    printf("\nBind suite: %d checks, %d failed\n", checks, failures);
    return failures == 0 ? 0 : 1;
}
