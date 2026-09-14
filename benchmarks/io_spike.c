/* benchmarks/io_spike.c - step 2.5 of 0.7: what does an encrypted read path cost?
 *
 * docs/ENCRYPTED_FORMAT.md, Decision 7: the engine reads every page as
 * `[DB_BASE + page * 4096]` into one shared mapping, and plaintext in a shared
 * mapping is plaintext on the disk. So an encrypted database cannot use that
 * mapping, and the question this program exists to answer is what the
 * alternatives cost - before a line of the real thing is written.
 *
 * Four shapes, on the same workload and the same file:
 *
 *   A   shared     MAP_SHARED / FILE_MAP_WRITE. What the engine does today,
 *                  and the baseline every other number is against.
 *   A'  dispatch   The same, reached through a function pointer, because an
 *                  encrypted build needs two read paths and the plaintext one
 *                  must not pay for the choice. This measures the branch.
 *   B   private    MAP_PRIVATE / copy-on-write. Stores cannot reach the file,
 *                  which is half of what encryption needs - and the page still
 *                  arrives as whatever the file holds, which is the other half
 *                  it does not solve.
 *   C   cache      Explicit reads into a bounded plaintext cache, with a
 *                  lookup instead of pointer arithmetic. Measured twice: once
 *                  moving bytes only, once with a transform standing in for an
 *                  AEAD, so that the architecture's cost and the cryptography's
 *                  cost do not arrive as one number.
 *
 * The transform is NOT a cipher. It is a keystream xor with a cheap PRF, and
 * it is here to establish a floor: a real AEAD does this much work and then
 * authenticates as well. Any conclusion that survives the floor being raised
 * is a conclusion; any conclusion that depends on the floor is not.
 *
 * Two workloads, because the engine has two shapes of access:
 *
 *   point   read 8 bytes of a page header, jumping between pages. Index
 *           descent, catalog navigation, queue segment lookup.
 *   scan    read every byte of a page, page after page. A table scan.
 *
 * Build (Linux):   sh build.sh --io-spike && ./build/io_spike
 * Build (Windows): build.bat --io-spike && build\io_spike.exe
 *
 * SPDX-License-Identifier: Apache-2.0
 * Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#ifdef _WIN32
#include <windows.h>
#else
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#endif

#define PAGE_SIZE   4096u
#define DEFAULT_PAGES   60000u          /* 240 MiB: bigger than a cache budget */
#define DEFAULT_TOUCHES 2000000u
#define CACHE_SHARE 10                  /* per cent of the file the cache may hold */

/* ------------------------------------------------------------------ timing */
static double now_seconds(void) {
#ifdef _WIN32
    static LARGE_INTEGER freq;
    LARGE_INTEGER t;
    if (freq.QuadPart == 0) QueryPerformanceFrequency(&freq);
    QueryPerformanceCounter(&t);
    return (double)t.QuadPart / (double)freq.QuadPart;
#else
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
#endif
}

/* ------------------------------------------------------- the file, portably */
typedef struct {
#ifdef _WIN32
    HANDLE fd;
    HANDLE mapping;
#else
    int fd;
#endif
    unsigned char *base;                /* mapping, when there is one */
    uint64_t bytes;
} spike_file;

static int file_create(spike_file *f, const char *path, uint64_t bytes) {
    memset(f, 0, sizeof *f);
    f->bytes = bytes;
#ifdef _WIN32
    f->fd = CreateFileA(path, GENERIC_READ | GENERIC_WRITE, 0, NULL,
                        CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (f->fd == INVALID_HANDLE_VALUE) return 0;
    {
        LARGE_INTEGER li;
        li.QuadPart = (LONGLONG)bytes;
        if (!SetFilePointerEx(f->fd, li, NULL, FILE_BEGIN)) return 0;
        if (!SetEndOfFile(f->fd)) return 0;
    }
    return 1;
#else
    f->fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0644);
    if (f->fd < 0) return 0;
    if (ftruncate(f->fd, (off_t)bytes) != 0) return 0;
    return 1;
#endif
}

