/* tests/mlkem_sample_test.c - where ML-KEM's polynomials come from
 *
 * Both samplers are checked against the definition written out in C, not
 * against themselves. The binomial sampler's assembly counts bits four at a
 * time with a mask-and-add trick; the reference below counts them one at a
 * time, which is slow, obviously correct, and unrelated to the trick.
 *
 * What these checks cannot settle is the one thing only another implementation
 * can: whether the two index bytes of the matrix XOF go in the order this code
 * puts them in. A transposed matrix is self-consistent and talks to nobody.
 * That is pinned by the OpenSSL interoperation step, and it is named here so
 * that a green suite is not mistaken for a finished sampler.
 *
 * Build (Linux):   sh build.sh --crypto-tests && ./build/mlkem_sample_test
 * Build (Windows): build.bat --crypto-tests && build\mlkem_sample_test.exe
 *
 * SPDX-License-Identifier: Apache-2.0
 * Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
 */
#include <stdio.h>
#include <string.h>
#include <stdint.h>

#define N 256
#define Q 3329
#define SHCTX_SIZE 232
#define SHAKE128_RATE 168
#define SHAKE_PAD 0x1f

void cyboudb_mlkem_sample_ntt(int16_t *poly, const uint8_t *seed, uint64_t i,
                              uint64_t j);
void cyboudb_mlkem_cbd2(int16_t *poly, const uint8_t *buf);
void cyboudb_mlkem_prf(uint8_t *out, uint64_t out_len, const uint8_t *key,
                       uint64_t nonce);

void cyboudb_sponge_init(uint8_t *ctx, uint64_t rate, uint64_t pad);
void cyboudb_sponge_absorb(uint8_t *ctx, const uint8_t *in, uint64_t len);
void cyboudb_sponge_finish(uint8_t *ctx);
void cyboudb_sponge_squeeze(uint8_t *ctx, uint8_t *out, uint64_t len);
void cyboudb_shake256(uint8_t *out, uint64_t out_len, const uint8_t *in,
                      uint64_t in_len);

static int checks, failures;

static void check(const char *what, int ok) {
    checks++;
    if (ok) printf("ok   %s\n", what);
    else { failures++; printf("FAIL %s\n", what); }
}

/* --- the definitions, written out --------------------------------------- */

/* SamplePolyCBD with eta = 2, counting bits one at a time. Coefficient i is
   built from bits 4i to 4i+3 of the buffer, least significant bit of each byte
   first: the first two bits count up, the next two count down. */
static void ref_cbd2(int16_t *poly, const uint8_t *buf) {
    int i;
    for (i = 0; i < N; i++) {
        int bit, a = 0, b = 0;
        for (bit = 0; bit < 2; bit++) {
            int p = 4 * i + bit;
            a += (buf[p >> 3] >> (p & 7)) & 1;
        }
        for (bit = 2; bit < 4; bit++) {
            int p = 4 * i + bit;
            b += (buf[p >> 3] >> (p & 7)) & 1;
        }
        poly[i] = (int16_t)(a - b);
    }
}

/* SampleNTT: three bytes of the XOF give two twelve-bit candidates, and a
   candidate is taken when it is below q. */
static void ref_sample_ntt(int16_t *poly, const uint8_t *seed, int i, int j) {
    uint8_t ctx[SHCTX_SIZE], three[3], extra[2];
    int count = 0;

    extra[0] = (uint8_t)j;
    extra[1] = (uint8_t)i;
    cyboudb_sponge_init(ctx, SHAKE128_RATE, SHAKE_PAD);
    cyboudb_sponge_absorb(ctx, seed, 32);
    cyboudb_sponge_absorb(ctx, extra, 2);
    cyboudb_sponge_finish(ctx);

    while (count < N) {
        unsigned d1, d2;
        cyboudb_sponge_squeeze(ctx, three, 3);
        d1 = three[0] + 256u * (three[1] & 0x0F);
        d2 = (three[1] >> 4) + 16u * three[2];
        if (d1 < Q && count < N) poly[count++] = (int16_t)d1;
        if (d2 < Q && count < N) poly[count++] = (int16_t)d2;
    }
}

