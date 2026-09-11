/* =============================================================================
 *  tests/c_api_test.c - Regression test suite for the CybouDB C ABI
 * =============================================================================
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include "cyboudb.h"

#define ASSERT_EQ(actual, expected, msg) do { \
    if ((actual) != (expected)) { \
        fprintf(stderr, "FAIL: %s (line %d): got %lld, expected %lld\n", \
                msg, __LINE__, (long long)(actual), (long long)(expected)); \
        exit(1); \
    } \
} while (0)

#define ASSERT_STR_EQ(actual, expected, msg) do { \
    if (!actual || strcmp(actual, expected) != 0) { \
        fprintf(stderr, "FAIL: %s (line %d): got '%s', expected '%s'\n", \
                msg, __LINE__, actual ? actual : "NULL", expected); \
        exit(1); \
    } \
} while (0)

static int total_tests = 0;

#ifdef CybouDB_API_TEST_ALLOC
/* Link-time substitution affects only API allocations. The shipping --lib
 * build calls the OS directly and has no injection controls. */
extern void *os_mem_alloc(size_t size);
extern void os_mem_free(void *ptr, size_t size);
static int alloc_fail_after = -1;
static size_t api_live_bytes = 0, api_live_allocations = 0;
void *cyboudb_test_mem_alloc(size_t size) {
    if (alloc_fail_after == 0) return NULL;
    if (alloc_fail_after > 0) alloc_fail_after--;
    void *ptr = os_mem_alloc(size);
    if (ptr) { api_live_bytes += size; api_live_allocations++; }
    return ptr;
}
void cyboudb_test_mem_free(void *ptr, size_t size) {
    ASSERT_EQ(api_live_allocations > 0 && api_live_bytes >= size, 1, "balanced API free");
    api_live_bytes -= size;
    api_live_allocations--;
    os_mem_free(ptr, size);
}
#endif

static void test_invalid_args(void) {
    cyboudb_db *db = NULL;
    int rc = cyboudb_open(NULL, CybouDB_OPEN_READONLY, &db);
    ASSERT_EQ(rc, CybouDB_MISUSE, "cyboudb_open NULL path");

    rc = cyboudb_open("test.cdb", CybouDB_OPEN_READONLY, NULL);
    ASSERT_EQ(rc, CybouDB_MISUSE, "cyboudb_open NULL out_db");

    rc = cyboudb_close(NULL);
    ASSERT_EQ(rc, CybouDB_OK, "cyboudb_close NULL db");

    rc = cyboudb_prepare(NULL, "SELECT 1", NULL);
    ASSERT_EQ(rc, CybouDB_MISUSE, "cyboudb_prepare NULL db");

    rc = cyboudb_finalize(NULL);
    ASSERT_EQ(rc, CybouDB_OK, "cyboudb_finalize NULL stmt");

    rc = cyboudb_step(NULL);
    ASSERT_EQ(rc, CybouDB_MISUSE, "cyboudb_step NULL stmt");

    rc = cyboudb_reset(NULL);
    ASSERT_EQ(rc, CybouDB_MISUSE, "cyboudb_reset NULL stmt");

    rc = cyboudb_column_count(NULL);
    ASSERT_EQ(rc, 0, "cyboudb_column_count NULL stmt");

    uint64_t byte_length = 123;
    rc = cyboudb_column_bytes(NULL, 0, NULL, 0, &byte_length);
    ASSERT_EQ(rc, CybouDB_MISUSE, "cyboudb_column_bytes NULL stmt");
    rc = cyboudb_column_bytes((cyboudb_stmt *)(uintptr_t)1, 0, NULL, 0, NULL);
    ASSERT_EQ(rc, CybouDB_MISUSE, "cyboudb_column_bytes NULL length");
    ASSERT_EQ(cyboudb_batch_bytes(NULL, NULL, 0, 0, NULL, 0),
              CybouDB_MISUSE, "cyboudb_batch_bytes NULL stmt");

    rc = cyboudb_open("non_existent_file_xyz123.cdb", CybouDB_OPEN_READONLY, &db);
    ASSERT_EQ(rc, CybouDB_ERROR, "cyboudb_open missing file");

    total_tests++;
    printf("ok   test_invalid_args\n");
}

static void test_crud_and_step(const char *db_path) {
    cyboudb_db *db = NULL;
    int rc = cyboudb_open(db_path, CybouDB_OPEN_READWRITE, &db);
    ASSERT_EQ(rc, CybouDB_OK, "cyboudb_open read-write");

    /* CREATE TABLE */
    rc = cyboudb_exec(db, "CREATE TABLE items ( id INT64 NOT NULL, cost INT32, active BOOL NOT NULL, weight FLOAT32 )");
    ASSERT_EQ(rc, CybouDB_OK, "cyboudb_exec CREATE TABLE");

    /* INSERT ROWS */
    rc = cyboudb_exec(db, "INSERT INTO items VALUES (1, 100, TRUE, 12.5), (2, NULL, FALSE, 25.0), (3, 300, TRUE, -1.5), (4, 400, TRUE, 0.0)");
    ASSERT_EQ(rc, CybouDB_OK, "cyboudb_exec INSERT");

    /* Syntax error handling */
    cyboudb_stmt *bad_stmt = NULL;
    rc = cyboudb_prepare(db, "SELECT * FROM nonexistent_table", &bad_stmt);
    ASSERT_EQ(rc, CybouDB_ERROR, "cyboudb_prepare nonexistent table");

    rc = cyboudb_prepare(db, "SELECT syntax error FROM items", &bad_stmt);
    ASSERT_EQ(rc, CybouDB_ERROR, "cyboudb_prepare syntax error");

    /* SELECT with WHERE filter */
    cyboudb_stmt *stmt = NULL;
    rc = cyboudb_prepare(db, "SELECT id, cost, active, weight FROM items WHERE id > 1", &stmt);
    ASSERT_EQ(rc, CybouDB_OK, "cyboudb_prepare SELECT");

    ASSERT_EQ(cyboudb_column_count(stmt), 4, "column_count == 4");
    ASSERT_STR_EQ(cyboudb_column_name(stmt, 0), "id", "col 0 name");
    ASSERT_STR_EQ(cyboudb_column_name(stmt, 1), "cost", "col 1 name");
    ASSERT_STR_EQ(cyboudb_column_name(stmt, 2), "active", "col 2 name");
    ASSERT_STR_EQ(cyboudb_column_name(stmt, 3), "weight", "col 3 name");

    ASSERT_EQ(cyboudb_column_type(stmt, 0), CybouDB_TYPE_INT64, "col 0 type");
    ASSERT_EQ(cyboudb_column_type(stmt, 1), CybouDB_TYPE_INT32, "col 1 type");
    ASSERT_EQ(cyboudb_column_type(stmt, 2), CybouDB_TYPE_BOOL, "col 2 type");
    ASSERT_EQ(cyboudb_column_type(stmt, 3), CybouDB_TYPE_FLOAT32, "col 3 type");

    /* Row 1: id=2, cost=NULL, active=FALSE, weight=25.0 */
    rc = cyboudb_step(stmt);
    ASSERT_EQ(rc, CybouDB_ROW, "step row 1");
    ASSERT_EQ(cyboudb_column_int64(stmt, 0), 2, "row 1 id");
    ASSERT_EQ(cyboudb_column_is_null(stmt, 1), 1, "row 1 cost is_null");
    ASSERT_EQ(cyboudb_column_bool(stmt, 2), 0, "row 1 active is false");
    ASSERT_EQ((int)cyboudb_column_float(stmt, 3), 25, "row 1 weight == 25.0");

    /* Row 2: id=3, cost=300, active=TRUE, weight=-1.5 */
    rc = cyboudb_step(stmt);
    ASSERT_EQ(rc, CybouDB_ROW, "step row 2");
    ASSERT_EQ(cyboudb_column_int64(stmt, 0), 3, "row 2 id");
    ASSERT_EQ(cyboudb_column_is_null(stmt, 1), 0, "row 2 cost not null");
    ASSERT_EQ(cyboudb_column_int32(stmt, 1), 300, "row 2 cost value");
    ASSERT_EQ(cyboudb_column_bool(stmt, 2), 1, "row 2 active is true");
    float f = cyboudb_column_float(stmt, 3);
    if (fabsf(f - (-1.5f)) > 0.001f) {
        fprintf(stderr, "FAIL: row 2 weight expected -1.5, got %f\n", f);
        exit(1);
    }

    /* Row 3: id=4, cost=400, active=TRUE, weight=0.0 */
    rc = cyboudb_step(stmt);
    ASSERT_EQ(rc, CybouDB_ROW, "step row 3");
    ASSERT_EQ(cyboudb_column_int64(stmt, 0), 4, "row 3 id");
    ASSERT_EQ(cyboudb_column_int32(stmt, 1), 400, "row 3 cost");

    /* End of scan */
    rc = cyboudb_step(stmt);
    ASSERT_EQ(rc, CybouDB_DONE, "step done");

    /* Reset and re-run */
    rc = cyboudb_reset(stmt);
    ASSERT_EQ(rc, CybouDB_OK, "reset ok");

    rc = cyboudb_step(stmt);
    ASSERT_EQ(rc, CybouDB_ROW, "step after reset row 1");
    ASSERT_EQ(cyboudb_column_int64(stmt, 0), 2, "step after reset id == 2");

    rc = cyboudb_finalize(stmt);
    ASSERT_EQ(rc, CybouDB_OK, "finalize ok");

    cyboudb_close(db);
    total_tests++;
    printf("ok   test_crud_and_step\n");
}

