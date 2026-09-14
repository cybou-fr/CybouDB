/* benchmarks/crypto_probe.c - step 3 of 0.7: what does sealing a page cost?
 *
 * The I/O spike (2026-09-15-encrypted-io.md) measured the architecture with a
 * stand-in transform and said, in effect: the cache decides, the cipher is
 * amortised. That was true of a floor. This replaces the floor with real
 * primitives, so the amortised term is a measured number rather than a guess.
 *
 * What it does:
 *
 *   1. reports the CPU features that decide which primitives are even
 *      available - the engine already dispatches on CPUID for POPCNT and BMI2,
 *      and a crypto backend has to do the same or refuse to run on a machine
 *      without AES-NI;
 *   2. checks ChaCha20 and Poly1305 against the test vectors in RFC 8439
 *      sections 2.3.2 and 2.5.2, verbatim. An implementation that has not been
 *      held to official vectors is not a reference implementation, it is a
 *      guess that compiles;
 *   3. measures both over a 4096-byte page, which is the unit the format seals.
 *
 * The AES-NI path is a throughput comparison and NOT validated here: it exists
 * to answer "how much does hardware AES change the decision", and if AES ever
 * becomes the shipped primitive it arrives with its own known-answer vectors.
 * A number from it is a speed, not a correctness claim.
 *
 * Build (Linux):   sh build.sh --crypto-probe && ./build/crypto_probe
 * Build (Windows): build.bat --crypto-probe && build\crypto_probe.exe
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
#include <intrin.h>
#else
#include <time.h>
#include <cpuid.h>
#include <wmmintrin.h>
#endif

#define PAGE_SIZE 4096u

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

/* --------------------------------------------------------------- CPU features */
typedef struct {
    int aesni, pclmul, sha_ni, avx2, rdseed, sse41;
} cpu_features;

static void cpu_detect(cpu_features *f) {
    uint32_t regs[4] = {0, 0, 0, 0};
    uint32_t maxleaf;
    memset(f, 0, sizeof *f);
#ifdef _WIN32
    __cpuid((int *)regs, 0);
#else
    __cpuid(0, regs[0], regs[1], regs[2], regs[3]);
#endif
    maxleaf = regs[0];
    if (maxleaf >= 1) {
#ifdef _WIN32
        __cpuid((int *)regs, 1);
#else
        __cpuid(1, regs[0], regs[1], regs[2], regs[3]);
#endif
        f->pclmul = (regs[2] >> 1) & 1;
        f->sse41  = (regs[2] >> 19) & 1;
        f->aesni  = (regs[2] >> 25) & 1;
    }
    if (maxleaf >= 7) {
#ifdef _WIN32
        __cpuidex((int *)regs, 7, 0);
#else
        __cpuid_count(7, 0, regs[0], regs[1], regs[2], regs[3]);
#endif
        f->avx2   = (regs[1] >> 5) & 1;
        f->rdseed = (regs[1] >> 18) & 1;
        f->sha_ni = (regs[1] >> 29) & 1;
    }
}

/* ------------------------------------------------------------------ ChaCha20 */
/* RFC 8439 section 2. Written for clarity, not for speed: the question this
   answers is what a straightforward implementation costs, because that is what
   a project writing its own backend would ship first. */
#define ROTL32(v, n) (((v) << (n)) | ((v) >> (32 - (n))))

#define QUARTERROUND(a, b, c, d)            \
    a += b; d ^= a; d = ROTL32(d, 16);      \
    c += d; b ^= c; b = ROTL32(b, 12);      \
    a += b; d ^= a; d = ROTL32(d, 8);       \
    c += d; b ^= c; b = ROTL32(b, 7)

static void chacha20_block(const uint8_t key[32], uint32_t counter,
                           const uint8_t nonce[12], uint8_t out[64]) {
    static const uint32_t C[4] = {0x61707865, 0x3320646e, 0x79622d32, 0x6b206574};
    uint32_t s[16], x[16];
    int i;

    s[0] = C[0]; s[1] = C[1]; s[2] = C[2]; s[3] = C[3];
    for (i = 0; i < 8; i++)
        s[4 + i] = (uint32_t)key[4 * i] | ((uint32_t)key[4 * i + 1] << 8) |
                   ((uint32_t)key[4 * i + 2] << 16) |
                   ((uint32_t)key[4 * i + 3] << 24);
    s[12] = counter;
    for (i = 0; i < 3; i++)
        s[13 + i] = (uint32_t)nonce[4 * i] | ((uint32_t)nonce[4 * i + 1] << 8) |
                    ((uint32_t)nonce[4 * i + 2] << 16) |
                    ((uint32_t)nonce[4 * i + 3] << 24);

    memcpy(x, s, sizeof x);
    for (i = 0; i < 10; i++) {
        QUARTERROUND(x[0], x[4], x[8],  x[12]);
        QUARTERROUND(x[1], x[5], x[9],  x[13]);
        QUARTERROUND(x[2], x[6], x[10], x[14]);
        QUARTERROUND(x[3], x[7], x[11], x[15]);
        QUARTERROUND(x[0], x[5], x[10], x[15]);
        QUARTERROUND(x[1], x[6], x[11], x[12]);
        QUARTERROUND(x[2], x[7], x[8],  x[13]);
        QUARTERROUND(x[3], x[4], x[9],  x[14]);
    }
    for (i = 0; i < 16; i++) {
        uint32_t v = x[i] + s[i];
        out[4 * i]     = (uint8_t)(v);
        out[4 * i + 1] = (uint8_t)(v >> 8);
        out[4 * i + 2] = (uint8_t)(v >> 16);
        out[4 * i + 3] = (uint8_t)(v >> 24);
    }
}

static void chacha20_xor(const uint8_t key[32], uint32_t counter,
                         const uint8_t nonce[12], uint8_t *buf, size_t len) {
    uint8_t ks[64];
    size_t done = 0;
    while (done < len) {
        size_t n = len - done < 64 ? len - done : 64;
        size_t i;
        chacha20_block(key, counter, nonce, ks);
        for (i = 0; i < n; i++) buf[done + i] ^= ks[i];
        done += n;
        counter++;
    }
}

/* The same cipher with the state built once instead of once per 64 bytes.
   chacha20_xor above re-derives the whole state - including parsing the key
   out of bytes - for every block, which is what makes the version above easy
   to check against the vector and unfair to measure. A real implementation
   looks like this one, and the gap between them is reported rather than
   quietly chosen. */
static void chacha20_xor_hoisted(const uint8_t key[32], uint32_t counter,
                                 const uint8_t nonce[12], uint8_t *buf,
                                 size_t len) {
    static const uint32_t C[4] = {0x61707865, 0x3320646e, 0x79622d32, 0x6b206574};
    uint32_t s[16];
    size_t done = 0;
    int i;

    s[0] = C[0]; s[1] = C[1]; s[2] = C[2]; s[3] = C[3];
    for (i = 0; i < 8; i++)
        s[4 + i] = (uint32_t)key[4 * i] | ((uint32_t)key[4 * i + 1] << 8) |
                   ((uint32_t)key[4 * i + 2] << 16) |
                   ((uint32_t)key[4 * i + 3] << 24);
    s[12] = counter;
    for (i = 0; i < 3; i++)
        s[13 + i] = (uint32_t)nonce[4 * i] | ((uint32_t)nonce[4 * i + 1] << 8) |
                    ((uint32_t)nonce[4 * i + 2] << 16) |
                    ((uint32_t)nonce[4 * i + 3] << 24);

    while (done < len) {
        uint32_t x[16];
        size_t n = len - done < 64 ? len - done : 64;
        size_t j;
        memcpy(x, s, sizeof x);
        for (i = 0; i < 10; i++) {
            QUARTERROUND(x[0], x[4], x[8],  x[12]);
            QUARTERROUND(x[1], x[5], x[9],  x[13]);
            QUARTERROUND(x[2], x[6], x[10], x[14]);
            QUARTERROUND(x[3], x[7], x[11], x[15]);
            QUARTERROUND(x[0], x[5], x[10], x[15]);
            QUARTERROUND(x[1], x[6], x[11], x[12]);
            QUARTERROUND(x[2], x[7], x[8],  x[13]);
            QUARTERROUND(x[3], x[4], x[9],  x[14]);
        }
        for (i = 0; i < 16; i++) x[i] += s[i];
        for (j = 0; j < n; j++)
            buf[done + j] ^= (uint8_t)(x[j >> 2] >> ((j & 3) * 8));
        done += n;
        s[12]++;
    }
}

