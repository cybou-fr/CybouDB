/* tests/aead_test.c - the page seal, against the vectors that define it
 *
 * src/crypto/aead.asm is the construction: the cipher and the authenticator
 * are already tested separately, and this is the wiring between them. Wiring
 * is where AEADs go wrong - the MAC key taken from the wrong counter, the
 * padding left out so that a byte can be moved from the associated data into
 * the ciphertext, the lengths not authenticated at all - and none of those
 * mistakes look like a bug from the inside. They look like a working
 * encryptor.
 *
 * So this file is mostly other people's numbers:
 *
 *   RFC 8439 section 2.6.2   the one-time key derivation
 *   RFC 8439 section 2.8.2   AEAD_CHACHA20_POLY1305
 *   draft-irtf-cfrg-xchacha section 2.2.1   HChaCha20
 *   draft-irtf-cfrg-xchacha appendix A.3.1  AEAD_XCHACHA20_POLY1305
 *
 * Build (Linux):   sh build.sh --crypto-tests && ./build/aead_test
 * Build (Windows): build.bat --crypto-tests && build\aead_test.exe
 *
 * SPDX-License-Identifier: Apache-2.0
 * Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

/* include/crypto.inc declares the same fields in the same order. */
typedef struct {
    const uint8_t *key;
    const uint8_t *nonce;
    const uint8_t *aad;
    uint64_t aad_len;
    uint8_t *buf;
    uint64_t buf_len;
    uint8_t *tag;
} cyboudb_aead_args;

int cyboudb_chacha20poly1305_seal(const cyboudb_aead_args *a);
int cyboudb_chacha20poly1305_open(const cyboudb_aead_args *a);
int cyboudb_xchacha20poly1305_seal(const cyboudb_aead_args *a);
int cyboudb_xchacha20poly1305_open(const cyboudb_aead_args *a);
void cyboudb_hchacha20(const uint8_t *key, const uint8_t *nonce, uint8_t *out);
void cyboudb_chacha20_xor(const uint8_t *key, uint32_t counter,
                          const uint8_t *nonce, uint8_t *buf, uint64_t len);

static int checks, failures;

static void check(const char *what, int ok) {
    checks++;
    if (ok) printf("ok   %s\n", what);
    else { failures++; printf("FAIL %s\n", what); }
}