static int file_map(spike_file *f, int shared) {
#ifdef _WIN32
    f->mapping = CreateFileMappingA(f->fd, NULL, PAGE_READWRITE, 0, 0, NULL);
    if (!f->mapping) return 0;
    f->base = (unsigned char *)MapViewOfFile(
        f->mapping, shared ? FILE_MAP_WRITE : FILE_MAP_COPY, 0, 0, 0);
    return f->base != NULL;
#else
    f->base = (unsigned char *)mmap(NULL, (size_t)f->bytes,
                                    PROT_READ | PROT_WRITE,
                                    shared ? MAP_SHARED : MAP_PRIVATE,
                                    f->fd, 0);
    if (f->base == MAP_FAILED) { f->base = NULL; return 0; }
    return 1;
#endif
}

static void file_unmap(spike_file *f) {
    if (!f->base) return;
#ifdef _WIN32
    UnmapViewOfFile(f->base);
    CloseHandle(f->mapping);
    f->mapping = NULL;
#else
    munmap(f->base, (size_t)f->bytes);
#endif
    f->base = NULL;
}

static int file_read_at(spike_file *f, uint64_t offset, void *buf, unsigned len) {
#ifdef _WIN32
    OVERLAPPED ov;
    DWORD got = 0;
    memset(&ov, 0, sizeof ov);
    ov.Offset = (DWORD)(offset & 0xFFFFFFFFu);
    ov.OffsetHigh = (DWORD)(offset >> 32);
    return ReadFile(f->fd, buf, len, &got, &ov) && got == len;
#else
    return pread(f->fd, buf, len, (off_t)offset) == (ssize_t)len;
#endif
}

static int file_write_at(spike_file *f, uint64_t offset, const void *buf,
                         unsigned len) {
#ifdef _WIN32
    OVERLAPPED ov;
    DWORD put = 0;
    memset(&ov, 0, sizeof ov);
    ov.Offset = (DWORD)(offset & 0xFFFFFFFFu);
    ov.OffsetHigh = (DWORD)(offset >> 32);
    return WriteFile(f->fd, buf, len, &put, &ov) && put == len;
#else
    return pwrite(f->fd, buf, len, (off_t)offset) == (ssize_t)len;
#endif
}

static void file_sync(spike_file *f) {
#ifdef _WIN32
    FlushFileBuffers(f->fd);
#else
    fsync(f->fd);
#endif
}

static void file_close(spike_file *f) {
    file_unmap(f);
#ifdef _WIN32
    CloseHandle(f->fd);
#else
    close(f->fd);
#endif
}

/* ------------------------------------------------------------- the workload */
/* One seeded sequence, so every architecture answers the same questions in the
   same order. Comparing architectures on different page orders would measure
   the page cache of the operating system and call it a result. */
static uint64_t rng_state;
static uint64_t rng_next(void) {
    rng_state ^= rng_state << 13;
    rng_state ^= rng_state >> 7;
    rng_state ^= rng_state << 17;
    return rng_state;
}

/* The stand-in for an AEAD: a keystream xor, no authentication. A floor. */
static void transform(unsigned char *page, uint64_t page_no) {
    uint64_t k = page_no * 0x9E3779B97F4A7C15ull + 0x1234567891234567ull;
    uint64_t *w = (uint64_t *)page;
    unsigned i;
    for (i = 0; i < PAGE_SIZE / 8; i++) {
        k ^= k << 13; k ^= k >> 7; k ^= k << 17;
        w[i] ^= k;
    }
}

/* ------------------------------------------------------ the plaintext cache */
/* Set-associative, WAYS entries per set, clock eviction inside the set.
   The first version of this was open-addressed with a global clock hand, which
   inserted a page anywhere and looked for it in a fixed probe window - so it
   almost never found what it had just stored, and reported a 0.1% hit rate on
   a cache holding a tenth of the file. The numbers that came out of it were a
   measurement of pread, not of a cache.

   A real cache also pins pages while they are in use, and pinning is a cost
   this does not model - so C's numbers here are optimistic. */
#define WAYS 8

