/* benchmarks/commit_probe.c - what a commit costs, and what it spends it on.
 *
 * The queue benchmark measured commits in microseconds and found they get
 * slower as a queue gets deeper. A clock cannot say why. This asks the
 * engine's own counters instead, per commit, at several retained depths:
 *
 *     queue segments walked      structural visits into the queue graph
 *     catalog pages validated    structural visits into the catalog
 *     PAX leaves validated       structural visits into table storage
 *     map leaves validated       allocation-map leaf pages proved
 *     pages flushed              what the two barriers handed the kernel
 *     validation time            rdtsc spent inside db_bitmap_validate
 *
 * A number that stays flat as depth grows is a cost that follows the change.
 * A number that grows with depth is a cost that follows what the database has
 * kept, and removing the second kind is what 0.5.0-preview.2 is for. Running
 * this before the commit path is touched is the point: it writes down the
 * shape from before, so that "it got faster" can be told apart from "it
 * stopped proving something".
 *
 * Validation time is reported beside the whole commit rather than instead of
 * it. The two fsyncs dominate the clock and are not being changed, so the
 * share column is the honest ceiling on what this work can win.
 *
 *   build/commit_probe [--depths 0,500,1000,2000,10000] [--rounds 200]
 *
 * SPDX-License-Identifier: Apache-2.0
 * Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
 */
#define _CRT_SECURE_NO_WARNINGS
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#ifdef _WIN32
#include <windows.h>
#else
#include <time.h>
#endif
#ifdef _MSC_VER
#include <intrin.h>
#endif
#include "cyboudb.h"

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

static uint64_t rdtsc_now(void) {
#ifdef _MSC_VER
    return (uint64_t)__rdtsc();
#else
    unsigned int lo, hi;
    __asm__ __volatile__("rdtsc" : "=a"(lo), "=d"(hi));
    return ((uint64_t)hi << 32) | lo;
#endif
}

/* Ticks per nanosecond, measured rather than assumed: without it the engine's
 * tick counter cannot be put beside the wall clock, and the whole question is
 * what fraction of a commit validation actually is. */
static double ticks_per_ns(void) {
    uint64_t c0 = rdtsc_now(), t0 = now_ns(), c1, t1;
    while (now_ns() - t0 < 50000000ull) { }
    c1 = rdtsc_now();
    t1 = now_ns();
    return (double)(c1 - c0) / (double)(t1 - t0);
}

/* The engine's counters. The engine never resets them: a caller reads one
 * before and after a span of work and subtracts. */
extern unsigned long long queue_segments_walked;
extern unsigned long long catalog_pages_validated;
extern unsigned long long pax_leaves_validated;
extern unsigned long long bitmap_leaves_validated;
extern unsigned long long commit_validations;
extern unsigned long long commit_validate_ticks;
extern unsigned long long pages_flushed;
extern unsigned long long sync_ticks;

typedef struct {
    unsigned long long qseg, cat, pax, map, flush, ticks, commits, sync;
    uint64_t wall_ns;
} counters;

static void read_counters(counters *c) {
    c->qseg    = queue_segments_walked;
    c->cat     = catalog_pages_validated;
    c->pax     = pax_leaves_validated;
    c->map     = bitmap_leaves_validated;
    c->flush   = pages_flushed;
    c->ticks   = commit_validate_ticks;
    c->commits = commit_validations;
    c->sync    = sync_ticks;
    c->wall_ns = 0;
}

#define CHECK(expr, what) do { \
    int rc_ = (expr); \
    if (rc_ != CybouDB_OK) { \
        printf("FAIL %s: rc=%d\n", what, rc_); \
        return -1; \
    } \
} while (0)

/* Fill an object to `depth` records, then measure `rounds` more single-record
 * commits on top of it. The fill is not measured - only what a commit costs
 * once that much is already retained. */
/* The allocation map has one leaf per CybouDB_MAP_LEAF_PAGES pages, so the
 * number of leaves a commit touches is a property of the file's size rather
 * than of what it holds. Making that adjustable is the only way to see it. */
static unsigned long file_pages = 60000;

