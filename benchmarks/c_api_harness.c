/* Same consumer and clock for the public pull API and internal callback API.
 * Usage: path sql iterations warmup mode backend trace zone_off
 * mode: 0 COUNT, 1 materialize. backend: 0 public, 1 internal.
 * Output: 10 uint64 fields followed by the six zone diagnostic counters.
 * Internal declarations below are harness-only, not additions to cyboudb.h. */
#include "cyboudb.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#include <windows.h>
#include <intrin.h>
#include <fcntl.h>
#include <io.h>
#define NOINLINE __declspec(noinline)
#else
#define NOINLINE __attribute__((noinline))
#endif
extern uint64_t os_monotonic_ns(void);
extern int db_open(const void *, void *, uint64_t, uint64_t);
extern int db_close(void *);
extern void sql_arena_init(void *, void *, uint64_t);
extern int sql_parse(const char *, uint64_t, void *, void **, void *);
extern int sql_bind(void *, void *, void *, void **, void *);
typedef int (*sink_fn)(void *, const cyboudb_batch_view *, const uint64_t *, uint64_t);
extern int sql_execute_batch(void *, void *, void *, sink_fn, void *, void *);
extern int sql_zone_trace, sql_zone_force_off;
extern uint64_t sql_zone_leaf_total, sql_zone_leaf_none, sql_zone_leaf_all;
extern uint64_t sql_zone_leaf_unknown, sql_zone_batch_total, sql_zone_column_mask;

