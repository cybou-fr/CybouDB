/*
 * benchmarks/queue_bench.c - a durable work queue, in CybouDB and in SQLite.
 *
 * This is the comparison the scan benchmarks cannot make. CybouDB has a queue
 * as a storage primitive; SQLite does not, so a service that needs one builds
 * it out of a table. That is a real and extremely common pattern, and it is
 * what this measures - not a synthetic proxy for it.
 *
 * The workloads are the three things a job queue actually does:
 *
 *   enqueue   one message, one transaction
 *   dequeue   one message, one transaction
 *   worker    take a job and write its result in ONE transaction, which is the
 *             only one of the three that says anything about atomicity
 *
 * Fairness is mostly a question of durability, because at one transaction per
 * message the fsync dominates everything else. CybouDB flushes twice per commit
 * (the data pages, then the publication) and has no knob to turn that off, so
 * the honest comparison is against SQLite at `synchronous = FULL`. The weaker
 * `synchronous = NORMAL` configuration is measured too and labelled as weaker:
 * it is what a lot of production code actually runs, and hiding it would be its
 * own kind of dishonesty.
 *
 * Both engines prepare once and then step/reset in the loop, which is the same
 * shape of work: CybouDB carries the payload in the statement, SQLite binds it
 * once. Neither pays SQL parsing per message.
 *
 *   Usage: queue_bench <engine> <workload> <messages> <payload> <db>
 *     engine    cyboudb | sqlite-delete-full | sqlite-wal-full | sqlite-wal-normal
 *     workload  enqueue | dequeue | worker
 *     an optional sixth argument is messages per transaction, default 1
 *
 * Prints one line: RESULT <ops> <elapsed_ns>
 *
 * SPDX-License-Identifier: Apache-2.0
 * Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#else
#include <time.h>
#include <dlfcn.h>
#endif

#include "cyboudb.h"

void *cyboudb_test_mem_alloc(size_t size) { return malloc(size); }
void cyboudb_test_mem_free(void *ptr, size_t size) { (void)size; free(ptr); }

/* Messages per transaction. One is the latency case: every message is its
   own durable commit. Larger values amortise that commit, which is the
   axis that actually describes this engine. */
static int batch = 1;

/* --- SQLite, loaded the way benchmarks/sqlite_harness.c loads it ----------- */
#define SQLITE_OK   0
#define SQLITE_ROW  100
#define SQLITE_DONE 101
#define SQLITE_STATIC ((void(*)(void*))0)
#define SQLITE_OPEN_READWRITE 0x00000002
#define SQLITE_OPEN_CREATE    0x00000004

typedef struct sqlite3 sqlite3;
typedef struct sqlite3_stmt sqlite3_stmt;

static int (*p_initialize)(void);
static int (*p_open_v2)(const char *, sqlite3 **, int, const char *);
static int (*p_exec)(sqlite3 *, const char *, void *, void *, char **);
static int (*p_prepare_v2)(sqlite3 *, const char *, int, sqlite3_stmt **, const char **);
static int (*p_step)(sqlite3_stmt *);
static int (*p_reset)(sqlite3_stmt *);
static int (*p_finalize)(sqlite3_stmt *);
static int (*p_close)(sqlite3 *);
static const char *(*p_errmsg)(sqlite3 *);
static int (*p_bind_text)(sqlite3_stmt *, int, const char *, int, void (*)(void *));
static const unsigned char *(*p_column_text)(sqlite3_stmt *, int);
static int (*p_column_bytes)(sqlite3_stmt *, int);
static const char *(*p_libversion)(void);

static int load_sqlite(void) {
#ifdef _WIN32
    HMODULE h = NULL;
    const char *env = getenv("SQLITE_DLL");
    if (env && *env) h = LoadLibraryA(env);
    if (!h) h = LoadLibraryA(
        "C:\\Users\\cybou\\AppData\\Local\\Python\\pythoncore-3.14-64\\DLLs\\sqlite3.dll");
    if (!h) h = LoadLibraryA("sqlite3.dll");
    if (!h) { fprintf(stderr, "error: could not load sqlite3.dll\n"); return 0; }
#define GET(name) *(FARPROC *)&p_##name = GetProcAddress(h, "sqlite3_" #name)
#else
    void *h = NULL;
    const char *env = getenv("SQLITE_DLL");
    if (env && *env) h = dlopen(env, RTLD_NOW);
    if (!h) h = dlopen("libsqlite3.so.0", RTLD_NOW);
    if (!h) h = dlopen("libsqlite3.so", RTLD_NOW);
    if (!h) { fprintf(stderr, "error: could not load libsqlite3\n"); return 0; }
#define GET(name) *(void **)&p_##name = dlsym(h, "sqlite3_" #name)
#endif
    GET(initialize); GET(open_v2); GET(exec); GET(prepare_v2); GET(step);
    GET(reset); GET(finalize); GET(close); GET(errmsg); GET(bind_text);
    GET(column_text); GET(column_bytes); GET(libversion);
#undef GET
    /* This library may be built with SQLITE_OMIT_AUTOINIT, in which case
       sqlite3_open_v2 on an uninitialised library is undefined and crashes. */
    if (p_initialize) p_initialize();
    return p_open_v2 && p_prepare_v2 && p_step && p_reset && p_finalize
        && p_exec && p_bind_text;
}