static void test_count_star(const char *db_path) {
    /* Internal test override: exercise the baseline CPU path through the API. */
    extern int popcount_force_scalar;
    cyboudb_db *db = NULL;
    int rc = cyboudb_open(db_path, CybouDB_OPEN_READONLY, &db);
    ASSERT_EQ(rc, CybouDB_OK, "cyboudb_open read-only");

    cyboudb_stmt *stmt = NULL;
    rc = cyboudb_prepare(db, "SELECT count(*) FROM items WHERE active = TRUE", &stmt);
    ASSERT_EQ(rc, CybouDB_OK, "prepare count(*)");

    ASSERT_EQ(cyboudb_column_count(stmt), 1, "count(*) column count == 1");
    ASSERT_STR_EQ(cyboudb_column_name(stmt, 0), "count(*)", "count(*) column name");
    ASSERT_EQ(cyboudb_column_type(stmt, 0), CybouDB_TYPE_INT64, "count(*) type INT64");

    rc = cyboudb_step(stmt);
    ASSERT_EQ(rc, CybouDB_ROW, "count(*) yields 1 row");
    ASSERT_EQ(cyboudb_column_int64(stmt, 0), 3, "count(*) matching rows == 3");

    rc = cyboudb_step(stmt);
    ASSERT_EQ(rc, CybouDB_DONE, "count(*) exhausted after 1 row");

    popcount_force_scalar = 1;
    ASSERT_EQ(cyboudb_reset(stmt), CybouDB_OK, "reset count for scalar fallback");
    ASSERT_EQ(cyboudb_step(stmt), CybouDB_ROW, "scalar count yields a row");
    ASSERT_EQ(cyboudb_column_int64(stmt, 0), 3, "scalar count matches dispatch");
    ASSERT_EQ(cyboudb_step(stmt), CybouDB_DONE, "scalar count exhausted");
    popcount_force_scalar = 0;

    cyboudb_finalize(stmt);
    cyboudb_close(db);
    total_tests++;
    printf("ok   test_count_star\n");
}

static void test_step_batch(const char *db_path) {
    cyboudb_db *db = NULL;
    int rc = cyboudb_open(db_path, CybouDB_OPEN_READONLY, &db);
    ASSERT_EQ(rc, CybouDB_OK, "cyboudb_open read-only");

    cyboudb_stmt *stmt = NULL;
    rc = cyboudb_prepare(db, "SELECT id, cost FROM items WHERE id <= 2", &stmt);
    ASSERT_EQ(rc, CybouDB_OK, "prepare for batch");

    const cyboudb_batch_view *batch = NULL;
    uint64_t mask = 0;
    rc = cyboudb_step_batch(stmt, &batch, &mask);
    ASSERT_EQ(rc, CybouDB_ROW, "step_batch returns CybouDB_ROW");
    if (!batch || mask == 0) {
        fprintf(stderr, "FAIL: null batch or zero mask\n");
        exit(1);
    }
    ASSERT_EQ(mask, 0x3, "mask for id=1 and id=2 has bits 0 and 1 set");

    const int64_t *ids = (const int64_t *)batch->columns[0].values_ptr;
    ASSERT_EQ(ids[0], 1, "batch row 0 id == 1");
    ASSERT_EQ(ids[1], 2, "batch row 1 id == 2");

    rc = cyboudb_step_batch(stmt, &batch, &mask);
    ASSERT_EQ(rc, CybouDB_DONE, "step_batch finished");

    cyboudb_finalize(stmt);
    cyboudb_close(db);
    total_tests++;
    printf("ok   test_step_batch\n");
}

static void test_limit_cursor(const char *db_path) {
    cyboudb_db *db = NULL;
    cyboudb_stmt *stmt = NULL;
    ASSERT_EQ(cyboudb_open(db_path, CybouDB_OPEN_READONLY, &db), CybouDB_OK,
              "open limit cursor");
    ASSERT_EQ(cyboudb_prepare(db, "SELECT id FROM items LIMIT 2 OFFSET 1", &stmt),
              CybouDB_OK, "prepare limit cursor");
    ASSERT_EQ(cyboudb_step(stmt), CybouDB_ROW, "limit first row");
    ASSERT_EQ(cyboudb_column_int64(stmt, 0), 2, "limit first value");
    ASSERT_EQ(cyboudb_step(stmt), CybouDB_ROW, "limit second row");
    ASSERT_EQ(cyboudb_column_int64(stmt, 0), 3, "limit second value");
    ASSERT_EQ(cyboudb_step(stmt), CybouDB_DONE, "limit row cursor exhausted");

    ASSERT_EQ(cyboudb_reset(stmt), CybouDB_OK, "reset limit cursor");
    const cyboudb_batch_view *batch = NULL;
    uint64_t mask = 0;
    ASSERT_EQ(cyboudb_step_batch(stmt, &batch, &mask), CybouDB_ROW,
              "limit batch row");
    ASSERT_EQ(mask, 0x6, "limit batch preserves physical lanes");
    ASSERT_EQ(cyboudb_step_batch(stmt, &batch, &mask), CybouDB_DONE,
              "limit batch exhausted");
    cyboudb_finalize(stmt);

    ASSERT_EQ(cyboudb_prepare(db, "SELECT count(*) FROM items LIMIT 0", &stmt),
              CybouDB_OK, "prepare zero aggregate limit");
    ASSERT_EQ(cyboudb_step(stmt), CybouDB_DONE, "zero aggregate limit exhausted");
    cyboudb_finalize(stmt);
    ASSERT_EQ(cyboudb_close(db), CybouDB_OK, "close limit cursor");
    total_tests++;
    printf("ok   test_limit_cursor\n");
}

static void test_statement_lifetime_and_stale_generation(const char *db_path) {
    cyboudb_db *db = NULL;
    int rc = cyboudb_open(db_path, CybouDB_OPEN_READWRITE, &db);
    ASSERT_EQ(rc, CybouDB_OK, "cyboudb_open read-write");

    /* Prepare statement */
    cyboudb_stmt *stmt = NULL;
    rc = cyboudb_prepare(db, "SELECT id FROM items", &stmt);
    ASSERT_EQ(rc, CybouDB_OK, "prepare stmt before mutation");

    /* Mutate database while stmt is prepared (increments DB_GENERATION) */
    rc = cyboudb_exec(db, "INSERT INTO items VALUES (5, 500, TRUE, 55.5)");
    ASSERT_EQ(rc, CybouDB_OK, "mutation executed");

    /* Execute stmt: verifies that stale generation falls back cleanly to slow-path without crashing */
    int rows = 0;
    while ((rc = cyboudb_step(stmt)) == CybouDB_ROW) {
        rows++;
    }
    ASSERT_EQ(rc, CybouDB_DONE, "stmt completed after generation change");
    ASSERT_EQ(rows, 5, "total 5 rows scanned after mutation");

    cyboudb_finalize(stmt);
    cyboudb_close(db);
    total_tests++;
    printf("ok   test_statement_lifetime_and_stale_generation\n");
}

