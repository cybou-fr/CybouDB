/* tests/mlkem_interop.c - encapsulate under a key from somewhere else
 *
 * Reads an encapsulation key (1184 bytes) and a message (32 bytes), writes a
 * ciphertext and the shared secret it carries. It exists so that
 * tools/check_mlkem_interop.py can hand our ciphertext to OpenSSL's
 * decapsulation and compare - the direction a checked-in fixture cannot cover,
 * because OpenSSL's command line brings its own randomness.
 *
 *     mlkem_interop <ek file> <m file> <ct out> <ss out>
 *
 * SPDX-License-Identifier: Apache-2.0
 * Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
 */
#include <stdio.h>
#include <stdint.h>

#define EK_BYTES 1184
#define CT_BYTES 1088
#define SS_BYTES 32

void cyboudb_mlkem_encaps(uint8_t *ct, uint8_t *ss, const uint8_t *ek,
                          const uint8_t *m);

static int slurp(const char *path, uint8_t *buf, size_t want) {
    FILE *f = fopen(path, "rb");
    size_t got;
    if (!f) { fprintf(stderr, "cannot open %s\n", path); return 0; }
    got = fread(buf, 1, want, f);
    fclose(f);
    if (got != want) {
        fprintf(stderr, "%s is %u bytes, expected %u\n", path,
                (unsigned)got, (unsigned)want);
        return 0;
    }
    return 1;
}

static int spill(const char *path, const uint8_t *buf, size_t n) {
    FILE *f = fopen(path, "wb");
    if (!f) { fprintf(stderr, "cannot write %s\n", path); return 0; }
    fwrite(buf, 1, n, f);
    fclose(f);
    return 1;
}

int main(int argc, char **argv) {
    static uint8_t ek[EK_BYTES], ct[CT_BYTES];
    uint8_t m[32], ss[SS_BYTES];

    if (argc != 5) {
        fprintf(stderr, "usage: %s <ek> <m> <ct out> <ss out>\n", argv[0]);
        return 2;
    }
    if (!slurp(argv[1], ek, EK_BYTES)) return 1;
    if (!slurp(argv[2], m, 32)) return 1;

    cyboudb_mlkem_encaps(ct, ss, ek, m);

    if (!spill(argv[3], ct, CT_BYTES)) return 1;
    if (!spill(argv[4], ss, SS_BYTES)) return 1;
    return 0;
}
