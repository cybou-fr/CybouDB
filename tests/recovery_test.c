/* tests/recovery_test.c - the twenty-four word door
 *
 * docs/RECOVERY_PHRASE.md. Two properties carry this step, and both are
 * negative:
 *
 *   a phrase with a word wrong is a typo, decidable without touching the file,
 *   and reported as CybouDB_E_PHRASE;
 *
 *   a phrase that is perfectly well formed and belongs to a different database
 *   is CybouDB_E_KEY - not a typo, not damage, and not something that leaves a
 *   plausible root behind.
 *
 * Build (Linux):   sh build.sh --crypto-tests && ./build/recovery_test
 * Build (Windows): build.bat --crypto-tests && build\recovery_test.exe
 *
 * SPDX-License-Identifier: Apache-2.0
 * Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
 */
#include <stdio.h>
#include <string.h>
#include <stdint.h>

#define WORDS  24
#define SECRET 32

#define CSLOT_KEY_ID   0
#define CSLOT_PURPOSE  8
#define CSLOT_FLAGS    12
#define CSLOT_WRAPPED  16
#define CSLOT_SIZE     96
#define FLAG_RECOVERY  1

#define E_KEY    38
#define E_PHRASE 41

int cyboudb_recovery_new(uint8_t *secret, uint16_t *indices);
void cyboudb_recovery_encode(uint16_t *indices, const uint8_t *secret);
int cyboudb_recovery_decode(uint8_t *secret, const uint16_t *indices);
int cyboudb_recovery_seal_root(uint8_t *slot, const uint8_t *secret,
                               const uint8_t *root_key, uint64_t key_id,
                               const uint8_t *aad, uint64_t aad_len);
int cyboudb_recovery_open_root(uint8_t *root_out, const uint8_t *slot,
                               const uint8_t *secret, const uint8_t *aad,
                               uint64_t aad_len);

static int checks, failures;

static void check(const char *what, int ok) {
    checks++;
    if (ok) printf("ok   %s\n", what);
    else { failures++; printf("FAIL %s\n", what); }
}

/* The encoding written out the other way: 264 bits, most significant first,
   eleven at a time. Independent of the assembly's rolling buffer, so a
   disagreement about bit order shows up here rather than in a phrase somebody
   cannot restore. */
static void ref_encode(uint16_t *indices, const uint8_t *secret,
                       uint8_t checksum) {
    uint8_t bits[33];
    int w, b;
    memcpy(bits, secret, 32);
    bits[32] = checksum;
    for (w = 0; w < WORDS; w++) {
        unsigned v = 0;
        for (b = 0; b < 11; b++) {
            int p = w * 11 + b;
            v = (v << 1) | ((bits[p >> 3] >> (7 - (p & 7))) & 1);
        }
        indices[w] = (uint16_t)v;
    }
}