static void test_batch_projection_contract(const char *db_path) {
    cyboudb_db *db = NULL;
    cyboudb_stmt *stmt = NULL, *other = NULL;
    const cyboudb_batch_view *batch = NULL;
    uint64_t mask = 0;
    ASSERT_EQ(cyboudb_open(db_path, CybouDB_OPEN_READONLY, &db), CybouDB_OK, "open projection test");
    ASSERT_EQ(cyboudb_prepare(db, "SELECT active, id, active, cost FROM items WHERE id <= 2", &stmt),
              CybouDB_OK, "prepare reordered duplicate projection");
    ASSERT_EQ(cyboudb_prepare(db, "SELECT id FROM items", &other), CybouDB_OK, "prepare other batch owner");
    ASSERT_EQ(cyboudb_column_count(stmt), 4, "four result columns");
    ASSERT_STR_EQ(cyboudb_column_name(stmt, 0), "active", "logical name 0");
    ASSERT_STR_EQ(cyboudb_column_name(stmt, 1), "id", "logical name 1");
    ASSERT_STR_EQ(cyboudb_column_name(stmt, 2), "active", "duplicate name");
    ASSERT_EQ(cyboudb_column_type(stmt, 0), CybouDB_TYPE_BOOL, "logical bool type");
    ASSERT_EQ(cyboudb_column_type(stmt, -1), 0, "negative metadata index");
    ASSERT_STR_EQ(cyboudb_column_name(stmt, 4), "", "out-of-range metadata name");
    ASSERT_EQ(cyboudb_step_batch(stmt, &batch, &mask), CybouDB_ROW, "projection batch");
    ASSERT_EQ(mask, 3, "projection selection mask");
    const cyboudb_colview *active = cyboudb_batch_column(stmt, batch, 0);
    const cyboudb_colview *id = cyboudb_batch_column(stmt, batch, 1);
    const cyboudb_colview *duplicate = cyboudb_batch_column(stmt, batch, 2);
    const cyboudb_colview *cost = cyboudb_batch_column(stmt, batch, 3);
    ASSERT_EQ(active != NULL && id != NULL && cost != NULL, 1, "views available");
    ASSERT_EQ(active == duplicate, 1, "duplicate projection shares zero-copy view");
    ASSERT_EQ(active->type, CybouDB_TYPE_BOOL, "batch bool type");
    ASSERT_EQ(active->width, 1, "batch bool width");
    ASSERT_EQ(((const uint8_t *)active->values_ptr)[0], 1, "first bool");
    ASSERT_EQ(((const uint8_t *)active->values_ptr)[1], 0, "second bool");
    ASSERT_EQ(((const int64_t *)id->values_ptr)[1], 2, "reordered id");
    ASSERT_EQ(cost->null_mask & 3, 2, "logical nullable projection");
    ASSERT_EQ(cyboudb_batch_column(NULL, batch, 0) == NULL, 1, "NULL owner");
    ASSERT_EQ(cyboudb_batch_column(stmt, NULL, 0) == NULL, 1, "NULL batch");
    ASSERT_EQ(cyboudb_batch_column(other, batch, 0) == NULL, 1, "wrong owner");
    ASSERT_EQ(cyboudb_batch_column(stmt, batch, -1) == NULL, 1, "negative result index");
    ASSERT_EQ(cyboudb_batch_column(stmt, batch, 4) == NULL, 1, "past last result index");
    const cyboudb_batch_view *old_batch = batch;
    ASSERT_EQ(cyboudb_step_batch(stmt, &batch, &mask), CybouDB_DONE, "batch exhausted");
    ASSERT_EQ(batch == NULL && mask == 0, 1, "no stale outputs on DONE");
    ASSERT_EQ(cyboudb_batch_column(stmt, old_batch, 0) == NULL, 1, "exhausted accessor");
    ASSERT_EQ(cyboudb_reset(stmt), CybouDB_OK, "reset projection");
    ASSERT_EQ(cyboudb_batch_column(stmt, old_batch, 0) == NULL, 1, "reset accessor");
    ASSERT_EQ(cyboudb_step(stmt), CybouDB_ROW, "row after reset");
    ASSERT_EQ(cyboudb_column_bool(stmt, 0), 1, "row logical bool");
    ASSERT_EQ(cyboudb_column_int64(stmt, 1), 1, "row logical id");
    ASSERT_EQ(cyboudb_column_bool(stmt, 2), 1, "row duplicate bool");
    ASSERT_EQ(cyboudb_finalize(stmt), CybouDB_OK, "finalize projection");
    ASSERT_EQ(cyboudb_finalize(other), CybouDB_OK, "finalize other owner");
    ASSERT_EQ(cyboudb_close(db), CybouDB_OK, "close projection test");
    total_tests++;
    printf("ok   test_batch_projection_contract\n");
}

static void test_batch_count_contract(const char *db_path) {
    const char *queries[] = {"SELECT COUNT(*) FROM items", "SELECT COUNT(*) FROM items WHERE id <= 2",
                             "SELECT COUNT(*) FROM items WHERE id = 999"};
    const int64_t expected[] = {5, 2, 0};
    cyboudb_db *db = NULL;
    ASSERT_EQ(cyboudb_open(db_path, CybouDB_OPEN_READONLY, &db), CybouDB_OK, "open batch counts");
    for (int i = 0; i < 3; i++) {
        cyboudb_stmt *stmt = NULL;
        ASSERT_EQ(cyboudb_prepare(db, queries[i], &stmt), CybouDB_OK, "prepare batch count");
        for (int run = 0; run < 2; run++) {
            const cyboudb_batch_view *batch = NULL;
            uint64_t mask = 0;
            ASSERT_EQ(cyboudb_step_batch(stmt, &batch, &mask), CybouDB_ROW, "count aggregate batch");
            ASSERT_EQ(batch->row_count, 1, "aggregate has one lane");
            ASSERT_EQ(mask, 1, "aggregate selection mask");
            const cyboudb_colview *col = cyboudb_batch_column(stmt, batch, 0);
            ASSERT_EQ(col != NULL, 1, "aggregate column view");
            ASSERT_EQ(col->type, CybouDB_TYPE_INT64, "aggregate type");
            ASSERT_EQ(col->width, 8, "aggregate width");
            ASSERT_EQ(col->null_mask, 0, "aggregate non-null");
            ASSERT_EQ(*(const int64_t *)col->values_ptr, expected[i], "aggregate count");
            ASSERT_EQ(cyboudb_step_batch(stmt, &batch, &mask), CybouDB_DONE, "one aggregate only");
            ASSERT_EQ(batch == NULL && mask == 0, 1, "aggregate exhausted outputs");
            ASSERT_EQ(cyboudb_reset(stmt), CybouDB_OK, "reset aggregate");
        }
        cyboudb_finalize(stmt);
    }
    ASSERT_EQ(cyboudb_close(db), CybouDB_OK, "close batch counts");
    total_tests++;
    printf("ok   test_batch_count_contract\n");
}