/* ----------------------------------------------------- ChaCha20, vectorised */
/* One block at a time in four 128-bit registers: the state's four rows, with
   the column and diagonal rounds turned into shuffles.

   SSE2 only, and deliberately so. SSE2 is part of the x86-64 baseline, so this
   path needs no CPUID question and no fallback - unlike POPCNT or AES-NI,
   there is no machine this engine supports that lacks it. The rotations are
   shift-or pairs rather than PSHUFB for the same reason: PSHUFB would be a
   little faster and would drag SSSE3 and a dispatch decision in with it.

   The output must be byte-identical to the scalar implementation. That is
   asserted below, not assumed: it is the property that lets the format say
   XChaCha20-Poly1305 without saying which instructions computed it. */
#if defined(__x86_64__) || defined(_M_X64)
#define HAVE_CHACHA_SSE2 1
#ifdef _WIN32
#include <emmintrin.h>
#else
#include <emmintrin.h>
#endif

static __m128i rotl_epi32(__m128i x, int n) {
    return _mm_or_si128(_mm_slli_epi32(x, n), _mm_srli_epi32(x, 32 - n));
}

static void chacha20_xor_sse2(const uint8_t key[32], uint32_t counter,
                              const uint8_t nonce[12], uint8_t *buf,
                              size_t len) {
    static const uint32_t C[4] = {0x61707865, 0x3320646e, 0x79622d32, 0x6b206574};
    uint32_t s[16];
    __m128i v0, v1, v2, v3;
    size_t done = 0;
    int i;

    s[0] = C[0]; s[1] = C[1]; s[2] = C[2]; s[3] = C[3];
    for (i = 0; i < 8; i++)
        s[4 + i] = (uint32_t)key[4 * i] | ((uint32_t)key[4 * i + 1] << 8) |
                   ((uint32_t)key[4 * i + 2] << 16) |
                   ((uint32_t)key[4 * i + 3] << 24);
    s[12] = counter;
    for (i = 0; i < 3; i++)
        s[13 + i] = (uint32_t)nonce[4 * i] | ((uint32_t)nonce[4 * i + 1] << 8) |
                    ((uint32_t)nonce[4 * i + 2] << 16) |
                    ((uint32_t)nonce[4 * i + 3] << 24);

    v0 = _mm_loadu_si128((const __m128i *)(s + 0));
    v1 = _mm_loadu_si128((const __m128i *)(s + 4));
    v2 = _mm_loadu_si128((const __m128i *)(s + 8));
    v3 = _mm_loadu_si128((const __m128i *)(s + 12));

    while (done < len) {
        __m128i a = v0, b = v1, c = v2, d = v3;
        uint8_t ks[64];
        size_t n = len - done < 64 ? len - done : 64;
        size_t j;

        for (i = 0; i < 10; i++) {
            a = _mm_add_epi32(a, b); d = _mm_xor_si128(d, a); d = rotl_epi32(d, 16);
            c = _mm_add_epi32(c, d); b = _mm_xor_si128(b, c); b = rotl_epi32(b, 12);
            a = _mm_add_epi32(a, b); d = _mm_xor_si128(d, a); d = rotl_epi32(d, 8);
            c = _mm_add_epi32(c, d); b = _mm_xor_si128(b, c); b = rotl_epi32(b, 7);

            b = _mm_shuffle_epi32(b, 0x39);   /* rows slide: 1,2,3 lanes over */
            c = _mm_shuffle_epi32(c, 0x4E);
            d = _mm_shuffle_epi32(d, 0x93);

            a = _mm_add_epi32(a, b); d = _mm_xor_si128(d, a); d = rotl_epi32(d, 16);
            c = _mm_add_epi32(c, d); b = _mm_xor_si128(b, c); b = rotl_epi32(b, 12);
            a = _mm_add_epi32(a, b); d = _mm_xor_si128(d, a); d = rotl_epi32(d, 8);
            c = _mm_add_epi32(c, d); b = _mm_xor_si128(b, c); b = rotl_epi32(b, 7);

            b = _mm_shuffle_epi32(b, 0x93);   /* and slide back */
            c = _mm_shuffle_epi32(c, 0x4E);
            d = _mm_shuffle_epi32(d, 0x39);
        }

        _mm_storeu_si128((__m128i *)(ks +  0), _mm_add_epi32(a, v0));
        _mm_storeu_si128((__m128i *)(ks + 16), _mm_add_epi32(b, v1));
        _mm_storeu_si128((__m128i *)(ks + 32), _mm_add_epi32(c, v2));
        _mm_storeu_si128((__m128i *)(ks + 48), _mm_add_epi32(d, v3));
        for (j = 0; j < n; j++) buf[done + j] ^= ks[j];

        done += n;
        v3 = _mm_add_epi32(v3, _mm_set_epi32(0, 0, 0, 1));
    }
}

/* Four blocks at once, transposed: each register holds word i of four
   different blocks, so a quarter-round is four independent quarter-rounds and
   the shuffles disappear entirely - the diagonal round is just a different
   choice of registers.

   The single-block version above is only 1.6x the scalar code because its four
   vectors form one dependency chain and the machine spends its time waiting.
   This one has four chains, which is the whole trick. */
static void chacha20_xor_sse2x4(const uint8_t key[32], uint32_t counter,
                                const uint8_t nonce[12], uint8_t *buf,
                                size_t len) {
    static const uint32_t C[4] = {0x61707865, 0x3320646e, 0x79622d32, 0x6b206574};
    uint32_t s[16];
    size_t done = 0;
    int i;

    s[0] = C[0]; s[1] = C[1]; s[2] = C[2]; s[3] = C[3];
    for (i = 0; i < 8; i++)
        s[4 + i] = (uint32_t)key[4 * i] | ((uint32_t)key[4 * i + 1] << 8) |
                   ((uint32_t)key[4 * i + 2] << 16) |
                   ((uint32_t)key[4 * i + 3] << 24);
    s[12] = counter;
    for (i = 0; i < 3; i++)
        s[13 + i] = (uint32_t)nonce[4 * i] | ((uint32_t)nonce[4 * i + 1] << 8) |
                    ((uint32_t)nonce[4 * i + 2] << 16) |
                    ((uint32_t)nonce[4 * i + 3] << 24);

    while (done < len) {
        __m128i x[16], o[16];
        uint32_t words[16][4];
        size_t chunk = len - done;
        int blk;

        for (i = 0; i < 16; i++) x[i] = _mm_set1_epi32((int)s[i]);
        x[12] = _mm_set_epi32((int)(s[12] + 3), (int)(s[12] + 2),
                              (int)(s[12] + 1), (int)(s[12] + 0));
        for (i = 0; i < 16; i++) o[i] = x[i];

#define QR4(a, b, c, d)                                                      \
        x[a] = _mm_add_epi32(x[a], x[b]);                                    \
        x[d] = _mm_xor_si128(x[d], x[a]); x[d] = rotl_epi32(x[d], 16);       \
        x[c] = _mm_add_epi32(x[c], x[d]);                                    \
        x[b] = _mm_xor_si128(x[b], x[c]); x[b] = rotl_epi32(x[b], 12);       \
        x[a] = _mm_add_epi32(x[a], x[b]);                                    \
        x[d] = _mm_xor_si128(x[d], x[a]); x[d] = rotl_epi32(x[d], 8);        \
        x[c] = _mm_add_epi32(x[c], x[d]);                                    \
        x[b] = _mm_xor_si128(x[b], x[c]); x[b] = rotl_epi32(x[b], 7)

        for (i = 0; i < 10; i++) {
            QR4(0, 4,  8, 12); QR4(1, 5,  9, 13);
            QR4(2, 6, 10, 14); QR4(3, 7, 11, 15);
            QR4(0, 5, 10, 15); QR4(1, 6, 11, 12);
            QR4(2, 7,  8, 13); QR4(3, 4,  9, 14);
        }
#undef QR4

        for (i = 0; i < 16; i++)
            _mm_storeu_si128((__m128i *)words[i], _mm_add_epi32(x[i], o[i]));

        for (blk = 0; blk < 4 && chunk > 0; blk++) {
            uint8_t ks[64];
            size_t n = chunk < 64 ? chunk : 64;
            size_t j;
            for (i = 0; i < 16; i++) {
                uint32_t v = words[i][blk];
                ks[4 * i]     = (uint8_t)v;
                ks[4 * i + 1] = (uint8_t)(v >> 8);
                ks[4 * i + 2] = (uint8_t)(v >> 16);
                ks[4 * i + 3] = (uint8_t)(v >> 24);
            }
            for (j = 0; j < n; j++) buf[done + j] ^= ks[j];
            done += n;
            chunk -= n;
        }
        s[12] += 4;
    }
}
#endif