int main(void) {
    uint8_t secret[SECRET], back[SECRET], root[SECRET], out[SECRET];
    uint8_t zero[SECRET], aad[24], other_aad[24];
    uint8_t slot[CSLOT_SIZE];
    uint16_t words[WORDS], words2[WORDS];
    unsigned i;

    printf("CybouDB recovery phrase test\n\n");

    memset(zero, 0, sizeof zero);
    for (i = 0; i < SECRET; i++) secret[i] = (uint8_t)(i * 11 + 3);
    for (i = 0; i < SECRET; i++) root[i] = (uint8_t)(i * 7 + 9);
    for (i = 0; i < 24; i++) aad[i] = (uint8_t)(i + 1);
    memcpy(other_aad, aad, 24);
    other_aad[0] ^= 0x40;

    /* --- the encoding -------------------------------------------------------- */
    cyboudb_recovery_encode(words, secret);
    {
        int in_range = 1;
        for (i = 0; i < WORDS; i++)
            if (words[i] >= 2048) in_range = 0;
        check("twenty-four indices, all inside a 2048-word list", in_range);
    }

    check("and the phrase decodes to the secret it was made from",
          cyboudb_recovery_decode(back, words) == 0 &&
          memcmp(back, secret, SECRET) == 0);

    /* The first 23 words carry 253 of the 256 secret bits, so the reference
       encoder can be checked against the assembly for the whole phrase once
       the checksum is taken from the assembly's own output - what is being
       compared is the bit order, which is the part that can silently differ. */
    {
        uint8_t checksum;
        uint16_t ref[WORDS];
        /* the last word holds the low 3 bits of the secret and 8 of checksum */
        checksum = (uint8_t)(words[WORDS - 1] & 0xFF);
        ref_encode(ref, secret, checksum);
        check("the bit order is most-significant-first, eleven at a time",
              memcmp(ref, words, sizeof ref) == 0);
    }

    check("a different secret gives a different phrase",
          (secret[0] ^= 0x01, cyboudb_recovery_encode(words2, secret),
           secret[0] ^= 0x01, memcmp(words, words2, sizeof words) != 0));

    /* --- typos --------------------------------------------------------------- */
    memcpy(words2, words, sizeof words);
    words2[7] = (uint16_t)((words2[7] + 1) % 2048);
    memset(back, 0xAA, sizeof back);
    check("one wrong word is caught by the checksum",
          cyboudb_recovery_decode(back, words2) == E_PHRASE);
    check("and leaves nothing that looks like a secret",
          memcmp(back, zero, SECRET) == 0);

    memcpy(words2, words, sizeof words);
    {
        uint16_t t = words2[3];
        words2[3] = words2[4];
        words2[4] = t;
    }
    check("two words swapped are caught as well",
          cyboudb_recovery_decode(back, words2) == E_PHRASE);

    memcpy(words2, words, sizeof words);
    words2[0] = 2048;
    check("an index outside the wordlist is refused rather than wrapped",
          cyboudb_recovery_decode(back, words2) == E_PHRASE);

    /* A checksum is eight bits, so roughly one wrong phrase in 256 passes it
       and then fails to open the file. That is the design, not a defect - and
       measuring it here keeps the claim honest rather than optimistic. */
    {
        int caught = 0, trials = 0;
        for (i = 0; i < 2048; i++) {
            memcpy(words2, words, sizeof words);
            words2[i % WORDS] = (uint16_t)((words2[i % WORDS] + 1 + i) % 2048);
            if (memcmp(words2, words, sizeof words) == 0) continue;
            trials++;
            if (cyboudb_recovery_decode(back, words2) == E_PHRASE) caught++;
        }
        check("and most single-word errors are caught - eight bits of "
              "checksum, so about 255 in 256",
              trials > 2000 && caught > trials * 99 / 100);
    }

    /* --- drawing a fresh one -------------------------------------------------- */
    {
        uint8_t s1[SECRET], s2[SECRET];
        uint16_t w1[WORDS], w2[WORDS];
        check("a fresh phrase can be drawn",
              cyboudb_recovery_new(s1, w1) == 0 &&
              memcmp(s1, zero, SECRET) != 0);
        check("and it decodes back to its own secret",
              cyboudb_recovery_decode(back, w1) == 0 &&
              memcmp(back, s1, SECRET) == 0);
        check("and two of them are not the same",
              cyboudb_recovery_new(s2, w2) == 0 &&
              memcmp(s1, s2, SECRET) != 0);
    }

    /* --- the second door ------------------------------------------------------ */
    check("a root key seals to a recovery secret",
          cyboudb_recovery_seal_root(slot, secret, root, 0xABCD, aad, 24) == 0);
    {
        uint32_t flags, purpose;
        uint64_t id;
        memcpy(&id, slot + CSLOT_KEY_ID, 8);
        memcpy(&purpose, slot + CSLOT_PURPOSE, 4);
        memcpy(&flags, slot + CSLOT_FLAGS, 4);
        check("and the slot says it is a recovery slot",
              id == 0xABCD && flags == FLAG_RECOVERY && purpose == 1);
        check("and does not contain the root",
              memcmp(slot + CSLOT_WRAPPED, root, SECRET) != 0);
    }

    memset(out, 0xAA, sizeof out);
    check("the phrase's secret opens it",
          cyboudb_recovery_open_root(out, slot, secret, aad, 24) == 0 &&
          memcmp(out, root, SECRET) == 0);

    /* Which is the point of the whole step: the phrase is a second door to the
       same root, reached without a private key. */
    {
        uint8_t decoded[SECRET];
        memset(out, 0xAA, sizeof out);
        check("and so does the phrase itself, decoded",
              cyboudb_recovery_decode(decoded, words) == 0 &&
              cyboudb_recovery_open_root(out, slot, decoded, aad, 24) == 0 &&
              memcmp(out, root, SECRET) == 0);
    }

    {
        uint8_t other[SECRET];
        memcpy(other, secret, SECRET);
        other[9] ^= 0x01;
        memset(out, 0xAA, sizeof out);
        check("another phrase - well formed, and for another database - is a "
              "key problem and not a typo",
              cyboudb_recovery_open_root(out, slot, other, aad, 24) == E_KEY &&
              memcmp(out, zero, SECRET) == 0);
    }

    memset(out, 0xAA, sizeof out);
    check("the right phrase against another database is refused too",
          cyboudb_recovery_open_root(out, slot, secret, other_aad, 24) == E_KEY &&
          memcmp(out, zero, SECRET) == 0);

    {
        uint8_t torn[CSLOT_SIZE];
        memcpy(torn, slot, CSLOT_SIZE);
        torn[CSLOT_WRAPPED + 40] ^= 0x01;
        memset(out, 0xAA, sizeof out);
        check("an altered wrapping is refused",
              cyboudb_recovery_open_root(out, torn, secret, aad, 24) == E_KEY &&
              memcmp(out, zero, SECRET) == 0);

        memcpy(torn, slot, CSLOT_SIZE);
        {
            uint64_t id = 0x1111;
            memcpy(torn + CSLOT_KEY_ID, &id, 8);
        }
        memset(out, 0xAA, sizeof out);
        check("and a slot renamed to another id - the id is in the context",
              cyboudb_recovery_open_root(out, torn, secret, aad, 24) == E_KEY &&
              memcmp(out, zero, SECRET) == 0);
    }

    printf("\nrecovery suite: %d checks, %d failed\n", checks, failures);
    return failures ? 1 : 0;
}
