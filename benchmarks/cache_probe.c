/* benchmarks/cache_probe.c - what shape should the plaintext page cache be?
 *
 * The encrypted I/O spike (benchmarks/results/2026-09-15-encrypted-io.md) left
 * two questions on the table and said plainly that it had not been designed to
 * answer them:
 *
 *   "77% is not a property of the idea, only of this structure" - eight-way
 *   sets with a low-bits index, on a workload that should have done better;
 *
 *   "a scan-resistant policy, or reading scans through a different door
 *   entirely, is a real design question for the engine and not a tuning knob".
 *
 * This probe answers both before the cache is written, because a cache is the
 * kind of thing that is easy to write once and hard to change afterwards.
 *
 * It simulates only the index structure - no I/O, no crypto, no timing of
 * anything but the simulation itself. What it reports is hit rate, which is
 * the only number the structure controls; what a miss costs was measured by
 * the spike and does not change here.
 *
 *     cc -O2 -o cache_probe benchmarks/cache_probe.c
 *
 * SPDX-License-Identifier: Apache-2.0
 * Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#define PAGES      60000u          /* a 240 MiB database */
#define CAPACITY    8192u          /* a cache holding about an eighth of it */
/* A power of two, and not negotiable: the index masks with (sets - 1), so a
   set count that is not a power of two aliases most of the cache away. The
   first run of this probe used 6000 and reported a 1.7% hit rate on uniform
   access - for a cache holding a tenth of the file, where the answer has to be
   about a tenth. That number is what found the bug. */
#define WARM        200000u
#define MEASURED   2000000u

/* --- a deterministic generator, so a surprising row can be re-run ---------- */
static uint64_t rng_state = 0x243F6A8885A308D3ull;
static uint64_t next_random(void) {
    rng_state ^= rng_state << 13;
    rng_state ^= rng_state >> 7;
    rng_state ^= rng_state << 17;
    return rng_state;
}
static void reseed(uint64_t s) { rng_state = s ? s : 1; }

/* --- the two index functions being compared ------------------------------- */
enum { HASH_LOW, HASH_MIX };

static uint32_t index_of(int hash, uint64_t page, uint32_t sets) {
    if (hash == HASH_LOW) return (uint32_t)(page & (sets - 1));
    /* Fibonacci hashing: the multiply spreads the high bits of a page number
       that low-bit masking throws away. Page numbers in a database are not
       random - they are allocated in runs, and runs share low bits. */
    return (uint32_t)((page * 0x9E3779B97F4A7C15ull) >> 40) & (sets - 1);
}

/* --- the cache ------------------------------------------------------------ */
enum { POLICY_CLOCK, POLICY_LRU, POLICY_PROBATION };

typedef struct {
    uint64_t page;       /* which page, or EMPTY */
    uint64_t stamp;      /* for LRU */
    uint8_t  referenced; /* for clock */
    uint8_t  resident;   /* promoted out of probation */
} slot;

#define EMPTY UINT64_MAX

typedef struct {
    slot    *slots;
    uint32_t sets, ways;
    uint32_t *hand;      /* one clock hand per set, as the spike's fix requires */
    int      hash, policy;
    uint64_t clock;
    uint64_t hits, misses;
} cache;

static void cache_init(cache *c, uint32_t ways, int hash, int policy) {
    uint32_t i;
    c->ways = ways;
    c->sets = CAPACITY / ways;
    c->slots = malloc(sizeof(slot) * CAPACITY);
    c->hand = calloc(c->sets, sizeof(uint32_t));
    for (i = 0; i < CAPACITY; i++) {
        c->slots[i].page = EMPTY;
        c->slots[i].stamp = 0;
        c->slots[i].referenced = 0;
        c->slots[i].resident = 0;
    }
    c->hash = hash;
    c->policy = policy;
    c->clock = 0;
    c->hits = c->misses = 0;
}

static void cache_free(cache *c) { free(c->slots); free(c->hand); }

/* Returns 1 on a hit.
 *
 * There is no "this is a scan" hint, and that is a finding rather than a
 * simplification: a page entering the cache is probationary whatever brought
 * it in, and a second touch promotes it. A sweep touches each page once, so it
 * evicts itself - without the engine having to know it was sweeping, which it
 * often does not. */
static int cache_get(cache *c, uint64_t page, int scan_hint) {
    (void)scan_hint;
    uint32_t set = index_of(c->hash, page, c->sets);
    slot *s = c->slots + (size_t)set * c->ways;
    uint32_t i, victim;

    c->clock++;

    for (i = 0; i < c->ways; i++) {
        if (s[i].page == page) {
            s[i].stamp = c->clock;
            s[i].referenced = 1;
            s[i].resident = 1;          /* a second touch promotes it */
            c->hits++;
            return 1;
        }
    }
    c->misses++;

    /* an empty slot first, whatever the policy */
    for (i = 0; i < c->ways; i++) {
        if (s[i].page == EMPTY) { victim = i; goto place; }
    }

    if (c->policy == POLICY_LRU) {
        uint64_t oldest = UINT64_MAX;
        victim = 0;
        for (i = 0; i < c->ways; i++)
            if (s[i].stamp < oldest) { oldest = s[i].stamp; victim = i; }
    } else if (c->policy == POLICY_CLOCK) {
        victim = c->hand[set];
        for (;;) {
            if (!s[victim].referenced) break;
            s[victim].referenced = 0;
            victim = (victim + 1) % c->ways;
        }
        c->hand[set] = (victim + 1) % c->ways;
    } else {
        /* Probation: a page that has only been touched once is the first to
           go, so a sweep evicts itself instead of the working set. */
        uint64_t oldest = UINT64_MAX;
        int found = 0;
        victim = 0;
        for (i = 0; i < c->ways; i++)
            if (!s[i].resident && s[i].stamp < oldest) {
                oldest = s[i].stamp; victim = i; found = 1;
            }
        if (!found) {
            oldest = UINT64_MAX;
            for (i = 0; i < c->ways; i++)
                if (s[i].stamp < oldest) { oldest = s[i].stamp; victim = i; }
        }
    }

place:
    s[victim].page = page;
    s[victim].stamp = c->clock;
    s[victim].referenced = 0;
    s[victim].resident = 0;             /* probationary until touched again */
    return 0;
}