typedef struct {
    uint64_t *tags;                     /* page number + 1, 0 when empty */
    unsigned char *slots;
    unsigned char *refbit;
    uint32_t *hand;                     /* one clock hand per set */
    uint32_t count;                     /* slots, a multiple of WAYS */
    uint32_t sets;
    uint32_t set_mask;
    uint64_t hits, misses;
} page_cache;

static int cache_init(page_cache *c, uint32_t slots) {
    uint32_t sets = 1;
    uint32_t want_sets = slots / WAYS ? slots / WAYS : 1;
    while (sets < want_sets) sets <<= 1;
    memset(c, 0, sizeof *c);
    c->sets = sets;
    c->set_mask = sets - 1;
    c->count = sets * WAYS;
    c->tags = (uint64_t *)calloc(c->count, sizeof(uint64_t));
    c->refbit = (unsigned char *)calloc(c->count, 1);
    c->hand = (uint32_t *)calloc(sets, sizeof(uint32_t));
    c->slots = (unsigned char *)malloc((size_t)c->count * PAGE_SIZE);
    return c->tags && c->slots && c->refbit && c->hand;
}

static void cache_free(page_cache *c) {
    free(c->tags); free(c->slots); free(c->refbit); free(c->hand);
}

static void cache_reset(page_cache *c) {
    memset(c->tags, 0, (size_t)c->count * sizeof(uint64_t));
    memset(c->refbit, 0, c->count);
    memset(c->hand, 0, (size_t)c->sets * sizeof(uint32_t));
    c->hits = c->misses = 0;
}

static unsigned char *cache_get(page_cache *c, spike_file *f, uint64_t page_no,
                                int with_transform) {
    uint64_t want = page_no + 1;
    uint32_t set = (uint32_t)((page_no * 0x9E3779B97F4A7C15ull) >> 33)
                   & c->set_mask;
    uint32_t base = set * WAYS, w, victim;

    for (w = 0; w < WAYS; w++) {
        if (c->tags[base + w] == want) {
            c->refbit[base + w] = 1;
            c->hits++;
            return c->slots + (size_t)(base + w) * PAGE_SIZE;
        }
    }
    c->misses++;

    /* Clock, inside this set: the victim is always a slot this page could
       have been found in, which is what the first version got wrong. */
    for (;;) {
        w = c->hand[set];
        c->hand[set] = (w + 1) % WAYS;
        if (c->tags[base + w] == 0 || c->refbit[base + w] == 0) break;
        c->refbit[base + w] = 0;
    }
    victim = base + w;
    {
        unsigned char *slot = c->slots + (size_t)victim * PAGE_SIZE;
        if (!file_read_at(f, page_no * PAGE_SIZE, slot, PAGE_SIZE)) return NULL;
        if (with_transform) transform(slot, page_no);
        c->tags[victim] = want;
        c->refbit[victim] = 1;
        return slot;
    }
}

/* ------------------------------------------------------------- measurements */
static uint64_t sink;                   /* keeps the reads from being removed */
typedef unsigned char *(*page_fn)(void *ctx, uint64_t page_no);

static unsigned char *shared_page(void *ctx, uint64_t page_no) {
    spike_file *f = (spike_file *)ctx;
    return f->base + page_no * PAGE_SIZE;
}


/* Every architecture gets a warm pass before the timed one, and the warm pass
   sweeps the whole file rather than sampling it.

   Both halves were learned from the numbers. Without any warm pass the first
   shape measured pays for faulting the mapping in, and the second looks faster
   than the thing it is a copy of. With a warm pass that only sampled a
   quarter of the pages at random, a 240 MiB file on a real disk still reported
   the shared mapping at 138 ns per page against 14 ns for the identical path
   behind a function pointer - the difference being page faults the sampling
   had not reached. A full sweep costs one pass and removes the question. */
static void warm(unsigned char *(*get)(void *, uint64_t), void *ctx,
                 uint64_t pages, uint64_t touches) {
    uint64_t i, acc = 0;
    for (i = 0; i < pages; i++) {            /* every page, in order */
        unsigned char *page = get(ctx, i);
        if (page) acc += *(uint64_t *)(page + 16);
    }
    rng_state = 0x2026091500000001ull;
    for (i = 0; i < touches; i++) {          /* then the shape of the workload */
        unsigned char *page = get(ctx, rng_next() % pages);
        if (page) acc += *(uint64_t *)(page + 16);
    }
    sink += acc;
}

