/* =============================================================================
 *  cyboudb.h - Public C API for the CybouDB Columnar Database Engine
 * =============================================================================
 *  Memory-mapped, typed columnar database engine with borrowed batch views.
 * =============================================================================
 */

#ifndef CybouDB_H
#define CybouDB_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* --- Return & Status Codes ------------------------------------------------ */
#define CybouDB_OK              0       /* Successful result */
#define CybouDB_ROW             100     /* cyboudb_step() has another row ready */
#define CybouDB_DONE            101     /* cyboudb_step() has finished executing */
#define CybouDB_ERROR           -1      /* Generic error / SQL error */
#define CybouDB_BUSY            -2      /* Database file locked or busy */
#define CybouDB_MISUSE          -3      /* Library used incorrectly / bad argument */
#define CybouDB_NOMEM           -4      /* Memory allocation failed */

/* --- Data Types ----------------------------------------------------------- */
#define CybouDB_TYPE_INT32      1       /* 32-bit signed integer */
#define CybouDB_TYPE_INT64      2       /* 64-bit signed integer */
#define CybouDB_TYPE_FLOAT32    3       /* 32-bit IEEE 754 floating point */
#define CybouDB_TYPE_BOOL       4       /* 1-byte boolean (0 = FALSE, 1 = TRUE) */
#define CybouDB_TYPE_TEXT       5       /* UTF-8 byte string; storage does not transcode */
#define CybouDB_TYPE_BLOB       6       /* Arbitrary byte string */

/* --- Codecs (Per-Column Compression) -------------------------------------- */
#define CybouDB_CODEC_RAW       0       /* Uncompressed raw values */
#define CybouDB_CODEC_CONST     1       /* Constant value across leaf */
#define CybouDB_CODEC_FOR       2       /* Frame-of-Reference (base + bitpacked) */

/* --- Feature Flags -------------------------------------------------------- */
#define CybouDB_FEATURE_COMPRESSION 0x0200 /* Per-column compression capability */

/* --- Open Flags ----------------------------------------------------------- */
#define CybouDB_OPEN_READONLY   0x0001  /* Open database in read-only mode */
#define CybouDB_OPEN_READWRITE  0x0002  /* Open database in read-write mode */

/* --- Opaque Types --------------------------------------------------------- */
typedef struct cyboudb_db cyboudb_db;
typedef struct cyboudb_stmt cyboudb_stmt;

/* --- Borrowed Column Batch View (Vectorized Access) ----------------------- */
typedef struct cyboudb_colview {
    const void *values_ptr;   /* Pointer to contiguous column memory (up to 64 items) */
    uint64_t null_mask;       /* Bitmask: bit i = 1 if row i is NULL */
    uint32_t type;            /* CybouDB_TYPE_* */
    uint32_t width;           /* Byte width per element (1, 4, or 8) */
} cyboudb_colview;

typedef struct cyboudb_batch_view {
    uint64_t row_count;       /* Total rows in this batch run (1..64) */
    cyboudb_colview columns[64]; /* Physical slots; use cyboudb_batch_column for SELECT order */
} cyboudb_batch_view;

/* =============================================================================
 *  Database Connection Management
 * =============================================================================
 */

/**
 * Open an existing CybouDB database file.
 *
 * @param path     Path to the database file (UTF-8).
 * @param flags    Bitwise combination of CybouDB_OPEN_* flags.
 * @param out_db   Pointer to receive the opaque connection handle.
 * @return         CybouDB_OK on success, or an CybouDB error code.
 */
int cyboudb_open(const char *path, uint32_t flags, cyboudb_db **out_db);

/**
 * Close an open CybouDB database connection and release mapped resources.
 * Returns CybouDB_BUSY while any prepared statements remain alive, including
 * exhausted or reset statements. A busy connection stays open and usable.
 * Finalize all statements before retrying close. Calls on one connection
 * and its statements must be serialized by the caller.
 *
 * @param db       The connection to close.
 * @return         CybouDB_OK on success, or an CybouDB error code.
 */
int cyboudb_close(cyboudb_db *db);

/**
 * Retrieve the English error message describing the last failure on db.
 */
const char *cyboudb_errmsg(cyboudb_db *db);

/**
 * Retrieve the internal numeric error code of the last failure on db.
 */
int cyboudb_errcode(cyboudb_db *db);

/* =============================================================================
 *  Prepared Statement Lifecycle
 * =============================================================================
 */

/**
 * Compile, parse and bind a SQL statement against an open database connection.
 * Storage grows as needed during prepare. A returned handle and its metadata
 * do not move. On allocation failure returns CybouDB_NOMEM with *out_stmt NULL;
 * no SQL is executed by prepare. The SQL string may be released after success.
 *
 * @param db       The database connection.
 * @param sql      Null-terminated SQL statement string (UTF-8).
 * @param out_stmt Pointer to receive the prepared statement handle.
 * @return         CybouDB_OK on success, or an CybouDB error code.
 */
int cyboudb_prepare(cyboudb_db *db, const char *sql, cyboudb_stmt **out_stmt);

/**
 * Advance a prepared statement to the next matching row.
 *
 * @param stmt     The prepared statement.
 * @return         CybouDB_ROW if a row is ready, CybouDB_DONE if exhausted,
 *                 or CybouDB_ERROR on failure.
 */
int cyboudb_step(cyboudb_stmt *stmt);

