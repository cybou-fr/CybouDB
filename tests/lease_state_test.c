/* tests/lease_state_test.c - which lease states make a file valid.
 *
 * The validator decides which files exist, so it is the part that cannot be
 * revised later. `docs/QUEUE.md`, "What a valid file looks like, with leases
 * and without", is the table; this is what holds the engine to it, and it
 * matters now rather than after the first CLAIM is written, because the first
 * file that escapes with a lease field settles the question for every reader.
 *
 * Nothing in the engine writes a lease state yet. So every state here is
 * written by hand into a committed page and the page is resealed with an
 * independent CRC-32C, which is what makes each case prove its rule rather
 * than prove the checksum - a damaged page that no longer checksums is refused
 * long before anything reads what it says.
 *
 * The case worth naming is the second accepted one: **HELD with a non-zero
 * token**. The obvious rule - held means never claimed, so the token is zero -
 * is wrong, and it is wrong against a decision this design already made. NACK
 * raises the token, because without that a worker could hand a message back,
 * watch another worker take it, and then acknowledge the work it abandoned. So
 * `CLAIM 7; NACK` leaves the message HELD with token 8, and a validator
 * demanding zero there would forbid the state NACK is defined to produce. The
 * token is the slot's fencing history, not a property of being claimed.
 *
 * The other half is the conditional: the same bytes that are legal in a
 * database created with leases must be refused in one created without them.
 * Two databases, the same edits, opposite verdicts.
 *
 * Usage: lease_state_test <create-leases db> <create-large db>
 *
 * SPDX-License-Identifier: Apache-2.0
 * Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
 */
#include "cyboudb.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#include <windows.h>
#endif

void *cyboudb_test_mem_alloc(size_t size) { return malloc(size); }
void cyboudb_test_mem_free(void *ptr, size_t size) { (void)size; free(ptr); }

#define Q_HEAD_OFF      40
#define Q_TAIL_OFF      48
#define Q_CLAIM_OFF     56
#define Q_NAME_OFF      64
#define Q_TIME_FLOOR_OFF 120
#define Q_ENTRIES_OFF   128

#define QSEG_SLOTS_OFF  64
#define QSEG_CRC_OFF    4092
#define QUEUE_SLOT_SIZE 64
#define QMSG_STATE_OFF        8
#define QMSG_LEASE_UNTIL_OFF 16
#define QMSG_LEASE_TOKEN_OFF 24

#define STATE_HELD    0
#define STATE_CLAIMED 1
#define STATE_ACKED   2

extern int db_catalog_put_queue(void *ctx, uint64_t id, const void *image);
extern int db_catalog_get(void *ctx, uint64_t id, uint64_t *out_page);
extern unsigned char *db_queue_seg_addr(void *ctx, uint64_t page);
extern int db_commit(void *ctx);
extern void db_catalog_seal(void *page);
extern int db_queue_push(void *ctx, uint64_t id, const void *bytes,
                         uint64_t length);
extern int db_open(const void *path, void *ctx, uint64_t writable,
                   uint64_t verify);
extern int db_close(void *ctx);

static int failures = 0;
static int checks = 0;

static void check(const char *what, int ok) {
    checks++;
    if (ok) {
        printf("ok   %s\n", what);
    } else {
        failures++;
        printf("FAIL %s\n", what);
    }
}

/* An independent CRC-32C, so that a bug shared with the engine's assembly
   cannot make these pages look sealed to one side and not the other. */
static uint32_t crc32c(const unsigned char *data, size_t n) {
    uint32_t crc = 0xFFFFFFFFu;
    for (size_t i = 0; i < n; i++) {
        crc ^= data[i];
        for (int b = 0; b < 8; b++) {
            crc = (crc & 1) ? (crc >> 1) ^ 0x82F63B78u : crc >> 1;
        }
    }
    return crc ^ 0xFFFFFFFFu;
}

static void seal_segment(unsigned char *seg) {
    uint32_t c = crc32c(seg, QSEG_CRC_OFF);
    memcpy(seg + QSEG_CRC_OFF, &c, 4);
}

static uint64_t u64(const unsigned char *p, int off) {
    uint64_t v;
    memcpy(&v, p + off, 8);
    return v;
}

static void put64(unsigned char *p, int off, uint64_t v) {
    memcpy(p + off, &v, 8);
}

static void put32(unsigned char *p, int off, uint32_t v) {
    memcpy(p + off, &v, 4);
}