static void test_maximum_result_metadata(const char *db_path) {
    cyboudb_db *db = NULL;
    cyboudb_stmt *stmt = NULL;
    char names[64][24], sql[8192];
    ASSERT_EQ(cyboudb_open(db_path, CybouDB_OPEN_READWRITE, &db), CybouDB_OK, "open maximum metadata");
    size_t used = (size_t)snprintf(sql, sizeof(sql), "CREATE TABLE wide_metadata (");
    for (int i = 0; i < 64; i++) {
        snprintf(names[i], sizeof(names[i]), "c%02d_abcdefghijklmnopqrs", i);
        ASSERT_EQ(strlen(names[i]), 23, "maximum column name length");
        used += (size_t)snprintf(sql + used, sizeof(sql) - used, "%s%s", names[i],
                                 i == 63 ? " INT32)" : " INT32, ");
    }
    ASSERT_EQ(cyboudb_prepare(db, sql, &stmt), CybouDB_OK, "prepare wide CREATE");
    ASSERT_EQ(cyboudb_column_count(stmt), 0, "CREATE has no result columns");
    ASSERT_EQ(cyboudb_step(stmt), CybouDB_DONE, "create wide table");
    cyboudb_finalize(stmt);
    used = (size_t)snprintf(sql, sizeof(sql), "INSERT INTO wide_metadata VALUES (");
    for (int i = 0; i < 64; i++) {
        used += (size_t)snprintf(sql + used, sizeof(sql) - used, "%d%s", i, i == 63 ? ")" : ",");
    }
    ASSERT_EQ(cyboudb_exec(db, sql), CybouDB_OK, "insert wide row");
    used = (size_t)snprintf(sql, sizeof(sql), "SELECT ");
    for (int i = 63; i >= 0; i--) {
        used += (size_t)snprintf(sql + used, sizeof(sql) - used, "%s%s", names[i],
                                 i == 0 ? " FROM wide_metadata" : ",");
    }
    ASSERT_EQ(cyboudb_prepare(db, sql, &stmt), CybouDB_OK, "prepare 64 reversed columns");
    memset(sql, 'x', sizeof(sql));      /* metadata must not refer to caller SQL */
    ASSERT_EQ(cyboudb_column_count(stmt), 64, "maximum result width");
    const cyboudb_batch_view *batch = NULL;
    uint64_t mask = 0;
    ASSERT_EQ(cyboudb_step_batch(stmt, &batch, &mask), CybouDB_ROW, "wide batch");
    for (int i = 0; i < 64; i++) {
        ASSERT_STR_EQ(cyboudb_column_name(stmt, i), names[63 - i], "full-width name snapshot");
        ASSERT_EQ(cyboudb_column_type(stmt, i), CybouDB_TYPE_INT32, "full-width type snapshot");
        const cyboudb_colview *col = cyboudb_batch_column(stmt, batch, i);
        ASSERT_EQ(col != NULL, 1, "full-width projection view");
        ASSERT_EQ(*(const int32_t *)col->values_ptr, 63 - i, "full-width reversed value");
    }
    cyboudb_finalize(stmt);
    ASSERT_EQ(cyboudb_close(db), CybouDB_OK, "close maximum metadata");
    total_tests++;
    printf("ok   test_maximum_result_metadata\n");
}

static void test_close_and_metadata_lifetime(const char *db_path) {
    cyboudb_db *db = NULL;
    cyboudb_stmt *stmt = NULL, *other = NULL, *bad = NULL;
    ASSERT_EQ(cyboudb_open(db_path, CybouDB_OPEN_READWRITE, &db), CybouDB_OK, "open lifetime test");
    ASSERT_EQ(cyboudb_prepare(db, "SELECT active, id, active FROM items", &stmt), CybouDB_OK, "prepare metadata");
    const char *name = cyboudb_column_name(stmt, 0);
    ASSERT_EQ(cyboudb_prepare(db, "SELECT id FROM items", &other), CybouDB_OK, "second live statement");
    int rc = cyboudb_close(db);
    ASSERT_EQ(rc, CybouDB_BUSY, "close refuses two live statements");
    ASSERT_EQ(cyboudb_errcode(db), CybouDB_BUSY, "busy error code");
    ASSERT_EQ(strstr(cyboudb_errmsg(db), "finalize") != NULL, 1, "busy error message");
    ASSERT_EQ(cyboudb_step(other), CybouDB_ROW, "connection still usable after busy");
    ASSERT_EQ(cyboudb_reset(other), CybouDB_OK, "reset keeps ownership");
    cyboudb_finalize(other);
    ASSERT_EQ(cyboudb_prepare(db, "SELECT FROM items", &bad), CybouDB_ERROR, "failed parse");
    ASSERT_EQ(bad == NULL, 1, "failed parse exposes no statement");
    ASSERT_EQ(cyboudb_prepare(db, "SELECT * FROM missing_table", &bad), CybouDB_ERROR, "failed bind");
    ASSERT_EQ(bad == NULL, 1, "failed bind exposes no statement");
    /* Repeated COW mutations and page reuse while metadata remains live. */
    for (int i = 0; i < 40; i++) {
        char sql[128];
        snprintf(sql, sizeof(sql), "INSERT INTO items VALUES (%d, 1, TRUE, 1.0)", 1000 + i);
        ASSERT_EQ(cyboudb_exec(db, sql), CybouDB_OK, "COW mutation");
        ASSERT_STR_EQ(name, "active", "saved name survives page reuse");
        ASSERT_EQ(name == cyboudb_column_name(stmt, 0), 1, "metadata address remains stable");
        ASSERT_STR_EQ(cyboudb_column_name(stmt, 1), "id", "reordered name remains stable");
        ASSERT_EQ(cyboudb_column_type(stmt, 2), CybouDB_TYPE_BOOL, "duplicate type remains stable");
    }
    int rows = 0;
    while ((rc = cyboudb_step(stmt)) == CybouDB_ROW) rows++;
    ASSERT_EQ(rc, CybouDB_DONE, "scan after COW");
    ASSERT_EQ(rows, 45, "scan sees current generation");
    rc = cyboudb_close(db);
    ASSERT_EQ(rc, CybouDB_BUSY, "exhausted statement still owns database");
    ASSERT_EQ(cyboudb_reset(stmt), CybouDB_OK, "reset metadata statement");
    ASSERT_STR_EQ(name, "active", "saved name survives reset");
    cyboudb_finalize(stmt);
    /* Non-result plans have no result metadata, but still own a DB ref. */
    ASSERT_EQ(cyboudb_prepare(db, "INSERT INTO items VALUES (2000, 1, TRUE, 1.0)", &stmt), CybouDB_OK,
              "prepare unexecuted insert");
    ASSERT_EQ(cyboudb_column_count(stmt), 0, "insert has no result columns");
    ASSERT_EQ(cyboudb_column_type(stmt, 0), 0, "insert has no result type");
    ASSERT_STR_EQ(cyboudb_column_name(stmt, 0), "", "insert has no result name");
    rc = cyboudb_close(db);
    ASSERT_EQ(rc, CybouDB_BUSY, "unexecuted mutation owns database");
    cyboudb_finalize(stmt);
    ASSERT_EQ(cyboudb_close(db), CybouDB_OK, "all refs released including failed prepares and exec");
    total_tests++;
    printf("ok   test_close_and_metadata_lifetime\n");
}

