/* tests/poly1305_test.c - the assembly authenticator, against RFC 8439 and C
 *
 * src/crypto/poly1305.asm computes the tag half of the page seal. Like the
 * cipher, it has to agree with a portable implementation exactly: the format
 * names XChaCha20-Poly1305 and never names the instructions.
 *
 * The C reference here uses five 26-bit limbs where the assembly uses three of
 * 44, 44 and 42, so the two do not share a representation, a carry chain or a
 * reduction. Agreeing at every length is therefore evidence rather than a
 * coincidence of shared arithmetic - which is the same reason the C probe
 * carries two implementations of this function.
 *
 * Build (Linux):   sh build.sh --crypto-tests && ./build/poly1305_test
 * Build (Windows): build.bat --crypto-tests && build\poly1305_test.exe
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
#include <time.h>
#endif

void cyboudb_poly1305(const uint8_t *key, const uint8_t *msg, uint64_t len,
                      uint8_t *mac);

static int checks, failures;

static void check(const char *what, int ok) {
    checks++;
    if (ok) printf("ok   %s\n", what);
    else { failures++; printf("FAIL %s\n", what); }
}

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

/* ----------------------------------- the reference: five 26-bit limbs ------ */
static uint32_t u8to32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

/* The five-limb reference, as init / update / finish - the shape that is
   already proven against RFC 8439 in benchmarks/crypto_probe.c. The first
   version written here tried to do it in one loop and had to special-case the
   empty message and the exact multiple of sixteen, which is how a reference
   acquires the bugs it exists to detect. */
typedef struct {
    uint32_t r[5], h[5], pad[4];
    size_t leftover;
    uint8_t buffer[16];
    int final;
} ref_ctx;

static void ref_init(ref_ctx *st, const uint8_t key[32]) {
    st->r[0] = (u8to32(key)          ) & 0x3ffffff;
    st->r[1] = (u8to32(key +  3) >> 2) & 0x3ffff03;
    st->r[2] = (u8to32(key +  6) >> 4) & 0x3ffc0ff;
    st->r[3] = (u8to32(key +  9) >> 6) & 0x3f03fff;
    st->r[4] = (u8to32(key + 12) >> 8) & 0x00fffff;
    memset(st->h, 0, sizeof st->h);
    st->pad[0] = u8to32(key + 16); st->pad[1] = u8to32(key + 20);
    st->pad[2] = u8to32(key + 24); st->pad[3] = u8to32(key + 28);
    st->leftover = 0;
    st->final = 0;
}