/* The integrity question rather than the recovery one: open with
   CybouDB_VERIFY_DEEP | CybouDB_VERIFY_INTEGRITY, which reports a damaged
   newest generation instead of quietly using the one before it. */
static int integrity_accepts(const char *path) {
    uint64_t vctx[512] = {0};
    const void *p = path;
#ifdef _WIN32
    static wchar_t wide[32768];
    if (!MultiByteToWideChar(CP_UTF8, 0, path, -1, wide, 32768)) return 0;
    p = wide;
#endif
    if (db_open(p, vctx, 0, 3) != 0) return 0;
    db_close(vctx);
    return 1;
}

/* One database's queue, filled and committed, with the addresses to poke. */
struct fixture {
    cyboudb_db *db;
    void *ctx;
    const char *path;
    unsigned char *qpage;
    unsigned char *seg;
};

static int open_fixture(struct fixture *f, const char *path, uint64_t id) {
    static unsigned char image[4096];
    uint64_t page = 0;
    f->db = NULL;
    f->path = path;
    if (cyboudb_open(path, CybouDB_OPEN_READWRITE, &f->db) != CybouDB_OK)
        return 0;
    f->ctx = f->db;
    memset(image, 0, sizeof image);
    strncpy((char *)image + Q_NAME_OFF, "leased", 31);
    if (db_catalog_put_queue(f->ctx, id, image) != 0) return 0;
    if (db_queue_push(f->ctx, id, "one", 3) != 0) return 0;
    if (db_queue_push(f->ctx, id, "two", 3) != 0) return 0;
    if (db_queue_push(f->ctx, id, "three", 5) != 0) return 0;
    if (db_commit(f->ctx) != CybouDB_OK) return 0;
    if (db_catalog_get(f->ctx, id, &page) != 0 || page == 0) return 0;
    f->qpage = db_queue_seg_addr(f->ctx, page);
    f->seg = db_queue_seg_addr(f->ctx, u64(f->qpage, Q_ENTRIES_OFF));
    return f->seg != NULL;
}

/* Write one slot's lease fields and reseal the page that holds them. */
static void set_slot(struct fixture *f, int slot, uint32_t state,
                     uint64_t deadline, uint64_t token) {
    unsigned char *s = f->seg + QSEG_SLOTS_OFF + slot * QUEUE_SLOT_SIZE;
    put32(s, QMSG_STATE_OFF, state);
    put64(s, QMSG_LEASE_UNTIL_OFF, deadline);
    put64(s, QMSG_LEASE_TOKEN_OFF, token);
    seal_segment(f->seg);
}

static void reset_slot(struct fixture *f, int slot) {
    set_slot(f, slot, STATE_HELD, 0, 0);
}

