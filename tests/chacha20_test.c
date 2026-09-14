/* tests/chacha20_test.c - the assembly cipher, against the RFC and against C
 *
 * src/crypto/chacha20.asm is the first cryptographic primitive this engine
 * owns, and it has one requirement beyond being fast: docs/CRYPTO_BACKEND.md
 * says the file names XChaCha20-Poly1305 and never names the instructions that
 * computed it. So the assembly must produce the same bytes as a C
 * implementation, at every length, or the format's promise is not keepable.
 *
 * The reference below is written from RFC 8439 section 2.3 and shares nothing
 * with the assembly - different language, different structure, no common
 * helper to be wrong in both. That is the point: two implementations that
 * agree are evidence, one implementation that passes its own vector is a
 * tautology.
 *
 * Build (Linux):   sh build.sh --crypto-tests && ./build/chacha20_test
 * Build (Windows): build.bat --crypto-tests && build\chacha20_test.exe
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

/* The assembly under test. */
void cyboudb_chacha20_xor(const uint8_t *key, uint32_t counter,
                          const uint8_t *nonce, uint8_t *buf, uint64_t len);

/* tests/chacha20_abi.asm: fills xmm6..xmm15, calls the cipher on enough bytes
   to take its three-block path, and returns a bitmask of the ones that did not
   survive. Win64 requires zero; System V has no such requirement, so the
   assertion below is made only where the convention makes one. */
unsigned cyboudb_chacha20_abi_probe(void);

static int checks, failures;

static void check(const char *what, int ok) {
    checks++;
    if (ok) {
        printf("ok   %s\n", what);
    } else {
        failures++;
        printf("FAIL %s\n", what);
    }
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

/* --------------------------------------------------- the reference, in C --- */
#define ROTL32(v, n) (((v) << (n)) | ((v) >> (32 - (n))))
#define QR(a, b, c, d)                      \
    a += b; d ^= a; d = ROTL32(d, 16);      \
    c += d; b ^= c; b = ROTL32(b, 12);      \
    a += b; d ^= a; d = ROTL32(d, 8);       \
    c += d; b ^= c; b = ROTL32(b, 7)

static void ref_block(const uint8_t key[32], uint32_t counter,
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
        QR(x[0], x[4], x[8],  x[12]); QR(x[1], x[5], x[9],  x[13]);
        QR(x[2], x[6], x[10], x[14]); QR(x[3], x[7], x[11], x[15]);
        QR(x[0], x[5], x[10], x[15]); QR(x[1], x[6], x[11], x[12]);
        QR(x[2], x[7], x[8],  x[13]); QR(x[3], x[4], x[9],  x[14]);
    }
    for (i = 0; i < 16; i++) {
        uint32_t v = x[i] + s[i];
        out[4 * i] = (uint8_t)v; out[4 * i + 1] = (uint8_t)(v >> 8);
        out[4 * i + 2] = (uint8_t)(v >> 16); out[4 * i + 3] = (uint8_t)(v >> 24);
    }
}

static void ref_xor(const uint8_t key[32], uint32_t counter,
                    const uint8_t nonce[12], uint8_t *buf, size_t len) {
    uint8_t ks[64];
    size_t done = 0;
    while (done < len) {
        size_t n = len - done < 64 ? len - done : 64;
        size_t i;
        ref_block(key, counter, nonce, ks);
        for (i = 0; i < n; i++) buf[done + i] ^= ks[i];
        done += n;
        counter++;
    }
}