int main(void) {
    static int16_t got[N], want[N], other[N];
    uint8_t seed[32], key[32], buf[128], prf_out[128], expect[128];
    int i;

    printf("CybouDB ML-KEM sampling test\n\n");

    for (i = 0; i < 32; i++) seed[i] = (uint8_t)(i * 7 + 1);
    for (i = 0; i < 32; i++) key[i] = (uint8_t)(i * 13 + 5);

    /* --- the PRF ---------------------------------------------------------- */
    {
        uint8_t joined[33];
        memcpy(joined, key, 32);
        joined[32] = 42;
        cyboudb_shake256(expect, sizeof expect, joined, 33);
        cyboudb_mlkem_prf(prf_out, sizeof prf_out, key, 42);
        check("the PRF is SHAKE256 of the key followed by the nonce",
              memcmp(prf_out, expect, sizeof expect) == 0);

        cyboudb_mlkem_prf(buf, sizeof buf, key, 43);
        check("and a different nonce gives different output",
              memcmp(prf_out, buf, sizeof buf) != 0);
    }

    /* --- centred binomial sampling ---------------------------------------- */
    {
        int ok = 1, in_range = 1, trial;
        long counts[5];
        memset(counts, 0, sizeof counts);

        for (trial = 0; trial < 64; trial++) {
            cyboudb_mlkem_prf(buf, sizeof buf, key, (uint64_t)trial);
            cyboudb_mlkem_cbd2(got, buf);
            ref_cbd2(want, buf);
            if (memcmp(got, want, sizeof want) != 0) ok = 0;
            for (i = 0; i < N; i++) {
                if (got[i] < -2 || got[i] > 2) in_range = 0;
                else counts[got[i] + 2]++;
            }
        }
        check("the binomial sampler agrees with counting the bits by hand", ok);
        check("and never leaves [-2, 2]", in_range);

        /* The distribution is binomial(4, 1/2) shifted: 1, 4, 6, 4, 1 in
           sixteenths. 16384 samples, so a factor-of-two deviation would be
           enormous - this catches a sampler that is uniform, or biased, or
           quietly dropping a bit, without pretending to be a statistical
           test. */
        {
            long total = 64L * N;
            double want_frac[5] = { 1.0/16, 4.0/16, 6.0/16, 4.0/16, 1.0/16 };
            int shape_ok = 1;
            for (i = 0; i < 5; i++) {
                double got_frac = (double)counts[i] / (double)total;
                if (got_frac < want_frac[i] * 0.85 ||
                    got_frac > want_frac[i] * 1.15) shape_ok = 0;
            }
            check("and the five outcomes come out 1:4:6:4:1", shape_ok);
        }
    }

    /* --- uniform sampling of the matrix ----------------------------------- */
    {
        int ok = 1, in_range = 1, row, col;
        for (row = 0; row < 3; row++)
            for (col = 0; col < 3; col++) {
                cyboudb_mlkem_sample_ntt(got, seed, (uint64_t)row,
                                         (uint64_t)col);
                ref_sample_ntt(want, seed, row, col);
                if (memcmp(got, want, sizeof want) != 0) ok = 0;
                for (i = 0; i < N; i++)
                    if (got[i] < 0 || got[i] >= Q) in_range = 0;
            }
        check("the matrix sampler agrees with the rejection loop written out",
              ok);
        check("and every coefficient it accepts is below q", in_range);

        cyboudb_mlkem_sample_ntt(got, seed, 0, 1);
        cyboudb_mlkem_sample_ntt(other, seed, 1, 0);
        check("A[0][1] and A[1][0] are different polynomials - the index "
              "bytes reach the XOF", memcmp(got, other, sizeof got) != 0);

        {
            uint8_t other_seed[32];
            memcpy(other_seed, seed, 32);
            other_seed[31] ^= 0x01;
            cyboudb_mlkem_sample_ntt(other, other_seed, 0, 1);
            cyboudb_mlkem_sample_ntt(got, seed, 0, 1);
            check("and one bit of the seed changes the whole polynomial",
                  memcmp(got, other, sizeof got) != 0);
        }

        cyboudb_mlkem_sample_ntt(other, seed, 0, 1);
        check("sampling twice gives the same polynomial",
              memcmp(got, other, sizeof got) == 0);

        /* A uniform sample over [0, q) should look uniform. The cheapest
           statement of that which is not a statistics library: the mean sits
           near the middle of the field. */
        {
            long sum = 0;
            for (i = 0; i < N; i++) sum += got[i];
            {
                double mean = (double)sum / N;
                check("and the coefficients are spread across the field, not "
                      "bunched", mean > Q * 0.4 && mean < Q * 0.6);
            }
        }
    }

    printf("\nML-KEM sampling suite: %d checks, %d failed\n", checks, failures);
    return failures ? 1 : 0;
}