static double run_point(unsigned char *(*get)(void *, uint64_t), void *ctx,
                        uint64_t pages, uint64_t touches) {
    double t0;
    uint64_t i, acc = 0;
    warm(get, ctx, pages, touches / 4);
    rng_state = 0x2026091500000001ull;
    t0 = now_seconds();
    for (i = 0; i < touches; i++) {
        uint64_t p = rng_next() % pages;
        unsigned char *page = get(ctx, p);
        if (!page) return -1.0;
        acc += *(uint64_t *)(page + 16);     /* a header field, as the engine does */
    }
    sink += acc;
    return now_seconds() - t0;
}

static double run_scan(unsigned char *(*get)(void *, uint64_t), void *ctx,
                       uint64_t pages, uint64_t sweeps) {
    double t0;
    uint64_t s, p, acc = 0;
    for (p = 0; p < pages; p++) {              /* one warm sweep */
        unsigned char *page = get(ctx, p);
        if (page) acc += *(uint64_t *)(page + 16);
    }
    t0 = now_seconds();
    for (s = 0; s < sweeps; s++) {
        for (p = 0; p < pages; p++) {
            unsigned char *page = get(ctx, p);
            uint64_t *w = (uint64_t *)page;
            unsigned j;
            if (!page) return -1.0;
            for (j = 0; j < PAGE_SIZE / 8; j += 8) acc += w[j];
        }
    }
    sink += acc;
    return now_seconds() - t0;
}

/* wrappers so every architecture is reached the same way */
static page_cache *g_cache;
static spike_file *g_file;
static int g_transform;

static unsigned char *cache_page(void *ctx, uint64_t page_no) {
    (void)ctx;
    return cache_get(g_cache, g_file, page_no, g_transform);
}

static page_fn g_dispatch;
static unsigned char *dispatch_page(void *ctx, uint64_t page_no) {
    return g_dispatch(ctx, page_no);
}

