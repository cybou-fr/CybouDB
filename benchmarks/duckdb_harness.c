/*
 * benchmarks/duckdb_harness.c - in-process measurement of DuckDB query execution
 *
 * Mirrors benchmarks/bench_harness.asm and benchmarks/sqlite_harness.c:
 *  - Opens the database once outside the measured region
 *  - Prepares the statement once outside the measured region
 *  - Warms up for WARMUP iterations
 *  - Measures N iterations with monotonic ns and RDTSC
 *  - Writes the same 80-byte binary record the other two harnesses write
 *
 * Results are consumed through the DuckDB C API: a streaming result is pulled
 * chunk by chunk, and the raw typed vectors of each chunk are read directly.
 * Nothing crosses a Python boundary and no row objects are materialized, so
 * what falls between the two clock reads is DuckDB's scan, its predicate
 * evaluation and the delivery of its DataChunks, and nothing else.
 *
 * The DuckDB C API is resolved at run time from a shared library, so this file
 * builds with no DuckDB headers or import library present. Point DUCKDB_DLL at
 * the library to use; the Python wheel's extension module exports the full C
 * API and works as one.
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <intrin.h>
#include <io.h>
#include <fcntl.h>
#else
#include <time.h>
#include <dlfcn.h>
#include <x86intrin.h>
#endif

#define DUCKDB_SUCCESS 0

/* duckdb_type ids used by this benchmark's schema */
#define DUCKDB_TYPE_BOOLEAN 1
#define DUCKDB_TYPE_INTEGER 4
#define DUCKDB_TYPE_BIGINT  5
#define DUCKDB_TYPE_FLOAT   10
#define DUCKDB_TYPE_DOUBLE  11

#define FNV_OFFSET_BASIS 14695981039346656037ULL
#define FNV_PRIME        1099511628211ULL
#define TAG_NULL         0xBFULL
#define TAG_VALUE        0x5AULL

typedef uint64_t idx_t;

/* Opaque handles: every one of these is a single pointer in the C API. */
typedef void *duckdb_database;
typedef void *duckdb_connection;
typedef void *duckdb_prepared_statement;
typedef void *duckdb_config;
typedef void *duckdb_data_chunk;
typedef void *duckdb_vector;

/*
 * duckdb_result is passed to duckdb_fetch_chunk by value, so its layout has to
 * be declared exactly. This is the 1.x definition; every field but the last is
 * deprecated and is only read through accessor functions here.
 */
typedef struct {
    idx_t deprecated_column_count;
    idx_t deprecated_row_count;
    idx_t deprecated_rows_changed;
    void *deprecated_columns;
    char *deprecated_error_message;
    void *internal_data;
} duckdb_result;

typedef int (*fn_open_ext)(const char *path, duckdb_database *out, duckdb_config config, char **err);
typedef int (*fn_create_config)(duckdb_config *out);
typedef int (*fn_set_config)(duckdb_config config, const char *name, const char *option);
typedef void (*fn_destroy_config)(duckdb_config *config);
typedef int (*fn_connect)(duckdb_database db, duckdb_connection *out);
typedef int (*fn_prepare)(duckdb_connection con, const char *sql, duckdb_prepared_statement *out);
typedef int (*fn_execute_prepared)(duckdb_prepared_statement stmt, duckdb_result *out);
typedef duckdb_data_chunk (*fn_fetch_chunk)(duckdb_result result);
typedef idx_t (*fn_chunk_get_size)(duckdb_data_chunk chunk);
typedef duckdb_vector (*fn_chunk_get_vector)(duckdb_data_chunk chunk, idx_t col);
typedef void *(*fn_vector_get_data)(duckdb_vector vector);
typedef uint64_t *(*fn_vector_get_validity)(duckdb_vector vector);
typedef void (*fn_destroy_chunk)(duckdb_data_chunk *chunk);
typedef void (*fn_destroy_result)(duckdb_result *result);
typedef void (*fn_destroy_prepare)(duckdb_prepared_statement *stmt);
typedef void (*fn_disconnect)(duckdb_connection *con);
typedef void (*fn_close)(duckdb_database *db);
typedef const char *(*fn_library_version)(void);
typedef idx_t (*fn_column_count)(duckdb_result *result);
typedef int (*fn_column_type)(duckdb_result *result, idx_t col);
typedef const char *(*fn_prepare_error)(duckdb_prepared_statement stmt);