/* Eight blocks, the same transposed idea one register width up.
   AVX2 is not baseline, so unlike the SSE2 paths this one is a dispatch
   decision: CPUID leaf 7 EBX bit 5, checked before it is called. It exists to
   answer how far this construction can go on a general-purpose core, which is
   the number docs/CRYPTO_BACKEND.md's Decision 3 rests on. */
/* The target attribute compiles this function for AVX2 without the whole
   translation unit being built for it, so no -mavx2 and no separate object:
   the guard is "does the compiler support that", not "was AVX2 requested". */
#if defined(_MSC_VER) || defined(__GNUC__)
#define HAVE_CHACHA_AVX2 1
#include <immintrin.h>

#ifdef _MSC_VER
#define CHACHA_AVX2_TARGET
#else
#define CHACHA_AVX2_TARGET __attribute__((target("avx2")))
#endif

CHACHA_AVX2_TARGET
static __m256i rotl_epi32_256(__m256i x, int n) {
    return _mm256_or_si256(_mm256_slli_epi32(x, n), _mm256_srli_epi32(x, 32 - n));
}

CHACHA_AVX2_TARGET
static void chacha20_xor_avx2(const uint8_t key[32], uint32_t counter,
                              const uint8_t nonce[12], uint8_t *buf,
                              size_t len) {
    static const uint32_t C[4] = {0x61707865, 0x3320646e, 0x79622d32, 0x6b206574};
    uint32_t s[16];
    size_t done = 0;
    int i;

    s[0] = C[0]; s[1] = C[1]; s[2] = C[2]; s[3] = C[3];
    for (i = 0; i < 8; i++)
        s[4 + i] = (uint32_t)key[4 * i] | ((uint32_t)key[4 * i + 1] << 8) |
                   ((uint32_t)key[4 * i + 2] << 16) |
                   ((uint32_t)key[4 * i + 3] << 24);
    s[12] = counter;
    for (i = 0; i < 3; i++)
        s[13 + i] = (uint32_t)nonce[4 * i] | ((uint32_t)nonce[4 * i + 1] << 8) |
                    ((uint32_t)nonce[4 * i + 2] << 16) |
                    ((uint32_t)nonce[4 * i + 3] << 24);

    while (done < len) {
        __m256i x[16], o[16];
        uint32_t words[16][8];
        size_t chunk = len - done;
        int blk;

        for (i = 0; i < 16; i++) x[i] = _mm256_set1_epi32((int)s[i]);
        x[12] = _mm256_set_epi32((int)(s[12] + 7), (int)(s[12] + 6),
                                 (int)(s[12] + 5), (int)(s[12] + 4),
                                 (int)(s[12] + 3), (int)(s[12] + 2),
                                 (int)(s[12] + 1), (int)(s[12] + 0));
        for (i = 0; i < 16; i++) o[i] = x[i];

#define QR8(a, b, c, d)                                                       \
        x[a] = _mm256_add_epi32(x[a], x[b]);                                  \
        x[d] = _mm256_xor_si256(x[d], x[a]); x[d] = rotl_epi32_256(x[d], 16); \
        x[c] = _mm256_add_epi32(x[c], x[d]);                                  \
        x[b] = _mm256_xor_si256(x[b], x[c]); x[b] = rotl_epi32_256(x[b], 12); \
        x[a] = _mm256_add_epi32(x[a], x[b]);                                  \
        x[d] = _mm256_xor_si256(x[d], x[a]); x[d] = rotl_epi32_256(x[d], 8);  \
        x[c] = _mm256_add_epi32(x[c], x[d]);                                  \
        x[b] = _mm256_xor_si256(x[b], x[c]); x[b] = rotl_epi32_256(x[b], 7)

        for (i = 0; i < 10; i++) {
            QR8(0, 4,  8, 12); QR8(1, 5,  9, 13);
            QR8(2, 6, 10, 14); QR8(3, 7, 11, 15);
            QR8(0, 5, 10, 15); QR8(1, 6, 11, 12);
            QR8(2, 7,  8, 13); QR8(3, 4,  9, 14);
        }
#undef QR8

        for (i = 0; i < 16; i++)
            _mm256_storeu_si256((__m256i *)words[i],
                                _mm256_add_epi32(x[i], o[i]));

        for (blk = 0; blk < 8 && chunk > 0; blk++) {
            uint8_t ks[64];
            size_t n = chunk < 64 ? chunk : 64;
            size_t j;
            for (i = 0; i < 16; i++) {
                uint32_t v = words[i][blk];
                ks[4 * i]     = (uint8_t)v;
                ks[4 * i + 1] = (uint8_t)(v >> 8);
                ks[4 * i + 2] = (uint8_t)(v >> 16);
                ks[4 * i + 3] = (uint8_t)(v >> 24);
            }
            for (j = 0; j < n; j++) buf[done + j] ^= ks[j];
            done += n;
            chunk -= n;
        }
        s[12] += 8;
    }
}
#endif

/* ------------------------------------------------------------------ Poly1305 */
/* RFC 8439 section 2.5, in 26-bit limbs so that every product fits in 64 bits
   and the code needs no 128-bit type - MSVC does not have one. */
typedef struct {
    uint32_t r[5], h[5], pad[4];
    size_t leftover;
    uint8_t buffer[16];
    int final;
} poly1305_ctx;

static uint32_t u8to32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static void poly1305_init(poly1305_ctx *st, const uint8_t key[32]) {
    st->r[0] = (u8to32(key)          ) & 0x3ffffff;
    st->r[1] = (u8to32(key +  3) >> 2) & 0x3ffff03;
    st->r[2] = (u8to32(key +  6) >> 4) & 0x3ffc0ff;
    st->r[3] = (u8to32(key +  9) >> 6) & 0x3f03fff;
    st->r[4] = (u8to32(key + 12) >> 8) & 0x00fffff;
    memset(st->h, 0, sizeof st->h);
    st->pad[0] = u8to32(key + 16);
    st->pad[1] = u8to32(key + 20);
    st->pad[2] = u8to32(key + 24);
    st->pad[3] = u8to32(key + 28);
    st->leftover = 0;
    st->final = 0;
}

static void poly1305_blocks(poly1305_ctx *st, const uint8_t *m, size_t bytes) {
    const uint32_t hibit = st->final ? 0 : (1UL << 24);
    uint32_t r0 = st->r[0], r1 = st->r[1], r2 = st->r[2], r3 = st->r[3],
             r4 = st->r[4];
    uint32_t s1 = r1 * 5, s2 = r2 * 5, s3 = r3 * 5, s4 = r4 * 5;
    uint32_t h0 = st->h[0], h1 = st->h[1], h2 = st->h[2], h3 = st->h[3],
             h4 = st->h[4];

    while (bytes >= 16) {
        uint64_t d0, d1, d2, d3, d4;
        uint32_t c;

        h0 += (u8to32(m)           ) & 0x3ffffff;
        h1 += (u8to32(m +  3) >>  2) & 0x3ffffff;
        h2 += (u8to32(m +  6) >>  4) & 0x3ffffff;
        h3 += (u8to32(m +  9) >>  6) & 0x3ffffff;
        h4 += (u8to32(m + 12) >>  8) | hibit;

        d0 = (uint64_t)h0 * r0 + (uint64_t)h1 * s4 + (uint64_t)h2 * s3 +
             (uint64_t)h3 * s2 + (uint64_t)h4 * s1;
        d1 = (uint64_t)h0 * r1 + (uint64_t)h1 * r0 + (uint64_t)h2 * s4 +
             (uint64_t)h3 * s3 + (uint64_t)h4 * s2;
        d2 = (uint64_t)h0 * r2 + (uint64_t)h1 * r1 + (uint64_t)h2 * r0 +
             (uint64_t)h3 * s4 + (uint64_t)h4 * s3;
        d3 = (uint64_t)h0 * r3 + (uint64_t)h1 * r2 + (uint64_t)h2 * r1 +
             (uint64_t)h3 * r0 + (uint64_t)h4 * s4;
        d4 = (uint64_t)h0 * r4 + (uint64_t)h1 * r3 + (uint64_t)h2 * r2 +
             (uint64_t)h3 * r1 + (uint64_t)h4 * r0;

        c = (uint32_t)(d0 >> 26); h0 = (uint32_t)d0 & 0x3ffffff;
        d1 += c; c = (uint32_t)(d1 >> 26); h1 = (uint32_t)d1 & 0x3ffffff;
        d2 += c; c = (uint32_t)(d2 >> 26); h2 = (uint32_t)d2 & 0x3ffffff;
        d3 += c; c = (uint32_t)(d3 >> 26); h3 = (uint32_t)d3 & 0x3ffffff;
        d4 += c; c = (uint32_t)(d4 >> 26); h4 = (uint32_t)d4 & 0x3ffffff;
        h0 += c * 5; c = h0 >> 26; h0 &= 0x3ffffff;
        h1 += c;

        m += 16;
        bytes -= 16;
    }
    st->h[0] = h0; st->h[1] = h1; st->h[2] = h2; st->h[3] = h3; st->h[4] = h4;
}

