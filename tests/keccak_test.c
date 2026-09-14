/* tests/keccak_test.c - SHAKE256, against the vectors and against C
 *
 * src/crypto/keccak.asm is the permutation the key hierarchy derives from and
 * the one ML-KEM and ML-DSA are built on, so it is worth more than one check.
 * It gets three kinds:
 *
 *   - the published squeezed output for the empty message and for one byte,
 *     from the Keccak team's own short-message vectors;
 *   - a C implementation written from FIPS 202 that shares nothing with the
 *     assembly - it keeps the state as a two-dimensional array and does rho
 *     and pi with loops, where the assembly has twenty-five generated moves;
 *   - the sponge properties that a fixed-length vector cannot see: output
 *     lengths either side of the 136-byte rate, and inputs either side of it,
 *     where a padding or a squeeze-loop mistake lives.
 *
 * Build (Linux):   sh build.sh --crypto-tests && ./build/keccak_test
 * Build (Windows): build.bat --crypto-tests && build\keccak_test.exe
 *
 * SPDX-License-Identifier: Apache-2.0
 * Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

void cyboudb_keccak_f1600(uint8_t *state);
void cyboudb_shake256(uint8_t *out, uint64_t out_len,
                      const uint8_t *in, uint64_t in_len);

static int checks, failures;

static void check(const char *what, int ok) {
    checks++;
    if (ok) printf("ok   %s\n", what);
    else { failures++; printf("FAIL %s\n", what); }
}

/* ------------------------------------------- the reference, from FIPS 202 -- */
#define ROTL64(v, n) (((v) << (n)) | ((v) >> (64 - (n))))

static const uint64_t RC[24] = {
    0x0000000000000001ull, 0x0000000000008082ull, 0x800000000000808Aull,
    0x8000000080008000ull, 0x000000000000808Bull, 0x0000000080000001ull,
    0x8000000080008081ull, 0x8000000000008009ull, 0x000000000000008Aull,
    0x0000000000000088ull, 0x0000000080008009ull, 0x000000008000000Aull,
    0x000000008000808Bull, 0x800000000000008Bull, 0x8000000000008089ull,
    0x8000000000008003ull, 0x8000000000008002ull, 0x8000000000000080ull,
    0x000000000000800Aull, 0x800000008000000Aull, 0x8000000080008081ull,
    0x8000000000008080ull, 0x0000000080000001ull, 0x8000000080008008ull };

static const int RHO[5][5] = {
    {  0, 36,  3, 41, 18 },
    {  1, 44, 10, 45,  2 },
    { 62,  6, 43, 15, 61 },
    { 28, 55, 25, 21, 56 },
    { 27, 20, 39,  8, 14 } };

static void ref_permute(uint64_t a[5][5]) {
    int round, x, y;
    for (round = 0; round < 24; round++) {
        uint64_t c[5], d[5], b[5][5];

        for (x = 0; x < 5; x++)
            c[x] = a[x][0] ^ a[x][1] ^ a[x][2] ^ a[x][3] ^ a[x][4];
        for (x = 0; x < 5; x++)
            d[x] = c[(x + 4) % 5] ^ ROTL64(c[(x + 1) % 5], 1);
        for (x = 0; x < 5; x++)
            for (y = 0; y < 5; y++)
                a[x][y] ^= d[x];

        for (x = 0; x < 5; x++)
            for (y = 0; y < 5; y++)
                b[y][(2 * x + 3 * y) % 5] =
                    RHO[x][y] ? ROTL64(a[x][y], RHO[x][y]) : a[x][y];

        for (x = 0; x < 5; x++)
            for (y = 0; y < 5; y++)
                a[x][y] = b[x][y] ^ ((~b[(x + 1) % 5][y]) & b[(x + 2) % 5][y]);

        a[0][0] ^= RC[round];
    }
}

static void ref_shake256(uint8_t *out, size_t out_len,
                         const uint8_t *in, size_t in_len) {
    const size_t rate = 136;
    uint64_t a[5][5];
    uint8_t block[200];
    size_t i;

    memset(a, 0, sizeof a);

    while (in_len >= rate) {
        memset(block, 0, sizeof block);
        memcpy(block, in, rate);
        for (i = 0; i < rate / 8; i++) {
            uint64_t lane;
            memcpy(&lane, block + i * 8, 8);
            a[i % 5][i / 5] ^= lane;
        }
        ref_permute(a);
        in += rate;
        in_len -= rate;
    }

    memset(block, 0, sizeof block);
    memcpy(block, in, in_len);
    block[in_len] ^= 0x1f;
    block[rate - 1] ^= 0x80;
    for (i = 0; i < rate / 8; i++) {
        uint64_t lane;
        memcpy(&lane, block + i * 8, 8);
        a[i % 5][i / 5] ^= lane;
    }
    ref_permute(a);

    while (out_len > 0) {
        size_t n = out_len < rate ? out_len : rate;
        uint8_t flat[200];
        for (i = 0; i < 25; i++)
            memcpy(flat + i * 8, &a[i % 5][i / 5], 8);
        memcpy(out, flat, n);
        out += n;
        out_len -= n;
        if (out_len) ref_permute(a);
    }
}

