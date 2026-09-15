/* tests/kmac_test.c - KMAC256, against OpenSSL and against NIST's own sample
 *
 * This suite exists because of a rule the project had already written down and
 * then broken: a primitive implemented here can be checked against another
 * implementation, and a construction invented here cannot. The seal tree and
 * the key hierarchy were both using a prefix MAC of my own design. KMAC is the
 * standard one, and this is the check that makes using it worth anything.
 *
 * Two independent sources, not one. tests/kmac_fixture.h is generated from
 * OpenSSL 3; the vector at the end is printed in NIST SP 800-185 itself, so a
 * shared misunderstanding between this code and OpenSSL would still have to
 * survive it.
 *
 * Build (Linux):   sh build.sh --crypto-tests && ./build/kmac_test
 * Build (Windows): build.bat --crypto-tests && build\kmac_test.exe
 *
 * SPDX-License-Identifier: Apache-2.0
 * Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
 */
#include <stdio.h>
#include <string.h>
#include <stdint.h>

#define SHCTX_SIZE 232

int cyboudb_kmac256_init(uint8_t *ctx, const uint8_t *key, uint64_t key_len,
                         const uint8_t *custom, uint64_t custom_len);
void cyboudb_kmac256_update(uint8_t *ctx, const uint8_t *in, uint64_t len);
void cyboudb_kmac256_final(uint8_t *ctx, uint8_t *out, uint64_t out_len);

struct kmac_args {
    uint8_t *out;          uint64_t out_len;
    const uint8_t *key;    uint64_t key_len;
    const uint8_t *msg;    uint64_t msg_len;
    const uint8_t *custom; uint64_t custom_len;
};
int cyboudb_kmac256(const struct kmac_args *args);

#include "kmac_fixture.h"

static int checks, failures;

static void check(const char *what, int ok) {
    checks++;
    if (ok) printf("ok   %s\n", what);
    else { failures++; printf("FAIL %s\n", what); }
}

static int hexeq(const uint8_t *got, const char *hex, size_t n) {
    size_t i;
    for (i = 0; i < n; i++) {
        unsigned v;
        if (sscanf(hex + 2 * i, "%2x", &v) != 1) return 0;
        if (got[i] != (uint8_t)v) return 0;
    }
    return 1;
}