int main(int argc, char **argv) {
    /* The file's location is an argument because it decides what is being
       measured: the same binary on a Linux filesystem and on a Windows drive
       seen through WSL measures the architecture in one case and the 9p
       bridge in the other. */
    const char *path = "build/io_spike.dat";
    uint64_t pages = DEFAULT_PAGES, touches = DEFAULT_TOUCHES;
    spike_file f;
    page_cache cache;
    double t_shared_pt, t_disp_pt, t_priv_pt, t_cache_pt, t_cachex_pt;
    double t_shared_sc, t_priv_sc, t_cache_sc, t_cachex_sc;
    double hit_point = 0.0, hit_scan = 0.0;
    uint64_t budget;
    unsigned share = CACHE_SHARE;   /* the budget is the experiment */

    if (argc > 1) pages = strtoull(argv[1], NULL, 10);
    if (argc > 2) touches = strtoull(argv[2], NULL, 10);
    if (argc > 3) path = argv[3];
    if (argc > 4) share = (unsigned)strtoul(argv[4], NULL, 10);
    budget = pages * share / 100;
    if (budget < 64) budget = 64;

    printf("CybouDB encrypted I/O spike\n");
    printf("  file          %llu pages, %llu MiB\n",
           (unsigned long long)pages,
           (unsigned long long)(pages * PAGE_SIZE / (1024 * 1024)));
    printf("  point touches %llu random pages\n", (unsigned long long)touches);
    printf("  cache budget  %llu pages (%u%% of the file)\n\n",
           (unsigned long long)budget, share);

    if (!file_create(&f, path, pages * PAGE_SIZE)) {
        fprintf(stderr, "io_spike: cannot create %s\n", path);
        return 1;
    }
    /* Fill it, so the pages exist and the reads are real reads. */
    if (!file_map(&f, 1)) { fprintf(stderr, "io_spike: cannot map\n"); return 1; }
    {
        uint64_t p;
        for (p = 0; p < pages; p++) {
            uint64_t *w = (uint64_t *)(f.base + p * PAGE_SIZE);
            w[0] = 0x50515341ull;
            w[2] = p;                   /* the field the point workload reads */
            w[8] = p * 2654435761ull;
        }
    }
    file_sync(&f);
    file_unmap(&f);
    g_file = &f;

    /* A - the shared mapping, as the engine has it today. */
    if (!file_map(&f, 1)) return 1;
    t_shared_pt = run_point(shared_page, &f, pages, touches);
    t_shared_sc = run_scan(shared_page, &f, pages, 2);

    /* A' - the same, through a function pointer. */
    g_dispatch = shared_page;
    t_disp_pt = run_point(dispatch_page, &f, pages, touches);
    file_unmap(&f);

    /* B - a private mapping. */
    if (!file_map(&f, 0)) return 1;
    t_priv_pt = run_point(shared_page, &f, pages, touches);
    t_priv_sc = run_scan(shared_page, &f, pages, 2);
    file_unmap(&f);

    /* C - explicit reads into a bounded cache, without and with the floor. */
    if (!cache_init(&cache, (uint32_t)budget)) {
        fprintf(stderr, "io_spike: cannot allocate the cache\n");
        return 1;
    }
    g_cache = &cache;
    g_transform = 0;

    cache_reset(&cache);
    t_cache_pt = run_point(cache_page, NULL, pages, touches);
    hit_point = 100.0 * (double)cache.hits / (double)(cache.hits + cache.misses);

    cache_reset(&cache);
    t_cache_sc = run_scan(cache_page, NULL, pages, 2);
    hit_scan = 100.0 * (double)cache.hits / (double)(cache.hits + cache.misses);

    g_transform = 1;
    cache_reset(&cache);
    t_cachex_pt = run_point(cache_page, NULL, pages, touches);
    cache_reset(&cache);
    t_cachex_sc = run_scan(cache_page, NULL, pages, 2);
    cache_free(&cache);

    printf("  cache hit rate: point %.1f%%, scan %.1f%% "
           "(%d-way, clock within the set)\n\n", hit_point, hit_scan, WAYS);

    printf("  %-34s %12s %12s\n", "", "point ns/pg", "scan ns/pg");
    printf("  %-34s %12.1f %12.1f\n", "A  shared mapping (today)",
           t_shared_pt * 1e9 / (double)touches,
           t_shared_sc * 1e9 / (double)(pages * 2));
    printf("  %-34s %12.1f %12s\n", "A' the same, through a pointer",
           t_disp_pt * 1e9 / (double)touches, "-");
    printf("  %-34s %12.1f %12.1f\n", "B  private mapping",
           t_priv_pt * 1e9 / (double)touches,
           t_priv_sc * 1e9 / (double)(pages * 2));
    printf("  %-34s %12.1f %12.1f\n", "C  cache, bytes only",
           t_cache_pt * 1e9 / (double)touches,
           t_cache_sc * 1e9 / (double)(pages * 2));
    printf("  %-34s %12.1f %12.1f\n", "C  cache + transform (a floor)",
           t_cachex_pt * 1e9 / (double)touches,
           t_cachex_sc * 1e9 / (double)(pages * 2));

    /* The commit side: k scattered pages, written and made durable. */
    printf("\n  %-34s %12s\n", "commit of k scattered pages", "us");
    {
        unsigned char buf[PAGE_SIZE];
        uint64_t k;
        memset(buf, 0x5A, sizeof buf);
        for (k = 1; k <= 64; k *= 8) {
            double t0;
            uint64_t i;
            char label[64];
            rng_state = 0x99887766ull;
            t0 = now_seconds();
            for (i = 0; i < k; i++)
                file_write_at(&f, (rng_next() % pages) * PAGE_SIZE, buf,
                              PAGE_SIZE);
            file_sync(&f);
            snprintf(label, sizeof label, "   k = %llu, write_at + sync",
                     (unsigned long long)k);
            printf("  %-34s %12.1f\n", label,
                   (now_seconds() - t0) * 1e6);
        }
    }

    file_close(&f);
    remove(path);
    if (sink == 0x123456789abcdefull) printf("(unreachable)\n");
    return 0;
}
