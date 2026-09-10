/*
 * benchmarks/sqlite_harness.c - in-process measurement of SQLite query execution
 *
 * Mirrors benchmarks/bench_harness.asm:
 *  - Opens database once outside the measured region
 *  - Prepares (compiles) the SQL statement once outside the measured region
 *  - Warms up for WARMUP iterations
 *  - Measures N iterations of sqlite3_step() loop with monotonic ns and RDTSC
 *  - Outputs the exact 80-byte binary record as bench_harness.asm
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

#define BENCH_RECORD_SIZE 80

#define SQLITE_OK           0
#define SQLITE_ROW          100
#define SQLITE_DONE         101
#define SQLITE_OPEN_READONLY 0x00000001

typedef struct sqlite3 sqlite3;
typedef struct sqlite3_stmt sqlite3_stmt;

typedef int (*fn_sqlite3_initialize)(void);
typedef int (*fn_sqlite3_open_v2)(const char *filename, sqlite3 **ppDb, int flags, const char *zVfs);
typedef int (*fn_sqlite3_prepare_v2)(sqlite3 *db, const char *zSql, int nByte, sqlite3_stmt **ppStmt, const char **pzTail);
typedef int (*fn_sqlite3_step)(sqlite3_stmt *pStmt);
typedef int (*fn_sqlite3_reset)(sqlite3_stmt *pStmt);
typedef int (*fn_sqlite3_finalize)(sqlite3_stmt *pStmt);
typedef int (*fn_sqlite3_close)(sqlite3 *db);
typedef const char *(*fn_sqlite3_errmsg)(sqlite3 *db);
typedef int (*fn_sqlite3_exec)(sqlite3 *db, const char *sql, int (*callback)(void*,int,char**,char**), void *arg, char **errmsg);
typedef int (*fn_sqlite3_column_count)(sqlite3_stmt *pStmt);
typedef int (*fn_sqlite3_column_type)(sqlite3_stmt *pStmt, int iCol);
typedef int64_t (*fn_sqlite3_column_int64)(sqlite3_stmt *pStmt, int iCol);
typedef double (*fn_sqlite3_column_double)(sqlite3_stmt *pStmt, int iCol);
typedef const char *(*fn_sqlite3_column_name)(sqlite3_stmt *pStmt, int N);
typedef const char *(*fn_sqlite3_libversion)(void);
typedef const char *(*fn_sqlite3_sourceid)(void);

static fn_sqlite3_initialize p_sqlite3_initialize = NULL;
static fn_sqlite3_open_v2 p_sqlite3_open_v2 = NULL;
static fn_sqlite3_prepare_v2 p_sqlite3_prepare_v2 = NULL;
static fn_sqlite3_step p_sqlite3_step = NULL;
static fn_sqlite3_reset p_sqlite3_reset = NULL;
static fn_sqlite3_finalize p_sqlite3_finalize = NULL;
static fn_sqlite3_close p_sqlite3_close = NULL;
static fn_sqlite3_errmsg p_sqlite3_errmsg = NULL;
static fn_sqlite3_exec p_sqlite3_exec = NULL;
static fn_sqlite3_column_count p_sqlite3_column_count = NULL;
static fn_sqlite3_column_type p_sqlite3_column_type = NULL;
static fn_sqlite3_column_int64 p_sqlite3_column_int64 = NULL;
static fn_sqlite3_column_double p_sqlite3_column_double = NULL;
static fn_sqlite3_column_name p_sqlite3_column_name = NULL;
static fn_sqlite3_libversion p_sqlite3_libversion = NULL;
static fn_sqlite3_sourceid p_sqlite3_sourceid = NULL;

#define FNV_OFFSET_BASIS 14695981039346656037ULL
#define FNV_PRIME        1099511628211ULL
#define TAG_NULL         0xBFULL
#define TAG_VALUE        0x5AULL

static int load_sqlite(void) {
#ifdef _WIN32
    HMODULE h = NULL;
    const char *env_dll = getenv("SQLITE_DLL");
    if (env_dll && *env_dll) {
        h = LoadLibraryA(env_dll);
    }
    if (!h) {
        h = LoadLibraryA("C:\\Users\\cybou\\AppData\\Local\\Python\\pythoncore-3.14-64\\DLLs\\sqlite3.dll");
    }
    if (!h) {
        h = LoadLibraryA("sqlite3.dll");
    }
    if (!h) {
        fprintf(stderr, "error: could not load sqlite3.dll\n");
        return -1;
    }
    p_sqlite3_initialize = (fn_sqlite3_initialize)GetProcAddress(h, "sqlite3_initialize");
    p_sqlite3_open_v2 = (fn_sqlite3_open_v2)GetProcAddress(h, "sqlite3_open_v2");
    p_sqlite3_prepare_v2 = (fn_sqlite3_prepare_v2)GetProcAddress(h, "sqlite3_prepare_v2");
    p_sqlite3_step = (fn_sqlite3_step)GetProcAddress(h, "sqlite3_step");
    p_sqlite3_reset = (fn_sqlite3_reset)GetProcAddress(h, "sqlite3_reset");
    p_sqlite3_finalize = (fn_sqlite3_finalize)GetProcAddress(h, "sqlite3_finalize");
    p_sqlite3_close = (fn_sqlite3_close)GetProcAddress(h, "sqlite3_close");
    p_sqlite3_errmsg = (fn_sqlite3_errmsg)GetProcAddress(h, "sqlite3_errmsg");
    p_sqlite3_exec = (fn_sqlite3_exec)GetProcAddress(h, "sqlite3_exec");
    p_sqlite3_column_count = (fn_sqlite3_column_count)GetProcAddress(h, "sqlite3_column_count");
    p_sqlite3_column_type = (fn_sqlite3_column_type)GetProcAddress(h, "sqlite3_column_type");
    p_sqlite3_column_int64 = (fn_sqlite3_column_int64)GetProcAddress(h, "sqlite3_column_int64");
    p_sqlite3_column_double = (fn_sqlite3_column_double)GetProcAddress(h, "sqlite3_column_double");
    p_sqlite3_column_name = (fn_sqlite3_column_name)GetProcAddress(h, "sqlite3_column_name");
    p_sqlite3_libversion = (fn_sqlite3_libversion)GetProcAddress(h, "sqlite3_libversion");
    p_sqlite3_sourceid = (fn_sqlite3_sourceid)GetProcAddress(h, "sqlite3_sourceid");
#else
    void *h = NULL;
    const char *env_dll = getenv("SQLITE_DLL");
    if (env_dll && *env_dll) {
        h = dlopen(env_dll, RTLD_NOW);
    }
    if (!h) {
        h = dlopen("libsqlite3.so.0", RTLD_NOW);
    }
    if (!h) {
        h = dlopen("libsqlite3.so", RTLD_NOW);
    }
    if (!h) {
        fprintf(stderr, "error: could not load libsqlite3.so: %s\n", dlerror());
        return -1;
    }
    p_sqlite3_initialize = (fn_sqlite3_initialize)dlsym(h, "sqlite3_initialize");
    p_sqlite3_open_v2 = (fn_sqlite3_open_v2)dlsym(h, "sqlite3_open_v2");
    p_sqlite3_prepare_v2 = (fn_sqlite3_prepare_v2)dlsym(h, "sqlite3_prepare_v2");
    p_sqlite3_step = (fn_sqlite3_step)dlsym(h, "sqlite3_step");
    p_sqlite3_reset = (fn_sqlite3_reset)dlsym(h, "sqlite3_reset");
    p_sqlite3_finalize = (fn_sqlite3_finalize)dlsym(h, "sqlite3_finalize");
    p_sqlite3_close = (fn_sqlite3_close)dlsym(h, "sqlite3_close");
    p_sqlite3_errmsg = (fn_sqlite3_errmsg)dlsym(h, "sqlite3_errmsg");
    p_sqlite3_exec = (fn_sqlite3_exec)dlsym(h, "sqlite3_exec");
    p_sqlite3_column_count = (fn_sqlite3_column_count)dlsym(h, "sqlite3_column_count");
    p_sqlite3_column_type = (fn_sqlite3_column_type)dlsym(h, "sqlite3_column_type");
    p_sqlite3_column_int64 = (fn_sqlite3_column_int64)dlsym(h, "sqlite3_column_int64");
    p_sqlite3_column_double = (fn_sqlite3_column_double)dlsym(h, "sqlite3_column_double");
    p_sqlite3_column_name = (fn_sqlite3_column_name)dlsym(h, "sqlite3_column_name");
    p_sqlite3_libversion = (fn_sqlite3_libversion)dlsym(h, "sqlite3_libversion");
    p_sqlite3_sourceid = (fn_sqlite3_sourceid)dlsym(h, "sqlite3_sourceid");
#endif

    if (!p_sqlite3_open_v2 || !p_sqlite3_prepare_v2 || !p_sqlite3_step ||
        !p_sqlite3_reset || !p_sqlite3_finalize || !p_sqlite3_close ||
        !p_sqlite3_column_count || !p_sqlite3_column_type || !p_sqlite3_column_int64 ||
        !p_sqlite3_column_double || !p_sqlite3_column_name) {
        fprintf(stderr, "error: missing SQLite symbols\n");
        return -1;
    }
    if (p_sqlite3_initialize) {
        p_sqlite3_initialize();
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

int main(int argc, char **argv) {
    if (argc >= 2 && strcmp(argv[1], "--version") == 0) {
        if (load_sqlite() != 0) return 1;
        int64_t effective_mmap = 0;
        if (argc >= 3) {
            sqlite3 *db = NULL;
            if (p_sqlite3_open_v2(argv[2], &db, SQLITE_OPEN_READONLY, NULL) == SQLITE_OK) {
                if (p_sqlite3_exec) p_sqlite3_exec(db, "PRAGMA mmap_size = 2147483648;", NULL, NULL, NULL);
                sqlite3_stmt *stmt_mmap = NULL;
                if (p_sqlite3_prepare_v2(db, "PRAGMA mmap_size;", -1, &stmt_mmap, NULL) == SQLITE_OK) {
                    if (p_sqlite3_step(stmt_mmap) == SQLITE_ROW) {
                        effective_mmap = p_sqlite3_column_int64(stmt_mmap, 0);
                    }
                    p_sqlite3_finalize(stmt_mmap);
                }
                p_sqlite3_close(db);
            }
        }
        printf("%s\n%s\n%lld\n",
            p_sqlite3_libversion ? p_sqlite3_libversion() : "unknown",
            p_sqlite3_sourceid ? p_sqlite3_sourceid() : "unknown",
            (long long)effective_mmap);
        return 0;
    }

    if (argc < 4) {
        fprintf(stderr, "Usage: %s <database> <sql> <iterations> [warmup] [mode]\n", argv[0]);
        return 1;
    }

    const char *db_path = argv[1];
    const char *sql = argv[2];
    uint64_t iterations = strtoull(argv[3], NULL, 10);
    uint64_t warmup = (argc >= 5) ? strtoull(argv[4], NULL, 10) : 0;
    uint64_t mode = (argc >= 6) ? strtoull(argv[5], NULL, 10) : 0;
    if (iterations == 0) iterations = 1;

    uint64_t record[10] = {0};

    if (load_sqlite() != 0) {
        record[0] = 1; /* status error */
        fwrite(record, 1, sizeof(record), stdout);
        return 1;
    }

    sqlite3 *db = NULL;
    int rc = p_sqlite3_open_v2(db_path, &db, SQLITE_OPEN_READONLY, NULL);
    if (rc != SQLITE_OK) {
        record[0] = (uint64_t)rc;
        fwrite(record, 1, sizeof(record), stdout);
        return 1;
    }

    /* Configure SQLite for fair in-memory / mmap execution: 2 GB mmap ceiling */
    if (p_sqlite3_exec) {
        p_sqlite3_exec(db, "PRAGMA mmap_size = 2147483648;", NULL, NULL, NULL);
        p_sqlite3_exec(db, "PRAGMA cache_size = -64000;", NULL, NULL, NULL);
    }

    sqlite3_stmt *stmt = NULL;
    rc = p_sqlite3_prepare_v2(db, sql, -1, &stmt, NULL);
    if (rc != SQLITE_OK) {
        record[0] = (uint64_t)rc;
        p_sqlite3_close(db);
        fwrite(record, 1, sizeof(record), stdout);
        return 1;
    }

    /* Warmup loop */
    for (uint64_t w = 0; w < warmup; w++) {
        p_sqlite3_reset(stmt);
        while (p_sqlite3_step(stmt) == SQLITE_ROW) {
            /* consume */
        }
    }

    /* Column types for materialization */
    int col_count = p_sqlite3_column_count(stmt);
    int col_kinds[64] = {0};
    for (int c = 0; c < col_count && c < 64; c++) {
        const char *name = p_sqlite3_column_name(stmt, c);
        if (name) {
            if (strcmp(name, "active") == 0) col_kinds[c] = 1;
            else if (strcmp(name, "category") == 0 || strcmp(name, "score") == 0 || strcmp(name, "tag") == 0) col_kinds[c] = 4;
            else if (strcmp(name, "weight") == 0) col_kinds[c] = 2;
            else col_kinds[c] = 8;
        } else {
            col_kinds[c] = 8;
        }
    }

    /* Measured region */
    uint64_t total_selected = 0;
    uint64_t checksum = FNV_OFFSET_BASIS;
    uint64_t t0_tsc = read_tsc();
    uint64_t t0_ns = monotonic_ns();

    if (mode == 0) {
        for (uint64_t iter = 0; iter < iterations; iter++) {
            p_sqlite3_reset(stmt);
            while (p_sqlite3_step(stmt) == SQLITE_ROW) {
                total_selected++;
            }
        }
    } else if (mode == 2) {
        /* Aggregate mode: the statement is a COUNT, so report its value. */
        for (uint64_t iter = 0; iter < iterations; iter++) {
            p_sqlite3_reset(stmt);
            while (p_sqlite3_step(stmt) == SQLITE_ROW) {
                total_selected += (uint64_t)p_sqlite3_column_int64(stmt, 0);
            }
        }
    } else {
        for (uint64_t iter = 0; iter < iterations; iter++) {
            p_sqlite3_reset(stmt);
            while (p_sqlite3_step(stmt) == SQLITE_ROW) {
                total_selected++;
                for (int c = 0; c < col_count; c++) {
                    int t = p_sqlite3_column_type(stmt, c);
                    if (t == 5 /* SQLITE_NULL */) {
                        checksum ^= TAG_NULL;
                        checksum *= FNV_PRIME;
                    } else {
                        checksum ^= TAG_VALUE;
                        checksum *= FNV_PRIME;
                        uint64_t val;
                        if (col_kinds[c] == 2) {
                            float f = (float)p_sqlite3_column_double(stmt, c);
                            uint32_t u;
                            memcpy(&u, &f, 4);
                            val = (uint64_t)u;
                        } else if (col_kinds[c] == 1) {
                            val = (uint64_t)(uint8_t)p_sqlite3_column_int64(stmt, c);
                        } else if (col_kinds[c] == 4) {
                            val = (uint64_t)(uint32_t)p_sqlite3_column_int64(stmt, c);
                        } else {
                            val = (uint64_t)p_sqlite3_column_int64(stmt, c);
                        }
                        checksum ^= val;
                        checksum *= FNV_PRIME;
                    }
                }
            }
        }
    }

    uint64_t t1_ns = monotonic_ns();
    uint64_t t1_tsc = read_tsc();

    p_sqlite3_finalize(stmt);
    p_sqlite3_close(db);

    record[0] = 0;                         /* BENCH_STATUS */
    record[1] = 0;                         /* BENCH_DOMAIN */
    record[2] = iterations;                /* BENCH_ITERATIONS */
    record[3] = total_selected;            /* BENCH_BATCHES */
    record[4] = total_selected;            /* BENCH_SELECTED */
    record[5] = checksum;                  /* BENCH_CHECKSUM */
    record[6] = t1_ns - t0_ns;             /* BENCH_NS */
    record[7] = t1_tsc - t0_tsc;           /* BENCH_TSC */
    record[8] = 0;                         /* BENCH_REQUIRED */
    record[9] = 0;                         /* BENCH_ROW_BYTES */

#ifdef _WIN32
    _setmode(_fileno(stdout), _O_BINARY);
#endif
    fwrite(record, 1, sizeof(record), stdout);
    fflush(stdout);

    return 0;
}