int main(void) {
    static uint8_t out[128], out2[128], ctx[SHCTX_SIZE];
    struct kmac_args a;
    unsigned c;

    printf("CybouDB KMAC256 test\n\n");

    /* --- against OpenSSL ----------------------------------------------------- */
    for (c = 0; c < sizeof kmac_cases / sizeof *kmac_cases; c++) {
        const kmac_case *k = &kmac_cases[c];
        char what[96];

        memset(out, 0, sizeof out);
        a.out = out;            a.out_len = k->want_len;
        a.key = k->key;         a.key_len = k->key_len;
        a.msg = k->msg;         a.msg_len = k->msg_len;
        a.custom = k->custom_len ? k->custom : NULL;
        a.custom_len = k->custom_len;

        snprintf(what, sizeof what, "OpenSSL's KMAC256 agrees: %s", k->name);
        check(what, cyboudb_kmac256(&a) == 0 &&
                    memcmp(out, k->want, (size_t)k->want_len) == 0);
    }

    /* --- against the published sample ---------------------------------------
       SP 800-185 sample #4: key 40..5F, data 00 01 02 03, S = "My Tagged
       Application", 512 bits out. A vector from the document itself, so an
       agreement between this implementation and OpenSSL that was wrong in the
       same way would still fail here. */
    {
        static const uint8_t key[32] = {
            0x40,0x41,0x42,0x43,0x44,0x45,0x46,0x47,0x48,0x49,0x4A,0x4B,
            0x4C,0x4D,0x4E,0x4F,0x50,0x51,0x52,0x53,0x54,0x55,0x56,0x57,
            0x58,0x59,0x5A,0x5B,0x5C,0x5D,0x5E,0x5F
        };
        static const uint8_t data[4] = { 0x00, 0x01, 0x02, 0x03 };
        static const char *custom = "My Tagged Application";

        a.out = out;      a.out_len = 64;
        a.key = key;      a.key_len = sizeof key;
        a.msg = data;     a.msg_len = sizeof data;
        a.custom = (const uint8_t *)custom;
        a.custom_len = strlen(custom);
        cyboudb_kmac256(&a);
        check("NIST SP 800-185's own KMAC256 sample",
              hexeq(out, "20c570c31346f703c9ac36c61c03cb64c3970d0cfc787e9b"
                         "79599d273a68d2f7f69d4cc3de9d104a351689f27cf6f595"
                         "1f0103f33f4f24871024d9c27773a8dd", 64));
    }

    /* --- what the encodings are for -------------------------------------------
       Each of these would collide under a naive prefix construction, and none
       of them collides under KMAC. That is the entire argument for using it. */
    {
        static const uint8_t key_a[3] = { 1, 2, 3 };
        static const uint8_t key_b[2] = { 1, 2 };
        static const uint8_t msg_a[2] = { 3, 4 };
        static const uint8_t msg_b[3] = { 3, 3, 4 };

        a.out = out;   a.out_len = 32;
        a.key = key_a; a.key_len = 3;
        a.msg = msg_a; a.msg_len = 2;
        a.custom = NULL; a.custom_len = 0;
        cyboudb_kmac256(&a);

        a.out = out2;
        a.key = key_b; a.key_len = 2;
        a.msg = msg_b; a.msg_len = 3;
        cyboudb_kmac256(&a);
        check("moving a byte from the key to the message changes the tag",
              memcmp(out, out2, 32) != 0);

        /* Two customization strings that share a prefix. */
        a.out = out;   a.key = key_a; a.key_len = 3;
        a.msg = msg_a; a.msg_len = 2;
        a.custom = (const uint8_t *)"seal"; a.custom_len = 4;
        cyboudb_kmac256(&a);
        a.out = out2;
        a.custom = (const uint8_t *)"seal-leaf"; a.custom_len = 9;
        cyboudb_kmac256(&a);
        check("and one customization string is never a prefix of another",
              memcmp(out, out2, 32) != 0);

        /* A shorter output is not a prefix of a longer one - right_encode(L)
           is inside the message, so the length is part of what is MAC'd. */
        a.out = out;  a.out_len = 16;
        a.custom = NULL; a.custom_len = 0;
        cyboudb_kmac256(&a);
        a.out = out2; a.out_len = 32;
        cyboudb_kmac256(&a);
        check("sixteen bytes of KMAC are not the first sixteen of thirty-two",
              memcmp(out, out2, 16) != 0);
    }

    /* --- streaming ------------------------------------------------------------
       The seal tree absorbs a page in pieces, so the pieces have to agree with
       one call. */
    {
        static uint8_t msg[300];
        unsigned i, split, ok = 1;
        for (i = 0; i < sizeof msg; i++) msg[i] = (uint8_t)(i * 7 + 1);

        a.out = out; a.out_len = 32;
        a.key = kmac_short_key; a.key_len = 32;
        a.msg = msg; a.msg_len = sizeof msg;
        a.custom = (const uint8_t *)"split"; a.custom_len = 5;
        cyboudb_kmac256(&a);

        for (split = 0; split <= sizeof msg; split += 7) {
            memset(out2, 0, sizeof out2);
            cyboudb_kmac256_init(ctx, kmac_short_key, 32,
                                 (const uint8_t *)"split", 5);
            cyboudb_kmac256_update(ctx, msg, split);
            cyboudb_kmac256_update(ctx, msg + split, sizeof msg - split);
            cyboudb_kmac256_final(ctx, out2, 32);
            if (memcmp(out, out2, 32) != 0) ok = 0;
        }
        check("absorbing a message in two pieces is absorbing it once", ok);
    }

    /* --- the caps -------------------------------------------------------------- */
    {
        static const uint8_t big[80] = { 0 };
        check("a key past the cap is refused rather than truncated",
              cyboudb_kmac256_init(ctx, big, 65, NULL, 0) != 0);
        check("and a customization string past the cap",
              cyboudb_kmac256_init(ctx, big, 32, big, 65) != 0);
        check("while the cap itself is allowed",
              cyboudb_kmac256_init(ctx, big, 64, big, 64) == 0);
    }

    printf("\nKMAC suite: %d checks, %d failed\n", checks, failures);
    return failures ? 1 : 0;
}
