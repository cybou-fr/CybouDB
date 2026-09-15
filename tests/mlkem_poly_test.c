/* tests/mlkem_poly_test.c - the arithmetic under ML-KEM
 *
 * The NTT is the part of a KEM that can be wrong without looking wrong. It
 * returns 256 plausible coefficients whatever it does, every internal check
 * passes, and the failure surfaces as "our ciphertexts decapsulate and nobody
 * else's do" - at the end of the work rather than the beginning of it.
 *
 * So the test here does not check the transform against itself. It multiplies
 * polynomials the long way, in plain C over 32-bit integers, in the ring
 * Z_q[X]/(X^256 + 1) as FIPS 203 defines it, and demands that the transform
 * agree. Round-tripping through the inverse would pass with the twiddles in
 * the wrong order; this does not.
 *
 * Build (Linux):   sh build.sh --crypto-tests && ./build/mlkem_poly_test
 * Build (Windows): build.bat --crypto-tests && build\mlkem_poly_test.exe
 *
 * SPDX-License-Identifier: Apache-2.0
 * Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
 */
#include <stdio.h>
#include <string.h>
#include <stdint.h>

#define N 256
#define Q 3329

void cyboudb_mlkem_ntt(int16_t *r);
void cyboudb_mlkem_invntt(int16_t *r);
void cyboudb_mlkem_basemul(int16_t *r, const int16_t *a, const int16_t *b);
void cyboudb_mlkem_poly_add(int16_t *r, const int16_t *a, const int16_t *b);
void cyboudb_mlkem_poly_sub(int16_t *r, const int16_t *a, const int16_t *b);
void cyboudb_mlkem_poly_reduce(int16_t *r);
void cyboudb_mlkem_poly_tomont(int16_t *r);
int cyboudb_mlkem_montgomery_reduce(int32_t a);
int cyboudb_mlkem_barrett_reduce(int32_t a);

void cyboudb_mlkem_poly_tobytes(uint8_t *out, const int16_t *poly);
void cyboudb_mlkem_poly_frombytes(int16_t *poly, const uint8_t *in);
void cyboudb_mlkem_poly_compress10(uint8_t *out, const int16_t *poly);
void cyboudb_mlkem_poly_decompress10(int16_t *poly, const uint8_t *in);
void cyboudb_mlkem_poly_compress4(uint8_t *out, const int16_t *poly);
void cyboudb_mlkem_poly_decompress4(int16_t *poly, const uint8_t *in);
void cyboudb_mlkem_poly_frommsg(int16_t *poly, const uint8_t *msg);
void cyboudb_mlkem_poly_tomsg(uint8_t *msg, const int16_t *poly);

static int checks, failures;

static void check(const char *what, int ok) {
    checks++;
    if (ok) printf("ok   %s\n", what);
    else { failures++; printf("FAIL %s\n", what); }
}

/* A deterministic stand-in for random coefficients: a linear congruential
   sequence, so a failure is reproducible and says which input caused it. */
static uint32_t seed = 12345;
static uint32_t next_random(void) {
    seed = seed * 1103515245u + 12345u;
    return seed >> 8;
}

static int16_t centred(int32_t x) {
    int32_t r = ((x % Q) + Q) % Q;
    return (int16_t)(r > Q / 2 ? r - Q : r);
}

static void random_poly(int16_t *p) {
    int i;
    for (i = 0; i < N; i++) p[i] = centred((int32_t)(next_random() % Q));
}

/* The product in Z_q[X]/(X^256 + 1), written out. X^256 = -1, so a term that
   lands past degree 255 comes back with its sign flipped - which is the whole
   of the ring and the only thing the NTT is a shortcut for. */