typedef struct { uint64_t record[10]; int mode; } consumer;
static NOINLINE void consume(consumer *c, const cyboudb_colview **cols, int n, uint64_t mask) {
    const uint64_t prime = UINT64_C(1099511628211);
    uint64_t hash = c->record[5];
    c->record[3]++;
    if (!c->mode) {
        uint64_t count = *(const uint64_t *)cols[0]->values_ptr;
        c->record[4] += count;
        c->record[5] = (hash ^ count) * prime;
        return;
    }
    while (mask) {
        unsigned row;
#ifdef _WIN32
        unsigned long bit;
        _BitScanForward64(&bit, mask);
        row = (unsigned)bit;
#else
        row = (unsigned)__builtin_ctzll(mask);
#endif
        mask &= mask - 1;
        c->record[4]++;
        for (int i = 0; i < n; i++) {
            const cyboudb_colview *v = cols[i];
            if ((v->null_mask >> row) & 1) {
                hash = (hash ^ 0xBF) * prime;
            } else {
                uint64_t value;
                if (v->width == 8) value = ((const uint64_t *)v->values_ptr)[row];
                else if (v->width == 1) value = ((const uint8_t *)v->values_ptr)[row];
                else value = ((const uint32_t *)v->values_ptr)[row];
                hash = ((hash ^ 0x5A) * prime ^ value) * prime;
            }
        }
    }
    c->record[5] = hash;
}
static int callback(void *ctx, const cyboudb_batch_view *batch, const uint64_t *projection, uint64_t mask) {
    const cyboudb_colview *cols[64];
    const uint32_t *indices = (const uint32_t *)(uintptr_t)projection[1];
    int n = (int)projection[0];
    for (int i = 0; i < n; i++) cols[i] = &batch->columns[indices[i]];
    consume((consumer *)ctx, cols, n, mask);
    return 0;
}
static int public_once(cyboudb_stmt *stmt, int n, consumer *c) {
    const cyboudb_batch_view *batch;
    const cyboudb_colview *cols[64];
    uint64_t mask;
    int rc = cyboudb_reset(stmt);
    if (rc) return rc;
    while ((rc = cyboudb_step_batch(stmt, &batch, &mask)) == CybouDB_ROW) {
        for (int i = 0; i < n; i++) {
            cols[i] = cyboudb_batch_column(stmt, batch, i);
            if (!cols[i]) return CybouDB_ERROR;
        }
        consume(c, cols, n, mask);
    }
    return rc == CybouDB_DONE ? 0 : rc;
}
int main(int argc, char **argv) {
    if (argc < 7) return 2;
    uint64_t iterations = strtoull(argv[3], NULL, 10), warmup = strtoull(argv[4], NULL, 10);
    int internal = atoi(argv[6]), rc = 0, columns = 0;
    consumer c = {{0}, 0};
    c.mode = atoi(argv[5]);
    if (!iterations || (c.mode != 0 && c.mode != 1)) return 2;
    sql_zone_trace = argc > 7 ? atoi(argv[7]) : 0;
    sql_zone_force_off = argc > 8 ? atoi(argv[8]) : 0;
    cyboudb_db *db = NULL;
    cyboudb_stmt *stmt = NULL;
    /* The internal path hands db_open a descriptor of its own rather than
     * going through cyboudb_open. CybouDB_DB_SIZE is not public, so this is
     * sized at 4 KiB, which is what the library allocates for a handle, so it
     * cannot be outgrown without the library noticing first. It was
     * uint64_t[20] - 160 bytes against a descriptor already at 184 - and the
     * overrun landed on `arena` and `error` below it. That cost nothing until
     * the descriptor grew, and then showed up as two backends disagreeing
     * about zone-pruning counters rather than as a crash. uint64_t[64] was the
     * next guess and the descriptor outgrew that too. */
    uint64_t ctx[512] = {0}, arena[4] = {0}, error[13] = {0}, mark = 0;
    void *ast = NULL, *plan = NULL, *memory = NULL;
    if (internal) {
        const void *path = argv[1];
#ifdef _WIN32
        wchar_t wide[32768];
        if (!MultiByteToWideChar(CP_UTF8, 0, argv[1], -1, wide, 32768)) return 2;
        path = wide;
#endif
        rc = db_open(path, ctx, 0, 0);
        if (rc) return 3;
        memory = malloc(1048576);
        if (!memory) return 3;
        sql_arena_init(arena, memory, 1048576);
        rc = sql_parse(argv[2], strlen(argv[2]), arena, &ast, error);
        if (!rc) rc = sql_bind(ctx, ast, arena, &plan, error);
        mark = arena[1];
    } else {
        rc = cyboudb_open(argv[1], CybouDB_OPEN_READONLY, &db);
        if (!rc) rc = cyboudb_prepare(db, argv[2], &stmt);
        if (!rc) columns = cyboudb_column_count(stmt);
    }
    if (rc) return 3;
    uint64_t start = 0;
    for (uint64_t i = 0; i < warmup + iterations; i++) {
        if (i == warmup) {
            memset(c.record, 0, sizeof(c.record));
            c.record[5] = UINT64_C(0xcbf29ce484222325);
            sql_zone_leaf_total = sql_zone_leaf_none = sql_zone_leaf_all = 0;
            sql_zone_leaf_unknown = sql_zone_batch_total = sql_zone_column_mask = 0;
            start = os_monotonic_ns();
        }
        if (internal) {
            arena[1] = mark;
            rc = sql_execute_batch(ctx, plan, arena, callback, &c, error);
        } else rc = public_once(stmt, columns, &c);
        if (rc) break;
    }
    c.record[6] = os_monotonic_ns() - start;
    c.record[0] = (uint64_t)rc;
    c.record[2] = iterations;
    uint64_t trace[6] = {sql_zone_leaf_total, sql_zone_leaf_none, sql_zone_leaf_all,
                         sql_zone_leaf_unknown, sql_zone_batch_total, sql_zone_column_mask};
    if (internal) { db_close(ctx); free(memory); }
    else { cyboudb_finalize(stmt); cyboudb_close(db); }
#ifdef _WIN32
    _setmode(_fileno(stdout), _O_BINARY);
#endif
    fwrite(c.record, sizeof(c.record), 1, stdout);
    fwrite(trace, sizeof(trace), 1, stdout);
    return rc ? 1 : 0;
}