static void test_growing_statement_storage(const char *db_path) {
    cyboudb_db *db = NULL;
    cyboudb_stmt *stmt = NULL;
    char create[4096];
    size_t used = (size_t)snprintf(create, sizeof(create), "CREATE TABLE large_prepare (");
    for (int col = 0; col < 64; col++)
        used += (size_t)snprintf(create + used, sizeof(create) - used, "c%d INT64%s", col,
                                 col == 63 ? ")" : ",");
    ASSERT_EQ(cyboudb_open(db_path, CybouDB_OPEN_READWRITE, &db), CybouDB_OK, "open growing arena");
    ASSERT_EQ(cyboudb_exec(db, create), CybouDB_OK, "create large prepare table");
    const size_t capacity = 512 * 1024;
    char *sql = (char *)malloc(capacity);
    ASSERT_EQ(sql != NULL, 1, "allocate maximum INSERT fixture");
    used = (size_t)snprintf(sql, capacity, "INSERT INTO large_prepare VALUES ");
    for (int row = 0; row < 256; row++) {
        used += (size_t)snprintf(sql + used, capacity - used, "%s(", row ? "," : "");
        for (int col = 0; col < 64; col++) {
            if ((row + col) % 17 == 0)
                used += (size_t)snprintf(sql + used, capacity - used, "NULL%s", col == 63 ? ")" : ",");
            else
                used += (size_t)snprintf(sql + used, capacity - used, "%d%s", row * 1000 + col,
                                         col == 63 ? ")" : ",");
        }
    }
    ASSERT_EQ(used < capacity, 1, "maximum INSERT fits fixture buffer");
#ifdef CybouDB_API_TEST_ALLOC
    const size_t baseline = api_live_bytes;
    int succeeded = 0;
    /* Fail every allocation in sequence, including growth after parse/bind
     * exhaustion. Every failed prepare must free all its temporary storage. */
    for (int fail = 0; fail < 16; fail++) {
        alloc_fail_after = fail;
        int rc = cyboudb_prepare(db, sql, &stmt);
        alloc_fail_after = -1;
        if (rc == CybouDB_OK) {
            ASSERT_EQ(fail > 1, 1, "maximum INSERT required growth");
            succeeded = 1;
            break;
        }
        ASSERT_EQ(rc, CybouDB_NOMEM, "injected prepare allocation failure");
        ASSERT_EQ(stmt == NULL, 1, "no output handle on OOM");
        ASSERT_EQ(cyboudb_errcode(db), CybouDB_NOMEM, "OOM diagnostic code");
        ASSERT_EQ(strstr(cyboudb_errmsg(db), "memory") != NULL, 1, "OOM diagnostic message");
        ASSERT_EQ(api_live_bytes, baseline, "OOM releases all temporary bytes");
        ASSERT_EQ(cyboudb_close(db), CybouDB_OK, "OOM does not retain a statement reference");
        ASSERT_EQ(cyboudb_open(db_path, CybouDB_OPEN_READWRITE, &db), CybouDB_OK, "reopen after OOM");
    }
    ASSERT_EQ(succeeded, 1, "maximum INSERT eventually prepared");
#else
    ASSERT_EQ(cyboudb_prepare(db, sql, &stmt), CybouDB_OK, "prepare maximum INSERT");
#endif
    /* A later syntax error still needs to release a grown temporary graph;
     * the already prepared statement must remain valid. */
    cyboudb_stmt *bad = NULL;
#ifdef CybouDB_API_TEST_ALLOC
    size_t prepared_bytes = api_live_bytes;
#endif
    sql[used] = '!';
    sql[used + 1] = 0;
    ASSERT_EQ(cyboudb_prepare(db, sql, &bad), CybouDB_ERROR, "syntax failure after arena growth");
    ASSERT_EQ(bad == NULL, 1, "grown syntax failure exposes no handle");
#ifdef CybouDB_API_TEST_ALLOC
    ASSERT_EQ(api_live_bytes, prepared_bytes, "grown parse failure frees temporary allocation");
#endif
    sql[used] = 0;
    /* The grown graph must own all required SQL data and survive reset. */
    memset(sql, 'x', used);
    free(sql);
    ASSERT_EQ(cyboudb_reset(stmt), CybouDB_OK, "reset grown statement");
    ASSERT_EQ(cyboudb_step(stmt), CybouDB_DONE, "execute 256 by 64 INSERT");
    ASSERT_EQ(cyboudb_step(stmt), CybouDB_DONE, "grown INSERT executes only once");
    ASSERT_EQ(cyboudb_finalize(stmt), CybouDB_OK, "finalize grown allocation");
    ASSERT_EQ(cyboudb_prepare(db, "SELECT * FROM large_prepare", &stmt), CybouDB_OK, "read maximum INSERT");
    int row = 0, rc;
    while ((rc = cyboudb_step(stmt)) == CybouDB_ROW) {
        ASSERT_EQ(row < 256, 1, "no excess rows");
        for (int col = 0; col < 64; col++) {
            ASSERT_EQ(cyboudb_column_is_null(stmt, col), (row + col) % 17 == 0, "maximum INSERT NULL bitmap");
            if ((row + col) % 17 != 0)
                ASSERT_EQ(cyboudb_column_int64(stmt, col), row * 1000 + col, "maximum INSERT cell");
        }
        row++;
    }
    ASSERT_EQ(rc, CybouDB_DONE, "maximum INSERT scan exhausted");
    ASSERT_EQ(row, 256, "all maximum INSERT rows persisted");
    cyboudb_finalize(stmt);
    ASSERT_EQ(cyboudb_close(db), CybouDB_OK, "close growing arena test");
#ifdef CybouDB_API_TEST_ALLOC
    ASSERT_EQ(api_live_allocations, 0, "no API allocation leaks");
    ASSERT_EQ(api_live_bytes, 0, "grown allocation freed with correct size");
#endif
    total_tests++;
    printf("ok   test_growing_statement_storage\n");
}

static void test_exec_single_statement(const char *db_path) {
    cyboudb_db *db = NULL;
    cyboudb_stmt *stmt = NULL;
    ASSERT_EQ(cyboudb_exec(NULL, "SELECT id FROM items"), CybouDB_MISUSE, "exec NULL connection");
    ASSERT_EQ(cyboudb_open(db_path, CybouDB_OPEN_READWRITE, &db), CybouDB_OK, "open exec contract");
    ASSERT_EQ(cyboudb_exec(db, NULL), CybouDB_MISUSE, "exec NULL SQL");
    ASSERT_EQ(cyboudb_exec(db, "SELECT active, id, active FROM items; -- discard results"), CybouDB_OK, "discard SELECT");
    ASSERT_EQ(cyboudb_exec(db, "SELECT COUNT(*) FROM items"), CybouDB_OK, "discard aggregate");
    ASSERT_EQ(cyboudb_exec(db, "SELECT FROM items"), CybouDB_ERROR, "exec propagates parse error");
    ASSERT_EQ(cyboudb_exec(db, "SELECT * FROM missing_table"), CybouDB_ERROR, "exec propagates bind error");
    ASSERT_EQ(cyboudb_exec(db, "INSERT INTO items VALUES (9999, 1, TRUE, 1.0); SELECT id FROM items"),
              CybouDB_ERROR, "multiple statements rejected");
    ASSERT_EQ(cyboudb_prepare(db, "SELECT COUNT(*) FROM items WHERE id = 9999", &stmt), CybouDB_OK, "check rejected mutation");
    ASSERT_EQ(cyboudb_step(stmt), CybouDB_ROW, "rejected mutation count");
    ASSERT_EQ(cyboudb_column_int64(stmt, 0), 0, "no prefix mutation executed");
    cyboudb_finalize(stmt);
#ifdef CybouDB_API_TEST_ALLOC
    size_t baseline = api_live_bytes;
    alloc_fail_after = 0;
    int rc = cyboudb_exec(db, "SELECT id FROM items");
    alloc_fail_after = -1;
    ASSERT_EQ(rc, CybouDB_NOMEM, "exec propagates OOM");
    ASSERT_EQ(api_live_bytes, baseline, "exec OOM frees storage");
#endif
    ASSERT_EQ(cyboudb_close(db), CybouDB_OK, "exec always finalizes its statement");
    ASSERT_EQ(cyboudb_open(db_path, CybouDB_OPEN_READONLY, &db), CybouDB_OK, "open read-only exec");
    ASSERT_EQ(cyboudb_exec(db, "INSERT INTO items VALUES (9999, 1, TRUE, 1.0)"), CybouDB_ERROR, "exec propagates step failure");
    ASSERT_EQ(cyboudb_close(db), CybouDB_OK, "failed exec finalizes statement");
    total_tests++;
    printf("ok   test_exec_single_statement\n");
}

static void test_independent_decode_views(const char *path) {
    cyboudb_db *a = NULL, *b = NULL;
    cyboudb_stmt *sa = NULL, *sb = NULL;
    const cyboudb_batch_view *ba = NULL, *bb = NULL;
    uint64_t ma, mb;
    ASSERT_EQ(cyboudb_open(path, CybouDB_OPEN_READWRITE, &a), CybouDB_OK, "open decode fixture");
    ASSERT_EQ(cyboudb_exec(a, "CREATE TABLE decode_views (v INT32)"), CybouDB_OK, "decode table");
    ASSERT_EQ(cyboudb_exec(a, "INSERT INTO decode_views VALUES (11),(22),(33),(44)"), CybouDB_OK, "decode values");
    ASSERT_EQ(cyboudb_open(path, CybouDB_OPEN_READONLY, &b), CybouDB_OK, "second decode connection");
    ASSERT_EQ(cyboudb_prepare(a, "SELECT v FROM decode_views", &sa), CybouDB_OK, "prepare first decode");
    ASSERT_EQ(cyboudb_prepare(b, "SELECT v FROM items", &sb), CybouDB_ERROR, "invalid projection rejected");
    ASSERT_EQ(cyboudb_prepare(b, "SELECT id FROM items", &sb), CybouDB_OK, "prepare second decode");
    ASSERT_EQ(cyboudb_step_batch(sa, &ba, &ma), CybouDB_ROW, "first decode batch");
    const cyboudb_colview *col = cyboudb_batch_column(sa, ba, 0);
    int32_t saved[4];
    memcpy(saved, col->values_ptr, sizeof(saved));
    ASSERT_EQ(cyboudb_step_batch(sb, &bb, &mb), CybouDB_ROW, "second decode batch");
    ASSERT_EQ(memcmp(saved, col->values_ptr, sizeof(saved)), 0, "another statement cannot overwrite borrowed values");
    ASSERT_EQ(saved[0], 11, "decoded first value");
    ASSERT_EQ(saved[3], 44, "decoded last value");
    cyboudb_finalize(sa);
    cyboudb_finalize(sb);
    ASSERT_EQ(cyboudb_close(b), CybouDB_OK, "close second decode connection");
    ASSERT_EQ(cyboudb_close(a), CybouDB_OK, "close first decode connection");
    total_tests++;
}

