/*
 * Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
 * SPDX-License-Identifier: Apache-2.0
 */
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

/* --- Version --------------------------------------------------------------
 * The product version, which is not the on-disk format version. This says
 * which build is doing the asking.
 *
 * Compatibility runs one way. A newer release supporting format v1 is expected
 * to read files produced by earlier released format-v1 builds. An older binary
 * is NOT guaranteed to open a file that uses feature bits introduced by a newer
 * release: an unrecognised incompatible feature bit obliges a reader to refuse
 * the file rather than guess at it, and that refusal is the format working as
 * designed. See docs/FORMAT.md, which is normative.
 */
#define CybouDB_VERSION         "0.7.0-dev"
#define CybouDB_VERSION_MAJOR   0
#define CybouDB_VERSION_MINOR   7
#define CybouDB_VERSION_PATCH   0

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
#define CybouDB_TYPE_VECTOR     7       /* Fixed-dimension float vector */

/* --- Codecs (Per-Column Compression) -------------------------------------- */
#define CybouDB_CODEC_RAW       0       /* Uncompressed raw values */
#define CybouDB_CODEC_CONST     1       /* Constant value across leaf */
#define CybouDB_CODEC_FOR       2       /* Frame-of-Reference (base + bitpacked) */

/* --- Feature Flags -------------------------------------------------------- */
#define CybouDB_FEATURE_COMPRESSION 0x0200 /* Per-column compression capability */
#define CybouDB_FEATURE_VECTOR      0x0800 /* Persistent vector storage capability */

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

/* --- Allocation-free Vector Runtime -------------------------------------- */
#define CybouDB_VECTOR_ABI_VERSION 2

#define CybouDB_VECTOR_OK          0
#define CybouDB_VECTOR_INVALID    -1
#define CybouDB_VECTOR_NONFINITE  -2
#define CybouDB_VECTOR_FULL       -3

typedef struct cyboudb_vector_arena {
    uint32_t struct_size;       /* sizeof(cyboudb_vector_arena) */
    uint32_t abi_version;       /* CybouDB_VECTOR_ABI_VERSION */
    float *base;
    uint64_t capacity;          /* caller-owned bytes at base */
    uint64_t used;
    uint64_t dimensions;
    uint64_t stride;
    uint64_t count;
} cyboudb_vector_arena;

typedef struct cyboudb_vector_topk {
    uint32_t struct_size;       /* sizeof(cyboudb_vector_topk) */
    uint32_t abi_version;       /* CybouDB_VECTOR_ABI_VERSION */
    const float *query;
    const float *vectors;
    uint64_t count;
    uint64_t dimensions;
    uint64_t k;
    uint64_t stride;
    uint64_t *out_ids;
    float *out_scores;
    uint64_t out_count;
    const uint64_t *candidates;
    uint64_t evaluated_count;
    uint64_t reverse;           /* 0: keep the k nearest; 1: keep the k farthest */
} cyboudb_vector_topk;

/**
 * Initialize a caller-owned contiguous vector arena.
 * Sets struct_size and abi_version, initializes counters to zero.
 */
int cyboudb_vector_arena_init(cyboudb_vector_arena *arena, void *memory,
                              uint64_t capacity, uint64_t dimensions);

/**
 * Append a raw FLOAT32 vector exactly as supplied into the arena.
 * Validates that all float elements are finite (no NaN or Inf).
 * Returns CybouDB_VECTOR_OK and assigns *out_id on success.
 */
int cyboudb_vector_arena_append_raw(cyboudb_vector_arena *arena,
                                    const float *vector, uint64_t *out_id);

/**
 * Append and normalize a FLOAT32 vector into the arena for cosine search.
 * Rejects zero, NaN, and Inf vectors with CybouDB_VECTOR_INVALID or
 * CybouDB_VECTOR_NONFINITE without modifying the arena.
 */
int cyboudb_vector_arena_append_normalized(cyboudb_vector_arena *arena,
                                           const float *vector, uint64_t *out_id);