int main(void) {
    /* --- RFC 8439 section 2.6.2: the one-time Poly1305 key ----------------- */
    {
        static const uint8_t key[32] = {
            0x80,0x81,0x82,0x83,0x84,0x85,0x86,0x87,0x88,0x89,0x8a,0x8b,
            0x8c,0x8d,0x8e,0x8f,0x90,0x91,0x92,0x93,0x94,0x95,0x96,0x97,
            0x98,0x99,0x9a,0x9b,0x9c,0x9d,0x9e,0x9f };
        static const uint8_t nonce[12] = {
            0,0,0,0,0,1,2,3,4,5,6,7 };
        /* 8a, not 8b. The first transcription of this vector into the test
           had the first byte wrong by one bit, and the disagreement was real
           evidence rather than noise: thirty-one bytes matched, both full AEAD
           vectors passed, and an independent C implementation agreed with the
           assembly against the constant. The RFC's own hex dump settled it.

           A test vector copied out of a document is a transcription, and a
           transcription is a thing that can be wrong. Two implementations
           agreeing is what makes that detectable. */
        static const uint8_t want[32] = {
            0x8a,0xd5,0xa0,0x8b,0x90,0x5f,0x81,0xcc,0x81,0x50,0x40,0x27,
            0x4a,0xb2,0x94,0x71,0xa8,0x33,0xb6,0x37,0xe3,0xfd,0x0d,0xa5,
            0x08,0xdb,0xb8,0xe2,0xfd,0xd1,0xa6,0x46 };
        uint8_t block[64];
        memset(block, 0, sizeof block);
        cyboudb_chacha20_xor(key, 0, nonce, block, sizeof block);
        check("the one-time key is keystream block zero "
              "(RFC 8439 section 2.6.2)", memcmp(block, want, 32) == 0);
    }

    /* --- RFC 8439 section 2.8.2: the whole AEAD ---------------------------- */
    {
        static const uint8_t key[32] = {
            0x80,0x81,0x82,0x83,0x84,0x85,0x86,0x87,0x88,0x89,0x8a,0x8b,
            0x8c,0x8d,0x8e,0x8f,0x90,0x91,0x92,0x93,0x94,0x95,0x96,0x97,
            0x98,0x99,0x9a,0x9b,0x9c,0x9d,0x9e,0x9f };
        static const uint8_t nonce[12] = {
            0x07,0,0,0,0x40,0x41,0x42,0x43,0x44,0x45,0x46,0x47 };
        static const uint8_t aad[12] = {
            0x50,0x51,0x52,0x53,0xc0,0xc1,0xc2,0xc3,0xc4,0xc5,0xc6,0xc7 };
        static const char *plain =
            "Ladies and Gentlemen of the class of '99: If I could offer you "
            "only one tip for the future, sunscreen would be it.";
        static const uint8_t want_c[114] = {
            0xd3,0x1a,0x8d,0x34,0x64,0x8e,0x60,0xdb,0x7b,0x86,0xaf,0xbc,
            0x53,0xef,0x7e,0xc2,0xa4,0xad,0xed,0x51,0x29,0x6e,0x08,0xfe,
            0xa9,0xe2,0xb5,0xa7,0x36,0xee,0x62,0xd6,0x3d,0xbe,0xa4,0x5e,
            0x8c,0xa9,0x67,0x12,0x82,0xfa,0xfb,0x69,0xda,0x92,0x72,0x8b,
            0x1a,0x71,0xde,0x0a,0x9e,0x06,0x0b,0x29,0x05,0xd6,0xa5,0xb6,
            0x7e,0xcd,0x3b,0x36,0x92,0xdd,0xbd,0x7f,0x2d,0x77,0x8b,0x8c,
            0x98,0x03,0xae,0xe3,0x28,0x09,0x1b,0x58,0xfa,0xb3,0x24,0xe4,
            0xfa,0xd6,0x75,0x94,0x55,0x85,0x80,0x8b,0x48,0x31,0xd7,0xbc,
            0x3f,0xf4,0xde,0xf0,0x8e,0x4b,0x7a,0x9d,0xe5,0x76,0xd2,0x65,
            0x86,0xce,0xc6,0x4b,0x61,0x16 };
        static const uint8_t want_tag[16] = {
            0x1a,0xe1,0x0b,0x59,0x4f,0x09,0xe2,0x6a,
            0x7e,0x90,0x2e,0xcb,0xd0,0x60,0x06,0x91 };
        uint8_t buf[114], tag[16];
        cyboudb_aead_args a;

        memcpy(buf, plain, 114);
        a.key = key; a.nonce = nonce; a.aad = aad; a.aad_len = 12;
        a.buf = buf; a.buf_len = 114; a.tag = tag;
        cyboudb_chacha20poly1305_seal(&a);
        check("ChaCha20-Poly1305 produces RFC 8439 section 2.8.2's ciphertext",
              memcmp(buf, want_c, 114) == 0);
        check("and its tag", memcmp(tag, want_tag, 16) == 0);

        check("opening it gives the plaintext back",
              cyboudb_chacha20poly1305_open(&a) == 0 &&
              memcmp(buf, plain, 114) == 0);
    }

    /* --- the extended nonce: HChaCha20, section 2.2.1 ---------------------- */
    {
        uint8_t key[32], nonce[16], out[32];
        static const uint8_t want[32] = {
            0x82,0x41,0x3b,0x42,0x27,0xb2,0x7b,0xfe,0xd3,0x0e,0x42,0x50,
            0x8a,0x87,0x7d,0x73,0xa0,0xf9,0xe4,0xd5,0x8a,0x74,0xa8,0x53,
            0xc1,0x2e,0xc4,0x13,0x26,0xd3,0xec,0xdc };
        static const uint8_t n[16] = {
            0x00,0x00,0x00,0x09,0x00,0x00,0x00,0x4a,
            0x00,0x00,0x00,0x00,0x31,0x41,0x59,0x27 };
        int i;
        for (i = 0; i < 32; i++) key[i] = (uint8_t)i;
        memcpy(nonce, n, 16);
        cyboudb_hchacha20(key, nonce, out);
        check("HChaCha20 matches draft-irtf-cfrg-xchacha section 2.2.1",
              memcmp(out, want, 32) == 0);
    }

    /* --- AEAD_XCHACHA20_POLY1305, appendix A.3.1 --------------------------- */
    {
        static const uint8_t key[32] = {
            0x80,0x81,0x82,0x83,0x84,0x85,0x86,0x87,0x88,0x89,0x8a,0x8b,
            0x8c,0x8d,0x8e,0x8f,0x90,0x91,0x92,0x93,0x94,0x95,0x96,0x97,
            0x98,0x99,0x9a,0x9b,0x9c,0x9d,0x9e,0x9f };
        static const uint8_t nonce[24] = {
            0x40,0x41,0x42,0x43,0x44,0x45,0x46,0x47,0x48,0x49,0x4a,0x4b,
            0x4c,0x4d,0x4e,0x4f,0x50,0x51,0x52,0x53,0x54,0x55,0x56,0x57 };
        static const uint8_t aad[12] = {
            0x50,0x51,0x52,0x53,0xc0,0xc1,0xc2,0xc3,0xc4,0xc5,0xc6,0xc7 };
        static const char *plain =
            "Ladies and Gentlemen of the class of '99: If I could offer you "
            "only one tip for the future, sunscreen would be it.";
        static const uint8_t want_c[114] = {
            0xbd,0x6d,0x17,0x9d,0x3e,0x83,0xd4,0x3b,0x95,0x76,0x57,0x94,
            0x93,0xc0,0xe9,0x39,0x57,0x2a,0x17,0x00,0x25,0x2b,0xfa,0xcc,
            0xbe,0xd2,0x90,0x2c,0x21,0x39,0x6c,0xbb,0x73,0x1c,0x7f,0x1b,
            0x0b,0x4a,0xa6,0x44,0x0b,0xf3,0xa8,0x2f,0x4e,0xda,0x7e,0x39,
            0xae,0x64,0xc6,0x70,0x8c,0x54,0xc2,0x16,0xcb,0x96,0xb7,0x2e,
            0x12,0x13,0xb4,0x52,0x2f,0x8c,0x9b,0xa4,0x0d,0xb5,0xd9,0x45,
            0xb1,0x1b,0x69,0xb9,0x82,0xc1,0xbb,0x9e,0x3f,0x3f,0xac,0x2b,
            0xc3,0x69,0x48,0x8f,0x76,0xb2,0x38,0x35,0x65,0xd3,0xff,0xf9,
            0x21,0xf9,0x66,0x4c,0x97,0x63,0x7d,0xa9,0x76,0x88,0x12,0xf6,
            0x15,0xc6,0x8b,0x13,0xb5,0x2e };
        static const uint8_t want_tag[16] = {
            0xc0,0x87,0x59,0x24,0xc1,0xc7,0x98,0x79,
            0x47,0xde,0xaf,0xd8,0x78,0x0a,0xcf,0x49 };
        uint8_t buf[114], tag[16];
        cyboudb_aead_args a;

        memcpy(buf, plain, 114);
        a.key = key; a.nonce = nonce; a.aad = aad; a.aad_len = 12;
        a.buf = buf; a.buf_len = 114; a.tag = tag;
        cyboudb_xchacha20poly1305_seal(&a);
        check("XChaCha20-Poly1305 produces the draft's A.3.1 ciphertext",
              memcmp(buf, want_c, 114) == 0);
        check("and its tag", memcmp(tag, want_tag, 16) == 0);
        check("and opening it returns the plaintext",
              cyboudb_xchacha20poly1305_open(&a) == 0 &&
              memcmp(buf, plain, 114) == 0);
    }

    /* --- what the format actually asks of it ------------------------------- */
    {
        uint8_t key[32], nonce[24], aad[48], page[4096], copy[4096], tag[16];
        cyboudb_aead_args a;
        unsigned i;

        for (i = 0; i < 32; i++) key[i] = (uint8_t)(i * 5 + 1);
        for (i = 0; i < 24; i++) nonce[i] = (uint8_t)(i * 3 + 7);
        for (i = 0; i < 48; i++) aad[i] = (uint8_t)(i + 100);
        for (i = 0; i < 4096; i++) page[i] = copy[i] = (uint8_t)(i * 7);

        a.key = key; a.nonce = nonce; a.aad = aad; a.aad_len = 48;
        a.buf = page; a.buf_len = 4096; a.tag = tag;

        cyboudb_xchacha20poly1305_seal(&a);
        check("a sealed page does not look like the page",
              memcmp(page, copy, 4096) != 0);
        check("and opens back to it",
              cyboudb_xchacha20poly1305_open(&a) == 0 &&
              memcmp(page, copy, 4096) == 0);

        /* Every one of these is a page a reader must refuse. */
        cyboudb_xchacha20poly1305_seal(&a);
        {
            uint8_t sealed[4096], sealed_tag[16];
            memcpy(sealed, page, 4096);
            memcpy(sealed_tag, tag, 16);

            page[2000] ^= 1;
            check("a flipped ciphertext bit is refused",
                  cyboudb_xchacha20poly1305_open(&a) != 0);
            memcpy(page, sealed, 4096);

            tag[7] ^= 0x80;
            check("a flipped tag bit is refused",
                  cyboudb_xchacha20poly1305_open(&a) != 0);
            memcpy(tag, sealed_tag, 16);

            aad[10] ^= 0x20;
            check("associated data that changed is refused - this is what "
                  "stops a page being read at another page number",
                  cyboudb_xchacha20poly1305_open(&a) != 0);
            aad[10] ^= 0x20;

            nonce[3] ^= 0x40;
            check("and so is the wrong nonce",
                  cyboudb_xchacha20poly1305_open(&a) != 0);
            nonce[3] ^= 0x40;

            key[0] ^= 0x01;
            check("and the wrong key",
                  cyboudb_xchacha20poly1305_open(&a) != 0);
            key[0] ^= 0x01;

            /* And after all those refusals the page is still the ciphertext:
               a refused open must not have decrypted anything. */
            check("a refused open leaves the ciphertext untouched",
                  memcmp(page, sealed, 4096) == 0);
            check("while the right key, nonce and aad still open it",
                  cyboudb_xchacha20poly1305_open(&a) == 0 &&
                  memcmp(page, copy, 4096) == 0);
        }
    }

    /* An empty message and empty associated data are both legal. */
    {
        uint8_t key[32], nonce[24], tag[16];
        cyboudb_aead_args a;
        unsigned i;
        for (i = 0; i < 32; i++) key[i] = (uint8_t)(i + 9);
        for (i = 0; i < 24; i++) nonce[i] = (uint8_t)(i + 21);
        a.key = key; a.nonce = nonce; a.aad = NULL; a.aad_len = 0;
        a.buf = NULL; a.buf_len = 0; a.tag = tag;
        cyboudb_xchacha20poly1305_seal(&a);
        check("an empty message with no associated data still has a tag",
              cyboudb_xchacha20poly1305_open(&a) == 0);
        tag[0] ^= 1;
        check("and that tag is still checked",
              cyboudb_xchacha20poly1305_open(&a) != 0);
    }

    printf("\nAEAD suite: %d checks, %d failed\n", checks, failures);
    return failures ? 1 : 0;
}
