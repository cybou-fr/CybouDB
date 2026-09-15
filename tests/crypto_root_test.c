/* tests/crypto_root_test.c - the crypto root page and what refuses it
 *
 * A validator is only worth what its refusals are worth, so every check here
 * takes a page that the validator has just accepted, breaks exactly one thing,
 * and demands the specific refusal for that thing. A validator that returned a
 * single "bad" code would pass a weaker test and would make the engine lie:
 * "this file is damaged" and "this build cannot read this file" are different
 * sentences to a user, and neither of them is "this key is wrong".
 *
 * Build (Linux):   sh build.sh --crypto-tests && ./build/crypto_root_test
 * Build (Windows): build.bat --crypto-tests && build\crypto_root_test.exe
 *
 * SPDX-License-Identifier: Apache-2.0
 * Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
 */
#include <stdio.h>
#include <string.h>
#include <stdint.h>

/* include/crypto.inc holds the same numbers. */
#define PAGE_SIZE            4096
#define CROOT_MAGIC          0
#define CROOT_VERSION        4
#define CROOT_SEAL_EPOCH     8
#define CROOT_AEAD_ID        16
#define CROOT_KDF_ID         20
#define CROOT_SEAL_DIR_FIRST 24
#define CROOT_SEAL_DIR_PAGES 32
#define CROOT_SEAL_TREE_ROOT 40
#define CROOT_MANIFEST_ROOT  48
#define CROOT_TOTAL_PAGES    56
#define CROOT_SALT           64
#define CROOT_WRAPPED_ROOT   96
#define CROOT_SLOT_COUNT     168
#define CROOT_RESERVED       172
#define CROOT_SLOTS          176
#define CROOT_KEM_ROOT       4016
#define CROOT_RESERVED_TAIL  4024
#define CROOT_MAC            4032
#define CROOT_RESERVED_PAD   4048
#define CROOT_CRC            4092
#define CROOT_SLOT_SIZE      96
#define CROOT_SLOT_MAX       40
#define CSLOT_KEY_ID         0
#define CSLOT_PURPOSE        8
#define CSLOT_FLAGS          12
#define CSLOT_WRAPPED        16
#define CSLOT_RESERVED       88

#define CROOT_OK         0
#define CROOT_E_MAGIC    1
#define CROOT_E_VERSION  2
#define CROOT_E_CRC      3
#define CROOT_E_AEAD     4
#define CROOT_E_KDF      5
#define CROOT_E_GEOMETRY 6
#define CROOT_E_SLOTS    7
#define CROOT_E_RESERVED 8

/* include/constants.inc holds these. */
#define E_FEATURES     11
#define E_KEY          38
#define E_CRYPTO_ROOT  39
#define E_CRYPTO_CRC   40

#define WRAPPED_KEY_SIZE 72

int cyboudb_crypto_root_init(uint8_t *page, uint64_t seal_epoch,
                             uint64_t seal_dir_first, uint64_t seal_dir_pages,
                             uint64_t seal_tree_root, uint64_t total_pages);
int cyboudb_crypto_root_add_slot(uint8_t *page, uint64_t key_id,
                                 uint64_t purpose, const uint8_t *wrapped);
const uint8_t *cyboudb_crypto_root_find(const uint8_t *page, uint64_t key_id);
int cyboudb_crypto_root_validate(const uint8_t *page);
int cyboudb_crypto_root_status(int croot_err);
int cyboudb_key_status(int unwrap_rc);

static int checks, failures;

static void check(const char *what, int ok) {
    checks++;
    if (ok) printf("ok   %s\n", what);
    else { failures++; printf("FAIL %s\n", what); }
}

static uint64_t rd64(const uint8_t *p, int off) {
    uint64_t v; memcpy(&v, p + off, 8); return v;
}
static void wr64(uint8_t *p, int off, uint64_t v) { memcpy(p + off, &v, 8); }
static uint32_t rd32(const uint8_t *p, int off) {
    uint32_t v; memcpy(&v, p + off, 4); return v;
}
static void wr32(uint8_t *p, int off, uint32_t v) { memcpy(p + off, &v, 4); }