static void test_public_zone_paths(const char *path) {
    extern int sql_zone_trace, sql_zone_force_off;
    extern uint64_t sql_zone_leaf_total, sql_zone_leaf_none, sql_zone_leaf_all;
    extern uint64_t sql_zone_batch_total;
    cyboudb_db *db = NULL;
    const char *queries[] = {
        "SELECT COUNT(*) FROM decode_views WHERE v < 0",
        "SELECT COUNT(*) FROM decode_views WHERE v >= 0",
        "SELECT COUNT(*) FROM decode_views WHERE v > 22"
    };
    const int expected[] = {0, 4, 2};
    ASSERT_EQ(cyboudb_open(path, CybouDB_OPEN_READONLY, &db), CybouDB_OK, "open public zone tests");
    sql_zone_trace = 1;
    for (int batch_mode = 0; batch_mode < 2; batch_mode++) {
        for (int q = 0; q < 3; q++) {
            cyboudb_stmt *stmt = NULL;
            ASSERT_EQ(cyboudb_prepare(db, queries[q], &stmt), CybouDB_OK, "prepare zone query");
            for (int off = 0; off < 2; off++) {
                const cyboudb_batch_view *batch = NULL;
                uint64_t mask = 0;
                sql_zone_force_off = off;
                sql_zone_leaf_total = sql_zone_leaf_none = sql_zone_leaf_all = sql_zone_batch_total = 0;
                ASSERT_EQ(cyboudb_reset(stmt), CybouDB_OK, "reset zone query");
                int rc = batch_mode ? cyboudb_step_batch(stmt, &batch, &mask) : cyboudb_step(stmt);
                ASSERT_EQ(rc, CybouDB_ROW, "zone COUNT produces aggregate");
                int64_t count = batch_mode ? *(const int64_t *)cyboudb_batch_column(stmt, batch, 0)->values_ptr
                                          : cyboudb_column_int64(stmt, 0);
                ASSERT_EQ(count, expected[q], "public zone ON/OFF parity");
                ASSERT_EQ(sql_zone_leaf_total > 0, 1, "public API enters shared zone core");
                if (!off && q < 2) {
                    ASSERT_EQ(sql_zone_batch_total, 0, "NONE and COUNT/ALL never request values");
                    ASSERT_EQ(q ? sql_zone_leaf_all : sql_zone_leaf_none, sql_zone_leaf_total,
                              "all leaves classified through public API");
                } else ASSERT_EQ(sql_zone_batch_total > 0, 1, "UNKNOWN reads batches");
                rc = batch_mode ? cyboudb_step_batch(stmt, &batch, &mask) : cyboudb_step(stmt);
                ASSERT_EQ(rc, CybouDB_DONE, "aggregate delivered exactly once");
            }
            cyboudb_finalize(stmt);
        }
    }
    sql_zone_trace = sql_zone_force_off = 0;
    ASSERT_EQ(cyboudb_close(db), CybouDB_OK, "close zone tests");
    total_tests++;
    printf("ok   test_public_zone_paths\n");
}

static void test_encoded_predicates(const char *path, int compressed) {
    extern int sql_zone_force_off;
    extern int sql_kernel_force_scalar;
    extern uint64_t pax_decode_trace, pax_decode_calls, pax_const_columns, pax_bool_columns, pax_null_columns;
    cyboudb_db *db = NULL;
    char sql[4096], row[96];
    ASSERT_EQ(cyboudb_open(path, CybouDB_OPEN_READWRITE, &db), CybouDB_OK, "open fast path fixture");
    ASSERT_EQ(cyboudb_exec(db, "CREATE TABLE fast_paths (id INT32, x INT32, b BOOL, f FLOAT32)"), CybouDB_OK, "fast path table");
    size_t used = (size_t)snprintf(sql, sizeof(sql), "INSERT INTO fast_paths VALUES ");
    for (int i = 0; i < 65; i++) {
        if (i % 7 == 0) snprintf(row, sizeof(row), "%s(%d,NULL,NULL,NULL)", i ? "," : "", i);
        else snprintf(row, sizeof(row), "%s(%d,42,%s,1.0)", i ? "," : "", i, i % 2 ? "TRUE" : "FALSE");
        int added = snprintf(sql + used, sizeof(sql) - used, "%s", row);
        ASSERT_EQ(added >= 0 && (size_t)added < sizeof(sql) - used, 1, "fixture SQL fits buffer");
        used += (size_t)added;
    }
    ASSERT_EQ(cyboudb_exec(db, sql), CybouDB_OK, "insert 65 nullable encoded rows");
    const char *predicates[] = {"x = 42", "b = TRUE", "b = FALSE", "x IS NULL", "x IS NOT NULL", "f = 1.0", "NOT(f != 1.0) OR b = TRUE"};
    const int counts[] = {55, 27, 28, 10, 55, 55, 55};
    sql_zone_force_off = 1;             /* Test batch fast paths independently of zone pruning. */
    pax_decode_trace = 1;
    for (int q = 0; q < 7; q++) {
        cyboudb_stmt *stmt = NULL;
        snprintf(sql, sizeof(sql), "SELECT COUNT(*) FROM fast_paths WHERE %s", predicates[q]);
        ASSERT_EQ(cyboudb_prepare(db, sql, &stmt), CybouDB_OK, "prepare encoded predicate");
        pax_decode_calls = pax_const_columns = pax_bool_columns = pax_null_columns = 0;
        ASSERT_EQ(cyboudb_step(stmt), CybouDB_ROW, "encoded predicate aggregate");
        ASSERT_EQ(cyboudb_column_int64(stmt, 0), counts[q], "encoded predicate 3VL result");
        ASSERT_EQ(pax_decode_calls, 0, "predicate requires no full value decode");
        if (q == 3 || q == 4) ASSERT_EQ(pax_null_columns > 0, 1, "NULL-only scanner path used");
        else if (compressed && (q == 1 || q == 2)) ASSERT_EQ(pax_bool_columns > 0, 1, "packed BOOL scanner path used");
        else if (compressed) ASSERT_EQ(pax_const_columns > 0, 1, "CONST scanner path used");
        cyboudb_finalize(stmt);
    }
    if (compressed) {
        /* Scalar forcing gates only AVX2 FOR descriptors; scalar-safe encoded
         * CONST and packed BOOL paths must stay enabled. */
        sql_kernel_force_scalar = 1;
        for (int q = 0; q < 2; q++) {
            int predicate = q == 0 ? 0 : 1;
            cyboudb_stmt *scalar_stmt = NULL;
            snprintf(sql, sizeof(sql), "SELECT COUNT(*) FROM fast_paths WHERE %s",
                     predicates[predicate]);
            pax_decode_calls = pax_const_columns = pax_bool_columns = 0;
            ASSERT_EQ(cyboudb_prepare(db, sql, &scalar_stmt), CybouDB_OK,
                      "prepare scalar-safe encoded predicate");
            ASSERT_EQ(cyboudb_step(scalar_stmt), CybouDB_ROW,
                      "scalar-safe encoded aggregate");
            ASSERT_EQ(pax_decode_calls, 0, "scalar keeps CONST/BOOL direct");
            if (q == 0) ASSERT_EQ(pax_const_columns > 0, 1,
                                  "scalar keeps CONST scanner path");
            else ASSERT_EQ(pax_bool_columns > 0, 1,
                           "scalar keeps BOOL scanner path");
            cyboudb_finalize(scalar_stmt);
        }
        sql_kernel_force_scalar = 0;
    }
    cyboudb_stmt *stmt = NULL;
    const cyboudb_batch_view *batch = NULL;
    uint64_t mask;
    ASSERT_EQ(cyboudb_prepare(db, "SELECT x FROM fast_paths WHERE x = 42", &stmt), CybouDB_OK, "prepare projected encoded value");
    pax_decode_calls = 0;
    ASSERT_EQ(cyboudb_step_batch(stmt, &batch, &mask), CybouDB_ROW, "projected encoded value batch");
    const cyboudb_colview *view = cyboudb_batch_column(stmt, batch, 0);
    ASSERT_EQ(((const int32_t *)view->values_ptr)[1], 42, "public projection remains typed");
    if (compressed) ASSERT_EQ(pax_decode_calls > 0, 1, "projected values decoded");
    cyboudb_finalize(stmt);
    ASSERT_EQ(cyboudb_prepare(db, "SELECT id FROM fast_paths", &stmt), CybouDB_OK, "prepare row lifetime");
    ASSERT_EQ(cyboudb_step(stmt), CybouDB_ROW, "row cursor has buffered lanes");
    ASSERT_EQ(cyboudb_exec(db, "INSERT INTO fast_paths VALUES (65,42,TRUE,1.0)"), CybouDB_OK, "invalidate cursor generation");
    ASSERT_EQ(cyboudb_step(stmt), CybouDB_ERROR, "buffered row cannot outlive generation");
    ASSERT_EQ(cyboudb_step(stmt), CybouDB_ERROR, "cursor error stays terminal");
    ASSERT_EQ(cyboudb_reset(stmt), CybouDB_OK, "reset recovers error state");
    int rows = 0, rc;
    while ((rc = cyboudb_step(stmt)) == CybouDB_ROW) rows++;
    ASSERT_EQ(rc, CybouDB_DONE, "reset cursor completes against fresh schema");
    ASSERT_EQ(rows, 66, "reset cursor observes committed append");
    cyboudb_finalize(stmt);
    pax_decode_trace = 0;
    sql_zone_force_off = 0;
    ASSERT_EQ(cyboudb_close(db), CybouDB_OK, "close encoded fixture");
    total_tests++;
    printf("ok   test_encoded_predicates\n");
}

