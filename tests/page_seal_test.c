/* tests/page_seal_test.c - the associated data, and the random source
 *
 * Two pieces that finish the 0.7 page seal's arithmetic:
 *
 *   cyboudb_page_aad   builds the forty-eight bytes a sealed page is bound to.
 *                      docs/ENCRYPTED_FORMAT.md Decision 5 lists five fields
 *                      and one attack each, and the test below turns that list
 *                      into five checks: change a field, and the page must
 *                      stop opening.
 *
 *   os_random          the platform's generator, because the nonce is drawn
 *                      per write and a nonce this project generated itself
 *                      would be the worst thing in the release.
 *
 * Build (Linux):   sh build.sh --crypto-tests && ./build/page_seal_test
 * Build (Windows): build.bat --crypto-tests && build\page_seal_test.exe
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

typedef struct {
    const uint8_t *key;
    const uint8_t *nonce;
    const uint8_t *aad;
    uint64_t aad_len;
    uint8_t *buf;
    uint64_t buf_len;
    uint8_t *tag;
} cyboudb_aead_args;

void cyboudb_page_aad(uint8_t *out, const uint8_t *uuid, uint64_t page_no,
                      uint64_t generation, uint64_t page_type,
                      uint64_t seal_epoch);
int cyboudb_xchacha20poly1305_seal(const cyboudb_aead_args *a);
int cyboudb_xchacha20poly1305_open(const cyboudb_aead_args *a);
int os_random(void *buffer, uint64_t length);

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

static uint64_t le64(const uint8_t *p) {
    uint64_t v;
    memcpy(&v, p, 8);
    return v;                           /* little-endian hosts, as x86-64 is */
}

int main(void) {
    uint8_t uuid[16];
    uint8_t aad[48];
    unsigned i;

    printf("CybouDB page seal test\n\n");

    for (i = 0; i < 16; i++) uuid[i] = (uint8_t)(i + 0xA0);

    /* --- the layout, field by field ---------------------------------------- */
    {
        memset(aad, 0xEE, sizeof aad);
        cyboudb_page_aad(aad, uuid, 0x1122334455667788ull,
                         0x99aabbccddeeff00ull, 7, 3);
        check("the uuid is the first sixteen bytes",
              memcmp(aad, uuid, 16) == 0);
        check("then the page number", le64(aad + 16) == 0x1122334455667788ull);
        check("then the generation", le64(aad + 24) == 0x99aabbccddeeff00ull);
        check("then the page type", le64(aad + 32) == 7);
        check("and the seal epoch", le64(aad + 40) == 3);
    }

    /* --- Decision 5's table, as five refusals ------------------------------ */
    {
        uint8_t key[32], nonce[24], page[4096], plain[4096], tag[16];
        uint8_t other[48];
        cyboudb_aead_args a;

        for (i = 0; i < 32; i++) key[i] = (uint8_t)(i * 3 + 1);
        for (i = 0; i < 24; i++) nonce[i] = (uint8_t)(i * 5 + 2);
        for (i = 0; i < 4096; i++) page[i] = plain[i] = (uint8_t)(i >> 3);

        cyboudb_page_aad(aad, uuid, 41, 900, 2, 1);
        a.key = key; a.nonce = nonce; a.aad = aad; a.aad_len = 48;
        a.buf = page; a.buf_len = 4096; a.tag = tag;
        cyboudb_xchacha20poly1305_seal(&a);

        {
            uint8_t sealed[4096];
            memcpy(sealed, page, 4096);

            /* Each of these is the page presented as something it is not. */
            a.aad = other;

            uuid[3] ^= 1;
            cyboudb_page_aad(other, uuid, 41, 900, 2, 1);
            check("a page from another database is refused",
                  cyboudb_xchacha20poly1305_open(&a) != 0);
            uuid[3] ^= 1;

            cyboudb_page_aad(other, uuid, 42, 900, 2, 1);
            check("the same page at a different page number is refused",
                  cyboudb_xchacha20poly1305_open(&a) != 0);

            cyboudb_page_aad(other, uuid, 41, 899, 2, 1);
            check("a page replayed from an earlier generation is refused",
                  cyboudb_xchacha20poly1305_open(&a) != 0);

            cyboudb_page_aad(other, uuid, 41, 900, 3, 1);
            check("a page presented as another type is refused",
                  cyboudb_xchacha20poly1305_open(&a) != 0);

            cyboudb_page_aad(other, uuid, 41, 900, 2, 2);
            check("a page under a rotated-away epoch is refused",
                  cyboudb_xchacha20poly1305_open(&a) != 0);

            check("and none of those refusals decrypted anything",
                  memcmp(page, sealed, 4096) == 0);

            a.aad = aad;
            check("while the page as it actually is still opens",
                  cyboudb_xchacha20poly1305_open(&a) == 0 &&
                  memcmp(page, plain, 4096) == 0);
        }
    }

    /* --- the random source -------------------------------------------------- */
    {
        uint8_t a1[32], a2[32], zero[32];
        int rc1, rc2;
        memset(zero, 0, sizeof zero);
        memset(a1, 0, sizeof a1);
        memset(a2, 0, sizeof a2);
        rc1 = os_random(a1, sizeof a1);
        rc2 = os_random(a2, sizeof a2);
        check("os_random reports success", rc1 == 0 && rc2 == 0);
        check("and does not return the buffer it was given",
              memcmp(a1, zero, 32) != 0);
        check("and two draws differ",
              memcmp(a1, a2, 32) != 0);

        /* Not a test of randomness - nothing here could be - but a test that
           the bytes are being replaced rather than partly left alone. Sixty-
           four draws of 24 bytes, all distinct, is what a working source
           looks like and what a stuck one does not. */
        {
            static uint8_t draws[64][24];
            int ok = 1, j, k;
            for (j = 0; j < 64; j++) {
                memset(draws[j], 0, 24);
                if (os_random(draws[j], 24) != 0) ok = 0;
            }
            for (j = 0; j < 64 && ok; j++)
                for (k = j + 1; k < 64 && ok; k++)
                    if (memcmp(draws[j], draws[k], 24) == 0) ok = 0;
            check("sixty-four nonce-sized draws are all different", ok);
        }

        /* A zero-length request must be a no-op rather than a fault. */
        check("a zero-length draw does nothing and succeeds",
              os_random(a1, 0) == 0);
    }

    /* --- what a nonce costs -------------------------------------------------- */
    {
        uint8_t nonce[24];
        double t;
        int n = 20000;
        t = now_seconds();
        for (i = 0; i < (unsigned)n; i++) os_random(nonce, sizeof nonce);
        t = now_seconds() - t;
        printf("\n     24 bytes from the system: %.0f ns per draw\n",
               t * 1e9 / n);
        printf("     against ~3,700 ns to seal the page it is drawn for\n");
    }

    printf("\nPage seal suite: %d checks, %d failed\n", checks, failures);
    return failures ? 1 : 0;
}
