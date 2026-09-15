/* tests/key_slots_test.c - sealing a database to a public key
 *
 * Step 5 end to end: a root key sealed to an ML-KEM encapsulation key, and
 * opened again with the decapsulation key and with nothing else.
 *
 * The check that carries the design is the negative one. Every way of holding
 * the wrong thing - the wrong private key, an altered ciphertext, an altered
 * wrapping, the right slot presented as another database's - has to come back
 * as CybouDB_E_KEY, leaving zeroes rather than a plausible root. If any of
 * them came back as damage, an engine would tell someone with the wrong key
 * that their database is corrupt.
 *
 * Build (Linux):   sh build.sh --crypto-tests && ./build/key_slots_test
 * Build (Windows): build.bat --crypto-tests && build\key_slots_test.exe
 *
 * SPDX-License-Identifier: Apache-2.0
 * Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
 */
#include <stdio.h>
#include <string.h>
#include <stdint.h>

#define PAGE_SIZE 4096
#define EK_BYTES  1184
#define DK_BYTES  2400

#define KSLOT_KEY_ID   0
#define KSLOT_FLAGS    8
#define KSLOT_RESERVED 12
#define KSLOT_KEM_CT   16
#define KSLOT_WRAPPED  1104
#define KSLOT_SIZE     1176

#define KPAGE_MAGIC         0
#define KPAGE_VERSION       4
#define KPAGE_NEXT          16
#define KPAGE_SLOT_COUNT    32
#define KPAGE_RESERVED      40
#define KPAGE_SLOTS         64
#define KPAGE_RESERVED_TAIL 3592
#define KPAGE_CRC           4092
#define KEYPAGE_SLOTS       3

#define KEYPAGE_OK         0
#define KEYPAGE_E_MAGIC    1
#define KEYPAGE_E_VERSION  2
#define KEYPAGE_E_CRC      3
#define KEYPAGE_E_RESERVED 4
#define KEYPAGE_E_SLOTS    5

#define E_KEY 38

void cyboudb_mlkem_keygen(uint8_t *ek, uint8_t *dk, const uint8_t *d,
                          const uint8_t *z);
uint64_t cyboudb_kem_key_id(uint8_t *out, const uint8_t *ek);
int cyboudb_kem_seal_root(uint8_t *slot, const uint8_t *ek,
                          const uint8_t *root_key, uint64_t key_id,
                          const uint8_t *aad, uint64_t aad_len);
int cyboudb_kem_open_root(uint8_t *root_out, const uint8_t *slot,
                          const uint8_t *dk, const uint8_t *aad,
                          uint64_t aad_len);
void cyboudb_keypage_init(uint8_t *page, uint64_t index, uint64_t generation);
int cyboudb_keypage_add(uint8_t *page, const uint8_t *slot);
const uint8_t *cyboudb_keypage_find(const uint8_t *page, uint64_t key_id);
int cyboudb_keypage_validate(const uint8_t *page);
void cyboudb_sha3_256(uint8_t *out, const uint8_t *in, uint64_t in_len);
uint32_t crc32c(const uint8_t *buf, uint64_t len);

static int checks, failures;

static void check(const char *what, int ok) {
    checks++;
    if (ok) printf("ok   %s\n", what);
    else { failures++; printf("FAIL %s\n", what); }
}

static void wr32(uint8_t *p, int off, uint32_t v) { memcpy(p + off, &v, 4); }
static void wr64(uint8_t *p, int off, uint64_t v) { memcpy(p + off, &v, 8); }
static uint64_t rd64(const uint8_t *p, int off) {
    uint64_t v; memcpy(&v, p + off, 8); return v;
}
static void repair_crc(uint8_t *page) {
    wr32(page, KPAGE_CRC, crc32c(page, KPAGE_CRC));
}

static uint8_t ek[EK_BYTES], dk[DK_BYTES];
static uint8_t ek2[EK_BYTES], dk2[DK_BYTES];
static uint8_t slot[KSLOT_SIZE], slot2[KSLOT_SIZE], torn[KSLOT_SIZE];
static uint8_t page[PAGE_SIZE], scratch[PAGE_SIZE];

