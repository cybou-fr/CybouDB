/* benchmarks/flush_probe.c - what does the durability barrier scale with?
 *
 * The commit baseline left one question open and made it the larger one: the
 * flush is about 99% of a commit, and it gets more expensive as a database
 * holds more. `benchmarks/results/2026-09-14-commit-baseline.md` has the
 * shape; this asks what causes it.
 *
 * Four hypotheses, and each scenario here is chosen to tell two of them apart.
 *
 *   range      the engine hands sync_pages a wider range as the file grows,
 *              because the span map copy is one page per 16,112 and the second
 *              barrier covers it. Already measured and already answered: at a
 *              fixed depth, growing the file from 60,000 to 4,000,000 pages
 *              takes the flushed range from 12 pages to 379 and leaves sync
 *              time flat. Kept here as the control.
 *
 *   live       the cost follows how much the database currently holds.
 *
 *   written    the cost follows how much of the file has ever been written -
 *              its materialised size, and the extent list the filesystem keeps
 *              for it. A queue filled and then drained has a small live set
 *              and a large written-ever set, which is what separates this from
 *              `live`.
 *
 *   cache      the cost follows dirty page-cache pages left by the filling,
 *              rather than anything on disk. Closing the database and opening
 *              it again between the fill and the measurement is what separates
 *              this from `written`: a reopen does not clean the file, but it
 *              does end the mapping that dirtied it.
 *
 * Scenarios:
 *
 *   fresh      create, fill to depth, measure            live + written + cache
 *   reopen     create, fill to depth, close, open, measure    live + written
 *   drained    create, fill to depth, drain to empty, measure      written
 *   empty      create, measure                                  none of them
 *
 * Print `du` of the file beside each and the picture is readable.
 *
 *   build/flush_probe <path> <pages> <depth> <rounds> <fresh|reopen|drained|empty>
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

static double ticks_per_ns(void) {
    uint64_t c0 = rdtsc_now(), t0 = now_ns(), c1, t1;
    while (now_ns() - t0 < 50000000ull) { }
    c1 = rdtsc_now();
    t1 = now_ns();
    return (double)(c1 - c0) / (double)(t1 - t0);
}

extern unsigned long long sync_ticks;
extern unsigned long long pages_flushed;
extern unsigned long long commit_validate_ticks;

#define CHECK(expr, what) do { \
    int rc_ = (expr); \
    if (rc_ != CybouDB_OK) { printf("FAIL %s: rc=%d\n", what, rc_); return 1; } \
} while (0)

int main(int argc, char **argv) {
    cyboudb_db *db = NULL;
    const char *path, *mode;
    unsigned long pages, depth, rounds, i;
    uint64_t s0, f0, v0, w0;
    double tpns;

    if (argc < 6) {
        printf("usage: flush_probe <path> <pages> <depth> <rounds> <mode>\n");
        return 2;
    }
    path = argv[1];
    pages = strtoul(argv[2], NULL, 10);
    depth = strtoul(argv[3], NULL, 10);
    rounds = strtoul(argv[4], NULL, 10);
    mode = argv[5];
    tpns = ticks_per_ns();

    remove(path);
    CHECK(cyboudb_create(path, pages, &db), "create");
    CHECK(cyboudb_exec(db, "CREATE QUEUE q"), "CREATE QUEUE");

    for (i = 0; i < depth; i++)
        CHECK(cyboudb_exec(db, "ENQUEUE INTO q VALUES ('a message of some "
                           "length so a segment fills')"), "fill");

    if (strcmp(mode, "drained") == 0) {
        cyboudb_stmt *st = NULL;
        for (i = 0; i < depth; i++) {
            CHECK(cyboudb_prepare(db, "DEQUEUE FROM q", &st), "prepare drain");
            if (cyboudb_step(st) != CybouDB_ROW) { printf("FAIL drain\n"); return 1; }
            cyboudb_finalize(st);
        }
    }

    if (strcmp(mode, "reopen") == 0) {
        CHECK(cyboudb_close(db), "close");
        db = NULL;
        CHECK(cyboudb_open(path, CybouDB_OPEN_READWRITE, &db), "reopen");
    }

    s0 = sync_ticks;
    f0 = pages_flushed;
    v0 = commit_validate_ticks;
    w0 = now_ns();
    for (i = 0; i < rounds; i++)
        CHECK(cyboudb_exec(db, "ENQUEUE INTO q VALUES ('a message of some "
                           "length so a segment fills')"), "measured");
    {
        double r = (double)rounds;
        double wall = (double)(now_ns() - w0) / r / 1000.0;
        double sync = (double)(sync_ticks - s0) / r / tpns / 1000.0;
        double val  = (double)(commit_validate_ticks - v0) / r / tpns / 1000.0;
        printf("| %-8s | %8lu | %6lu | %8.2f | %8.1f | %7.1f | %9.1f |\n",
               mode, pages, depth, (double)(pages_flushed - f0) / r,
               sync, val, wall);
    }
    CHECK(cyboudb_close(db), "close");
    return 0;
}