/* --- the workloads -------------------------------------------------------- */

/* Zipf-ish without a table: pick a random rank with a heavy bias to the front.
   Not a calibrated zeta distribution, and not claimed to be one - what matters
   is that a small set of pages is much hotter than the rest, which is what a
   database index actually looks like. */
/* HOT_BASE exists because the first version of this put the hot set at page
   zero, which hands a low-bits index a perfectly spread working set for free -
   and the table then reported that low bits beat a mixing hash. That was a
   property of the workload, not of the index. The base is an odd offset with
   bits set high and low, so neither index function is being flattered. */
#define HOT_BASE 21737u

static uint64_t hot_page(void) {
    uint64_t r = next_random();
    int bucket = (int)(r & 7);
    uint64_t span = PAGES >> (bucket + 1);
    if (span == 0) span = 1;
    return (HOT_BASE + (next_random() % span)) % PAGES;
}

static uint64_t uniform_page(void) { return next_random() % PAGES; }

/* Page numbers in a real file come in runs, and a table that is read over and
   over is read as the same runs - so the runs here start inside a working set
   a good cache could hold. A workload with no reuse measures nothing about a
   cache, which is what the first version of this one did. */
static uint64_t run_page(uint64_t *cursor, uint64_t *left) {
    if (*left == 0) {
        uint64_t starts = CAPACITY / 8;      /* a working set of about 8k pages */
        *cursor = (HOT_BASE + (next_random() % starts) * 8) % PAGES;
        *left = 4 + (next_random() % 12);
    }
    (*left)--;
    return (*cursor)++ % PAGES;
}

typedef enum { W_UNIFORM, W_HOT, W_RUNS, W_SCAN_STORM } workload;

static const char *workload_name(workload w) {
    switch (w) {
    case W_UNIFORM:     return "uniform";
    case W_HOT:         return "hot set";
    case W_RUNS:        return "runs";
    default:            return "scan storm";
    }
}

/* Runs one workload and returns the hit rate. For the scan storm it returns
   the hit rate of the POINT queries only - the scan's own hits are not the
   question, the question is what the scan does to everything else. */
static double run_workload(cache *c, workload w, uint64_t seed) {
    uint64_t i, cursor = 0, left = 0, scan_at = 0;
    uint64_t point_hits = 0, point_total = 0;

    reseed(seed);
    c->hits = c->misses = 0;

    for (i = 0; i < WARM + MEASURED; i++) {
        uint64_t page;
        int is_scan = 0;

        switch (w) {
        case W_UNIFORM: page = uniform_page(); break;
        case W_HOT:     page = hot_page(); break;
        case W_RUNS:    page = run_page(&cursor, &left); break;
        default:
            /* one page of a sweep for every nine point queries */
            if ((i % 10) == 0) { page = scan_at++ % PAGES; is_scan = 1; }
            else page = hot_page();
            break;
        }

        {
            int hit = cache_get(c, page, is_scan);
            if (i >= WARM && !is_scan) {
                point_total++;
                if (hit) point_hits++;
            }
        }
    }

    if (w == W_SCAN_STORM)
        return point_total ? 100.0 * (double)point_hits / (double)point_total
                           : 0.0;
    return 100.0 * (double)c->hits / (double)(c->hits + c->misses);
}

int main(void) {
    static const uint32_t ways[] = { 1, 2, 4, 8, 16, 32 };
    static const char *policy_name[] = { "clock", "lru", "probation" };
    static const char *hash_name[] = { "low bits", "mixed" };
    int hash, policy;
    unsigned wi;
    workload w;

    printf("CybouDB page cache shape probe\n");
    printf("%u pages, a cache of %u (%.0f%%), %u measured accesses\n\n",
           PAGES, CAPACITY, 100.0 * CAPACITY / PAGES, MEASURED);

    for (w = W_UNIFORM; w <= W_SCAN_STORM; w++) {
        printf("--- %s%s\n", workload_name(w),
               w == W_SCAN_STORM ? " (hit rate of the point queries only)"
                                 : "");
        printf("%-10s %-10s", "hash", "policy");
        for (wi = 0; wi < sizeof ways / sizeof *ways; wi++)
            printf("%8u-way", ways[wi]);
        printf("\n");

        for (hash = HASH_LOW; hash <= HASH_MIX; hash++) {
            for (policy = POLICY_CLOCK; policy <= POLICY_PROBATION; policy++) {
                printf("%-10s %-10s", hash_name[hash], policy_name[policy]);
                for (wi = 0; wi < sizeof ways / sizeof *ways; wi++) {
                    cache c;
                    double rate;
                    cache_init(&c, ways[wi], hash, policy);
                    rate = run_workload(&c, w, 0x9E3779B9ull + w);
                    cache_free(&c);
                    printf("%11.1f%%", rate);
                }
                printf("\n");
            }
        }
        printf("\n");
    }

    return 0;
}