/* --- clock ---------------------------------------------------------------- */
static uint64_t now_ns(void) {
#ifdef _WIN32
    static LARGE_INTEGER freq;
    LARGE_INTEGER t;
    if (!freq.QuadPart) QueryPerformanceFrequency(&freq);
    QueryPerformanceCounter(&t);
    return (uint64_t)((double)t.QuadPart * 1e9 / (double)freq.QuadPart);
#else
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
#endif
}

static void die(const char *what) {
    fprintf(stderr, "queue_bench: %s failed\n", what);
    exit(2);
}

/* --- CybouDB -------------------------------------------------------------- */
static uint64_t run_cyboudb(const char *workload, int messages,
                            const char *payload, const char *path) {
    cyboudb_db *db = NULL;
    cyboudb_stmt *enq = NULL, *deq = NULL, *ins = NULL;
    char sql[4096];
    uint64_t start, elapsed;
    int i, rc;

    remove(path);
    if (cyboudb_create(path, 200000, &db) != CybouDB_OK) die("cyboudb_create");
    if (cyboudb_exec(db, "CREATE QUEUE jobs") != CybouDB_OK) die("CREATE QUEUE");
    if (cyboudb_exec(db, "CREATE TABLE results (n INT64, seq INT64)")
            != CybouDB_OK) die("CREATE TABLE");

    snprintf(sql, sizeof sql, "ENQUEUE INTO jobs VALUES ('%s')", payload);
    if (cyboudb_prepare(db, sql, &enq) != CybouDB_OK) die("prepare ENQUEUE");
    if (cyboudb_prepare(db, "DEQUEUE FROM jobs", &deq) != CybouDB_OK)
        die("prepare DEQUEUE");
    if (cyboudb_prepare(db, "INSERT INTO results VALUES (1, 2)", &ins)
            != CybouDB_OK) die("prepare INSERT");

    /* Anything the workload consumes has to be there before the clock starts. */
    if (strcmp(workload, "dequeue") == 0 || strcmp(workload, "worker") == 0) {
        for (i = 0; i < messages; i++) {
            if (cyboudb_step(enq) != CybouDB_DONE) die("prefill ENQUEUE");
            cyboudb_reset(enq);
        }
    }

    start = now_ns();
    for (i = 0; i < messages; i++) {
        if (i % batch == 0 && cyboudb_exec(db, "BEGIN") != CybouDB_OK)
            die("BEGIN");
        if (strcmp(workload, "enqueue") == 0) {
            if (cyboudb_step(enq) != CybouDB_DONE) die("ENQUEUE");
            cyboudb_reset(enq);
        } else if (strcmp(workload, "dequeue") == 0) {
            rc = cyboudb_step(deq);
            if (rc != CybouDB_ROW) die("DEQUEUE");
            cyboudb_reset(deq);
        } else if (strcmp(workload, "worker") == 0) {
            rc = cyboudb_step(deq);
            if (rc != CybouDB_ROW) die("worker DEQUEUE");
            cyboudb_reset(deq);
            if (cyboudb_step(ins) != CybouDB_DONE) die("worker INSERT");
            cyboudb_reset(ins);
        } else {
            die("unknown workload");
        }
        if (i % batch == batch - 1 && cyboudb_exec(db, "COMMIT") != CybouDB_OK)
            die("COMMIT");
    }
    if (messages % batch) cyboudb_exec(db, "COMMIT");
    elapsed = now_ns() - start;

    cyboudb_finalize(enq);
    cyboudb_finalize(deq);
    cyboudb_finalize(ins);
    cyboudb_close(db);
    return elapsed;
}

/* --- SQLite as a queue ---------------------------------------------------- */
/* DELETE ... RETURNING is one statement and atomic, which is what a careful
   person writes on a modern SQLite. The older SELECT-then-DELETE shape is two
   statements and needs a transaction around it to be safe; it is not measured
   here, and would be slower rather than faster. */
static const char *SQL_TAKE =
    "DELETE FROM jobs WHERE id = (SELECT id FROM jobs ORDER BY id LIMIT 1) "
    "RETURNING payload";