static void poly1305_update(poly1305_ctx *st, const uint8_t *m, size_t bytes) {
    if (st->leftover) {
        size_t want = 16 - st->leftover;
        if (want > bytes) want = bytes;
        memcpy(st->buffer + st->leftover, m, want);
        bytes -= want;
        m += want;
        st->leftover += want;
        if (st->leftover < 16) return;
        poly1305_blocks(st, st->buffer, 16);
        st->leftover = 0;
    }
    if (bytes >= 16) {
        size_t want = bytes & ~(size_t)15;
        poly1305_blocks(st, m, want);
        m += want;
        bytes -= want;
    }
    if (bytes) {
        memcpy(st->buffer + st->leftover, m, bytes);
        st->leftover += bytes;
    }
}

static void poly1305_finish(poly1305_ctx *st, uint8_t mac[16]) {
    uint32_t h0, h1, h2, h3, h4, c, g0, g1, g2, g3, g4, mask;
    uint64_t f;

    if (st->leftover) {
        size_t i = st->leftover;
        st->buffer[i++] = 1;
        for (; i < 16; i++) st->buffer[i] = 0;
        st->final = 1;
        poly1305_blocks(st, st->buffer, 16);
    }

    h0 = st->h[0]; h1 = st->h[1]; h2 = st->h[2]; h3 = st->h[3]; h4 = st->h[4];
    c = h1 >> 26; h1 &= 0x3ffffff;
    h2 += c; c = h2 >> 26; h2 &= 0x3ffffff;
    h3 += c; c = h3 >> 26; h3 &= 0x3ffffff;
    h4 += c; c = h4 >> 26; h4 &= 0x3ffffff;
    h0 += c * 5; c = h0 >> 26; h0 &= 0x3ffffff;
    h1 += c;

    g0 = h0 + 5; c = g0 >> 26; g0 &= 0x3ffffff;
    g1 = h1 + c; c = g1 >> 26; g1 &= 0x3ffffff;
    g2 = h2 + c; c = g2 >> 26; g2 &= 0x3ffffff;
    g3 = h3 + c; c = g3 >> 26; g3 &= 0x3ffffff;
    g4 = h4 + c - (1UL << 26);

    mask = (g4 >> 31) - 1;              /* 0 if g4 borrowed, all ones if not */
    g0 &= mask; g1 &= mask; g2 &= mask; g3 &= mask; g4 &= mask;
    mask = ~mask;
    h0 = (h0 & mask) | g0;
    h1 = (h1 & mask) | g1;
    h2 = (h2 & mask) | g2;
    h3 = (h3 & mask) | g3;
    h4 = (h4 & mask) | g4;

    h0 = (h0      ) | (h1 << 26);
    h1 = (h1 >>  6) | (h2 << 20);
    h2 = (h2 >> 12) | (h3 << 14);
    h3 = (h3 >> 18) | (h4 <<  8);

    f = (uint64_t)h0 + st->pad[0]; h0 = (uint32_t)f;
    f = (uint64_t)h1 + st->pad[1] + (f >> 32); h1 = (uint32_t)f;
    f = (uint64_t)h2 + st->pad[2] + (f >> 32); h2 = (uint32_t)f;
    f = (uint64_t)h3 + st->pad[3] + (f >> 32); h3 = (uint32_t)f;

    mac[0] = (uint8_t)h0; mac[1] = (uint8_t)(h0 >> 8);
    mac[2] = (uint8_t)(h0 >> 16); mac[3] = (uint8_t)(h0 >> 24);
    mac[4] = (uint8_t)h1; mac[5] = (uint8_t)(h1 >> 8);
    mac[6] = (uint8_t)(h1 >> 16); mac[7] = (uint8_t)(h1 >> 24);
    mac[8] = (uint8_t)h2; mac[9] = (uint8_t)(h2 >> 8);
    mac[10] = (uint8_t)(h2 >> 16); mac[11] = (uint8_t)(h2 >> 24);
    mac[12] = (uint8_t)h3; mac[13] = (uint8_t)(h3 >> 8);
    mac[14] = (uint8_t)(h3 >> 16); mac[15] = (uint8_t)(h3 >> 24);
}

/* ------------------------------------------- Poly1305 in 64-bit limbs */
/* The 26-bit version above needs five limbs and twenty-five 32x32 products per
   block because it was written to need nothing wider than a uint64_t. On
   x86-64 a 64x64->128 multiply is one instruction, so three limbs of 44, 44
   and 42 bits need nine products instead - and the field reduction stays the
   same shape.

   This is the same algorithm, not a different one: both are held to the RFC
   vector, and each is checked against the other on inputs of every length,
   which is a stronger statement than either check alone. */
#ifdef _MSC_VER
typedef struct { uint64_t lo, hi; } u128_t;
static u128_t u128_mul(uint64_t a, uint64_t b) {
    u128_t r;
    r.lo = _umul128(a, b, &r.hi);
    return r;
}
static u128_t u128_add(u128_t a, u128_t b) {
    u128_t r;
    unsigned char c = _addcarry_u64(0, a.lo, b.lo, &r.lo);
    _addcarry_u64(c, a.hi, b.hi, &r.hi);
    return r;
}
static u128_t u128_addu(u128_t a, uint64_t b) {
    u128_t t; t.lo = b; t.hi = 0;
    return u128_add(a, t);
}
static uint64_t u128_low44(u128_t a) { return a.lo & 0xfffffffffffULL; }
static uint64_t u128_low42(u128_t a) { return a.lo & 0x3ffffffffffULL; }
static uint64_t u128_shr44(u128_t a) { return (a.lo >> 44) | (a.hi << 20); }
static uint64_t u128_shr42(u128_t a) { return (a.lo >> 42) | (a.hi << 22); }
#else
typedef unsigned __int128 u128_t;
static u128_t u128_mul(uint64_t a, uint64_t b) { return (u128_t)a * b; }
static u128_t u128_add(u128_t a, u128_t b) { return a + b; }
static u128_t u128_addu(u128_t a, uint64_t b) { return a + b; }
static uint64_t u128_low44(u128_t a) { return (uint64_t)a & 0xfffffffffffULL; }
static uint64_t u128_low42(u128_t a) { return (uint64_t)a & 0x3ffffffffffULL; }
static uint64_t u128_shr44(u128_t a) { return (uint64_t)(a >> 44); }
static uint64_t u128_shr42(u128_t a) { return (uint64_t)(a >> 42); }
#endif

typedef struct {
    uint64_t r[3], h[3], pad[2];
    size_t leftover;
    uint8_t buffer[16];
    int final;
} poly1305_64;

/* memcpy rather than eight shifted byte loads. Both are correct and portable;
   this one is a single instruction on any little-endian machine because the
   compiler knows what memcpy of eight bytes into a uint64_t means, and the
   other is fourteen shifts and ors the optimiser may or may not recognise.
   The difference turned out to be most of Poly1305's cost - see the result. */
static uint64_t load64le(const uint8_t *p) {
    uint64_t v;
    memcpy(&v, p, 8);
    return v;                       /* little-endian hosts only, as x86-64 is */
}