static fn_open_ext p_open_ext = NULL;
static fn_create_config p_create_config = NULL;
static fn_set_config p_set_config = NULL;
static fn_destroy_config p_destroy_config = NULL;
static fn_connect p_connect = NULL;
static fn_prepare p_prepare = NULL;
static fn_execute_prepared p_execute_streaming = NULL;
static fn_fetch_chunk p_fetch_chunk = NULL;
static fn_chunk_get_size p_chunk_get_size = NULL;
static fn_chunk_get_vector p_chunk_get_vector = NULL;
static fn_vector_get_data p_vector_get_data = NULL;
static fn_vector_get_validity p_vector_get_validity = NULL;
static fn_destroy_chunk p_destroy_chunk = NULL;
static fn_destroy_result p_destroy_result = NULL;
static fn_destroy_prepare p_destroy_prepare = NULL;
static fn_disconnect p_disconnect = NULL;
static fn_close p_close = NULL;
static fn_library_version p_library_version = NULL;
static fn_column_count p_column_count = NULL;
static fn_column_type p_column_type = NULL;
static fn_prepare_error p_prepare_error = NULL;

#ifdef _WIN32
static HMODULE lib_handle = NULL;
#define SYM(name) GetProcAddress(lib_handle, name)
#else
static void *lib_handle = NULL;
#define SYM(name) dlsym(lib_handle, name)
#endif

static int load_duckdb(void) {
    const char *env_lib = getenv("DUCKDB_DLL");

#ifdef _WIN32
    if (env_lib && *env_lib) {
        /* The Python wheel's extension module resolves its own dependencies
         * from the interpreter directory, so search alongside the library. */
        lib_handle = LoadLibraryExA(env_lib, NULL, LOAD_WITH_ALTERED_SEARCH_PATH);
        if (!lib_handle) {
            lib_handle = LoadLibraryA(env_lib);
        }
    }
    if (!lib_handle) {
        lib_handle = LoadLibraryA("duckdb.dll");
    }
#else
    if (env_lib && *env_lib) {
        lib_handle = dlopen(env_lib, RTLD_NOW);
    }
    if (!lib_handle) {
        lib_handle = dlopen("libduckdb.so", RTLD_NOW);
    }
#endif
    if (!lib_handle) {
        fprintf(stderr, "error: could not load the DuckDB library; set DUCKDB_DLL\n");
        return -1;
    }

    p_open_ext = (fn_open_ext)SYM("duckdb_open_ext");
    p_create_config = (fn_create_config)SYM("duckdb_create_config");
    p_set_config = (fn_set_config)SYM("duckdb_set_config");
    p_destroy_config = (fn_destroy_config)SYM("duckdb_destroy_config");
    p_connect = (fn_connect)SYM("duckdb_connect");
    p_prepare = (fn_prepare)SYM("duckdb_prepare");
    p_execute_streaming = (fn_execute_prepared)SYM("duckdb_execute_prepared_streaming");
    if (!p_execute_streaming) {
        p_execute_streaming = (fn_execute_prepared)SYM("duckdb_execute_prepared");
    }
    p_fetch_chunk = (fn_fetch_chunk)SYM("duckdb_fetch_chunk");
    p_chunk_get_size = (fn_chunk_get_size)SYM("duckdb_data_chunk_get_size");
    p_chunk_get_vector = (fn_chunk_get_vector)SYM("duckdb_data_chunk_get_vector");
    p_vector_get_data = (fn_vector_get_data)SYM("duckdb_vector_get_data");
    p_vector_get_validity = (fn_vector_get_validity)SYM("duckdb_vector_get_validity");
    p_destroy_chunk = (fn_destroy_chunk)SYM("duckdb_destroy_data_chunk");
    p_destroy_result = (fn_destroy_result)SYM("duckdb_destroy_result");
    p_destroy_prepare = (fn_destroy_prepare)SYM("duckdb_destroy_prepare");
    p_disconnect = (fn_disconnect)SYM("duckdb_disconnect");
    p_close = (fn_close)SYM("duckdb_close");
    p_library_version = (fn_library_version)SYM("duckdb_library_version");
    p_column_count = (fn_column_count)SYM("duckdb_column_count");
    p_column_type = (fn_column_type)SYM("duckdb_column_type");
    p_prepare_error = (fn_prepare_error)SYM("duckdb_prepare_error");

    if (!p_open_ext || !p_connect || !p_prepare || !p_execute_streaming ||
        !p_fetch_chunk || !p_chunk_get_size || !p_chunk_get_vector ||
        !p_vector_get_data || !p_vector_get_validity || !p_destroy_chunk ||
        !p_destroy_result || !p_column_count || !p_column_type) {
        fprintf(stderr, "error: missing DuckDB C API symbols\n");
        return -1;
    }
    return 0;
}

static uint64_t monotonic_ns(void) {
#ifdef _WIN32
    static LARGE_INTEGER freq;
    static int init = 0;
    LARGE_INTEGER count;
    if (!init) {
        QueryPerformanceFrequency(&freq);
        init = 1;
    }
    QueryPerformanceCounter(&count);
    return (uint64_t)((count.QuadPart * 1000000000ULL) / freq.QuadPart);
#else
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
#endif
}