/**
 * Default append: appends a raw FLOAT32 vector (alias for cyboudb_vector_arena_append_raw).
 */
int cyboudb_vector_arena_append(cyboudb_vector_arena *arena,
                                const float *vector, uint64_t *out_id);

/**
 * Retrieve a pointer to the vector at slot vector_id in the arena.
 * Returns NULL if vector_id >= arena->count or arena validation fails.
 */
const float *cyboudb_vector_arena_get(const cyboudb_vector_arena *arena,
                                      uint64_t vector_id);

/**
 * Normalize an input FLOAT32 vector using Euclidean (L2) norm.
 * Input and output may alias. Rejects zero vectors (CybouDB_VECTOR_INVALID)
 * and non-finite / overflowing vectors (CybouDB_VECTOR_NONFINITE).
 */
int cyboudb_vector_normalize_f32(const float *input, float *output,
                                 uint64_t dimensions);

/**
 * Compute the dot product of two FLOAT32 vectors.
 * For dimensions > 0, left and right must each reference dimensions readable floats.
 * For dimensions == 0, returns 0.0f and left/right may be NULL.
 */
float cyboudb_vector_dot_f32(const float *left, const float *right,
                             uint64_t dimensions);

/**
 * Compute the squared Euclidean (L2) distance of two FLOAT32 vectors.
 * For dimensions > 0, left and right must each reference dimensions readable floats.
 * For dimensions == 0, returns 0.0f and left/right may be NULL.
 */
float cyboudb_vector_l2sq_f32(const float *left, const float *right,
                              uint64_t dimensions);

/**
 * Initialize a vector Top-K search descriptor with current ABI metadata.
 */
int cyboudb_vector_topk_init(cyboudb_vector_topk *search);

/**
 * Begin a streaming exact cosine Top-K search session.
 * Resets search->out_count and search->evaluated_count to zero and validates parameters.
 */
int cyboudb_vector_topk_cosine_begin(cyboudb_vector_topk *search);

/**
 * Feed a batch of up to 64 vectors with a 64-bit candidate selection mask into cosine Top-K.
 * If bit i of candidate_mask is 1, evaluates vectors[i] against search->query and updates Top-K.
 */
int cyboudb_vector_topk_cosine_feed(cyboudb_vector_topk *search,
                                    uint64_t base_id,
                                    const float *vectors,
                                    uint64_t count,
                                    uint64_t candidate_mask);

/**
 * Finish a streaming exact cosine Top-K session.
 */
int cyboudb_vector_topk_cosine_finish(cyboudb_vector_topk *search);

/**
 * Begin a streaming exact squared-L2 Top-K search session.
 */
int cyboudb_vector_topk_l2sq_begin(cyboudb_vector_topk *search);

/**
 * Feed a batch of up to 64 vectors with a 64-bit candidate selection mask into squared-L2 Top-K.
 */
int cyboudb_vector_topk_l2sq_feed(cyboudb_vector_topk *search,
                                  uint64_t base_id,
                                  const float *vectors,
                                  uint64_t count,
                                  uint64_t candidate_mask);

/**
 * Finish a streaming exact squared-L2 Top-K session.
 */
int cyboudb_vector_topk_l2sq_finish(cyboudb_vector_topk *search);

/**
 * Monolithic exact cosine Top-K search over contiguous candidate array.
 */
int cyboudb_vector_topk_cosine_f32(cyboudb_vector_topk *search);

/**
 * Monolithic exact squared-L2 Top-K search over contiguous candidate array.
 */