/* Test that FOR8/FOR16 predicate-only columns take the zero-decode path.
 *
 * category INT32 with values 0..7 compresses to FOR8 (delta fits in 3 bits,
 * rounded to width=8).  score INT32 with values 0..99 also fits in FOR8
 * (7 bits -> width=8).  x INT64 with values -10..(n-10) has a delta range of
 * n-1; for small n this stays in FOR8 or FOR16.
 *
 * We use pax_decode_calls to prove no full decompress happened.
 * sql_zone_force_off=1 prevents zone pruning from hiding leaves.
 */
static void test_for_predicate_fast_paths(const char *path, int compressed) {
    if (!compressed) {
        total_tests++;
        printf("ok   test_for_predicate_fast_paths (skipped: uncompressed build)\n");
        return;
    }
    extern int sql_zone_force_off;
    extern int sql_kernel_force_scalar;
    extern uint64_t pax_decode_trace, pax_decode_calls, pax_for_columns;
    cyboudb_db *db = NULL;
    char sql[16384];
    ASSERT_EQ(cyboudb_open(path, CybouDB_OPEN_READWRITE, &db), CybouDB_OK, "open FOR fast path fixture");
    ASSERT_EQ(cyboudb_exec(db,
        "CREATE TABLE for_test ("
        "  id INT64 NOT NULL, category INT32 NOT NULL, score INT32 NOT NULL)"),
        CybouDB_OK, "create FOR test table");

    /* Insert enough rows to get multiple leaves and cover boundary sizes.
     * Values chosen so:
     *   category in [0,7]  -> 3-bit delta -> rounds to FOR8
     *   score    in [0,99] -> 7-bit delta -> rounds to FOR8
     *   id       is a monotone INT64, delta small -> also FOR8 or FOR16 */
    const int sizes[] = {1, 31, 32, 33, 63, 64, 65, 447, 448, 449, 0};
    int total_rows = 0;
    for (int s = 0; sizes[s]; s++) {
        int target = sizes[s];
        while (total_rows < target) {
            int chunk = target - total_rows;
            if (chunk > 100) chunk = 100;
            int chunk_end = total_rows + chunk;
            size_t used = (size_t)snprintf(sql, sizeof(sql), "INSERT INTO for_test VALUES ");
            for (int r = total_rows; r < chunk_end; r++) {
                int added = snprintf(sql + used, sizeof(sql) - used,
                    "%s(%lld,%d,%d)",
                    r > total_rows ? "," : "",
                    (long long)r,
                    r % 8,
                    r % 100);
                used += (size_t)added;
            }
            ASSERT_EQ(cyboudb_exec(db, sql), CybouDB_OK, "insert FOR test rows");
            total_rows = chunk_end;
        }
    }

    sql_zone_force_off = 1;
    pax_decode_trace = 1;

    /* --- predicate-only queries: decode must not happen -------------------- */
    const char *pred_queries[] = {
        "SELECT COUNT(*) FROM for_test WHERE category = 3",
        "SELECT COUNT(*) FROM for_test WHERE score > 90",
        "SELECT COUNT(*) FROM for_test WHERE category < 4",
        "SELECT COUNT(*) FROM for_test WHERE score >= 50",
        "SELECT COUNT(*) FROM for_test WHERE category != 5",
        "SELECT COUNT(*) FROM for_test WHERE category = 3 AND score > 90",
        "SELECT COUNT(*) FROM for_test WHERE category = 3 OR score > 90",
        "SELECT COUNT(*) FROM for_test WHERE id >= 400",
        NULL
    };

    /* Precompute expected counts */
    int expected[8];
    {
        int eq3 = 0, gt90 = 0, lt4 = 0, ge50 = 0, ne5 = 0, and_ = 0, or_ = 0;
        for (int r = 0; r < total_rows; r++) {
            int cat = r % 8, sc = r % 100;
            if (cat == 3) eq3++;
            if (sc > 90)  gt90++;
            if (cat < 4)  lt4++;
            if (sc >= 50) ge50++;
            if (cat != 5) ne5++;
            if (cat == 3 && sc > 90) and_++;
            if (cat == 3 || sc > 90) or_++;
        }
        expected[0] = eq3; expected[1] = gt90; expected[2] = lt4;
        expected[3] = ge50; expected[4] = ne5;
        expected[5] = and_; expected[6] = or_;
        expected[7] = total_rows - 400;
    }

    /* A forced-scalar SELECT must decode FOR8/FOR16 and must never publish an
     * encoded FOR descriptor.  CONST, BOOL and NULL-only paths remain direct. */
    {
        cyboudb_stmt *stmt = NULL;
        sql_kernel_force_scalar = 1;
        pax_decode_calls = 0;
        pax_for_columns = 0;
        ASSERT_EQ(cyboudb_prepare(db, pred_queries[0], &stmt), CybouDB_OK,
                  "prepare forced-scalar FOR predicate");
        ASSERT_EQ(cyboudb_step(stmt), CybouDB_ROW, "forced-scalar FOR aggregate");
        ASSERT_EQ(cyboudb_column_int64(stmt, 0), expected[0],
                  "forced-scalar FOR correct result");
        ASSERT_EQ(pax_decode_calls > 0, 1, "forced-scalar FOR decodes values");
        ASSERT_EQ(pax_for_columns, 0, "forced-scalar publishes no FOR descriptor");
        cyboudb_finalize(stmt);
        sql_kernel_force_scalar = 0;
    }

    for (int q = 0; pred_queries[q]; q++) {
        cyboudb_stmt *stmt = NULL;
        ASSERT_EQ(cyboudb_prepare(db, pred_queries[q], &stmt), CybouDB_OK, "prepare FOR predicate");
        pax_decode_calls = 0;
        pax_for_columns = 0;
        ASSERT_EQ(cyboudb_step(stmt), CybouDB_ROW, "FOR predicate aggregate");
        ASSERT_EQ(cyboudb_column_int64(stmt, 0), expected[q], "FOR predicate correct result");
        ASSERT_EQ(pax_decode_calls, 0, "predicate-only FOR requires no decode");
        ASSERT_EQ(pax_for_columns > 0, 1, "FOR scanner path used");
        cyboudb_finalize(stmt);
    }

    /* --- projected column: decode IS required ------------------------------ */
    {
        cyboudb_stmt *stmt = NULL;
        ASSERT_EQ(cyboudb_prepare(db, "SELECT category FROM for_test WHERE category = 3", &stmt),
                  CybouDB_OK, "prepare projected FOR column");
        pax_decode_calls = 0;
        ASSERT_EQ(cyboudb_step(stmt), CybouDB_ROW, "projected FOR batch");
        ASSERT_EQ(pax_decode_calls > 0, 1, "projected column triggers decode");
        cyboudb_finalize(stmt);
    }

    pax_decode_trace = 0;
    sql_zone_force_off = 0;
    ASSERT_EQ(cyboudb_close(db), CybouDB_OK, "close FOR fast path fixture");
    total_tests++;
    printf("ok   test_for_predicate_fast_paths\n");
}