static void schoolbook(int16_t *r, const int16_t *a, const int16_t *b) {
    int32_t acc[2 * N];
    int i, j;
    memset(acc, 0, sizeof acc);
    for (i = 0; i < N; i++)
        for (j = 0; j < N; j++)
            acc[i + j] = (acc[i + j] + (int32_t)a[i] * b[j]) % Q;
    for (i = 0; i < N; i++)
        r[i] = centred(acc[i] - acc[i + N]);
}

static int same(const int16_t *a, const int16_t *b) {
    int i;
    for (i = 0; i < N; i++)
        if (centred(a[i]) != centred(b[i])) return 0;
    return 1;
}

int main(void) {
    static int16_t a[N], b[N], c[N], d[N], want[N], keep[N];
    int i, r;

    printf("CybouDB ML-KEM arithmetic test\n\n");

    /* --- the reductions, across their range -------------------------------- */
    {
        int ok = 1, in_range = 1;
        for (i = -32768; i < 32768; i += 7) {
            int got = cyboudb_mlkem_barrett_reduce(i);
            if (centred(got) != centred(i)) ok = 0;
            if (got <= -Q / 2 - 1 || got > Q / 2) in_range = 0;
        }
        check("Barrett reduction preserves the residue", ok);
        check("and lands inside (-q/2, q/2]", in_range);

        ok = 1;
        for (i = -20000; i < 20000; i += 13) {
            /* montgomery_reduce(a) = a * 2^-16, so a * 2^16 comes back as a */
            int got = cyboudb_mlkem_montgomery_reduce(i * 65536);
            if (centred(got) != centred(i)) ok = 0;
        }
        check("Montgomery reduction divides by 2^16 modulo q", ok);
    }

    /* --- the transform, against multiplication done the long way ------------ */
    {
        int ok = 1;
        for (r = 0; r < 8; r++) {
            random_poly(a);
            random_poly(b);
            schoolbook(want, a, b);

            memcpy(c, a, sizeof a);
            memcpy(d, b, sizeof b);
            cyboudb_mlkem_ntt(c);
            cyboudb_mlkem_ntt(d);
            cyboudb_mlkem_basemul(c, c, d);
            cyboudb_mlkem_invntt(c);

            if (!same(c, want)) ok = 0;
        }
        check("the NTT multiplies polynomials, and agrees with doing it by hand",
              ok);
    }

    /* A product with a polynomial that is 1: the identity, and the case that
       catches a transform which is self-consistent but scaled wrong. */
    {
        random_poly(a);
        memset(b, 0, sizeof b);
        b[0] = 1;
        memcpy(c, a, sizeof a);
        memcpy(d, b, sizeof b);
        cyboudb_mlkem_ntt(c);
        cyboudb_mlkem_ntt(d);
        cyboudb_mlkem_basemul(c, c, d);
        cyboudb_mlkem_invntt(c);
        check("multiplying by one gives the polynomial back, unscaled",
              same(c, a));
    }

    /* X^255 * X = -1: the wrap that makes this ring what it is. */
    {
        memset(a, 0, sizeof a);
        memset(b, 0, sizeof b);
        a[255] = 1;
        b[1] = 1;
        schoolbook(want, a, b);
        check("X^255 times X is minus one, in the reference multiply",
              centred(want[0]) == -1);
        cyboudb_mlkem_ntt(a);
        cyboudb_mlkem_ntt(b);
        cyboudb_mlkem_basemul(c, a, b);
        cyboudb_mlkem_invntt(c);
        check("and in the transform", same(c, want));
    }

    /* --- the inverse is an inverse ------------------------------------------ */
    {
        random_poly(a);
        memcpy(keep, a, sizeof a);
        cyboudb_mlkem_ntt(a);
        check("the transform changes the polynomial", !same(a, keep));
        cyboudb_mlkem_invntt(a);
        /* A round trip is not the identity, and the direction matters. The
           seven inverse layers carry a factor of 128 and the final scaling
           multiplies by 1441 * 2^-16, so what comes back is the polynomial
           times 128 * 1441 * 2^-16 = 2^16 mod q: one Montgomery factor too
           many, not one too few. That surplus is exactly what basemul's
           2^-16 cancels, which is why the multiplication above lands
           unscaled - and why a caller who uses the transform without a
           basemul between the halves has to divide it out. */
        {
            int ok = 1;
            for (i = 0; i < N; i++)
                if (centred(cyboudb_mlkem_montgomery_reduce(a[i])) !=
                    centred(keep[i])) ok = 0;
            check("and the inverse puts it back, carrying one Montgomery "
                  "factor", ok);
        }

        /* poly_tomont is the other direction, and the two undo each other. */
        memcpy(a, keep, sizeof keep);
        cyboudb_mlkem_poly_tomont(a);
        {
            int ok = 1;
            for (i = 0; i < N; i++)
                if (centred(cyboudb_mlkem_montgomery_reduce(a[i])) !=
                    centred(keep[i])) ok = 0;
            check("entering the Montgomery domain and leaving it is the "
                  "identity", ok);
        }
    }

    /* --- the coefficient-wise pieces ---------------------------------------- */
    {
        int ok = 1;
        random_poly(a);
        random_poly(b);
        cyboudb_mlkem_poly_add(c, a, b);
        for (i = 0; i < N; i++)
            if (centred(c[i]) != centred(a[i] + b[i])) ok = 0;
        check("addition is addition", ok);

        ok = 1;
        cyboudb_mlkem_poly_sub(c, a, b);
        for (i = 0; i < N; i++)
            if (centred(c[i]) != centred(a[i] - b[i])) ok = 0;
        check("and subtraction is subtraction", ok);

        ok = 1;
        for (i = 0; i < N; i++) c[i] = (int16_t)(i * 97 - 12000);
        memcpy(d, c, sizeof c);
        cyboudb_mlkem_poly_reduce(c);
        for (i = 0; i < N; i++)
            if (centred(c[i]) != centred(d[i]) || c[i] > Q / 2 || c[i] <= -Q)
                ok = 0;
        check("reduction changes representatives and not residues", ok);
    }

/* --- the encodings ------------------------------------------------------
       Compression is defined in FIPS 203 as round(2^d * x / q) mod 2^d, and
       the assembly computes it with a multiply and a shift because a real
       division is not constant time. So the test does the real division, in
       C, for every one of the 3329 possible coefficients - not a sample of
       them - and compares. A multiply-and-shift that is off by one anywhere
       in the range would be found here rather than by two implementations
       disagreeing about a ciphertext in a year. */
    {
        int ok10 = 1, ok4 = 1, x;
        static int16_t p[N], back[N];
        static uint8_t packed[320];

        for (x = 0; x < Q; x++) {
            int d;
            for (d = 0; d < N; d++) p[d] = (int16_t)x;
            cyboudb_mlkem_poly_compress10(packed, p);
            /* the first coefficient is enough: they are all the same value */
            if ((packed[0] | ((packed[1] & 0x03) << 8)) !=
                ((((uint32_t)x << 10) + Q / 2) / Q & 0x3FF)) ok10 = 0;
            cyboudb_mlkem_poly_compress4(packed, p);
            if ((packed[0] & 0x0F) != ((((uint32_t)x << 4) + Q / 2) / Q & 0x0F))
                ok4 = 0;
        }
        check("ten-bit compression matches the definition, for every "
              "coefficient in the field", ok10);
        check("and four-bit compression likewise", ok4);

        /* Negative representatives must compress as their positive twins: the
           engine hands out centred coefficients, and a compression that took
           the sign literally would encode half the field as zero. */
        {
            int ok = 1;
            for (x = 1; x <= Q / 2; x++) {
                uint8_t a_packed[320], b_packed[320];
                int d;
                for (d = 0; d < N; d++) p[d] = (int16_t)(-x);
                cyboudb_mlkem_poly_compress10(a_packed, p);
                for (d = 0; d < N; d++) p[d] = (int16_t)(Q - x);
                cyboudb_mlkem_poly_compress10(b_packed, p);
                if (memcmp(a_packed, b_packed, 320) != 0) ok = 0;
            }
            check("a negative coefficient compresses as its positive twin", ok);
        }

        /* Decompression is not an inverse - that is the point of it - but the
           error it introduces is bounded, and the bound is what decapsulation
           depends on. */
        {
            int worst10 = 0, worst4 = 0, i2;
            random_poly(p);
            for (i2 = 0; i2 < N; i2++)
                p[i2] = (int16_t)(((uint32_t)next_random()) % Q);
            cyboudb_mlkem_poly_compress10(packed, p);
            cyboudb_mlkem_poly_decompress10(back, packed);
            for (i2 = 0; i2 < N; i2++) {
                int e = centred(back[i2] - p[i2]);
                if (e < 0) e = -e;
                if (e > worst10) worst10 = e;
            }
            check("ten-bit round trip stays within q/2^11 + 1", worst10 <= 2);

            cyboudb_mlkem_poly_compress4(packed, p);
            cyboudb_mlkem_poly_decompress4(back, packed);
            for (i2 = 0; i2 < N; i2++) {
                int e = centred(back[i2] - p[i2]);
                if (e < 0) e = -e;
                if (e > worst4) worst4 = e;
            }
            check("and four-bit within q/2^5 + 1", worst4 <= 105);
        }

        /* Twelve-bit encoding is lossless, and that is checkable exactly. */
        {
            static uint8_t bytes[384];
            int ok = 1, i2;
            for (i2 = 0; i2 < N; i2++)
                p[i2] = (int16_t)(next_random() % Q);
            cyboudb_mlkem_poly_tobytes(bytes, p);
            cyboudb_mlkem_poly_frombytes(back, bytes);
            for (i2 = 0; i2 < N; i2++)
                if (centred(back[i2]) != centred(p[i2])) ok = 0;
            check("twelve-bit encoding loses nothing", ok);

            for (i2 = 0; i2 < N; i2++) p[i2] = (int16_t)(-(i2 % (Q / 2)));
            cyboudb_mlkem_poly_tobytes(bytes, p);
            cyboudb_mlkem_poly_frombytes(back, bytes);
            ok = 1;
            for (i2 = 0; i2 < N; i2++)
                if (centred(back[i2]) != centred(p[i2])) ok = 0;
            check("including for negative representatives", ok);
        }

        /* The message path, which the FO transform's security runs through. */
        {
            static uint8_t msg[32], out[32];
            int ok = 1, trial;
            for (trial = 0; trial < 16; trial++) {
                int i2;
                for (i2 = 0; i2 < 32; i2++) msg[i2] = (uint8_t)next_random();
                cyboudb_mlkem_poly_frommsg(p, msg);
                cyboudb_mlkem_poly_tomsg(out, p);
                if (memcmp(msg, out, 32) != 0) ok = 0;
            }
            check("a message survives the trip through a polynomial", ok);

            /* And survives noise: every coefficient nudged by less than q/4
               must still decode to the same bit, which is the margin
               decapsulation lives on. */
            memset(msg, 0xA5, 32);
            cyboudb_mlkem_poly_frommsg(p, msg);
            {
                int i2;
                for (i2 = 0; i2 < N; i2++)
                    p[i2] = (int16_t)centred(p[i2] +
                                             (int16_t)(next_random() % (Q / 4))
                                             * ((i2 & 1) ? 1 : -1));
            }
            cyboudb_mlkem_poly_tomsg(out, p);
            check("and survives noise of up to a quarter of q",
                  memcmp(msg, out, 32) == 0);
        }
    }

    printf("\nML-KEM arithmetic suite: %d checks, %d failed\n",
           checks, failures);
    return failures ? 1 : 0;
}