int main(int argc, char **argv) {
    struct fixture leased, plain;
    int i;

    if (argc < 3) {
        fprintf(stderr, "usage: lease_state_test <leases db> <ordinary db>\n");
        return 2;
    }
    setvbuf(stdout, NULL, _IONBF, 0);

    check("a queue in a database created with leases",
          open_fixture(&leased, argv[1], 710001));
    check("and one in a database created without them",
          open_fixture(&plain, argv[2], 710002));
    if (failures) return 2;

    check("both are intact to begin with",
          integrity_accepts(leased.path) && integrity_accepts(plain.path));

    /* --- what a leases database may carry --------------------------------- */
    {
        struct { const char *what; uint32_t state; uint64_t dl, tok;
                 int legal; } cases[] = {
          { "HELD with nothing set, which is what an ENQUEUE leaves",
            STATE_HELD,    0,    0, 1 },
          /* The one that the obvious rule gets wrong. */
          { "HELD with a token, which is what a NACK leaves",
            STATE_HELD,    0,    8, 1 },
          { "CLAIMED with a deadline and a token",
            STATE_CLAIMED, 1700000000000ULL, 1, 1 },
          { "ACKED keeping the token that finished it",
            STATE_ACKED,   0,    3, 1 },

          { "HELD with a deadline, which nobody is holding",
            STATE_HELD,    1700000000000ULL, 0, 0 },
          { "CLAIMED with no deadline, which would never lapse",
            STATE_CLAIMED, 0,    1, 0 },
          { "CLAIMED with no token, which no claim produces",
            STATE_CLAIMED, 1700000000000ULL, 0, 0 },
          { "ACKED with a zero token, the one value a forgery could guess",
            STATE_ACKED,   0,    0, 0 },
          { "ACKED with a deadline still on it",
            STATE_ACKED,   1700000000000ULL, 3, 0 },
          { "a fourth state nothing defines",
            3,             0,    1, 0 },
        };
        for (i = 0; i < (int)(sizeof cases / sizeof cases[0]); i++) {
            char label[200];
            int accepted;
            set_slot(&leased, 1, cases[i].state, cases[i].dl, cases[i].tok);
            accepted = integrity_accepts(leased.path);
            reset_slot(&leased, 1);
            snprintf(label, sizeof label, "%s is %s", cases[i].what,
                     cases[i].legal ? "accepted" : "refused");
            check(label, accepted == cases[i].legal);
        }
        check("and the queue is intact again afterwards",
              integrity_accepts(leased.path));
    }

    /* --- the conditional: the same bytes, the other database -------------- */
    {
        struct { const char *what; uint32_t state; uint64_t dl, tok; } same[] = {
          { "a claimed message",       STATE_CLAIMED, 1700000000000ULL, 1 },
          { "an acknowledged one",     STATE_ACKED,   0, 3 },
          { "a held one carrying a token", STATE_HELD, 0, 8 },
        };
        for (i = 0; i < (int)(sizeof same / sizeof same[0]); i++) {
            char label[200];
            int accepted;
            set_slot(&plain, 1, same[i].state, same[i].dl, same[i].tok);
            accepted = integrity_accepts(plain.path);
            reset_slot(&plain, 1);
            snprintf(label, sizeof label,
                     "%s is refused by a database created without leases",
                     same[i].what);
            check(label, !accepted);
        }
        check("which is otherwise intact", integrity_accepts(plain.path));
    }

    /* --- the cursor, and the clock's high-water --------------------------- */
    {
        uint64_t head = u64(leased.qpage, Q_HEAD_OFF);
        uint64_t tail = u64(leased.qpage, Q_TAIL_OFF);
        struct { const char *what; uint64_t claim; int legal; } cursor[] = {
          { "a claim cursor standing on the head",  0, 1 },
          { "one that has run ahead of it",         2, 1 },
          { "one standing on the tail",             3, 1 },
          { "one past the tail",                    4, 0 },
        };
        check("three messages, head at zero", head == 0 && tail == 3);
        for (i = 0; i < (int)(sizeof cursor / sizeof cursor[0]); i++) {
            char label[200];
            int accepted;
            put64(leased.qpage, Q_CLAIM_OFF, cursor[i].claim);
            db_catalog_seal(leased.qpage);
            accepted = integrity_accepts(leased.path);
            put64(leased.qpage, Q_CLAIM_OFF, head);
            db_catalog_seal(leased.qpage);
            snprintf(label, sizeof label, "%s is %s", cursor[i].what,
                     cursor[i].legal ? "accepted" : "refused");
            check(label, accepted == cursor[i].legal);
        }

        /* Having leases and having used them are different facts, so a clock
           that has never been read is as valid as one that has. */
        put64(leased.qpage, Q_TIME_FLOOR_OFF, 1700000000000ULL);
        db_catalog_seal(leased.qpage);
        check("a clock high-water is accepted where leases exist",
              integrity_accepts(leased.path));
        put64(plain.qpage, Q_TIME_FLOOR_OFF, 1700000000000ULL);
        db_catalog_seal(plain.qpage);
        check("and refused where they do not", !integrity_accepts(plain.path));
        put64(leased.qpage, Q_TIME_FLOOR_OFF, 0);
        db_catalog_seal(leased.qpage);
        put64(plain.qpage, Q_TIME_FLOOR_OFF, 0);
        db_catalog_seal(plain.qpage);
        check("both intact once it is put back",
              integrity_accepts(leased.path) && integrity_accepts(plain.path));
    }

    /* A claim cursor running ahead is the one thing a database without leases
       must keep refusing, because that is what preview.1 and preview.2 do and
       the bit is what tells them a file is not theirs to read. */
    {
        uint64_t head = u64(plain.qpage, Q_HEAD_OFF);
        put64(plain.qpage, Q_CLAIM_OFF, 2);
        db_catalog_seal(plain.qpage);
        check("a claim cursor ahead of the head is refused without leases",
              !integrity_accepts(plain.path));
        put64(plain.qpage, Q_CLAIM_OFF, head);
        db_catalog_seal(plain.qpage);
    }

    cyboudb_close(leased.db);
    cyboudb_close(plain.db);
    printf("\nLease state suite: %d passed, %d failed\n", checks - failures,
           failures);
    return failures ? 1 : 0;
}