static uint64_t run_sqlite(const char *engine, const char *workload,
                           int messages, const char *payload,
                           const char *path) {
    sqlite3 *db = NULL;
    sqlite3_stmt *enq = NULL, *deq = NULL, *ins = NULL;
    char journal[64], sync[64];
    uint64_t start, elapsed;
    int i, rc, plen = (int)strlen(payload);

    remove(path);
    if (p_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, NULL)
            != SQLITE_OK) die("sqlite open");

    if (strcmp(engine, "sqlite-delete-full") == 0) {
        snprintf(journal, sizeof journal, "PRAGMA journal_mode = DELETE");
        snprintf(sync, sizeof sync, "PRAGMA synchronous = FULL");
    } else if (strcmp(engine, "sqlite-wal-full") == 0) {
        snprintf(journal, sizeof journal, "PRAGMA journal_mode = WAL");
        snprintf(sync, sizeof sync, "PRAGMA synchronous = FULL");
    } else {
        snprintf(journal, sizeof journal, "PRAGMA journal_mode = WAL");
        snprintf(sync, sizeof sync, "PRAGMA synchronous = NORMAL");
    }
    p_exec(db, journal, NULL, NULL, NULL);
    p_exec(db, sync, NULL, NULL, NULL);
    if (p_exec(db, "CREATE TABLE jobs (id INTEGER PRIMARY KEY, payload TEXT)",
               NULL, NULL, NULL) != SQLITE_OK) die("sqlite CREATE jobs");
    if (p_exec(db, "CREATE TABLE results (n INTEGER, seq INTEGER)",
               NULL, NULL, NULL) != SQLITE_OK) die("sqlite CREATE results");

    if (p_prepare_v2(db, "INSERT INTO jobs (payload) VALUES (?)", -1, &enq, NULL)
            != SQLITE_OK) die("sqlite prepare insert");
    if (p_prepare_v2(db, SQL_TAKE, -1, &deq, NULL) != SQLITE_OK)
        die("sqlite prepare take");
    if (p_prepare_v2(db, "INSERT INTO results VALUES (1, 2)", -1, &ins, NULL)
            != SQLITE_OK) die("sqlite prepare result");
    p_bind_text(enq, 1, payload, plen, SQLITE_STATIC);

    if (strcmp(workload, "dequeue") == 0 || strcmp(workload, "worker") == 0) {
        p_exec(db, "BEGIN", NULL, NULL, NULL);
        for (i = 0; i < messages; i++) {
            if (p_step(enq) != SQLITE_DONE) die("sqlite prefill");
            p_reset(enq);
        }
        p_exec(db, "COMMIT", NULL, NULL, NULL);
    }

    start = now_ns();
    for (i = 0; i < messages; i++) {
        if (i % batch == 0) p_exec(db, "BEGIN", NULL, NULL, NULL);
        if (strcmp(workload, "enqueue") == 0) {
            if (p_step(enq) != SQLITE_DONE) die("sqlite INSERT");
            p_reset(enq);
        } else if (strcmp(workload, "dequeue") == 0) {
            rc = p_step(deq);
            if (rc != SQLITE_ROW) die("sqlite take");
            p_reset(deq);
        } else if (strcmp(workload, "worker") == 0) {
            rc = p_step(deq);
            if (rc != SQLITE_ROW) die("sqlite worker take");
            p_reset(deq);
            if (p_step(ins) != SQLITE_DONE) die("sqlite worker insert");
            p_reset(ins);
        } else {
            die("unknown workload");
        }
        if (i % batch == batch - 1 &&
            p_exec(db, "COMMIT", NULL, NULL, NULL) != SQLITE_OK)
            die("sqlite COMMIT");
    }
    if (messages % batch) p_exec(db, "COMMIT", NULL, NULL, NULL);
    elapsed = now_ns() - start;

    p_finalize(enq); p_finalize(deq); p_finalize(ins);
    p_close(db);
    return elapsed;
}

int main(int argc, char **argv) {
    const char *engine, *workload, *path;
    int messages, payload_bytes, i;
    char *payload;
    uint64_t elapsed;

    if (argc < 6) {
        fprintf(stderr, "usage: queue_bench <engine> <workload> <messages> "
                        "<payload bytes> <db path> [per txn]\n");
        return 2;
    }
    if (argc > 6) batch = atoi(argv[6]);
    if (batch < 1) batch = 1;
    engine = argv[1];
    workload = argv[2];
    messages = atoi(argv[3]);
    payload_bytes = atoi(argv[4]);
    path = argv[5];

    payload = (char *)malloc((size_t)payload_bytes + 1);
    if (!payload) return 2;
    for (i = 0; i < payload_bytes; i++) payload[i] = (char)('a' + (i % 26));
    payload[payload_bytes] = 0;

    if (strcmp(engine, "cyboudb") == 0) {
        elapsed = run_cyboudb(workload, messages, payload, path);
    } else {
        if (!load_sqlite()) return 2;
        elapsed = run_sqlite(engine, workload, messages, payload, path);
    }

    printf("RESULT %d %llu\n", messages, (unsigned long long)elapsed);
    free(payload);
    return 0;
}
