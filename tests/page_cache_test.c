/* tests/page_cache_test.c - the plaintext page cache
 *
 * The last check in this file is the one worth reading first. The shape of
 * this cache was chosen from a simulation
 * (benchmarks/results/2026-09-15-cache-shape.md), and a simulation that agrees
 * with nothing is a story. So the suite runs the simulator's own hot-set
 * workload against the real assembly and demands the hit rate the simulation
 * predicted - 82% at eight ways, give or take a point.
 *
 * If the implementation and the measurement that justified it ever disagree,
 * one of them is wrong, and this is where that shows up.
 *
 * Build (Linux):   sh build.sh --crypto-tests && ./build/page_cache_test
 * Build (Windows): build.bat --core-c-tests && build\page_cache_test.exe
 *
 * SPDX-License-Identifier: Apache-2.0
 * Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#define PAGE_SIZE 4096
#define WAYS      8

uint64_t cyboudb_pcache_bytes(uint64_t frames);
int cyboudb_pcache_init(uint8_t *mem, uint64_t bytes, uint64_t frames);
uint8_t *cyboudb_pcache_lookup(uint8_t *cache, uint64_t page);
uint8_t *cyboudb_pcache_admit(uint8_t *cache, uint64_t page,
                              uint64_t *evicted);
int cyboudb_pcache_mark_dirty(uint8_t *cache, uint64_t page);
uint8_t *cyboudb_pcache_frame(uint8_t *cache, uint64_t page);
int cyboudb_pcache_invalidate(uint8_t *cache, uint64_t page);
void cyboudb_pcache_stats(const uint8_t *cache, uint64_t *out);

static int checks, failures;

static void check(const char *what, int ok) {
    checks++;
    if (ok) printf("ok   %s\n", what);
    else { failures++; printf("FAIL %s\n", what); }
}

/* Page-aligned memory, without depending on a platform allocator that gives
   it for free. */
static uint8_t *aligned_block(uint64_t bytes, uint8_t **raw_out) {
    uint8_t *raw = malloc((size_t)bytes + PAGE_SIZE);
    uintptr_t p = (uintptr_t)raw;
    *raw_out = raw;
    p = (p + PAGE_SIZE - 1) & ~(uintptr_t)(PAGE_SIZE - 1);
    return (uint8_t *)p;
}

/* The simulator's generator, copied deliberately: this test is comparing the
   implementation against that measurement, so it has to ask the same question
   in the same words. */
static uint64_t rng_state = 0x243F6A8885A308D3ull;
static uint64_t next_random(void) {
    rng_state ^= rng_state << 13;
    rng_state ^= rng_state >> 7;
    rng_state ^= rng_state << 17;
    return rng_state;
}

#define SIM_PAGES 60000u
#define HOT_BASE  21737u

static uint64_t hot_page(void) {
    uint64_t r = next_random();
    int bucket = (int)(r & 7);
    uint64_t span = SIM_PAGES >> (bucket + 1);
    if (span == 0) span = 1;
    return (HOT_BASE + (next_random() % span)) % SIM_PAGES;
}