static void test_varlen_accessors(const char *db_path, int enabled) {
    if (!enabled) return;
    cyboudb_db *db = NULL;
    cyboudb_stmt *stmt = NULL;
    unsigned char buf[16];
    uint64_t len = 0, mask = 0;
    const cyboudb_batch_view *batch = NULL;

    printf("diag varlen open\n");
    ASSERT_EQ(cyboudb_open(db_path, CybouDB_OPEN_READWRITE, &db), CybouDB_OK, "open varlen fixture");
    printf("diag varlen create\n");
    ASSERT_EQ(cyboudb_exec(db, "CREATE TABLE api_var (id INT64 NOT NULL, body TEXT, raw BLOB)"), CybouDB_OK, "create varlen table");
    ASSERT_EQ(cyboudb_exec(db, "INSERT INTO api_var VALUES (1, 'alpha', X'00FF'), (2, '', X''), (3, NULL, NULL)"), CybouDB_OK, "insert varlen rows");
    printf("diag varlen prepare\n");
    ASSERT_EQ(cyboudb_prepare(db, "SELECT body, raw FROM api_var", &stmt), CybouDB_OK, "prepare varlen select");
    ASSERT_EQ(cyboudb_column_type(stmt, 0), CybouDB_TYPE_TEXT, "TEXT public type");
    ASSERT_EQ(cyboudb_column_type(stmt, 1), CybouDB_TYPE_BLOB, "BLOB public type");

    ASSERT_EQ(cyboudb_step(stmt), CybouDB_ROW, "varlen row one");
    printf("diag varlen row accessor\n");
    memset(buf, 0xA5, sizeof(buf));
    ASSERT_EQ(cyboudb_column_bytes(stmt, 0, buf, 4, &len), CybouDB_MISUSE, "reject short row buffer");
    printf("diag varlen short done\n");
    ASSERT_EQ(len, 5, "report required row length");
    ASSERT_EQ(buf[0], 0xA5, "short row destination unchanged");
    ASSERT_EQ(cyboudb_column_bytes(stmt, 0, buf, sizeof(buf), &len), CybouDB_OK, "copy TEXT row");
    printf("diag varlen text done\n");
    ASSERT_EQ(len, 5, "TEXT row length");
    ASSERT_EQ(memcmp(buf, "alpha", 5), 0, "TEXT row bytes");
    ASSERT_EQ(cyboudb_column_bytes(stmt, 1, buf, sizeof(buf), &len), CybouDB_OK, "copy BLOB row");
    printf("diag varlen blob done len=%llu bytes=%u,%u\n", (unsigned long long)len, buf[0], buf[1]);
    ASSERT_EQ(len, 2, "BLOB row length");
    ASSERT_EQ(buf[0], 0, "BLOB zero byte");
    ASSERT_EQ(buf[1], 0xFF, "BLOB high byte");

    printf("diag before row two stmt=%p\n", (void *)stmt);
    ASSERT_EQ(cyboudb_step(stmt), CybouDB_ROW, "varlen empty row");
    printf("diag after row two\n");
    ASSERT_EQ(cyboudb_column_bytes(stmt, 0, NULL, 0, &len), CybouDB_OK, "empty TEXT copy");
    printf("diag empty copy done\n");
    ASSERT_EQ(len, 0, "empty TEXT length");
    ASSERT_EQ(cyboudb_step(stmt), CybouDB_ROW, "varlen NULL row");
    printf("diag null row done\n");
    ASSERT_EQ(cyboudb_column_is_null(stmt, 0), 1, "TEXT NULL remains distinct");
    ASSERT_EQ(cyboudb_column_bytes(stmt, 0, NULL, 0, &len), CybouDB_OK, "NULL TEXT copy");
    printf("diag null copy done\n");
    ASSERT_EQ(len, 0, "NULL TEXT length");

    ASSERT_EQ(cyboudb_reset(stmt), CybouDB_OK, "reset for varlen batch");
    ASSERT_EQ(cyboudb_step_batch(stmt, &batch, &mask), CybouDB_ROW, "varlen batch");
    ASSERT_EQ(mask, 7, "varlen batch selection mask");
    ASSERT_EQ(cyboudb_batch_column(stmt, batch, 0) == NULL, 1, "generic view hides descriptors");
    ASSERT_EQ(cyboudb_batch_bytes(stmt, batch, 0, 0, buf, sizeof(buf)), 5, "batch TEXT length");
    ASSERT_EQ(memcmp(buf, "alpha", 5), 0, "batch TEXT bytes");
    ASSERT_EQ(cyboudb_batch_bytes(stmt, batch, 1, 0, buf, 1), CybouDB_MISUSE, "reject short batch buffer");
    ASSERT_EQ(cyboudb_batch_bytes(stmt, batch, 0, 1, NULL, 0), 0, "batch empty TEXT");
    ASSERT_EQ(cyboudb_batch_bytes(stmt, batch, 0, 3, buf, sizeof(buf)), CybouDB_MISUSE, "reject row outside batch");

    cyboudb_finalize(stmt);
    ASSERT_EQ(cyboudb_close(db), CybouDB_OK, "close varlen fixture");
    total_tests++;
    printf("ok   test_varlen_accessors\n");
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);
    const char *db_path = (argc > 1) ? argv[1] : "test_c_api.cdb";
    printf("Running CybouDB C API Test Suite on %s...\n", db_path);

    if (argc > 2 && strcmp(argv[2], "varlen") == 0) {
        test_invalid_args();
        test_varlen_accessors(db_path, 1);
#ifdef CybouDB_API_TEST_ALLOC
        ASSERT_EQ(api_live_bytes, 0, "all varlen API allocations released");
        ASSERT_EQ(api_live_allocations, 0, "all varlen API handles released");
#endif
        printf("CybouDB C API test suite: %d test groups PASSED\n", total_tests);
        return 0;
    }

    test_invalid_args();
    test_crud_and_step(db_path);
    test_count_star(db_path);
    test_step_batch(db_path);
    test_limit_cursor(db_path);
    test_statement_lifetime_and_stale_generation(db_path);
    test_batch_projection_contract(db_path);
    test_batch_count_contract(db_path);
    test_maximum_result_metadata(db_path);
    test_close_and_metadata_lifetime(db_path);
    test_growing_statement_storage(db_path);
    test_exec_single_statement(db_path);
    test_independent_decode_views(db_path);
    test_public_zone_paths(db_path);
    test_encoded_predicates(db_path, argc > 2 && strcmp(argv[2], "compressed") == 0);
    test_for_predicate_fast_paths(db_path, argc > 2 && strcmp(argv[2], "compressed") == 0);
#ifdef CybouDB_API_TEST_ALLOC
    ASSERT_EQ(api_live_bytes, 0, "all API test allocations released");
    ASSERT_EQ(api_live_allocations, 0, "all API handles released");
#endif

    printf("CybouDB C API test suite: %d test groups PASSED\n", total_tests);
    return 0;
}