int cyboudb_vector_topk_l2sq_f32(cyboudb_vector_topk *search);

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
 * Create a database file and open it read-write.
 *
 * One kind of database is made, and it is the one to want: tables, secondary
 * indexes, TEXT/BLOB storage, vectors, queues, streams, and the per-row
 * tombstone reservation that lets DELETE mark rows instead of rewriting the
 * table. That reservation exists only if it was made when the file was
 * created, so this is the profile rather than a smaller one.
 *
 * @param path     UTF-8 path. An existing file is not replaced.
 * @param pages    Size of the file in 4 KiB pages.
 * @param out_db   Receives the handle on success, NULL otherwise.
 * @return CybouDB_OK, or CybouDB_ERROR if the file could not be created
 *         (including because something is already at that path).
 */
int cyboudb_create(const char *path, uint64_t pages, cyboudb_db **out_db);

/**
 * Capabilities a database can only be given when it is made.
 *
 * Some things are decided once, in the file header, and never afterwards -
 * queue leases are the first. Set `struct_size` to `sizeof` this struct as
 * your build sees it; a library that later learns a new field uses that to
 * tell whether you knew about it, which is what lets this grow without a
 * third entry point.
 *
 * A flag this build does not implement is refused rather than ignored. Asking
 * for a capability and quietly receiving a database without it is the one
 * outcome that would be worse than an error.
 *
 * **The rule that keeps that true as this struct grows:** `struct_size` may
 * safely carry new fields, but any field that changes the database being made,
 * or asks for a capability, must come with a flag of its own. The two do
 * different jobs -
 *
 *     struct_size   safely widens the representation
 *     flags         declare the semantics being asked for
 *
 * - and only the second is something an older library can refuse. A future
 * field added without a flag would be ignored by a build that predates it,
 * which would then silently create a database other than the one the caller
 * asked for: the failure this design exists to prevent, arriving through the
 * mechanism meant to allow growth.
 */
typedef struct cyboudb_create_options {
    uint32_t struct_size;
    uint32_t flags;
} cyboudb_create_options;

/** Queues may be claimed with a deadline. See docs/QUEUE.md. */
#define CybouDB_CREATE_QUEUE_LEASES 0x0001u

/**
 * Create a database with capabilities chosen at creation.
 *
 * `options` may be NULL, which is exactly cyboudb_create - the profile a
 * caller who was not asked gets. A database created without a capability stays
 * readable by builds that predate it; one created with it is refused by them,
 * saying which capability it needs.
 *
 * @return CybouDB_OK, CybouDB_MISUSE for a null path or out_db, a
 *         `struct_size` smaller than the fields it must have, or a flag this
 *         build does not implement, and CybouDB_ERROR if the file could not be
 *         created or opened.
 */
int cyboudb_create_with_options(const char *path, uint64_t pages,
                                const cyboudb_create_options *options,
                                cyboudb_db **out_db);

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
/**
 * Why the most recent call failed, or "ok" when it did not.
 *
 * The message describes the call that just returned, and nothing earlier: an
 * entry point that can fail clears it on the way in. A caller may therefore
 * read it after any call and know what it is about, rather than having to
 * remember whether the last few succeeded.
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
 * TEXT/BLOB and VECTOR columns intentionally return NULL here because their
 * internal values are non-contiguous extent descriptors. Use cyboudb_batch_bytes()
 * or cyboudb_batch_vector_f32().
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
 * Copy one selected VECTOR cell from the current batch into caller-owned float
 * memory. Returns its dimension count on success, CybouDB_MISUSE for invalid
 * arguments/type/capacity, or CybouDB_ERROR for a corrupt extent chain.
 * NULL returns zero; inspect the batch column null_mask before calling to
 * distinguish NULL from non-NULL.
 *
 * @param stmt             The prepared statement.
 * @param batch            The current batch view.
 * @param result_col       Result column index (0-indexed).
 * @param row              Row offset within the batch run (0..row_count-1).
 * @param out              Destination float buffer.
 * @param capacity_floats  Maximum number of float elements out can hold.
 * @return                 Dimension count (>0) on success, 0 for NULL, or negative on error.
 */
int64_t cyboudb_batch_vector_f32(cyboudb_stmt *stmt,
                                 const cyboudb_batch_view *batch,
                                 int result_col, uint32_t row,
                                 float *out, uint64_t capacity_floats);