static void poly64_init(poly1305_64 *st, const uint8_t key[32]) {
    uint64_t t0 = load64le(key), t1 = load64le(key + 8);
    st->r[0] = (t0                         ) & 0x0ffc0fffffffULL;
    st->r[1] = ((t0 >> 44) | (t1 << 20)    ) & 0x0fffffc0ffffULL;
    st->r[2] = ((t1 >> 24)                 ) & 0x00ffffffc0fULL;
    st->h[0] = st->h[1] = st->h[2] = 0;
    st->pad[0] = load64le(key + 16);
    st->pad[1] = load64le(key + 24);
    st->leftover = 0;
    st->final = 0;
}

static void poly64_blocks(poly1305_64 *st, const uint8_t *m, size_t bytes) {
    const uint64_t hibit = st->final ? 0 : ((uint64_t)1 << 40);
    uint64_t r0 = st->r[0], r1 = st->r[1], r2 = st->r[2];
    uint64_t s1 = r1 * 20, s2 = r2 * 20;
    uint64_t h0 = st->h[0], h1 = st->h[1], h2 = st->h[2];

    while (bytes >= 16) {
        u128_t d0, d1, d2;
        uint64_t c, t0 = load64le(m), t1 = load64le(m + 8);

        h0 += (t0                      ) & 0xfffffffffffULL;
        h1 += ((t0 >> 44) | (t1 << 20) ) & 0xfffffffffffULL;
        h2 += (((t1 >> 24)             ) & 0x3ffffffffffULL) | hibit;

        d0 = u128_add(u128_add(u128_mul(h0, r0), u128_mul(h1, s2)),
                      u128_mul(h2, s1));
        d1 = u128_add(u128_add(u128_mul(h0, r1), u128_mul(h1, r0)),
                      u128_mul(h2, s2));
        d2 = u128_add(u128_add(u128_mul(h0, r2), u128_mul(h1, r1)),
                      u128_mul(h2, r0));

        c  = u128_shr44(d0); h0 = u128_low44(d0);
        d1 = u128_addu(d1, c);
        c  = u128_shr44(d1); h1 = u128_low44(d1);
        d2 = u128_addu(d2, c);
        c  = u128_shr42(d2); h2 = u128_low42(d2);
        h0 += c * 5;
        c = h0 >> 44; h0 &= 0xfffffffffffULL;
        h1 += c;

        m += 16;
        bytes -= 16;
    }
    st->h[0] = h0; st->h[1] = h1; st->h[2] = h2;
}

static void poly64_update(poly1305_64 *st, const uint8_t *m, size_t bytes) {
    if (st->leftover) {
        size_t want = 16 - st->leftover;
        if (want > bytes) want = bytes;
        memcpy(st->buffer + st->leftover, m, want);
        bytes -= want; m += want; st->leftover += want;
        if (st->leftover < 16) return;
        poly64_blocks(st, st->buffer, 16);
        st->leftover = 0;
    }
    if (bytes >= 16) {
        size_t want = bytes & ~(size_t)15;
        poly64_blocks(st, m, want);
        m += want; bytes -= want;
    }
    if (bytes) {
        memcpy(st->buffer + st->leftover, m, bytes);
        st->leftover += bytes;
    }
}

static void poly64_finish(poly1305_64 *st, uint8_t mac[16]) {
    uint64_t h0, h1, h2, c, g0, g1, g2, t0, t1;

    if (st->leftover) {
        size_t i = st->leftover;
        st->buffer[i++] = 1;
        for (; i < 16; i++) st->buffer[i] = 0;
        st->final = 1;
        poly64_blocks(st, st->buffer, 16);
    }

    h0 = st->h[0]; h1 = st->h[1]; h2 = st->h[2];
    c = h1 >> 44; h1 &= 0xfffffffffffULL;
    h2 += c; c = h2 >> 42; h2 &= 0x3ffffffffffULL;
    h0 += c * 5; c = h0 >> 44; h0 &= 0xfffffffffffULL;
    h1 += c; c = h1 >> 44; h1 &= 0xfffffffffffULL;
    h2 += c; c = h2 >> 42; h2 &= 0x3ffffffffffULL;
    h0 += c * 5; c = h0 >> 44; h0 &= 0xfffffffffffULL;
    h1 += c;

    g0 = h0 + 5; c = g0 >> 44; g0 &= 0xfffffffffffULL;
    g1 = h1 + c; c = g1 >> 44; g1 &= 0xfffffffffffULL;
    g2 = h2 + c - ((uint64_t)1 << 42);

    c = (g2 >> 63) - 1;                 /* all ones when g did not borrow */
    g0 &= c; g1 &= c; g2 &= c;
    c = ~c;
    h0 = (h0 & c) | g0;
    h1 = (h1 & c) | g1;
    h2 = (h2 & c) | g2;

    t0 = st->pad[0]; t1 = st->pad[1];
    h0 += (t0                      ) & 0xfffffffffffULL;
    c = h0 >> 44; h0 &= 0xfffffffffffULL;
    h1 += (((t0 >> 44) | (t1 << 20)) & 0xfffffffffffULL) + c;
    c = h1 >> 44; h1 &= 0xfffffffffffULL;
    h2 += (((t1 >> 24)             ) & 0x3ffffffffffULL) + c;
    h2 &= 0x3ffffffffffULL;

    h0 = h0 | (h1 << 44);
    h1 = (h1 >> 20) | (h2 << 24);

    for (c = 0; c < 8; c++) {
        mac[c]     = (uint8_t)(h0 >> (8 * c));
        mac[c + 8] = (uint8_t)(h1 >> (8 * c));
    }
}

/* ------------------------------------------- Poly1305, four chains at once */
/* Poly1305 is a Horner evaluation: h = (((h + m1)r + m2)r + m3)r ... Each
   block's multiply needs the previous block's result, so the loop runs at the
   latency of one multiply chain and the machine's multipliers sit idle. That
   is why 64-bit limbs bought only 11% over 26-bit ones: nine wide products
   instead of twenty-five narrow ones does not help when the problem is waiting
   rather than working.

   The fix is the same one that made ChaCha20 fast: more chains. Splitting the
   message four ways

       H = m1.r^n + m2.r^(n-1) + ... + mn.r

   into four accumulators that each advance by r^4, and combining them at the
   end with r^4, r^3, r^2 and r, gives four independent multiplies per group.
   The powers of r are computed once per message.

   This is arithmetic, not a new construction: the result is the same tag, and
   the differential check against the 26-bit implementation at every length is
   what says so. */
#ifdef _MSC_VER
#define FE_INLINE __forceinline
#else
#define FE_INLINE __attribute__((always_inline)) inline
#endif

static FE_INLINE void fe_mul(const uint64_t a[3], const uint64_t b[3],
                             uint64_t out[3]) {
    uint64_t s1 = b[1] * 20, s2 = b[2] * 20, c;
    u128_t d0, d1, d2;

    d0 = u128_add(u128_add(u128_mul(a[0], b[0]), u128_mul(a[1], s2)),
                  u128_mul(a[2], s1));
    d1 = u128_add(u128_add(u128_mul(a[0], b[1]), u128_mul(a[1], b[0])),
                  u128_mul(a[2], s2));
    d2 = u128_add(u128_add(u128_mul(a[0], b[2]), u128_mul(a[1], b[1])),
                  u128_mul(a[2], b[0]));

    c = u128_shr44(d0); out[0] = u128_low44(d0);
    d1 = u128_addu(d1, c);
    c = u128_shr44(d1); out[1] = u128_low44(d1);
    d2 = u128_addu(d2, c);
    c = u128_shr42(d2); out[2] = u128_low42(d2);
    out[0] += c * 5;
    c = out[0] >> 44; out[0] &= 0xfffffffffffULL;
    out[1] += c;
}

/* One-shot: the engine seals a whole page at a time, so the streaming shape
   the other two implementations carry is not what this one has to answer. */