int main(void) {
    uint8_t d[32], z[32], root[32], out[32], zero[32], aad[24], other_aad[24];
    unsigned i;

    printf("CybouDB key slot test\n\n");

    for (i = 0; i < 32; i++) d[i] = (uint8_t)(i + 1);
    for (i = 0; i < 32; i++) z[i] = (uint8_t)(i * 2 + 7);
    for (i = 0; i < 32; i++) root[i] = (uint8_t)(i * 9 + 4);
    for (i = 0; i < 24; i++) aad[i] = (uint8_t)(i * 3 + 1);
    memcpy(other_aad, aad, 24);
    other_aad[0] ^= 0x20;               /* another database's uuid */
    memset(zero, 0, sizeof zero);

    cyboudb_mlkem_keygen(ek, dk, d, z);
    d[0] ^= 0x01;
    cyboudb_mlkem_keygen(ek2, dk2, d, z);
    d[0] ^= 0x01;

    /* --- the key id is a hint, and says so ---------------------------------- */
    {
        uint8_t id[8], digest[32];
        uint64_t as_number = cyboudb_kem_key_id(id, ek);
        cyboudb_sha3_256(digest, ek, EK_BYTES);
        check("the key id is the first eight bytes of H(ek)",
              memcmp(id, digest, 8) == 0);
        check("and the same value comes back as a number",
              memcmp(&as_number, digest, 8) == 0);

        cyboudb_kem_key_id(id, ek2);
        check("another key has another id", memcmp(id, digest, 8) != 0);
    }

    /* --- seal, then open ---------------------------------------------------- */
    check("a root key seals to a public key",
          cyboudb_kem_seal_root(slot, ek, root, 0x1234, aad, 24) == 0);
    check("and the slot says which key it is for",
          rd64(slot, KSLOT_KEY_ID) == 0x1234);
    check("and holds neither the root nor anything that looks like it",
          memcmp(slot + KSLOT_WRAPPED, root, 32) != 0 &&
          memcmp(slot + KSLOT_KEM_CT, root, 32) != 0);

    memset(out, 0xAA, sizeof out);
    check("the private key opens it",
          cyboudb_kem_open_root(out, slot, dk, aad, 24) == 0 &&
          memcmp(out, root, 32) == 0);

    /* Sealing the same root twice gives different slots - the KEM message is
       drawn per seal - and both open. */
    check("sealing twice gives different bytes",
          cyboudb_kem_seal_root(slot2, ek, root, 0x1234, aad, 24) == 0 &&
          memcmp(slot, slot2, KSLOT_SIZE) != 0);
    memset(out, 0xAA, sizeof out);
    check("and both open to the same root",
          cyboudb_kem_open_root(out, slot2, dk, aad, 24) == 0 &&
          memcmp(out, root, 32) == 0);

    /* --- every way of holding the wrong thing -------------------------------
       All of them CybouDB_E_KEY, all of them leaving zeroes. */
    memset(out, 0xAA, sizeof out);
    check("the wrong private key is refused",
          cyboudb_kem_open_root(out, slot, dk2, aad, 24) == E_KEY);
    check("and leaves zeroes rather than a plausible root",
          memcmp(out, zero, 32) == 0);

    memcpy(torn, slot, KSLOT_SIZE);
    torn[KSLOT_KEM_CT + 500] ^= 0x01;
    memset(out, 0xAA, sizeof out);
    check("an altered ciphertext is refused - and as a key, not as damage",
          cyboudb_kem_open_root(out, torn, dk, aad, 24) == E_KEY &&
          memcmp(out, zero, 32) == 0);

    memcpy(torn, slot, KSLOT_SIZE);
    torn[KSLOT_WRAPPED + 30] ^= 0x01;
    memset(out, 0xAA, sizeof out);
    check("an altered wrapping is refused",
          cyboudb_kem_open_root(out, torn, dk, aad, 24) == E_KEY &&
          memcmp(out, zero, 32) == 0);

    memset(out, 0xAA, sizeof out);
    check("the right slot presented as another database's is refused",
          cyboudb_kem_open_root(out, slot, dk, other_aad, 24) == E_KEY &&
          memcmp(out, zero, 32) == 0);

    /* The key id is bound into the KDF context, so a slot cannot be filed
       under a different id and still open. */
    memcpy(torn, slot, KSLOT_SIZE);
    wr64(torn, KSLOT_KEY_ID, 0x9999);
    memset(out, 0xAA, sizeof out);
    check("and so is a slot renamed to another key id",
          cyboudb_kem_open_root(out, torn, dk, aad, 24) == E_KEY &&
          memcmp(out, zero, 32) == 0);

    /* --- two keys, one database --------------------------------------------- */
    {
        uint8_t out2[32];
        check("the same root seals to a second public key",
              cyboudb_kem_seal_root(slot2, ek2, root, 0x5678, aad, 24) == 0);
        memset(out, 0xAA, sizeof out);
        memset(out2, 0xAA, sizeof out2);
        check("and each holder opens it with their own key",
              cyboudb_kem_open_root(out, slot, dk, aad, 24) == 0 &&
              cyboudb_kem_open_root(out2, slot2, dk2, aad, 24) == 0 &&
              memcmp(out, root, 32) == 0 && memcmp(out2, root, 32) == 0);
        check("while neither opens the other's slot",
              cyboudb_kem_open_root(out, slot2, dk, aad, 24) == E_KEY &&
              cyboudb_kem_open_root(out2, slot, dk2, aad, 24) == E_KEY);
    }

    /* --- the page the slots live in ----------------------------------------- */
    cyboudb_keypage_init(page, 0, 7);
    check("a fresh key slot page validates",
          cyboudb_keypage_validate(page) == KEYPAGE_OK);
    check("and holds no keys yet", rd64(page, KPAGE_SLOT_COUNT) == 0);

    check("a slot goes in",
          cyboudb_keypage_add(page, slot) == 0 &&
          cyboudb_keypage_validate(page) == KEYPAGE_OK);
    check("and comes back by its id",
          cyboudb_keypage_find(page, 0x1234) == page + KPAGE_SLOTS);
    check("while an id that was never added is not found",
          cyboudb_keypage_find(page, 0x1234u + 1) == NULL);

    check("and the slot found on the page still opens",
          cyboudb_kem_open_root(out, cyboudb_keypage_find(page, 0x1234), dk,
                                aad, 24) == 0 &&
          memcmp(out, root, 32) == 0);

    check("a second key id goes in beside it",
          cyboudb_keypage_add(page, slot2) == 0 &&
          rd64(page, KPAGE_SLOT_COUNT) == 2);
    check("and the same id twice is refused",
          cyboudb_keypage_add(page, slot) == KEYPAGE_E_SLOTS);

    {
        uint8_t third[KSLOT_SIZE], fourth[KSLOT_SIZE];
        memcpy(third, slot, KSLOT_SIZE);
        wr64(third, KSLOT_KEY_ID, 0x3333);
        memcpy(fourth, slot, KSLOT_SIZE);
        wr64(fourth, KSLOT_KEY_ID, 0x4444);
        check("the page fills at three",
              cyboudb_keypage_add(page, third) == 0 &&
              rd64(page, KPAGE_SLOT_COUNT) == KEYPAGE_SLOTS);
        check("and a fourth is refused rather than written past the end",
              cyboudb_keypage_add(page, fourth) == KEYPAGE_E_SLOTS &&
              cyboudb_keypage_validate(page) == KEYPAGE_OK);
    }

    /* --- structural refusals, which are damage and not keys ------------------ */
    cyboudb_keypage_init(page, 0, 7);
    cyboudb_keypage_add(page, slot);
    memcpy(scratch, page, PAGE_SIZE);

    wr32(page, KPAGE_MAGIC, 0x11223344);
    repair_crc(page);
    check("a page that is not a key slot page says so",
          cyboudb_keypage_validate(page) == KEYPAGE_E_MAGIC);

    memcpy(page, scratch, PAGE_SIZE);
    wr32(page, KPAGE_VERSION, 9);
    repair_crc(page);
    check("a key slot page from a later build is refused by version",
          cyboudb_keypage_validate(page) == KEYPAGE_E_VERSION);

    memcpy(page, scratch, PAGE_SIZE);
    page[900] ^= 0x01;
    check("a damaged page is damage",
          cyboudb_keypage_validate(page) == KEYPAGE_E_CRC);

    memcpy(page, scratch, PAGE_SIZE);
    page[KPAGE_RESERVED + 5] = 0x01;
    repair_crc(page);
    check("a non-zero reserved field is refused",
          cyboudb_keypage_validate(page) == KEYPAGE_E_RESERVED);

    memcpy(page, scratch, PAGE_SIZE);
    page[KPAGE_RESERVED_TAIL + 400] = 0x01;
    repair_crc(page);
    check("and so is a byte in the space after the slots",
          cyboudb_keypage_validate(page) == KEYPAGE_E_RESERVED);

    memcpy(page, scratch, PAGE_SIZE);
    wr64(page, KPAGE_SLOT_COUNT, KEYPAGE_SLOTS + 1);
    repair_crc(page);
    check("a slot count past the end of the page is refused",
          cyboudb_keypage_validate(page) == KEYPAGE_E_SLOTS);

    memcpy(page, scratch, PAGE_SIZE);
    wr64(page, KPAGE_SLOTS + KSLOT_KEY_ID, 0);
    repair_crc(page);
    check("a live slot with no key id is refused",
          cyboudb_keypage_validate(page) == KEYPAGE_E_SLOTS);

    memcpy(page, scratch, PAGE_SIZE);
    wr32(page, KPAGE_SLOTS + KSLOT_FLAGS, 1);
    repair_crc(page);
    check("and a flag this build does not know",
          cyboudb_keypage_validate(page) == KEYPAGE_E_SLOTS);

    /* A key removed by lowering the count would otherwise sit there, still
       wrapping the root, invisible to everything that trusts the count. */
    cyboudb_keypage_init(page, 0, 7);
    cyboudb_keypage_add(page, slot);
    cyboudb_keypage_add(page, slot2);
    wr64(page, KPAGE_SLOT_COUNT, 1);
    repair_crc(page);
    check("a key left past the count is refused, not quietly ignored",
          cyboudb_keypage_validate(page) == KEYPAGE_E_SLOTS);

    printf("\nkey slot suite: %d checks, %d failed\n", checks, failures);
    return failures ? 1 : 0;
}