/**
 * Reset a prepared statement back to its initial state so it can be re-run.
 *
 * @param stmt     The prepared statement.
 * @return         CybouDB_OK on success.
 */
int cyboudb_reset(cyboudb_stmt *stmt);

/*
 * Parameters.
 *
 * A `?` is a placeholder whose value arrives before the statement is stepped.
 * Placeholders are positional and unnamed: the first `?` in a statement is
 * parameter 0, and the statement says how many it has.
 *
 * They are accepted in INSERT ... VALUES and on the value side of a WHERE
 * comparison. A predicate parameter takes the four scalar types a comparison
 * already takes - INT32, INT64, FLOAT32 and BOOL - and not TEXT, BLOB or
 * VECTOR, which is where predicate comparisons already stopped. NULL is not
 * bindable in a predicate either: `x = NULL` is unknown rather than a
 * comparison against a value, and IS NULL is how to ask that.
 *
 * A bound value is input to one execution, not part of the prepared plan, so
 * binding never changes what prepare produced and a statement may be bound,
 * stepped, reset and bound again. Bindings survive cyboudb_reset; they are
 * gone when the statement is finalized.
 *
 * The engine copies the bytes of TEXT, BLOB and VECTOR values, so the caller's
 * buffer stops mattering the moment the call returns. That buffer is bounded:
 * a value it cannot hold is CybouDB_NOMEM at the call rather than a dangling
 * pointer at commit. Re-binding a parameter reuses the bytes it already owns
 * when the new value fits, so binding in a loop does not exhaust it.
 *
 * Each bind names the column type it is for and refuses any other, rather than
 * converting: what gets stored should not depend on which function the caller
 * reached for. An unbound parameter stops the statement at step; it does not
 * quietly become NULL.
 */

/*
 * How many parameters the statement holds. Zero for a statement with none,
 * and zero for an invalid handle.
 */
int cyboudb_bind_parameter_count(cyboudb_stmt *stmt);

/*
 * @return CybouDB_OK, or CybouDB_MISUSE for a bad handle, an index outside the
 *         statement's parameters, a column of a different type, or a bind
 *         while a scan is in progress. CybouDB_NOMEM when a TEXT, BLOB or
 *         VECTOR value does not fit the statement's copy buffer.
 */
int cyboudb_bind_int32(cyboudb_stmt *stmt, int idx, int32_t value);
int cyboudb_bind_int64(cyboudb_stmt *stmt, int idx, int64_t value);
int cyboudb_bind_float(cyboudb_stmt *stmt, int idx, float value);
int cyboudb_bind_bool(cyboudb_stmt *stmt, int idx, int value);

/* A negative len means text is NUL-terminated and the engine measures it. The
 * terminator is not stored: TEXT is bytes and a length. */
int cyboudb_bind_text(cyboudb_stmt *stmt, int idx, const char *text,
                      int64_t len);
int cyboudb_bind_blob(cyboudb_stmt *stmt, int idx, const void *data,
                      int64_t len);

/* dims must equal the column's declared dimension; the width is part of the
 * type, and nothing downstream would catch a vector of the wrong one. */
int cyboudb_bind_vector_f32(cyboudb_stmt *stmt, int idx, const float *values,
                            int dims);

/* CybouDB_MISUSE if the column does not accept NULL - said here rather than
 * halfway through an insert. */
int cyboudb_bind_null(cyboudb_stmt *stmt, int idx);

/*
 * Return every parameter to unbound.
 *
 * The three verbs are separable on purpose:
 *
 *   cyboudb_reset            clears what an execution did, keeps the bindings
 *   cyboudb_clear_bindings   clears the bindings, keeps the statement
 *   cyboudb_finalize         destroys both
 *
 * Without the middle one the only way back to unbound is to prepare the
 * statement again.
 *
 * @return CybouDB_OK, or CybouDB_MISUSE for a bad handle or a call while a
 *         scan is in progress. A statement with no parameters succeeds.
 */