/**
 * Vectorized batch stepping: advances the prepared statement to the next
 * batch of up to 64 rows, returning borrowed typed views. RAW columns may
 * reference mapped storage; encoded columns reference temporary decoded storage.
 * COUNT(*) returns one INT64 aggregate row, including for an empty input.
 * Use cyboudb_batch_column() to access columns in SELECT projection order.
 * Batch pointers expire on the next step, reset, finalize or mutation on this
 * connection. Do not mix row and batch stepping without resetting first.
 *
 * @param stmt      The prepared statement.
 * @param out_batch Pointer to receive the batch descriptor.
 * @param out_mask  Pointer to receive the 64-bit lane selection mask.
 * @return          CybouDB_ROW if a non-empty batch was produced,
 *                  CybouDB_DONE if scan is exhausted, or CybouDB_ERROR.
 */
int cyboudb_step_batch(cyboudb_stmt *stmt, const cyboudb_batch_view **out_batch, uint64_t *out_mask);

/**
 * Return a column of the current batch by zero-based result index, preserving
 * reordered and duplicate SELECT projections. Returns NULL for invalid indices,
 * NULL arguments, another statement's batch or an exhausted/reset statement.
 * The returned view has the same lifetime as the batch.
 * TEXT/BLOB columns intentionally return NULL here because their internal
 * values are non-contiguous extent descriptors. Use cyboudb_batch_bytes().
 */
const cyboudb_colview *cyboudb_batch_column(cyboudb_stmt *stmt,
                                    const cyboudb_batch_view *batch, int result_col);

/**
 * Copy one selected TEXT/BLOB cell from the current batch into caller-owned
 * memory. Returns its non-negative logical byte length on success,
 * CybouDB_MISUSE for invalid arguments/type/capacity, or CybouDB_ERROR for a
 * corrupt extent chain. NULL and empty both return zero; inspect the batch
 * column null_mask before calling to distinguish them.
 */
int64_t cyboudb_batch_bytes(cyboudb_stmt *stmt,
                            const cyboudb_batch_view *batch,
                            int result_col, uint32_t row,
                            void *out, uint64_t capacity);

/**
 * Reset a prepared statement back to its initial state so it can be re-run.
 *
 * @param stmt     The prepared statement.
 * @return         CybouDB_OK on success.
 */
int cyboudb_reset(cyboudb_stmt *stmt);

/**
 * Destroy a prepared statement and release all its resources.
 *
 * @param stmt     The statement to destroy.
 * @return         CybouDB_OK on success.
 */
int cyboudb_finalize(cyboudb_stmt *stmt);

/* =============================================================================
 *  Column Accessors (Current Row)
 * =============================================================================
 */

/**
 * Return the number of projected columns in the result set.
 */
int cyboudb_column_count(cyboudb_stmt *stmt);

/**
 * Return the data type of the specified column (0-indexed).
 */
int cyboudb_column_type(cyboudb_stmt *stmt, int col_idx);

/**
 * Return the name of the specified column (0-indexed).
 * Names are owned by the statement and remain valid until finalize, including
 * across reset and database mutations. Types and projection order are also
 * captured at prepare time. Non-result statements have zero result columns.
 */
const char *cyboudb_column_name(cyboudb_stmt *stmt, int col_idx);

/**
 * Check if the column value in the current row is NULL.
 *
 * @return 1 if NULL, 0 if non-NULL.
 */
int cyboudb_column_is_null(cyboudb_stmt *stmt, int col_idx);

/**
 * Return the 64-bit integer value of the column.
 */
int64_t cyboudb_column_int64(cyboudb_stmt *stmt, int col_idx);

/**
 * Return the 32-bit integer value of the column.
 */
int32_t cyboudb_column_int32(cyboudb_stmt *stmt, int col_idx);

/**
 * Return the 32-bit float value of the column.
 */
float cyboudb_column_float(cyboudb_stmt *stmt, int col_idx);

/**
 * Return the boolean value of the column (1 for TRUE, 0 for FALSE).
 */
int cyboudb_column_bool(cyboudb_stmt *stmt, int col_idx);

/**
 * Copy the current TEXT/BLOB value into caller-owned memory.
 *
 * On a valid TEXT/BLOB column, *out_length receives the logical byte length.
 * Empty and NULL values both have length zero; use cyboudb_column_is_null() to
 * distinguish them. A NULL output pointer is accepted only for zero-length
 * values. The destination is unchanged when capacity is insufficient or the
 * persistent extent chain fails validation.
 *
 * @return CybouDB_OK, CybouDB_MISUSE for invalid arguments/type/capacity, or
 *         CybouDB_ERROR if the persistent value is corrupt.
 */
int cyboudb_column_bytes(cyboudb_stmt *stmt, int col_idx, void *out,
                         uint64_t capacity, uint64_t *out_length);

/* =============================================================================
 *  Convenience One-Shot Execution
 * =============================================================================
 */

/**
 * Execute exactly one SQL statement and discard any result rows.
 * Use prepare/step or step_batch to consume results. Multiple statements are
 * rejected before execution; a trailing semicolon and comments are allowed.
 * Mutations follow the same autocommit rules as cyboudb_step.
 *
 * @param db       The database connection.
 * @param sql      SQL string.
 * @return         CybouDB_OK on success, or an CybouDB error code.
 */
int cyboudb_exec(cyboudb_db *db, const char *sql);

#ifdef __cplusplus
}
#endif

#endif /* CybouDB_H */