static void ref_blocks(ref_ctx *st, const uint8_t *m, size_t bytes) {
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

        d0 = (uint64_t)h0*r0 + (uint64_t)h1*s4 + (uint64_t)h2*s3 +
             (uint64_t)h3*s2 + (uint64_t)h4*s1;
        d1 = (uint64_t)h0*r1 + (uint64_t)h1*r0 + (uint64_t)h2*s4 +
             (uint64_t)h3*s3 + (uint64_t)h4*s2;
        d2 = (uint64_t)h0*r2 + (uint64_t)h1*r1 + (uint64_t)h2*r0 +
             (uint64_t)h3*s4 + (uint64_t)h4*s3;
        d3 = (uint64_t)h0*r3 + (uint64_t)h1*r2 + (uint64_t)h2*r1 +
             (uint64_t)h3*r0 + (uint64_t)h4*s4;
        d4 = (uint64_t)h0*r4 + (uint64_t)h1*r3 + (uint64_t)h2*r2 +
             (uint64_t)h3*r1 + (uint64_t)h4*r0;

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

static void ref_finish(ref_ctx *st, uint8_t mac[16]) {
    uint32_t h0, h1, h2, h3, h4, c, g0, g1, g2, g3, g4, mask;
    uint64_t f;

    if (st->leftover) {
        size_t i = st->leftover;
        st->buffer[i++] = 1;
        for (; i < 16; i++) st->buffer[i] = 0;
        st->final = 1;
        ref_blocks(st, st->buffer, 16);
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

    mask = (g4 >> 31) - 1;
    g0 &= mask; g1 &= mask; g2 &= mask; g3 &= mask; g4 &= mask;
    mask = ~mask;
    h0 = (h0 & mask) | g0; h1 = (h1 & mask) | g1; h2 = (h2 & mask) | g2;
    h3 = (h3 & mask) | g3; h4 = (h4 & mask) | g4;

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

static void ref_poly1305(const uint8_t key[32], const uint8_t *m, size_t bytes,
                         uint8_t mac[16]) {
    ref_ctx st;
    ref_init(&st, key);
    if (bytes >= 16) {
        size_t whole = bytes & ~(size_t)15;
        ref_blocks(&st, m, whole);
        m += whole;
        bytes -= whole;
    }
    if (bytes) {
        memcpy(st.buffer, m, bytes);
        st.leftover = bytes;
    }
    ref_finish(&st, mac);
}

int main(void) {
    uint8_t key[32], msg[600];
    unsigned i;

    printf("CybouDB Poly1305 (assembly) test\n\n");

    /* RFC 8439 section 2.5.2, verbatim. */
    {
        static const uint8_t k[32] = {
            0x85,0xd6,0xbe,0x78,0x57,0x55,0x6d,0x33,0x7f,0x44,0x52,0xfe,
            0x42,0xd5,0x06,0xa8,0x01,0x03,0x80,0x8a,0xfb,0x0d,0xb2,0xfd,
            0x4a,0xbf,0xf6,0xaf,0x41,0x49,0xf5,0x1b };
        static const char *m = "Cryptographic Forum Research Group";
        static const uint8_t want[16] = {
            0xa8,0x06,0x1d,0xc1,0x30,0x51,0x36,0xc6,
            0xc2,0x2b,0x8b,0xaf,0x0c,0x01,0x27,0xa9 };
        uint8_t got[16];
        cyboudb_poly1305(k, (const uint8_t *)m, strlen(m), got);
        check("the assembly matches RFC 8439 section 2.5.2",
              memcmp(got, want, 16) == 0);
    }

    for (i = 0; i < 32; i++) key[i] = (uint8_t)(i * 7 + 3);
    for (i = 0; i < sizeof msg; i++) msg[i] = (uint8_t)(i * 11 + 5);

    /* Every length, against a reference that shares no representation with it:
       three limbs of 44 bits against five of 26. The lengths that matter are
       the ones either side of a block - 15, 16, 17 - and the empty message. */
    {
        int ok = 1, len, bad = -1;
        for (len = 0; len <= 600; len++) {
            uint8_t a[16], b[16];
            ref_poly1305(key, msg, (size_t)len, a);
            cyboudb_poly1305(key, msg, (uint64_t)len, b);
            if (memcmp(a, b, 16) != 0) { ok = 0; bad = len; break; }
        }
        if (!ok) printf("     first disagreement at length %d\n", bad);
        check("and a 26-bit C reference, at every length from 0 to 600", ok);
    }

    /* A key whose r is all ones before clamping, and a message of all ones:
       the carries that a small message never exercises. */
    {
        uint8_t k2[32], m2[64], a[16], b[16];
        memset(k2, 0xff, sizeof k2);
        memset(m2, 0xff, sizeof m2);
        ref_poly1305(k2, m2, sizeof m2, a);
        cyboudb_poly1305(k2, m2, sizeof m2, b);
        check("all-ones key and message agree too", memcmp(a, b, 16) == 0);
    }

    /* h landing exactly on the prime is the case the final reduction exists
       for, and random data will not find it. This does not construct it - that
       needs the inverse of r - but it does sweep a lot of nearby states. */
    {
        int ok = 1;
        unsigned t;
        for (t = 0; t < 256 && ok; t++) {
            uint8_t k2[32], m2[32], a[16], b[16];
            unsigned j;
            for (j = 0; j < 32; j++) k2[j] = (uint8_t)(t * 31 + j);
            for (j = 0; j < 32; j++) m2[j] = (uint8_t)(0xff - t + j);
            ref_poly1305(k2, m2, sizeof m2, a);
            cyboudb_poly1305(k2, m2, sizeof m2, b);
            if (memcmp(a, b, 16) != 0) ok = 0;
        }
        check("two hundred and fifty-six key and message pairs agree", ok);
    }

    /* The tag of a 4096-byte page, and what it costs. */
    {
        static uint8_t page[4096];
        uint8_t mac[16];
        double t;
        for (i = 0; i < sizeof page; i++) page[i] = (uint8_t)i;
        t = now_seconds();
        for (i = 0; i < 20000; i++)
            cyboudb_poly1305(key, page, sizeof page, mac);
        t = now_seconds() - t;
        printf("\n     4096-byte page: %.0f ns, %.2f GB/s\n",
               t * 1e9 / 20000.0, 4096.0 * 20000.0 / t / 1e9);
    }

    printf("\nPoly1305 assembly suite: %d checks, %d failed\n",
           checks, failures);
    return failures ? 1 : 0;
}
