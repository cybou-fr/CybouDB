/* tests/kdf_test.c - derivation and key wrapping
 *
 * docs/KEY_HIERARCHY.md makes four claims that a test can hold it to, and this
 * file is those four:
 *
 *   1. two purposes never produce the same key from the same root, so the page
 *      seal key cannot unwrap a DEK because the arithmetic forbids it rather
 *      than because the code declines;
 *   2. the context separates as well, so one epoch's key is not the next one's
 *      and one scope's is not another's;
 *   3. a wrapped key is unreadable without the KEK, and unwrapping with the
 *      wrong one fails rather than returning something that looks like a key;
 *   4. the associated data binds a wrapped key to its identity, so a key for
 *      one scope presented as another scope's does not unwrap.
 *
 * Build (Linux):   sh build.sh --crypto-tests && ./build/kdf_test
 * Build (Windows): build.bat --crypto-tests && build\kdf_test.exe
 *
 * SPDX-License-Identifier: Apache-2.0
 * Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

/* include/crypto.inc holds the same numbers. */
#define KDF_METADATA_KEK 1
#define KDF_PAGE_SEAL    2
#define KDF_SEAL_TREE    3
#define KDF_SCOPE_KEK    4
#define KDF_MANIFEST     5
#define WRAPPED_KEY_SIZE 72

int cyboudb_kdf(uint8_t *out, uint64_t out_len, uint64_t purpose,
                const uint8_t *root, const uint8_t *context,
                uint64_t context_len);
int cyboudb_key_wrap(uint8_t *out, const uint8_t *kek, const uint8_t *key,
                     const uint8_t *aad, uint64_t aad_len);
int cyboudb_key_unwrap(uint8_t *key_out, const uint8_t *kek,
                       const uint8_t *wrapped, const uint8_t *aad,
                       uint64_t aad_len);
int cyboudb_key_status(int unwrap_rc);

#define E_KEY 38

static int checks, failures;

static void check(const char *what, int ok) {
    checks++;
    if (ok) printf("ok   %s\n", what);
    else { failures++; printf("FAIL %s\n", what); }
}