static void poly1305_x4(const uint8_t key[32], const uint8_t *m, size_t bytes,
                        uint8_t mac[16]) {
    uint64_t r[3], r2[3], r3[3], r4[3];
    uint64_t acc[4][3];
    uint64_t h0, h1, h2, c, g0, g1, g2, t0, t1, pad0, pad1;
    int j, lane;

    t0 = load64le(key); t1 = load64le(key + 8);
    r[0] = (t0                        ) & 0x0ffc0fffffffULL;
    r[1] = ((t0 >> 44) | (t1 << 20)   ) & 0x0fffffc0ffffULL;
    r[2] = ((t1 >> 24)                ) & 0x00ffffffc0fULL;
    pad0 = load64le(key + 16); pad1 = load64le(key + 24);

    fe_mul(r, r, r2);
    fe_mul(r2, r, r3);
    fe_mul(r2, r2, r4);

    for (lane = 0; lane < 4; lane++)
        acc[lane][0] = acc[lane][1] = acc[lane][2] = 0;

    /* Groups of four whole blocks: four independent multiplies by r^4. */
    while (bytes >= 64) {
        for (lane = 0; lane < 4; lane++) {
            const uint8_t *b = m + lane * 16;
            uint64_t w0 = load64le(b), w1 = load64le(b + 8);
            /* acc = acc.r^4 + m, not (acc + m).r^4 - the second gives every
               block one factor of r^4 too many, which the vector for a
               34-byte message cannot see because 34 bytes never reach this
               loop. The differential check at every length did. */
            fe_mul(acc[lane], r4, acc[lane]);
            acc[lane][0] += (w0                     ) & 0xfffffffffffULL;
            acc[lane][1] += ((w0 >> 44) | (w1 << 20)) & 0xfffffffffffULL;
            acc[lane][2] += (((w1 >> 24)) & 0x3ffffffffffULL) |
                            ((uint64_t)1 << 40);
        }
        m += 64;
        bytes -= 64;
    }

    /* Combine: H = a0.r^4 + a1.r^3 + a2.r^2 + a3.r */
    {
        uint64_t p0[3], p1[3], p2[3], p3[3];
        fe_mul(acc[0], r4, p0);
        fe_mul(acc[1], r3, p1);
        fe_mul(acc[2], r2, p2);
        fe_mul(acc[3], r,  p3);
        h0 = p0[0] + p1[0] + p2[0] + p3[0];
        h1 = p0[1] + p1[1] + p2[1] + p3[1];
        h2 = p0[2] + p1[2] + p2[2] + p3[2];
        c = h0 >> 44; h0 &= 0xfffffffffffULL; h1 += c;
        c = h1 >> 44; h1 &= 0xfffffffffffULL; h2 += c;
        c = h2 >> 42; h2 &= 0x3ffffffffffULL; h0 += c * 5;
        c = h0 >> 44; h0 &= 0xfffffffffffULL; h1 += c;
    }

    /* Whatever is left - up to three whole blocks and a partial one - is the
       ordinary serial Horner, because there is nothing to parallelise. */
    {
        uint64_t h[3];
        h[0] = h0; h[1] = h1; h[2] = h2;
        while (bytes > 0) {
            uint8_t last[16];
            const uint8_t *b;
            uint64_t w0, w1, hibit;
            size_t n = bytes < 16 ? bytes : 16;
            if (n == 16) {
                b = m;
                hibit = (uint64_t)1 << 40;
            } else {
                memcpy(last, m, n);
                last[n] = 1;
                for (j = (int)n + 1; j < 16; j++) last[j] = 0;
                b = last;
                hibit = 0;
            }
            w0 = load64le(b); w1 = load64le(b + 8);
            h[0] += (w0                     ) & 0xfffffffffffULL;
            h[1] += ((w0 >> 44) | (w1 << 20)) & 0xfffffffffffULL;
            h[2] += (((w1 >> 24)) & 0x3ffffffffffULL) | hibit;
            fe_mul(h, r, h);
            m += n;
            bytes -= n;
        }
        h0 = h[0]; h1 = h[1]; h2 = h[2];
    }

    c = h1 >> 44; h1 &= 0xfffffffffffULL;
    h2 += c; c = h2 >> 42; h2 &= 0x3ffffffffffULL;
    h0 += c * 5; c = h0 >> 44; h0 &= 0xfffffffffffULL;
    h1 += c;

    g0 = h0 + 5; c = g0 >> 44; g0 &= 0xfffffffffffULL;
    g1 = h1 + c; c = g1 >> 44; g1 &= 0xfffffffffffULL;
    g2 = h2 + c - ((uint64_t)1 << 42);

    c = (g2 >> 63) - 1;
    g0 &= c; g1 &= c; g2 &= c;
    c = ~c;
    h0 = (h0 & c) | g0;
    h1 = (h1 & c) | g1;
    h2 = (h2 & c) | g2;

    h0 += (pad0                        ) & 0xfffffffffffULL;
    c = h0 >> 44; h0 &= 0xfffffffffffULL;
    h1 += (((pad0 >> 44) | (pad1 << 20)) & 0xfffffffffffULL) + c;
    c = h1 >> 44; h1 &= 0xfffffffffffULL;
    h2 += (((pad1 >> 24)               ) & 0x3ffffffffffULL) + c;
    h2 &= 0x3ffffffffffULL;

    h0 = h0 | (h1 << 44);
    h1 = (h1 >> 20) | (h2 << 24);

    for (c = 0; c < 8; c++) {
        mac[c]     = (uint8_t)(h0 >> (8 * c));
        mac[c + 8] = (uint8_t)(h1 >> (8 * c));
    }
}

/* ------------------------------------------------------- known-answer vectors */
static int checks_run, checks_failed;

static void check(const char *what, int ok) {
    checks_run++;
    if (!ok) { checks_failed++; printf("  FAIL %s\n", what); }
    else printf("  ok   %s\n", what);
}

/* RFC 8439, section 2.3.2. */
static void kat_chacha20(void) {
    uint8_t key[32], nonce[12] = {0, 0, 0, 9, 0, 0, 0, 0x4a, 0, 0, 0, 0};
    uint8_t got[64];
    static const uint8_t want[64] = {
        0x10,0xf1,0xe7,0xe4,0xd1,0x3b,0x59,0x15,0x50,0x0f,0xdd,0x1f,0xa3,0x20,0x71,0xc4,
        0xc7,0xd1,0xf4,0xc7,0x33,0xc0,0x68,0x03,0x04,0x22,0xaa,0x9a,0xc3,0xd4,0x6c,0x4e,
        0xd2,0x82,0x64,0x46,0x07,0x9f,0xaa,0x09,0x14,0xc2,0xd7,0x05,0xd9,0x8b,0x02,0xa2,
        0xb5,0x12,0x9c,0xd1,0xde,0x16,0x4e,0xb9,0xcb,0xd0,0x83,0xe8,0xa2,0x50,0x3c,0x4e };
    int i;
    for (i = 0; i < 32; i++) key[i] = (uint8_t)i;
    chacha20_block(key, 1, nonce, got);
    check("ChaCha20 block matches RFC 8439 section 2.3.2",
          memcmp(got, want, 64) == 0);
}

/* RFC 8439, section 2.5.2. */
static void kat_poly1305(void) {
    static const uint8_t key[32] = {
        0x85,0xd6,0xbe,0x78,0x57,0x55,0x6d,0x33,0x7f,0x44,0x52,0xfe,0x42,0xd5,0x06,0xa8,
        0x01,0x03,0x80,0x8a,0xfb,0x0d,0xb2,0xfd,0x4a,0xbf,0xf6,0xaf,0x41,0x49,0xf5,0x1b };
    static const char *msg = "Cryptographic Forum Research Group";
    static const uint8_t want[16] = {
        0xa8,0x06,0x1d,0xc1,0x30,0x51,0x36,0xc6,0xc2,0x2b,0x8b,0xaf,0x0c,0x01,0x27,0xa9 };
    poly1305_ctx st;
    uint8_t mac[16];
    poly1305_init(&st, key);
    poly1305_update(&st, (const uint8_t *)msg, strlen(msg));
    poly1305_finish(&st, mac);
    check("Poly1305 tag matches RFC 8439 section 2.5.2",
          memcmp(mac, want, 16) == 0);
    {
        uint8_t mac4[16];
        poly1305_x4(key, (const uint8_t *)msg, strlen(msg), mac4);
        check("and so does the four-chain implementation",
              memcmp(mac4, want, 16) == 0);
    }
    {
        poly1305_64 st64;
        uint8_t mac64[16];
        poly64_init(&st64, key);
        poly64_update(&st64, (const uint8_t *)msg, strlen(msg));
        poly64_finish(&st64, mac64);
        check("and so does the 64-bit implementation",
              memcmp(mac64, want, 16) == 0);
    }
}

/* The keystream must not depend on where the buffer is split, nor on which
   instructions computed it. */
static cpu_features host;