static uint64_t read_tsc(void) {
    return (uint64_t)__rdtsc();
}

static int row_is_valid(const uint64_t *validity, idx_t row) {
    if (!validity) {
        return 1;
    }
    return (validity[row / 64] & (1ULL << (row % 64))) != 0;
}

/*
 * Consume one result.
 *
 * mode 0 (FILTER): chunks are walked to completion and only their row counts
 * are added up, so nothing per selected row happens outside DuckDB.
 *
 * mode 2 (AGGREGATE): the statement is a COUNT, so the single BIGINT of the
 * result is read out and reported as the selected-row count. This is what the
 * filter comparison uses, and it is how the parity check gets its number.
 *
 * mode 1 (MATERIALIZE): every projected cell of every chunk is read out of the
 * raw typed vector and folded into the same tagged FNV-1a hash the CybouDB and
 * SQLite harnesses compute, in row-major order, so the three checksums are
 * comparable bit for bit. A second, order-independent accumulator is kept as
 * well, because a multi-threaded DuckDB result is not required to arrive in
 * table order.
 */
static void consume_result(duckdb_result *result, uint64_t mode, int col_count,
                           const int *col_types, uint64_t *selected,
                           uint64_t *checksum, uint64_t *unordered) {
    duckdb_data_chunk chunk;
    while ((chunk = p_fetch_chunk(*result)) != NULL) {
        idx_t rows = p_chunk_get_size(chunk);
        if (mode == 0) {
            *selected += (uint64_t)rows;
        } else if (mode == 2) {
            duckdb_vector v = p_chunk_get_vector(chunk, 0);
            const int64_t *data = (const int64_t *)p_vector_get_data(v);
            for (idx_t r = 0; r < rows; r++) {
                *selected += (uint64_t)data[r];
            }
        } else {
            *selected += (uint64_t)rows;
            for (idx_t r = 0; r < rows; r++) {
                uint64_t row_hash = FNV_OFFSET_BASIS;
                for (int c = 0; c < col_count; c++) {
                    duckdb_vector v = p_chunk_get_vector(chunk, (idx_t)c);
                    const void *data = p_vector_get_data(v);
                    const uint64_t *validity = p_vector_get_validity(v);
                    if (!row_is_valid(validity, r)) {
                        *checksum ^= TAG_NULL;
                        *checksum *= FNV_PRIME;
                        row_hash ^= TAG_NULL;
                        row_hash *= FNV_PRIME;
                        continue;
                    }
                    uint64_t val;
                    switch (col_types[c]) {
                    case DUCKDB_TYPE_BOOLEAN:
                        val = (uint64_t)((const uint8_t *)data)[r];
                        break;
                    case DUCKDB_TYPE_INTEGER:
                        val = (uint64_t)(uint32_t)((const int32_t *)data)[r];
                        break;
                    case DUCKDB_TYPE_FLOAT: {
                        float f = ((const float *)data)[r];
                        uint32_t u;
                        memcpy(&u, &f, 4);
                        val = (uint64_t)u;
                        break;
                    }
                    case DUCKDB_TYPE_DOUBLE: {
                        float f = (float)((const double *)data)[r];
                        uint32_t u;
                        memcpy(&u, &f, 4);
                        val = (uint64_t)u;
                        break;
                    }
                    default:
                        val = (uint64_t)((const int64_t *)data)[r];
                        break;
                    }
                    *checksum ^= TAG_VALUE;
                    *checksum *= FNV_PRIME;
                    *checksum ^= val;
                    *checksum *= FNV_PRIME;
                    row_hash ^= TAG_VALUE;
                    row_hash *= FNV_PRIME;
                    row_hash ^= val;
                    row_hash *= FNV_PRIME;
                }
                *unordered += row_hash;
            }
        }
        p_destroy_chunk(&chunk);
    }
}