int cyboudb_clear_bindings(cyboudb_stmt *stmt);

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

/**
 * Copy the message the last step of a DEQUEUE took.
 *
 * A queue holds bytes and no schema to say how to read them, so a message is
 * not a column and is not presented as one. `cyboudb_step` on a DEQUEUE
 * answers CybouDB_ROW when it took a message and CybouDB_DONE when the queue
 * was empty; this fetches the bytes after a ROW. Stepping again asks again -
 * a queue is not a result set that runs out, and a message enqueued in
 * between is there to be taken.
 *
 * Each step is its own transaction unless one is already open, which is the
 * commit-then-work order: a crash after the step has taken the message and
 * not done the work. A caller that wants the other order opens a transaction
 * around the step. See docs/QUEUE.md.
 *
 * The bytes stay valid until the next step or the finalize.
 *
 * @return CybouDB_OK, or CybouDB_MISUSE when the last step took nothing, the
 *         statement is not a DEQUEUE, or the buffer is too small.
 */
int cyboudb_message(cyboudb_stmt *stmt, void *out, uint64_t capacity,
                    uint64_t *out_length);

/**
 * What the last CLAIM took, and the proof that this caller holds it.
 *
 * `CLAIM FROM q FOR <milliseconds>` takes the first claimable message and
 * gives it a deadline instead of removing it. Stepping it answers CybouDB_ROW
 * when it took one and CybouDB_DONE when nothing was claimable; the bytes come
 * out through cyboudb_message, and this hands back the position and the token
 * to acknowledge it with:
 *
 *     ACK   FROM q AT <position> TOKEN <token>
 *     NACK  FROM q AT <position> TOKEN <token>
 *     RENEW FROM q AT <position> TOKEN <token> FOR <milliseconds>
 *
 * The ticket is data the caller keeps rather than state the statement
 * remembers, because a worker acknowledges from a different transaction and
 * possibly after the file was reopened.
 *
 * The deadline decides when a message becomes claimable again; the token
 * decides whose acknowledgement counts. A lapsed deadline is not by itself a
 * refusal - if another worker had taken the message, the token would say so.
 * See docs/QUEUE.md.
 *
 * Either pointer may be NULL.
 *
 * @return CybouDB_OK, or CybouDB_MISUSE for a bad handle, a statement that is
 *         not a CLAIM, or a claim whose last step took nothing.
 */
int cyboudb_claim_ticket(cyboudb_stmt *stmt, uint64_t *position,
                         uint64_t *token);

/**
 * Return the dimension count of a VECTOR column (1..4096).
 *
 * @param stmt     The prepared statement.
 * @param col_idx  Result column index (0-indexed).
 * @return         Dimension count on success, or negative CybouDB_MISUSE
 *                 if not a vector column or invalid argument.
 */
int cyboudb_column_vector_dimensions(cyboudb_stmt *stmt, int col_idx);

/**
 * Copy the current VECTOR value into caller-owned float memory.
 *
 * On a valid VECTOR column, *out_dim receives the dimension count.
 * NULL values have dimension zero; use cyboudb_column_is_null() to distinguish
 * them. A NULL output pointer is accepted only for NULL values.
 *
 * @param stmt             The prepared statement.
 * @param col_idx          Result column index (0-indexed).
 * @param out              Destination float buffer.
 * @param capacity_floats  Maximum number of float elements out can hold.
 * @param out_dim          Receives dimension count (or 0 for NULL).
 * @return                 CybouDB_OK, CybouDB_MISUSE for invalid arguments/type/capacity,
 *                         or CybouDB_ERROR if the persistent value is corrupt.
 */
int cyboudb_column_vector_f32(cyboudb_stmt *stmt, int col_idx, float *out,
                             uint64_t capacity_floats, uint64_t *out_dim);

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