static void kat_streaming(void) {
    uint8_t key[32], nonce[12], a[200], b[200];
    poly1305_ctx s1, s2;
    uint8_t m1[16], m2[16];
    int i;
    for (i = 0; i < 32; i++) key[i] = (uint8_t)(i * 7 + 1);
    for (i = 0; i < 12; i++) nonce[i] = (uint8_t)(i * 3);
    for (i = 0; i < 200; i++) a[i] = b[i] = (uint8_t)i;
    chacha20_xor(key, 0, nonce, a, 200);
    chacha20_xor(key, 0, nonce, b, 64);
    chacha20_xor(key, 1, nonce, b + 64, 136);
    check("ChaCha20 is the same stream whatever the chunking",
          memcmp(a, b, 200) == 0);

    for (i = 0; i < 200; i++) b[i] = (uint8_t)i;
    chacha20_xor_hoisted(key, 0, nonce, b, 200);
    check("and the hoisted implementation agrees with the clear one",
          memcmp(a, b, 200) == 0);

#ifdef HAVE_CHACHA_SSE2
    /* Decision 3 of docs/CRYPTO_BACKEND.md in one assertion: the machine may
       choose how fast, never what. Odd lengths included, because the tail is
       where a vector implementation goes wrong. */
    {
        int ok = 1, len;
        for (len = 1; len <= 200; len++) {
            uint8_t p1[200], p2[200];
            int k;
            for (k = 0; k < len; k++) p1[k] = p2[k] = (uint8_t)(k * 11 + 3);
            chacha20_xor_hoisted(key, 7, nonce, p1, (size_t)len);
            chacha20_xor_sse2(key, 7, nonce, p2, (size_t)len);
            if (memcmp(p1, p2, (size_t)len) != 0) { ok = 0; break; }
        }
        check("SSE2 ChaCha20 is byte-identical to scalar, every length 1..200",
              ok);

        ok = 1;
        for (len = 1; len <= 400; len++) {
            uint8_t p1[400], p2[400];
            int k;
            for (k = 0; k < len; k++) p1[k] = p2[k] = (uint8_t)(k * 11 + 3);
            chacha20_xor_hoisted(key, 7, nonce, p1, (size_t)len);
            chacha20_xor_sse2x4(key, 7, nonce, p2, (size_t)len);
            if (memcmp(p1, p2, (size_t)len) != 0) { ok = 0; break; }
        }
        check("four-block SSE2 agrees too, every length 1..400 "
              "(the tails a 4x implementation gets wrong)", ok);

#ifdef HAVE_CHACHA_AVX2
        if (host.avx2) {
            ok = 1;
            for (len = 1; len <= 700; len++) {
                uint8_t p1[700], p2[700];
                int k;
                for (k = 0; k < len; k++) p1[k] = p2[k] = (uint8_t)(k * 11 + 3);
                chacha20_xor_hoisted(key, 7, nonce, p1, (size_t)len);
                chacha20_xor_avx2(key, 7, nonce, p2, (size_t)len);
                if (memcmp(p1, p2, (size_t)len) != 0) { ok = 0; break; }
            }
            check("and AVX2 agrees, every length 1..700", ok);
        }
#endif
    }
#endif

    poly1305_init(&s1, key);
    poly1305_update(&s1, a, 200);
    poly1305_finish(&s1, m1);
    poly1305_init(&s2, key);
    poly1305_update(&s2, a, 7);
    poly1305_update(&s2, a + 7, 1);
    poly1305_update(&s2, a + 8, 192);
    poly1305_finish(&s2, m2);
    check("Poly1305 is the same tag whatever the chunking",
          memcmp(m1, m2, 16) == 0);

    /* The two Poly1305s must agree with each other, at every length, including
       the partial final block and the empty message. Two implementations of
       the same function checked against each other catch what a single vector
       cannot: a bug that is right on 34 bytes and wrong on 33. */
    {
        int ok = 1, len;
        for (len = 0; len <= 300; len++) {
            poly1305_ctx c26;
            poly1305_64 c64;
            uint8_t t26[16], t64[16];
            poly1305_init(&c26, key);
            poly1305_update(&c26, a, (size_t)len);
            poly1305_finish(&c26, t26);
            poly64_init(&c64, key);
            poly64_update(&c64, a, (size_t)len);
            poly64_finish(&c64, t64);
            if (memcmp(t26, t64, 16) != 0) { ok = 0; break; }
        }
        check("64-bit Poly1305 agrees with the 26-bit one, lengths 0..300",
              ok);

        ok = 1;
        for (len = 0; len <= 300; len++) {
            poly1305_ctx c26;
            uint8_t t26[16], t4[16];
            poly1305_init(&c26, key);
            poly1305_update(&c26, a, (size_t)len);
            poly1305_finish(&c26, t26);
            poly1305_x4(key, a, (size_t)len, t4);
            if (memcmp(t26, t4, 16) != 0) { ok = 0; break; }
        }
        check("four-chain Poly1305 agrees as well, lengths 0..300", ok);
    }
}

/* ------------------------------------------------------------------- AES-NI */
/* Throughput only: no vectors, no claim of correctness. It answers one
   question - how much does hardware AES change the decision. */
#if defined(__GNUC__) && !defined(__AES__)
#define NO_AESNI_BUILD 1
#endif

#ifndef NO_AESNI_BUILD
static double aesni_ctr_page(uint8_t *page, int rounds) {
    __m128i rk[11], ctr;
    double t0;
    int r, i;
    for (i = 0; i < 11; i++) rk[i] = _mm_set1_epi32(0x01020304 + i);
    t0 = now_seconds();
    for (r = 0; r < rounds; r++) {
        ctr = _mm_set_epi64x(0, r);
        for (i = 0; i < (int)(PAGE_SIZE / 16); i++) {
            __m128i b = _mm_xor_si128(ctr, rk[0]);
            b = _mm_aesenc_si128(b, rk[1]);
            b = _mm_aesenc_si128(b, rk[2]);
            b = _mm_aesenc_si128(b, rk[3]);
            b = _mm_aesenc_si128(b, rk[4]);
            b = _mm_aesenc_si128(b, rk[5]);
            b = _mm_aesenc_si128(b, rk[6]);
            b = _mm_aesenc_si128(b, rk[7]);
            b = _mm_aesenc_si128(b, rk[8]);
            b = _mm_aesenc_si128(b, rk[9]);
            b = _mm_aesenclast_si128(b, rk[10]);
            _mm_storeu_si128((__m128i *)(page + i * 16),
                             _mm_xor_si128(_mm_loadu_si128((__m128i *)(page + i * 16)), b));
            ctr = _mm_add_epi64(ctr, _mm_set_epi64x(0, 1));
        }
    }
    return now_seconds() - t0;
}
#endif

/* A carry-less multiply chain over the page, the shape GHASH and POLYVAL both
   have: one 128-bit multiply in GF(2^128) per 16 bytes, serially dependent.
   Unvalidated and unreduced - it bounds the MAC term on the hardware path
   rather than implementing it. The real thing adds the reduction, which is two
   more multiplies and some shifts per block, so this is a floor again and is
   labelled as one. */
static volatile uint64_t clmul_sink;

#ifndef NO_AESNI_BUILD
static double clmul_page(const uint8_t *page, int rounds) {
    __m128i h = _mm_set_epi64x(0x0123456789abcdefLL, 0xfedcba9876543210LL);
    __m128i acc = _mm_setzero_si128();
    double t0 = now_seconds();
    int r, i;
    for (r = 0; r < rounds; r++) {
        for (i = 0; i < (int)(PAGE_SIZE / 16); i++) {
            __m128i b = _mm_loadu_si128((const __m128i *)(page + i * 16));
            __m128i x = _mm_xor_si128(acc, b);
            __m128i lo = _mm_clmulepi64_si128(x, h, 0x00);
            __m128i hi = _mm_clmulepi64_si128(x, h, 0x11);
            __m128i mid = _mm_clmulepi64_si128(x, h, 0x10);
            acc = _mm_xor_si128(_mm_xor_si128(lo, hi), mid);
        }
    }
    {   /* the accumulator has to escape, or the whole chain is dead code -
           the first version of this measured 1.6 TB/s, which is what a loop
           the compiler deleted looks like from the outside */
        double dt = now_seconds() - t0;
        clmul_sink = (uint64_t)_mm_cvtsi128_si64(acc);
        return dt;
    }
}
#endif

