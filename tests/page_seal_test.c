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

/* --- sealing a whole page ------------------------------------------------ */
#define PAGE_SIZE 4096
#define SENTRY_NONCE 0
#define SENTRY_TAG   24
#define SENTRY_SIZE  40
#define E_SEAL 42

struct pseal_args {
    const uint8_t *key;
    uint8_t *page;
    uint8_t *entry;
    const uint8_t *uuid;
    uint64_t page_no;
    uint64_t generation;
    uint64_t page_type;
    uint64_t epoch;
};

int cyboudb_page_seal(const struct pseal_args *args);
int cyboudb_page_open(const struct pseal_args *args);

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

    {
        static uint8_t plain[PAGE_SIZE], page[PAGE_SIZE], copy[PAGE_SIZE];
        static uint8_t entry[SENTRY_SIZE], entry2[SENTRY_SIZE];
        uint8_t key[32], other_key[32], uuid[16], other_uuid[16];
        struct pseal_args a;
        unsigned k;

        for (k = 0; k < PAGE_SIZE; k++) plain[k] = (uint8_t)(k * 7 + 11);
        for (k = 0; k < 32; k++) key[k] = (uint8_t)(k * 5 + 1);
        memcpy(other_key, key, 32);
        other_key[0] ^= 0x10;
        for (k = 0; k < 16; k++) uuid[k] = (uint8_t)(k + 3);
        memcpy(other_uuid, uuid, 16);
        other_uuid[15] ^= 0x01;

        memcpy(page, plain, PAGE_SIZE);
        a.key = key; a.page = page; a.entry = entry; a.uuid = uuid;
        a.page_no = 817; a.generation = 42; a.page_type = 3; a.epoch = 5;

        check("a page seals", cyboudb_page_seal(&a) == 0);
        check("and the page is no longer the page",
              memcmp(page, plain, PAGE_SIZE) != 0);
        {
            uint8_t zero[SENTRY_SIZE];
            memset(zero, 0, sizeof zero);
            check("and the entry holds a nonce and a tag",
                  memcmp(entry, zero, SENTRY_SIZE) != 0);
        }

        memcpy(copy, page, PAGE_SIZE);
        check("and opens again to what went in",
              cyboudb_page_open(&a) == 0 &&
              memcmp(page, plain, PAGE_SIZE) == 0);

        /* Sealing the same page twice must not repeat a nonce: a repeated
           nonce under one key is the end of the cipher, which is why
           Decision 4 stores the nonce instead of deriving it. */
        memcpy(page, plain, PAGE_SIZE);
        a.entry = entry2;
        check("sealing the same page again draws a different nonce",
              cyboudb_page_seal(&a) == 0 &&
              memcmp(entry, entry2, 24) != 0);
        a.entry = entry;

        /* The nonce contract in docs/ENCRYPTED_FORMAT.md is probabilistic, not
           proven: 192 bits per seal from the OS CSPRNG, never derived and
           never reused. These are weak tests of a strong claim, and that is
           what a probabilistic contract permits - the strength is in the bits,
           and what a test can check is that the bits are actually drawn. */
        {
            static uint8_t nonces[512][24];
            unsigned n, m;
            int distinct = 1, seal_ok = 1;
            for (n = 0; n < 512; n++) {
                memcpy(page, plain, PAGE_SIZE);
                a.entry = entry2;
                if (cyboudb_page_seal(&a) != 0) seal_ok = 0;
                memcpy(nonces[n], entry2, 24);
            }
            for (n = 0; n < 512 && distinct; n++)
                for (m = n + 1; m < 512; m++)
                    if (memcmp(nonces[n], nonces[m], 24) == 0) { distinct = 0; break; }
            check("five hundred seals of one page produce no repeated nonce",
                  seal_ok && distinct);

            /* And the nonce is not a function of anything the page says: the
               page number, the generation and the epoch all vary here without
               the nonce becoming predictable from them, because none of them
               reaches the draw. */
            {
                struct pseal_args b = a;
                uint8_t n1[24], n2[24];
                b.entry = entry2;
                b.page_no = 1; b.generation = 1; b.epoch = 1;
                memcpy(page, plain, PAGE_SIZE);
                cyboudb_page_seal(&b);
                memcpy(n1, entry2, 24);
                memcpy(page, plain, PAGE_SIZE);
                cyboudb_page_seal(&b);
                memcpy(n2, entry2, 24);
                check("and two seals with identical arguments still differ",
                      memcmp(n1, n2, 24) != 0);
            }
            a.entry = entry;
        }

        /* --- what the associated data is for ------------------------------
           Each of the five fields exists because leaving it out enables one
           specific substitution. Here each one is changed on the way back in,
           and the page has to refuse to open. */
        {
            struct pseal_args b;
            memcpy(page, copy, PAGE_SIZE);
            b = a; b.key = other_key;
            check("another epoch's key does not open the page",
                  cyboudb_page_open(&b) == E_SEAL);

            memcpy(page, copy, PAGE_SIZE);
            b = a; b.page_no = 818;
            check("the page presented at another page number does not open",
                  cyboudb_page_open(&b) == E_SEAL);

            memcpy(page, copy, PAGE_SIZE);
            b = a; b.generation = 41;
            check("nor replayed into an earlier generation",
                  cyboudb_page_open(&b) == E_SEAL);

            /* The page type no longer travels in the arguments on the way
               back in: Decision 5b puts it in the last byte of the nonce,
               because the reader that needs it is the one that cannot know
               it. So open ignores what the caller says the type is - and the
               type is protected by the tag instead, which the next two checks
               are about. */
            memcpy(page, copy, PAGE_SIZE);
            b = a; b.page_type = 4;
            check("the type a caller claims on the way in is ignored",
                  cyboudb_page_open(&b) == 0);
            memcpy(page, copy, PAGE_SIZE);

            memcpy(page, copy, PAGE_SIZE);
            b = a; b.epoch = 6;
            check("nor accepted after the seal key was rotated away",
                  cyboudb_page_open(&b) == E_SEAL);

            memcpy(page, copy, PAGE_SIZE);
            b = a; b.uuid = other_uuid;
            check("nor spliced into another database of the same shape",
                  cyboudb_page_open(&b) == E_SEAL);
        }

        /* --- the page type, which now lives in the nonce ---------------------- */
    {
        struct pseal_args b = a;
        uint8_t entry_type[SENTRY_SIZE];

        memcpy(page, plain, PAGE_SIZE);
        b.entry = entry_type;
        b.page_type = 9;
        check("sealing writes the page type into the last byte of the nonce",
              cyboudb_page_seal(&b) == 0 &&
              entry_type[SENTRY_NONCE + 23] == 9);

        {
            uint8_t again[SENTRY_SIZE];
            struct pseal_args c = a;
            memcpy(page, plain, PAGE_SIZE);
            c.entry = again;
            c.page_type = 9;
            cyboudb_page_seal(&c);
            check("and the other twenty-three bytes are still drawn fresh",
                  memcmp(entry_type, again, 23) != 0);
        }

        /* A page whose entry claims a different type fails, which is the
           protection the type had before and still has: the nonce is an AEAD
           input, so changing it changes the keystream as well as the
           associated data. */
        {
            uint8_t lying[SENTRY_SIZE];
            struct pseal_args c = a;
            memcpy(page, plain, PAGE_SIZE);
            c.entry = lying;
            c.page_type = 3;
            cyboudb_page_seal(&c);
            lying[SENTRY_NONCE + 23] = 4;
            check("a page whose entry claims another type is refused",
                  cyboudb_page_open(&c) == E_SEAL);
        }
    }

    /* --- and what the tag is for --------------------------------------- */
        {
            uint8_t torn[SENTRY_SIZE];
            memcpy(page, copy, PAGE_SIZE);
            page[2000] ^= 0x01;
            check("a rewritten ciphertext is refused",
                  cyboudb_page_open(&a) == E_SEAL);

            memcpy(page, copy, PAGE_SIZE);
            memcpy(torn, entry, SENTRY_SIZE);
            torn[SENTRY_TAG + 3] ^= 0x01;
            a.entry = torn;
            check("a rewritten tag is refused",
                  cyboudb_page_open(&a) == E_SEAL);

            memcpy(torn, entry, SENTRY_SIZE);
            torn[SENTRY_NONCE + 3] ^= 0x01;
            memcpy(page, copy, PAGE_SIZE);
            check("and a rewritten nonce is refused",
                  cyboudb_page_open(&a) == E_SEAL);
            a.entry = entry;

            /* After every refusal above, the page that was right still opens -
               so the refusals are about the change and not about the test
               having broken something permanently. */
            memcpy(page, copy, PAGE_SIZE);
            check("while the page as it was written still opens",
                  cyboudb_page_open(&a) == 0 &&
                  memcmp(page, plain, PAGE_SIZE) == 0);
        }
    }

    printf("\nPage seal suite: %d checks, %d failed\n", checks, failures);
    return failures ? 1 : 0;
}