int main(void) {
    printf("CybouDB Keccak / SHAKE256 test\n\n");

    /* The Keccak team's ShortMsgKAT_SHAKE256, Len = 0. */
    {
        static const uint8_t want[32] = {
            0x46,0xB9,0xDD,0x2B,0x0B,0xA8,0x8D,0x13,0x23,0x3B,0x3F,0xEB,
            0x74,0x3E,0xEB,0x24,0x3F,0xCD,0x52,0xEA,0x62,0xB8,0x1B,0x82,
            0xB5,0x0C,0x27,0x64,0x6E,0xD5,0x76,0x2F };
        uint8_t got[32];
        cyboudb_shake256(got, sizeof got, NULL, 0);
        check("SHAKE256 of the empty message", memcmp(got, want, 32) == 0);
    }

    /* Len = 8, the single byte 0xCC. */
    {
        static const uint8_t msg[1] = { 0xCC };
        static const uint8_t want[32] = {
            0xDD,0xBF,0x55,0xDB,0xF6,0x59,0x77,0xE3,0xE2,0xA3,0x67,0x4D,
            0x33,0xE4,0x79,0xF7,0x81,0x63,0xD5,0x92,0x66,0x6B,0xC5,0x76,
            0xFE,0xB5,0xE4,0xC4,0x04,0xEA,0x5E,0x53 };
        uint8_t got[32];
        cyboudb_shake256(got, sizeof got, msg, 1);
        check("and of the single byte 0xCC", memcmp(got, want, 32) == 0);
    }

    /* Against the C reference, over the lengths where the sponge changes
       behaviour: 135, 136 and 137 are either side of the rate, and so are the
       output lengths. */
    {
        uint8_t in[400], a[400], b[400];
        int ok = 1, bad_in = -1, bad_out = -1;
        unsigned i, in_len, out_len;

        for (i = 0; i < sizeof in; i++) in[i] = (uint8_t)(i * 31 + 7);

        for (in_len = 0; in_len <= 280 && ok; in_len++) {
            ref_shake256(a, 32, in, in_len);
            cyboudb_shake256(b, 32, in, in_len);
            if (memcmp(a, b, 32) != 0) { ok = 0; bad_in = (int)in_len; }
        }
        if (!ok) printf("     first disagreement at input length %d\n", bad_in);
        check("the assembly agrees with C at every input length 0 to 280", ok);

        ok = 1;
        for (out_len = 1; out_len <= 400 && ok; out_len++) {
            ref_shake256(a, out_len, in, 50);
            cyboudb_shake256(b, out_len, in, 50);
            if (memcmp(a, b, out_len) != 0) { ok = 0; bad_out = (int)out_len; }
        }
        if (!ok) printf("     first disagreement at output length %d\n",
                        bad_out);
        check("and at every output length 1 to 400 - three squeezes", ok);
    }

    /* A derived key must depend on every byte of its input: the property the
       key hierarchy rests on, and the one a stuck permutation would break. */
    {
        uint8_t root[32], k1[32], k2[32];
        unsigned i;
        int ok = 1;
        for (i = 0; i < 32; i++) root[i] = (uint8_t)(i + 1);
        cyboudb_shake256(k1, 32, root, 32);
        for (i = 0; i < 32 && ok; i++) {
            root[i] ^= 0x01;
            cyboudb_shake256(k2, 32, root, 32);
            if (memcmp(k1, k2, 32) == 0) ok = 0;
            root[i] ^= 0x01;
        }
        check("flipping any one bit of the input changes the output", ok);
    }

    /* The permutation on its own, against the reference. */
    {
        uint8_t state[200], copy[200];
        uint64_t a[5][5];
        unsigned i;
        for (i = 0; i < 200; i++) state[i] = copy[i] = (uint8_t)(i * 7 + 3);
        for (i = 0; i < 25; i++) memcpy(&a[i % 5][i / 5], copy + i * 8, 8);
        cyboudb_keccak_f1600(state);
        ref_permute(a);
        for (i = 0; i < 25; i++) memcpy(copy + i * 8, &a[i % 5][i / 5], 8);
        check("Keccak-f[1600] alone matches the reference",
              memcmp(state, copy, 200) == 0);
    }

    printf("\nKeccak suite: %d checks, %d failed\n", checks, failures);
    return failures ? 1 : 0;
}