/* ------------------------------------------------------------------ tests --- */
int main(void) {
    uint8_t key[32], nonce[12];
    unsigned i;

    printf("CybouDB ChaCha20 (assembly) test\n\n");

    for (i = 0; i < 32; i++) key[i] = (uint8_t)i;
    memset(nonce, 0, sizeof nonce);
    nonce[3] = 0x09; nonce[7] = 0x4a;

    /* RFC 8439 section 2.3.2, the block function's own vector. The assembly
       xors a keystream rather than emitting one, so an all-zero buffer is the
       keystream. */
    {
        static const uint8_t want[64] = {
            0x10,0xf1,0xe7,0xe4,0xd1,0x3b,0x59,0x15,0x50,0x0f,0xdd,0x1f,
            0xa3,0x20,0x71,0xc4,0xc7,0xd1,0xf4,0xc7,0x33,0xc0,0x68,0x03,
            0x04,0x22,0xaa,0x9a,0xc3,0xd4,0x6c,0x4e,0xd2,0x82,0x64,0x46,
            0x07,0x9f,0xaa,0x09,0x14,0xc2,0xd7,0x05,0xd9,0x8b,0x02,0xa2,
            0xb5,0x12,0x9c,0xd1,0xde,0x16,0x4e,0xb9,0xcb,0xd0,0x83,0xe8,
            0xa2,0x50,0x3c,0x4e };
        uint8_t got[64];
        memset(got, 0, sizeof got);
        cyboudb_chacha20_xor(key, 1, nonce, got, sizeof got);
        check("the assembly matches RFC 8439 section 2.3.2",
              memcmp(got, want, 64) == 0);
    }

    /* Every length, against the C reference. The tail is where a block cipher
       driver goes wrong, and a 4096-byte page would never show it. */
    {
        int ok = 1, len, bad = -1;
        for (len = 0; len <= 600; len++) {
            uint8_t a[600], b[600];
            int k;
            for (k = 0; k < len; k++) a[k] = b[k] = (uint8_t)(k * 7 + 1);
            ref_xor(key, 3, nonce, a, (size_t)len);
            cyboudb_chacha20_xor(key, 3, nonce, b, (size_t)len);
            if (memcmp(a, b, (size_t)len) != 0) { ok = 0; bad = len; break; }
        }
        if (!ok) printf("     first disagreement at length %d\n", bad);
        check("and the C reference, at every length from 0 to 600", ok);
    }

    /* Xoring twice is the identity: what encrypts must decrypt. */
    {
        uint8_t a[300], b[300];
        for (i = 0; i < 300; i++) a[i] = b[i] = (uint8_t)(i * 3 + 11);
        cyboudb_chacha20_xor(key, 9, nonce, a, sizeof a);
        cyboudb_chacha20_xor(key, 9, nonce, a, sizeof a);
        check("xoring the same stream twice gives the plaintext back",
              memcmp(a, b, sizeof a) == 0);
    }

    /* Starting at block n must equal skipping n blocks of the stream, or the
       engine cannot seal a page anywhere but at the start of a file. */
    {
        uint8_t whole[256], part[128];
        for (i = 0; i < 256; i++) whole[i] = 0;
        for (i = 0; i < 128; i++) part[i] = 0;
        cyboudb_chacha20_xor(key, 5, nonce, whole, sizeof whole);
        cyboudb_chacha20_xor(key, 7, nonce, part, sizeof part);
        check("the counter selects the block: 5+2 lands where 7 starts",
              memcmp(whole + 128, part, 128) == 0);
    }

    /* The counter wraps at 2^32 rather than running into the nonce. */
    {
        uint8_t a[128], b[128];
        memset(a, 0, sizeof a);
        memset(b, 0, sizeof b);
        cyboudb_chacha20_xor(key, 0xffffffffu, nonce, a, sizeof a);
        ref_xor(key, 0xffffffffu, nonce, b, sizeof b);
        check("and wraps at 2^32 the way the reference does",
              memcmp(a, b, sizeof a) == 0);
    }

    /* A zero length must touch nothing at all. */
    {
        uint8_t guard[16];
        memset(guard, 0xA5, sizeof guard);
        cyboudb_chacha20_xor(key, 1, nonce, guard, 0);
        for (i = 0; i < 16; i++) if (guard[i] != 0xA5) break;
        check("a zero-length call writes nothing", i == 16);
    }

    /* The registers the caller lent it. A C test cannot check this: nothing
       here keeps a live value in xmm6..xmm15 across the call, so the test
       would agree with an implementation that trampled all ten. */
    {
        unsigned changed = cyboudb_chacha20_abi_probe();
#ifdef _WIN32
        if (changed) printf("     clobbered mask %#x (bit 0 = xmm6)\n", changed);
        check("the caller's xmm6..xmm15 come back unchanged (Win64)",
              changed == 0);
#else
        /* Volatile under System V - reported, not required. */
        printf("ok   xmm6..xmm15 are scratch here; the cipher changed %#x\n",
               changed);
        checks++;
#endif
    }

    /* What it costs, on the unit the format seals. Not a gate - the numbers
       live in benchmarks/results - but a test that runs the thing 20,000 times
       may as well say how long it took. */
    {
        static uint8_t page[4096];
        double t = now_seconds();
        for (i = 0; i < 20000; i++)
            cyboudb_chacha20_xor(key, i, nonce, page, sizeof page);
        t = now_seconds() - t;
        printf("\n     4096-byte page: %.0f ns, %.2f GB/s\n",
               t * 1e9 / 20000.0, 4096.0 * 20000.0 / t / 1e9);
    }

    printf("\nChaCha20 assembly suite: %d checks, %d failed\n",
           checks, failures);
    return failures ? 1 : 0;
}