int main(void) {
    uint8_t root[32], zero[32];
    unsigned i;

    printf("CybouDB key derivation and wrapping test\n\n");

    for (i = 0; i < 32; i++) root[i] = (uint8_t)(i * 9 + 4);
    memset(zero, 0, sizeof zero);

    /* --- derivation is a function, not a coincidence ----------------------- */
    {
        uint8_t a[32], b[32];
        check("the same purpose and root give the same key twice",
              cyboudb_kdf(a, 32, KDF_PAGE_SEAL, root, NULL, 0) == 0 &&
              cyboudb_kdf(b, 32, KDF_PAGE_SEAL, root, NULL, 0) == 0 &&
              memcmp(a, b, 32) == 0);
        check("and it is not the root", memcmp(a, root, 32) != 0);
        check("and not zero", memcmp(a, zero, 32) != 0);
    }

    /* --- every pair of purposes, which is the claim the hierarchy rests on -- */
    {
        uint8_t keys[5][32];
        int p, q, ok = 1;
        for (p = 0; p < 5; p++)
            if (cyboudb_kdf(keys[p], 32, (uint64_t)(p + 1), root, NULL, 0) != 0)
                ok = 0;
        check("all five purposes derive", ok);

        ok = 1;
        for (p = 0; p < 5; p++)
            for (q = p + 1; q < 5; q++)
                if (memcmp(keys[p], keys[q], 32) == 0) ok = 0;
        check("and no two of them are the same key", ok);
    }

    /* --- the context separates too ----------------------------------------- */
    {
        uint8_t e0[32], e1[32], s1[32], s2[32];
        uint64_t epoch0 = 0, epoch1 = 1;
        static const char *scope_a = "finance";
        static const char *scope_b = "telemetry";

        cyboudb_kdf(e0, 32, KDF_PAGE_SEAL, root, (const uint8_t *)&epoch0, 8);
        cyboudb_kdf(e1, 32, KDF_PAGE_SEAL, root, (const uint8_t *)&epoch1, 8);
        check("one epoch's page seal key is not the next one's",
              memcmp(e0, e1, 32) != 0);

        cyboudb_kdf(s1, 32, KDF_SCOPE_KEK, root,
                    (const uint8_t *)scope_a, strlen(scope_a));
        cyboudb_kdf(s2, 32, KDF_SCOPE_KEK, root,
                    (const uint8_t *)scope_b, strlen(scope_b));
        check("and one scope's key is not another's", memcmp(s1, s2, 32) != 0);

        /* The separator after the label earns its byte here: without it,
           "page-seal" with context "X" and a label "page-sealX" with none
           would be the same input. The same argument applies between a label
           and the root, which is why the root is fixed-length. */
        {
            uint8_t with_ctx[32], without[32];
            cyboudb_kdf(with_ctx, 32, KDF_MANIFEST, root,
                        (const uint8_t *)"", 0);
            cyboudb_kdf(without, 32, KDF_MANIFEST, root, NULL, 0);
            check("an empty context and no context are the same thing",
                  memcmp(with_ctx, without, 32) == 0);
        }
    }

    /* --- a different root is a different world ------------------------------ */
    {
        uint8_t other[32], a[32], b[32];
        memcpy(other, root, 32);
        other[31] ^= 0x01;
        cyboudb_kdf(a, 32, KDF_METADATA_KEK, root, NULL, 0);
        cyboudb_kdf(b, 32, KDF_METADATA_KEK, other, NULL, 0);
        check("one bit of the root changes the derived key",
              memcmp(a, b, 32) != 0);
    }

    /* --- what the closed list refuses --------------------------------------- */
    {
        uint8_t out[32];
        uint8_t ctx[128];
        memset(ctx, 0, sizeof ctx);
        check("purpose zero is refused",
              cyboudb_kdf(out, 32, 0, root, NULL, 0) != 0);
        check("and a purpose past the list",
              cyboudb_kdf(out, 32, 6, root, NULL, 0) != 0);
        check("and a context longer than the format allows",
              cyboudb_kdf(out, 32, KDF_PAGE_SEAL, root, ctx, 65) != 0);
        check("while the longest allowed context works",
              cyboudb_kdf(out, 32, KDF_PAGE_SEAL, root, ctx, 64) == 0);
    }

    /* --- a derived key can be any length the caller needs ------------------- */
    {
        uint8_t short_key[16], long_key[96];
        check("sixteen bytes and ninety-six both derive",
              cyboudb_kdf(short_key, 16, KDF_SEAL_TREE, root, NULL, 0) == 0 &&
              cyboudb_kdf(long_key, 96, KDF_SEAL_TREE, root, NULL, 0) == 0);
        check("and the shorter is a prefix of the longer, as a sponge gives it",
              memcmp(short_key, long_key, 16) == 0);
    }

    /* --- wrapping ------------------------------------------------------------ */
    {
        uint8_t kek[32], dek[32], back[32];
        uint8_t wrapped[WRAPPED_KEY_SIZE], again[WRAPPED_KEY_SIZE];
        uint8_t aad[24], other_aad[24];

        cyboudb_kdf(kek, 32, KDF_METADATA_KEK, root, NULL, 0);
        for (i = 0; i < 32; i++) dek[i] = (uint8_t)(i * 11 + 2);
        for (i = 0; i < 24; i++) aad[i] = (uint8_t)(i + 1);
        memcpy(other_aad, aad, 24);
        other_aad[0] ^= 0x10;           /* a different key id */

        check("wrapping succeeds",
              cyboudb_key_wrap(wrapped, kek, dek, aad, 24) == 0);
        check("and the wrapped bytes are not the key",
              memcmp(wrapped + 24, dek, 32) != 0);
        check("and unwrapping gives it back",
              cyboudb_key_unwrap(back, kek, wrapped, aad, 24) == 0 &&
              memcmp(back, dek, 32) == 0);

        check("wrapping the same key twice gives different bytes - the nonce",
              cyboudb_key_wrap(again, kek, dek, aad, 24) == 0 &&
              memcmp(wrapped, again, WRAPPED_KEY_SIZE) != 0);
        check("and both unwrap to the same key",
              cyboudb_key_unwrap(back, kek, again, aad, 24) == 0 &&
              memcmp(back, dek, 32) == 0);

        /* Every refusal, and what each one is the defence against. */
        {
            uint8_t wrong_kek[32];
            cyboudb_kdf(wrong_kek, 32, KDF_SCOPE_KEK, root, NULL, 0);
            memset(back, 0xAA, 32);
            check("the wrong key-encryption key is refused",
                  cyboudb_key_unwrap(back, wrong_kek, wrapped, aad, 24) != 0);
            /* And what the user hears. A wrong key is the one failure an
               engine must not describe as damage: the file is perfect, and
               the person holding the wrong passphrase should be told to find
               the right one rather than to go looking for a backup. */
            check("and reported as a key that does not open this file",
                  cyboudb_key_status(
                      cyboudb_key_unwrap(back, wrong_kek, wrapped, aad, 24))
                      == E_KEY);
            check("and leaves zeroes rather than a plausible key",
                  memcmp(back, zero, 32) == 0);
        }

        memset(back, 0xAA, 32);
        check("a key presented under another identity is refused",
              cyboudb_key_unwrap(back, kek, wrapped, other_aad, 24) != 0 &&
              memcmp(back, zero, 32) == 0);

        {
            uint8_t torn[WRAPPED_KEY_SIZE];
            memcpy(torn, wrapped, WRAPPED_KEY_SIZE);
            torn[30] ^= 0x01;
            check("an altered ciphertext is refused",
                  cyboudb_key_unwrap(back, kek, torn, aad, 24) != 0);

            memcpy(torn, wrapped, WRAPPED_KEY_SIZE);
            torn[60] ^= 0x01;
            check("an altered tag is refused",
                  cyboudb_key_unwrap(back, kek, torn, aad, 24) != 0);

            memcpy(torn, wrapped, WRAPPED_KEY_SIZE);
            torn[2] ^= 0x01;
            check("and an altered nonce is refused",
                  cyboudb_key_unwrap(back, kek, torn, aad, 24) != 0);
        }

        /* The hierarchy in miniature: a root, a KEK derived from it, a DEK
           wrapped under that, and none of it recoverable from the wrapped
           bytes alone. */
        {
            uint8_t rebuilt_kek[32], rebuilt[32];
            cyboudb_kdf(rebuilt_kek, 32, KDF_METADATA_KEK, root, NULL, 0);
            check("and the KEK is reproducible from the root alone",
                  memcmp(rebuilt_kek, kek, 32) == 0 &&
                  cyboudb_key_unwrap(rebuilt, rebuilt_kek, wrapped, aad, 24)
                      == 0 &&
                  memcmp(rebuilt, dek, 32) == 0);
        }
    }

    printf("\nKDF suite: %d checks, %d failed\n", checks, failures);
    return failures ? 1 : 0;
}