static int measure(const char *path, unsigned long depth, unsigned long rounds,
                   int is_queue, counters *out)
{
    cyboudb_db *db = NULL;
    counters a, b;
    unsigned long i;
    const char *write_one = is_queue
        ? "ENQUEUE INTO q VALUES ('a message of some length')"
        : "APPEND TO s VALUES ('a record of some length')";

    remove(path);
    CHECK(cyboudb_create(path, file_pages, &db), "create");
    if (is_queue) {
        CHECK(cyboudb_exec(db, "CREATE QUEUE q"), "CREATE QUEUE");
    } else {
        CHECK(cyboudb_exec(db, "CREATE STREAM s"), "CREATE STREAM");
        CHECK(cyboudb_exec(db, "CREATE CURSOR c ON s"), "CREATE CURSOR");
    }

    for (i = 0; i < depth; i++)
        CHECK(cyboudb_exec(db, write_one), "fill");

    read_counters(&a);
    a.wall_ns = now_ns();
    for (i = 0; i < rounds; i++)
        CHECK(cyboudb_exec(db, write_one), "measured");
    read_counters(&b);
    b.wall_ns = now_ns();

    out->qseg    = b.qseg    - a.qseg;
    out->cat     = b.cat     - a.cat;
    out->pax     = b.pax     - a.pax;
    out->map     = b.map     - a.map;
    out->flush   = b.flush   - a.flush;
    out->ticks   = b.ticks   - a.ticks;
    out->commits = b.commits - a.commits;
    out->sync    = b.sync    - a.sync;
    out->wall_ns = b.wall_ns - a.wall_ns;

    CHECK(cyboudb_close(db), "close");
    remove(path);
    return 0;
}

static void row(unsigned long depth, const counters *d, unsigned long rounds,
                double tpns)
{
    double r = (double)rounds;
    double wall_us = (double)d->wall_ns / r / 1000.0;
    double val_us  = (double)d->ticks / r / tpns / 1000.0;
    double sync_us = (double)d->sync / r / tpns / 1000.0;
    double share   = wall_us > 0.0 ? 100.0 * val_us / wall_us : 0.0;

    printf("| %7lu | %8.2f | %6.2f | %6.2f | %6.2f | %7.2f | %7.1f | %7.1f | %8.1f | %5.1f%% |\n",
           depth,
           (double)d->qseg  / r,
           (double)d->cat   / r,
           (double)d->pax   / r,
           (double)d->map   / r,
           (double)d->flush / r,
           val_us, sync_us, wall_us, share);
}

int main(int argc, char **argv) {
    unsigned long depths[16] = {0, 500, 1000, 2000, 10000};
    int ndepths = 5;
    unsigned long rounds = 200;
    double tpns;
    int i, o;

    for (i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--rounds") == 0 && i + 1 < argc) {
            rounds = strtoul(argv[++i], NULL, 10);
        } else if (strcmp(argv[i], "--pages") == 0 && i + 1 < argc) {
            file_pages = strtoul(argv[++i], NULL, 10);
        } else if (strcmp(argv[i], "--depths") == 0 && i + 1 < argc) {
            char *s = argv[++i], *tok;
            ndepths = 0;
            for (tok = strtok(s, ","); tok && ndepths < 16;
                 tok = strtok(NULL, ","))
                depths[ndepths++] = strtoul(tok, NULL, 10);
        } else {
            printf("usage: commit_probe [--depths a,b,c] [--rounds n]"
                   " [--pages n]\n");
            return 2;
        }
    }

    tpns = ticks_per_ns();
    printf("CybouDB %s - what one commit visits, by retained depth\n",
           CybouDB_VERSION);
    printf("%lu measured commits at each depth, one record per transaction,"
           " in a file of %lu pages.\n", rounds, file_pages);
    printf("rdtsc measured at %.3f GHz. \"valid\" is time inside "
           "db_bitmap_validate.\n", tpns);

    for (o = 0; o < 2; o++) {
        counters d;
        printf("\n### %s: per commit\n\n", o == 0 ? "queue" : "stream");
        printf("|   depth | queue seg | cat pg | PAX lf | map lf | flush pg "
               "| valid us | sync us | commit us | share |\n");
        printf("| ------: | --------: | -----: | -----: | -----: | -------: "
               "| -------: | ------: | --------: | ----: |\n");
        for (i = 0; i < ndepths; i++) {
            if (measure("commit_probe.cdb", depths[i], rounds,
                        o == 0, &d) != 0)
                return 1;
            row(depths[i], &d, rounds, tpns);
            fflush(stdout);
        }
    }

    printf("\nA column that is flat across depth is a cost that follows the\n"
           "transaction. A column that grows is a cost that follows what the\n"
           "database has kept.\n");
    return 0;
}