int main(void) {
    cpu_features f;
    uint8_t page[PAGE_SIZE], key[32], nonce[12], mac[16];
    unsigned i;
    int rounds = 20000;
    double t;

    printf("CybouDB crypto backend probe\n\n");

    cpu_detect(&f);
    host = f;
    printf("  CPU: AES-NI %s, PCLMULQDQ %s, SHA-NI %s, AVX2 %s, RDSEED %s\n\n",
           f.aesni ? "yes" : "NO", f.pclmul ? "yes" : "NO",
           f.sha_ni ? "yes" : "NO", f.avx2 ? "yes" : "NO",
           f.rdseed ? "yes" : "NO");

    printf("  known-answer vectors\n");
    kat_chacha20();
    kat_poly1305();
    kat_streaming();
    printf("\n");

    for (i = 0; i < 32; i++) key[i] = (uint8_t)(i + 1);
    for (i = 0; i < 12; i++) nonce[i] = (uint8_t)(i + 100);
    for (i = 0; i < PAGE_SIZE; i++) page[i] = (uint8_t)i;

    printf("  %-40s %10s %10s\n", "one 4096-byte page", "ns", "GB/s");

    t = now_seconds();
    for (i = 0; i < (unsigned)rounds; i++)
        chacha20_xor(key, i, nonce, page, PAGE_SIZE);
    t = now_seconds() - t;
    printf("  %-40s %10.0f %10.2f\n", "ChaCha20, state rebuilt per block",
           t * 1e9 / rounds, (double)PAGE_SIZE * rounds / t / 1e9);

    t = now_seconds();
    for (i = 0; i < (unsigned)rounds; i++)
        chacha20_xor_hoisted(key, i, nonce, page, PAGE_SIZE);
    t = now_seconds() - t;
    printf("  %-40s %10.0f %10.2f\n", "ChaCha20, portable C",
           t * 1e9 / rounds, (double)PAGE_SIZE * rounds / t / 1e9);

#ifdef HAVE_CHACHA_SSE2
    t = now_seconds();
    for (i = 0; i < (unsigned)rounds; i++)
        chacha20_xor_sse2(key, i, nonce, page, PAGE_SIZE);
    t = now_seconds() - t;
    printf("  %-40s %10.0f %10.2f\n", "ChaCha20, SSE2, one block",
           t * 1e9 / rounds, (double)PAGE_SIZE * rounds / t / 1e9);

    t = now_seconds();
    for (i = 0; i < (unsigned)rounds; i++)
        chacha20_xor_sse2x4(key, i, nonce, page, PAGE_SIZE);
    t = now_seconds() - t;
    printf("  %-40s %10.0f %10.2f\n", "ChaCha20, SSE2, four blocks",
           t * 1e9 / rounds, (double)PAGE_SIZE * rounds / t / 1e9);
#endif

#ifdef HAVE_CHACHA_AVX2
    if (f.avx2) {
        t = now_seconds();
        for (i = 0; i < (unsigned)rounds; i++)
            chacha20_xor_avx2(key, i, nonce, page, PAGE_SIZE);
        t = now_seconds() - t;
        printf("  %-40s %10.0f %10.2f\n", "ChaCha20, AVX2, eight blocks",
               t * 1e9 / rounds, (double)PAGE_SIZE * rounds / t / 1e9);
    }
#endif

    t = now_seconds();
    for (i = 0; i < (unsigned)rounds; i++) {
        poly1305_ctx st;
        poly1305_init(&st, key);
        poly1305_update(&st, page, PAGE_SIZE);
        poly1305_finish(&st, mac);
    }
    t = now_seconds() - t;
    printf("  %-40s %10.0f %10.2f\n", "Poly1305, 26-bit limbs",
           t * 1e9 / rounds, (double)PAGE_SIZE * rounds / t / 1e9);

    t = now_seconds();
    for (i = 0; i < (unsigned)rounds; i++) {
        poly1305_64 st;
        poly64_init(&st, key);
        poly64_update(&st, page, PAGE_SIZE);
        poly64_finish(&st, mac);
    }
    t = now_seconds() - t;
    printf("  %-40s %10.0f %10.2f\n", "Poly1305, 64-bit limbs",
           t * 1e9 / rounds, (double)PAGE_SIZE * rounds / t / 1e9);

    t = now_seconds();
    for (i = 0; i < (unsigned)rounds; i++)
        poly1305_x4(key, page, PAGE_SIZE, mac);
    t = now_seconds() - t;
    printf("  %-40s %10.0f %10.2f\n", "Poly1305, four chains",
           t * 1e9 / rounds, (double)PAGE_SIZE * rounds / t / 1e9);

    t = now_seconds();
    for (i = 0; i < (unsigned)rounds; i++) {
        poly1305_ctx st;
        chacha20_xor_hoisted(key, i, nonce, page, PAGE_SIZE);
        poly1305_init(&st, key);
        poly1305_update(&st, page, PAGE_SIZE);
        poly1305_finish(&st, mac);
    }
    t = now_seconds() - t;
    printf("  %-40s %10.0f %10.2f\n", "sealing a page, scalar",
           t * 1e9 / rounds, (double)PAGE_SIZE * rounds / t / 1e9);

#ifdef HAVE_CHACHA_SSE2
    t = now_seconds();
    for (i = 0; i < (unsigned)rounds; i++) {
        poly1305_ctx st;
        chacha20_xor_sse2x4(key, i, nonce, page, PAGE_SIZE);
        poly1305_init(&st, key);
        poly1305_update(&st, page, PAGE_SIZE);
        poly1305_finish(&st, mac);
    }
    t = now_seconds() - t;
    printf("  %-40s %10.0f %10.2f\n", "sealing a page, SSE2 four-block cipher",
           t * 1e9 / rounds, (double)PAGE_SIZE * rounds / t / 1e9);
#endif

#ifdef HAVE_CHACHA_AVX2
    if (f.avx2) {
        t = now_seconds();
        for (i = 0; i < (unsigned)rounds; i++) {
            poly1305_ctx st;
            chacha20_xor_avx2(key, i, nonce, page, PAGE_SIZE);
            poly1305_init(&st, key);
            poly1305_update(&st, page, PAGE_SIZE);
            poly1305_finish(&st, mac);
        }
        t = now_seconds() - t;
        printf("  %-40s %10.0f %10.2f\n", "sealing a page, AVX2 cipher",
               t * 1e9 / rounds, (double)PAGE_SIZE * rounds / t / 1e9);
    }
#endif

#ifdef HAVE_CHACHA_SSE2
    t = now_seconds();
    for (i = 0; i < (unsigned)rounds; i++) {
        chacha20_xor_sse2x4(key, i, nonce, page, PAGE_SIZE);
        poly1305_x4(key, page, PAGE_SIZE, mac);
    }
    t = now_seconds() - t;
    printf("  %-40s %10.0f %10.2f\n",
           "sealing a page, SSE2 cipher + 4-chain MAC",
           t * 1e9 / rounds, (double)PAGE_SIZE * rounds / t / 1e9);
#endif

#ifdef HAVE_CHACHA_AVX2
    if (f.avx2) {
        t = now_seconds();
        for (i = 0; i < (unsigned)rounds; i++) {
            chacha20_xor_avx2(key, i, nonce, page, PAGE_SIZE);
            poly1305_x4(key, page, PAGE_SIZE, mac);
        }
        t = now_seconds() - t;
        printf("  %-40s %10.0f %10.2f\n",
               "sealing a page, AVX2 cipher + 4-chain MAC",
               t * 1e9 / rounds, (double)PAGE_SIZE * rounds / t / 1e9);
    }
#endif

#ifndef NO_AESNI_BUILD
    if (f.aesni) {
        t = aesni_ctr_page(page, rounds);
        printf("  %-40s %10.0f %10.2f\n",
               "AES-128-CTR (AES-NI, unvalidated)",
               t * 1e9 / rounds, (double)PAGE_SIZE * rounds / t / 1e9);
    } else {
        printf("  %-40s %10s %10s\n",
               "AES-128-CTR (AES-NI, unvalidated)", "no AES-NI", "-");
    }
#else
    printf("  %-40s %10s %10s\n",
           "AES-128-CTR (AES-NI, unvalidated)", "not built", "-");
#endif

#ifndef NO_AESNI_BUILD
    if (f.pclmul) {
        t = clmul_page(page, rounds);
        printf("  %-40s %10.0f %10.2f\n",
               "carry-less multiply chain (PCLMULQDQ)",
               t * 1e9 / rounds, (double)PAGE_SIZE * rounds / t / 1e9);
    }
#endif

    printf("\n  %d checks, %d failed\n", checks_run, checks_failed);
    if (mac[0] == 0xff && page[0] == 0xff) printf("(unreachable)\n");
    return checks_failed ? 1 : 0;
}