/* A file of 60,000 pages: the 240 MiB row of the overhead table in
   docs/ENCRYPTED_FORMAT.md, so the geometry here is one a real file has. */
#define TOTAL_PAGES 60000u
#define DIR_FIRST   3u
#define DIR_PAGES   600u
#define TREE_ROOT   1204u

static void good(uint8_t *page) {
    cyboudb_crypto_root_init(page, 7, DIR_FIRST, DIR_PAGES, TREE_ROOT,
                             TOTAL_PAGES);
}

/* Each case below breaks exactly one field of a valid page and repairs the
   CRC first, so the refusal reported is that field's own rather than the
   checksum's. The two cases that leave the CRC broken on purpose are the two
   that are about the CRC. */
uint32_t crc32c(const uint8_t *buf, uint64_t len);
static void repair_crc(uint8_t *page) {
    wr32(page, CROOT_CRC, crc32c(page, CROOT_CRC));
}

int main(void) {
    static uint8_t page[PAGE_SIZE];
    uint8_t wrapped[WRAPPED_KEY_SIZE];
    unsigned i;

    printf("CybouDB crypto root page test\n\n");

    for (i = 0; i < WRAPPED_KEY_SIZE; i++) wrapped[i] = (uint8_t)(i * 7 + 1);

    /* --- what init writes --------------------------------------------------- */
    memset(page, 0xCC, sizeof page);        /* init must not rely on a zeroed page */
    check("a freshly written crypto root validates",
          cyboudb_crypto_root_init(page, 7, DIR_FIRST, DIR_PAGES, TREE_ROOT,
                                   TOTAL_PAGES) == CROOT_OK);
    check("and it says which AEAD and KDF sealed the file",
          rd32(page, CROOT_AEAD_ID) == 1 && rd32(page, CROOT_KDF_ID) == 1);
    check("and carries the epoch and the geometry it was given",
          rd64(page, CROOT_SEAL_EPOCH) == 7 &&
          rd64(page, CROOT_SEAL_DIR_FIRST) == DIR_FIRST &&
          rd64(page, CROOT_SEAL_DIR_PAGES) == DIR_PAGES &&
          rd64(page, CROOT_SEAL_TREE_ROOT) == TREE_ROOT &&
          rd64(page, CROOT_TOTAL_PAGES) == TOTAL_PAGES);
    {
        int all_zero = 1;
        for (i = CROOT_SLOTS; i < CROOT_RESERVED_TAIL; i++)
            if (page[i]) all_zero = 0;
        check("and every byte it did not set is zero, not left over", all_zero &&
              rd32(page, CROOT_SLOT_COUNT) == 0 &&
              rd64(page, CROOT_WRAPPED_ROOT) == 0 &&
              rd64(page, CROOT_SALT) == 0);
    }

    /* --- the three sentences a user can be told apart ----------------------- */
    good(page);
    wr32(page, CROOT_MAGIC, 0x41424344);
    repair_crc(page);
    check("a page that is not a crypto root says so",
          cyboudb_crypto_root_validate(page) == CROOT_E_MAGIC);

    good(page);
    wr32(page, CROOT_VERSION, 2);
    repair_crc(page);
    check("a crypto root from a later build is refused by version, not guessed at",
          cyboudb_crypto_root_validate(page) == CROOT_E_VERSION);

    good(page);
    page[2000] ^= 0x01;                     /* a byte inside the CRC's range */
    check("a damaged page is damage, and is not blamed on the format",
          cyboudb_crypto_root_validate(page) == CROOT_E_CRC);

    good(page);
    wr32(page, CROOT_CRC, rd32(page, CROOT_CRC) ^ 0x01u);
    check("and so is a damaged CRC field itself",
          cyboudb_crypto_root_validate(page) == CROOT_E_CRC);

    /* --- an algorithm this build does not have ------------------------------ */
    good(page);
    wr32(page, CROOT_AEAD_ID, 2);
    repair_crc(page);
    check("a file sealed with an unknown AEAD is refused by name",
          cyboudb_crypto_root_validate(page) == CROOT_E_AEAD);

    good(page);
    wr32(page, CROOT_KDF_ID, 9);
    repair_crc(page);
    check("and one derived with an unknown KDF",
          cyboudb_crypto_root_validate(page) == CROOT_E_KDF);

    /* --- reserved means reserved -------------------------------------------- */
    good(page);
    wr32(page, CROOT_RESERVED, 1);
    repair_crc(page);
    check("a reserved word that is not zero is refused",
          cyboudb_crypto_root_validate(page) == CROOT_E_RESERVED);

    good(page);
    page[CROOT_RESERVED_TAIL + 3] = 0x01;
    repair_crc(page);
    check("and so is a reserved tail byte",
          cyboudb_crypto_root_validate(page) == CROOT_E_RESERVED);

    /* The first eight bytes of what used to be the reserved tail are now the
       key slot pointer, and they are geometry rather than reserved. */
    good(page);
    wr64(page, CROOT_KEM_ROOT, TOTAL_PAGES);
    repair_crc(page);
    check("a key slot page outside the file is refused",
          cyboudb_crypto_root_validate(page) == CROOT_E_GEOMETRY);

    good(page);
    wr64(page, CROOT_KEM_ROOT, 1);
    repair_crc(page);
    check("and one that would sit on a superblock",
          cyboudb_crypto_root_validate(page) == CROOT_E_GEOMETRY);

    good(page);
    wr64(page, CROOT_KEM_ROOT, 4000);
    repair_crc(page);
    check("while a real page is accepted",
          cyboudb_crypto_root_validate(page) == CROOT_OK);

    good(page);
    check("and zero means the file is sealed to no public key, which is legal",
          rd64(page, CROOT_KEM_ROOT) == 0 &&
          cyboudb_crypto_root_validate(page) == CROOT_OK);

    good(page);
    page[CROOT_RESERVED_PAD + 43] = 0x80;
    repair_crc(page);
    check("and the last byte before the CRC",
          cyboudb_crypto_root_validate(page) == CROOT_E_RESERVED);

    good(page);
    memset(page + CROOT_MAC, 0x5A, 16);
    repair_crc(page);
    check("while the MAC field is not reserved - it is filled in later",
          cyboudb_crypto_root_validate(page) == CROOT_OK);

    /* --- geometry that cannot be true --------------------------------------- */
    good(page);
    wr64(page, CROOT_SEAL_DIR_PAGES, 0);
    repair_crc(page);
    check("a seal directory of no pages is refused",
          cyboudb_crypto_root_validate(page) == CROOT_E_GEOMETRY);

    good(page);
    wr64(page, CROOT_SEAL_DIR_PAGES, TOTAL_PAGES);
    repair_crc(page);
    check("and one that does not fit in the file it describes",
          cyboudb_crypto_root_validate(page) == CROOT_E_GEOMETRY);

    good(page);
    wr64(page, CROOT_SEAL_DIR_FIRST, 1);
    repair_crc(page);
    check("and one that would start on top of a superblock",
          cyboudb_crypto_root_validate(page) == CROOT_E_GEOMETRY);

    good(page);
    wr64(page, CROOT_SEAL_DIR_PAGES, 0x8000000000000000ull);
    repair_crc(page);
    check("and a page count whose two copies overflow, rather than wrapping",
          cyboudb_crypto_root_validate(page) == CROOT_E_GEOMETRY);

    good(page);
    wr64(page, CROOT_SEAL_TREE_ROOT, 0);
    repair_crc(page);
    check("a seal tree with no root is refused - Decision 3b has no optional half",
          cyboudb_crypto_root_validate(page) == CROOT_E_GEOMETRY);

    good(page);
    wr64(page, CROOT_SEAL_TREE_ROOT, TOTAL_PAGES);
    repair_crc(page);
    check("and one outside the file",
          cyboudb_crypto_root_validate(page) == CROOT_E_GEOMETRY);

    good(page);
    wr64(page, CROOT_MANIFEST_ROOT, TOTAL_PAGES + 1);
    repair_crc(page);
    check("a manifest outside the file is refused",
          cyboudb_crypto_root_validate(page) == CROOT_E_GEOMETRY);

    good(page);
    wr64(page, CROOT_MANIFEST_ROOT, 0);
    repair_crc(page);
    check("while no manifest at all is legal until step 10",
          cyboudb_crypto_root_validate(page) == CROOT_OK);

    check("init itself refuses an impossible geometry",
          cyboudb_crypto_root_init(page, 0, DIR_FIRST, DIR_PAGES, TREE_ROOT, 10)
              == CROOT_E_GEOMETRY);

    /* --- slots --------------------------------------------------------------- */
    good(page);
    check("a scoped key can be added",
          cyboudb_crypto_root_add_slot(page, 0x1001, 4, wrapped) == 0 &&
          cyboudb_crypto_root_validate(page) == CROOT_OK);
    check("and found again by its id",
          cyboudb_crypto_root_find(page, 0x1001) != NULL &&
          memcmp(cyboudb_crypto_root_find(page, 0x1001) + CSLOT_WRAPPED,
                 wrapped, WRAPPED_KEY_SIZE) == 0);
    check("and an id that was never added is not found",
          cyboudb_crypto_root_find(page, 0x1002) == NULL);

    check("a second key with the same id is refused",
          cyboudb_crypto_root_add_slot(page, 0x1001, 4, wrapped) ==
              CROOT_E_SLOTS);
    check("a key id of zero is refused - zero is how an empty slot reads",
          cyboudb_crypto_root_add_slot(page, 0, 4, wrapped) == CROOT_E_SLOTS);
    check("and a purpose outside the closed list",
          cyboudb_crypto_root_add_slot(page, 0x2001, 6, wrapped) ==
              CROOT_E_SLOTS);
    check("the page is still valid after every refusal",
          cyboudb_crypto_root_validate(page) == CROOT_OK &&
          rd32(page, CROOT_SLOT_COUNT) == 1);

    good(page);
    {
        int ok = 1;
        for (i = 0; i < CROOT_SLOT_MAX; i++)
            if (cyboudb_crypto_root_add_slot(page, 0x100 + i, 1, wrapped) != 0)
                ok = 0;
        check("the table fills to its last slot", ok &&
              cyboudb_crypto_root_validate(page) == CROOT_OK);
        check("and one more is refused rather than written past the end",
              cyboudb_crypto_root_add_slot(page, 0x999, 1, wrapped) ==
                  CROOT_E_SLOTS);
    }

    /* Damage inside the slot table, with the CRC repaired so the validator has
       to find it by reading the table rather than by checksum. */
    good(page);
    cyboudb_crypto_root_add_slot(page, 0x1001, 4, wrapped);
    wr64(page, CROOT_SLOTS + CSLOT_KEY_ID, 0);
    repair_crc(page);
    check("a live slot with no key id is refused",
          cyboudb_crypto_root_validate(page) == CROOT_E_SLOTS);

    good(page);
    cyboudb_crypto_root_add_slot(page, 0x1001, 4, wrapped);
    cyboudb_crypto_root_add_slot(page, 0x1002, 4, wrapped);
    wr64(page, CROOT_SLOTS + CROOT_SLOT_SIZE + CSLOT_KEY_ID, 0x1001);
    repair_crc(page);
    check("two slots claiming one key id are refused",
          cyboudb_crypto_root_validate(page) == CROOT_E_SLOTS);

    good(page);
    cyboudb_crypto_root_add_slot(page, 0x1001, 4, wrapped);
    wr32(page, CROOT_SLOTS + CSLOT_PURPOSE, 7);
    repair_crc(page);
    check("a slot whose purpose is not in the list is refused",
          cyboudb_crypto_root_validate(page) == CROOT_E_SLOTS);

    /* Bit 0 is the recovery flag, which this build knows; bit 1 is not
       anything yet, and an unknown flag is refused rather than ignored - the
       same rule the format applies to feature bits. */
    good(page);
    cyboudb_crypto_root_add_slot(page, 0x1001, 4, wrapped);
    wr32(page, CROOT_SLOTS + CSLOT_FLAGS, 1);
    repair_crc(page);
    check("a slot flagged as a recovery slot is accepted",
          cyboudb_crypto_root_validate(page) == CROOT_OK);

    good(page);
    cyboudb_crypto_root_add_slot(page, 0x1001, 4, wrapped);
    wr32(page, CROOT_SLOTS + CSLOT_FLAGS, 2);
    repair_crc(page);
    check("and one with a flag this build does not know is refused",
          cyboudb_crypto_root_validate(page) == CROOT_E_SLOTS);

    good(page);
    cyboudb_crypto_root_add_slot(page, 0x1001, 4, wrapped);
    wr64(page, CROOT_SLOTS + CSLOT_RESERVED, 1);
    repair_crc(page);
    check("and one whose reserved word is not zero",
          cyboudb_crypto_root_validate(page) == CROOT_E_SLOTS);

    good(page);
    wr32(page, CROOT_SLOT_COUNT, CROOT_SLOT_MAX + 1);
    repair_crc(page);
    check("a slot count past the end of the table is refused",
          cyboudb_crypto_root_validate(page) == CROOT_E_SLOTS);

    /* The count is not the only thing that says how many keys there are: a
       slot left behind by a shrinking count would otherwise sit there, still
       wrapping a key, invisible to every check that trusts the count. */
    good(page);
    cyboudb_crypto_root_add_slot(page, 0x1001, 4, wrapped);
    cyboudb_crypto_root_add_slot(page, 0x1002, 4, wrapped);
    wr32(page, CROOT_SLOT_COUNT, 1);
    repair_crc(page);
    check("a key left past the count is refused, not quietly ignored",
          cyboudb_crypto_root_validate(page) == CROOT_E_SLOTS);

    /* --- what the user is told ---------------------------------------------
       The validator's codes are structural; these are the sentences. The
       property being tested is not that the mapping is clever but that it
       never reaches for E_KEY: not one of these situations is decidable with
       a key, so not one of them may be blamed on one. */
    check("a crypto root that is not one is metadata, not damage",
          cyboudb_crypto_root_status(CROOT_E_MAGIC) == E_CRYPTO_ROOT);
    check("a bad checksum is damage",
          cyboudb_crypto_root_status(CROOT_E_CRC) == E_CRYPTO_CRC);
    check("a newer version, AEAD or KDF is a feature this build lacks",
          cyboudb_crypto_root_status(CROOT_E_VERSION) == E_FEATURES &&
          cyboudb_crypto_root_status(CROOT_E_AEAD) == E_FEATURES &&
          cyboudb_crypto_root_status(CROOT_E_KDF) == E_FEATURES);
    check("impossible geometry and a contradictory slot table are metadata",
          cyboudb_crypto_root_status(CROOT_E_GEOMETRY) == E_CRYPTO_ROOT &&
          cyboudb_crypto_root_status(CROOT_E_SLOTS) == E_CRYPTO_ROOT &&
          cyboudb_crypto_root_status(CROOT_E_RESERVED) == E_CRYPTO_ROOT);
    check("a valid page is no error at all",
          cyboudb_crypto_root_status(CROOT_OK) == 0);
    {
        int e, ok = 1;
        for (e = 0; e < 64; e++)
            if (cyboudb_crypto_root_status(e) == E_KEY) ok = 0;
        check("and no structural refusal, known or not, is ever a key problem",
              ok);
        ok = 1;
        for (e = 1; e < 64; e++)
            if (cyboudb_crypto_root_status(e) == 0) ok = 0;
        check("while every refusal is some error - none of them passes as ok",
              ok);
    }

    check("a failed unwrap is the key, every time and without inspection",
          cyboudb_key_status(1) == E_KEY && cyboudb_key_status(-1) == E_KEY &&
          cyboudb_key_status(255) == E_KEY);
    check("and a successful one is not an error",
          cyboudb_key_status(0) == 0);

    printf("\ncrypto root suite: %d checks, %d failed\n", checks, failures);
    return failures ? 1 : 0;
}