int main(int argc, char **argv) {
    if (argc >= 2 && strcmp(argv[1], "--version") == 0) {
        if (load_duckdb() != 0) return 1;
        printf("%s\n", p_library_version ? p_library_version() : "unknown");
        return 0;
    }

    if (argc < 4) {
        fprintf(stderr,
                "Usage: %s <database> <sql> <iterations> [warmup] [mode] [threads]\n",
                argv[0]);
        return 1;
    }

    const char *db_path = argv[1];
    const char *sql = argv[2];
    uint64_t iterations = strtoull(argv[3], NULL, 10);
    uint64_t warmup = (argc >= 5) ? strtoull(argv[4], NULL, 10) : 0;
    uint64_t mode = (argc >= 6) ? strtoull(argv[5], NULL, 10) : 0;
    const char *threads = (argc >= 7) ? argv[6] : "1";
    if (iterations == 0) iterations = 1;

    uint64_t record[10] = {0};

#ifdef _WIN32
    _setmode(_fileno(stdout), _O_BINARY);
#endif

    if (load_duckdb() != 0) {
        record[0] = 1;
        fwrite(record, 1, sizeof(record), stdout);
        return 1;
    }

    duckdb_config config = NULL;
    if (p_create_config && p_set_config && p_create_config(&config) == DUCKDB_SUCCESS) {
        p_set_config(config, "access_mode", "READ_ONLY");
        p_set_config(config, "threads", threads);
    }

    duckdb_database db = NULL;
    char *open_err = NULL;
    if (p_open_ext(db_path, &db, config, &open_err) != DUCKDB_SUCCESS) {
        fprintf(stderr, "error: could not open %s: %s\n",
                db_path, open_err ? open_err : "unknown");
        record[0] = 2;
        fwrite(record, 1, sizeof(record), stdout);
        return 1;
    }
    if (config && p_destroy_config) {
        p_destroy_config(&config);
    }

    duckdb_connection con = NULL;
    if (p_connect(db, &con) != DUCKDB_SUCCESS) {
        record[0] = 3;
        fwrite(record, 1, sizeof(record), stdout);
        return 1;
    }

    duckdb_prepared_statement stmt = NULL;
    if (p_prepare(con, sql, &stmt) != DUCKDB_SUCCESS) {
        fprintf(stderr, "error: prepare failed: %s\n",
                (p_prepare_error && stmt) ? p_prepare_error(stmt) : "unknown");
        record[0] = 4;
        fwrite(record, 1, sizeof(record), stdout);
        return 1;
    }

    /* One execution outside the measured region establishes the result shape. */
    int col_count = 0;
    int col_types[64] = {0};
    {
        duckdb_result probe;
        memset(&probe, 0, sizeof(probe));
        if (p_execute_streaming(stmt, &probe) != DUCKDB_SUCCESS) {
            fprintf(stderr, "error: execute failed\n");
            record[0] = 5;
            fwrite(record, 1, sizeof(record), stdout);
            return 1;
        }
        col_count = (int)p_column_count(&probe);
        if (col_count > 64) col_count = 64;
        for (int c = 0; c < col_count; c++) {
            col_types[c] = p_column_type(&probe, (idx_t)c);
        }
        uint64_t dummy_sel = 0, dummy_sum = FNV_OFFSET_BASIS, dummy_un = 0;
        consume_result(&probe, mode, col_count, col_types, &dummy_sel, &dummy_sum, &dummy_un);
        p_destroy_result(&probe);
    }

    for (uint64_t w = 0; w < warmup; w++) {
        duckdb_result result;
        memset(&result, 0, sizeof(result));
        if (p_execute_streaming(stmt, &result) != DUCKDB_SUCCESS) {
            record[0] = 5;
            fwrite(record, 1, sizeof(record), stdout);
            return 1;
        }
        uint64_t sel = 0, sum = FNV_OFFSET_BASIS, un = 0;
        consume_result(&result, mode, col_count, col_types, &sel, &sum, &un);
        p_destroy_result(&result);
    }

    uint64_t total_selected = 0;
    uint64_t checksum = FNV_OFFSET_BASIS;
    uint64_t unordered = 0;
    int failed = 0;

    uint64_t t0_tsc = read_tsc();
    uint64_t t0_ns = monotonic_ns();

    for (uint64_t iter = 0; iter < iterations; iter++) {
        duckdb_result result;
        memset(&result, 0, sizeof(result));
        if (p_execute_streaming(stmt, &result) != DUCKDB_SUCCESS) {
            failed = 1;
            break;
        }
        consume_result(&result, mode, col_count, col_types,
                       &total_selected, &checksum, &unordered);
        p_destroy_result(&result);
    }

    uint64_t t1_ns = monotonic_ns();
    uint64_t t1_tsc = read_tsc();

    if (p_destroy_prepare) p_destroy_prepare(&stmt);
    if (p_disconnect) p_disconnect(&con);
    if (p_close) p_close(&db);

    record[0] = failed ? 5 : 0;     /* BENCH_STATUS */
    record[1] = 0;                  /* BENCH_DOMAIN */
    record[2] = iterations;         /* BENCH_ITERATIONS */
    record[3] = total_selected;     /* BENCH_BATCHES */
    record[4] = total_selected;     /* BENCH_SELECTED */
    record[5] = checksum;           /* BENCH_CHECKSUM (row order dependent) */
    record[6] = t1_ns - t0_ns;      /* BENCH_NS */
    record[7] = t1_tsc - t0_tsc;    /* BENCH_TSC */
    record[8] = unordered;          /* order independent checksum */
    record[9] = 0;                  /* BENCH_ROW_BYTES */

    fwrite(record, 1, sizeof(record), stdout);
    fflush(stdout);
    return failed;
}