int main(void) {
    uint8_t *raw, *mem, *cache;
    uint64_t bytes, stats[3];

    printf("CybouDB page cache test\n\n");

    /* --- what shape is allowed ---------------------------------------------- */
    check("a cache must be eight times a power of two",
          cyboudb_pcache_bytes(64) != 0 &&
          cyboudb_pcache_bytes(8) != 0 &&
          cyboudb_pcache_bytes(0) == 0 &&
          cyboudb_pcache_bytes(12) == 0 &&   /* not a multiple of the ways */
          cyboudb_pcache_bytes(24) == 0);    /* three sets is not a power of two */

    bytes = cyboudb_pcache_bytes(64);
    check("and it asks for the frames plus a little",
          bytes > 64 * PAGE_SIZE && bytes < 66 * PAGE_SIZE);

    mem = aligned_block(bytes, &raw);
    check("a cache initialises", cyboudb_pcache_init(mem, bytes, 64) == 0);
    check("and refuses memory that is too small",
          cyboudb_pcache_init(mem, bytes - 1, 64) != 0);
    check("and refuses a frame count it cannot index",
          cyboudb_pcache_init(mem, bytes, 12) != 0);
    cache = mem;
    cyboudb_pcache_init(cache, bytes, 64);

    /* --- a page goes in and comes back -------------------------------------- */
    check("an empty cache holds nothing",
          cyboudb_pcache_lookup(cache, 100) == NULL);

    {
        uint64_t evicted = 12345;
        uint8_t *frame = cyboudb_pcache_admit(cache, 100, &evicted);
        check("admitting a page gives a frame", frame != NULL);
        check("and evicts nothing when the set has room",
              evicted == UINT64_MAX);

        memset(frame, 0xAB, PAGE_SIZE);
        check("the frame comes back on a hit",
              cyboudb_pcache_lookup(cache, 100) == frame);
        check("and still holds what was written into it",
              frame[0] == 0xAB && frame[PAGE_SIZE - 1] == 0xAB);
        check("while another page is still a miss",
              cyboudb_pcache_lookup(cache, 101) == NULL);
    }

    /* --- frames do not overlap ----------------------------------------------- */
    {
        uint64_t i, evicted;
        int distinct = 1;
        uint8_t *frames[8];
        cyboudb_pcache_init(cache, bytes, 64);
        for (i = 0; i < 8; i++) {
            frames[i] = cyboudb_pcache_admit(cache, i * 8, &evicted);
            memset(frames[i], (int)(i + 1), PAGE_SIZE);
        }
        for (i = 0; i < 8; i++)
            if (frames[i][0] != (uint8_t)(i + 1) ||
                frames[i][PAGE_SIZE - 1] != (uint8_t)(i + 1)) distinct = 0;
        check("eight pages in one set get eight frames that do not overlap",
              distinct);
    }

    /* --- the policy ----------------------------------------------------------
       A page asked for twice survives a sweep of pages asked for once. This is
       the property the whole shape was chosen for, and it is checkable in ten
       lines. */
    {
        uint64_t evicted, i;
        uint8_t *hot;
        cyboudb_pcache_init(cache, bytes, 64);

        /* page 0 is admitted and then asked for again, so it is resident */
        cyboudb_pcache_admit(cache, 0, &evicted);
        hot = cyboudb_pcache_lookup(cache, 0);
        check("a page asked for twice is a hit the second time", hot != NULL);

        /* now sweep eight more pages through the same set */
        for (i = 1; i <= WAYS; i++)
            cyboudb_pcache_admit(cache, i * 8, &evicted);

        check("and it is still there after a sweep of the set it lives in",
              cyboudb_pcache_lookup(cache, 0) != NULL);

        /* a probationary page, by contrast, does not survive its set filling */
        cyboudb_pcache_init(cache, bytes, 64);
        cyboudb_pcache_admit(cache, 0, &evicted);
        for (i = 1; i <= WAYS; i++)
            cyboudb_pcache_admit(cache, i * 8, &evicted);
        check("while a page asked for once does not",
              cyboudb_pcache_lookup(cache, 0) == NULL);
    }

    /* --- what eviction reports ------------------------------------------------ */
    {
        uint64_t evicted = 0, i;
        cyboudb_pcache_init(cache, bytes, 64);
        for (i = 0; i < WAYS; i++) cyboudb_pcache_admit(cache, i * 8, &evicted);
        cyboudb_pcache_admit(cache, WAYS * 8, &evicted);
        /* The first page admitted to the set is page zero, and it is the
           oldest probationary page in it - so this check only means anything
           because "nothing was evicted" is all ones rather than zero. The
           first version of this API used zero and this check is what found
           it. */
        check("a full set reports which page it threw out",
              evicted == 0);

        cyboudb_pcache_init(cache, bytes, 64);
        for (i = 0; i < WAYS; i++) {
            cyboudb_pcache_admit(cache, i * 8, &evicted);
            cyboudb_pcache_mark_dirty(cache, i * 8);
        }
        cyboudb_pcache_admit(cache, WAYS * 8, &evicted);
        check("and says when what it threw out has to be written back first",
              (evicted & (1ull << 63)) != 0);

        check("marking a page the cache does not hold is refused",
              cyboudb_pcache_mark_dirty(cache, 999999) != 0);
    }

    /* --- invalidation ---------------------------------------------------------- */
    {
        uint64_t evicted;
        cyboudb_pcache_init(cache, bytes, 64);
        cyboudb_pcache_admit(cache, 77, &evicted);
        check("a page can be dropped",
              cyboudb_pcache_invalidate(cache, 77) == 0 &&
              cyboudb_pcache_lookup(cache, 77) == NULL);
        check("and dropping one that is not there is refused",
              cyboudb_pcache_invalidate(cache, 77) != 0);
    }

    /* --- the address without the bookkeeping ----------------------------------- */
    {
        uint64_t evicted, before[3], after[3];
        cyboudb_pcache_init(cache, bytes, 64);
        cyboudb_pcache_admit(cache, 5, &evicted);
        cyboudb_pcache_stats(cache, before);
        check("asking where a page is does not count as a hit",
              cyboudb_pcache_frame(cache, 5) != NULL &&
              (cyboudb_pcache_stats(cache, after), 1) &&
              after[0] == before[0] && after[1] == before[1]);
    }

    /* --- against the measurement that chose this shape --------------------------
       The simulator's hot-set workload, at eight ways, predicted 82.1% with
       promote-on-second-touch. This is the same workload against the real
       thing. */
    {
        uint64_t sim_bytes = cyboudb_pcache_bytes(8192);
        uint8_t *sim_raw, *sim_mem = aligned_block(sim_bytes, &sim_raw);
        uint64_t i, hits = 0, total = 0, evicted;
        double rate;

        cyboudb_pcache_init(sim_mem, sim_bytes, 8192);
        rng_state = 0x9E3779B9ull + 1;      /* the simulator's hot-set seed */

        for (i = 0; i < 200000 + 2000000; i++) {
            uint64_t page = hot_page();
            uint8_t *frame = cyboudb_pcache_lookup(sim_mem, page);
            if (i >= 200000) {
                total++;
                if (frame) hits++;
            }
            if (!frame) cyboudb_pcache_admit(sim_mem, page, &evicted);
        }
        rate = 100.0 * (double)hits / (double)total;
        printf("\n     hot-set workload, eight ways: %.1f%% "
               "(the simulation said 82.1%%)\n\n", rate);
        check("the cache hits as often as the measurement that chose its shape "
              "said it would",
              rate > 81.0 && rate < 83.5);
        free(sim_raw);
    }

    cyboudb_pcache_stats(cache, stats);
    printf("\npage cache suite: %d checks, %d failed\n", checks, failures);
    free(raw);
    return failures ? 1 : 0;
}
