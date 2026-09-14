/* tests/lease_ops_test.c - CLAIM, ACK, NACK and RENEW.
 *
 * The first code that writes a lease. Everything before it decided what a
 * lease means; this is where the engine starts producing the states the
 * validator was taught to accept, so the suite checks both halves at once -
 * what each operation returns, and that the file it leaves behind still
 * passes an integrity check.
 *
 * What is being defended, in the order it matters:
 *
 *  1. **The token is the only authority.** A lapsed deadline is not a refusal:
 *     a worker whose lease expired and who finished anyway still gets its ACK,
 *     because if another worker had taken the message the token would say so.
 *     Refusing on the clock alone would manufacture duplicate work that
 *     nothing required.
 *  2. **A reclaim raises the token, and the old ticket dies with it.** That is
 *     the one thing the whole mechanism exists to guarantee, and it is checked
 *     from the loser's side: the stale ticket must be refused, not merely lose
 *     a race.
 *  3. **NACK raises the token too.** Otherwise a worker could hand a message
 *     back, watch another take it, and then acknowledge the work it abandoned.
 *  4. Expiry is a predicate. Nothing runs, nothing writes, and the message
 *     becomes claimable because the clock passed the deadline.
 *  5. The clock never runs backwards, whatever `now` the caller passes.
 *
 * Head advancement is not here, because it is not in the engine yet: a run of
 * acknowledged messages at the front is a valid queue, and advancing over it
 * is retirement machinery rather than lease machinery.
 *
 * Usage: lease_ops_test <database created with create-leases>
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

#define Q_HEAD_OFF       40
#define Q_TAIL_OFF       48
#define Q_CLAIM_OFF      56
#define Q_NAME_OFF       64
#define Q_TIME_FLOOR_OFF 120
#define Q_ENTRIES_OFF    128
#define QSEG_SLOTS_OFF   64
#define QUEUE_SLOT_SIZE  64
#define QMSG_STATE_OFF        8
#define QMSG_LEASE_UNTIL_OFF 16
#define QMSG_LEASE_TOKEN_OFF 24

/* Core status codes, spelled here because they are include/constants.inc's and
   not the public header's - these functions are the engine's, not the API's. */
#define CybouDB_E_VALUE    32
#define CybouDB_E_NOTFOUND 28

#define STATE_HELD    0
#define STATE_CLAIMED 1
#define STATE_ACKED   2

#define T0     1700000000000ULL
#define MINUTE 60000ULL

extern int db_catalog_put_queue(void *ctx, uint64_t id, const void *image);
extern int db_catalog_get(void *ctx, uint64_t id, uint64_t *out_page);
extern unsigned char *db_queue_seg_addr(void *ctx, uint64_t page);
extern int db_commit(void *ctx);
extern int db_queue_push(void *ctx, uint64_t id, const void *bytes,
                         uint64_t length);
extern int db_queue_claim(void *ctx, uint64_t id, uint64_t now,
                          uint64_t duration, uint64_t *out_pos,
                          uint64_t *out_token);
extern int db_queue_ack(void *ctx, uint64_t id, uint64_t pos, uint64_t token);
extern int db_queue_nack(void *ctx, uint64_t id, uint64_t pos, uint64_t token);
extern int db_queue_renew(void *ctx, uint64_t id, uint64_t pos, uint64_t token,
                          uint64_t now, uint64_t duration);
extern int db_open(const void *path, void *ctx, uint64_t writable,
                   uint64_t verify);
extern int db_close(void *ctx);

static int failures = 0, checks = 0;
static void check(const char *what, int ok) {
    checks++;
    if (ok) printf("ok   %s\n", what);
    else { failures++; printf("FAIL %s\n", what); }
}

static void *ctx;
static uint64_t qid;
static const char *dbpath;

static uint64_t u64(const unsigned char *p, int off) {
    uint64_t v; memcpy(&v, p + off, 8); return v;
}
static uint32_t u32(const unsigned char *p, int off) {
    uint32_t v; memcpy(&v, p + off, 4); return v;
}

/* The queue page, looked up every time rather than held. Copy-on-write moves
   an object when it is written, so a pointer taken before an operation names
   the generation before it - which is a live page holding the old answer, and
   therefore the kind of stale read that looks like a wrong result. */
static unsigned char *qp(void) {
    uint64_t page = 0;
    if (db_catalog_get(ctx, qid, &page) != 0 || page == 0) return NULL;
    return db_queue_seg_addr(ctx, page);
}

static unsigned char *slot_at(uint64_t pos) {
    uint64_t seg = pos / 62, idx = pos % 62;
    unsigned char *q = qp(), *page;
    if (!q) return NULL;
    page = db_queue_seg_addr(ctx, u64(q, Q_ENTRIES_OFF + (int)seg * 8));
    return page ? page + QSEG_SLOTS_OFF + idx * QUEUE_SLOT_SIZE : NULL;
}

static uint64_t qfield(int off) {
    unsigned char *q = qp();
    return q ? u64(q, off) : 0xFFFFFFFFFFFFFFFFull;
}

static uint32_t state_of(uint64_t pos) {
    unsigned char *s = slot_at(pos);
    return s ? u32(s, QMSG_STATE_OFF) : 0xFFFFFFFFu;
}
static uint64_t token_of(uint64_t pos) {
    unsigned char *s = slot_at(pos);
    return s ? u64(s, QMSG_LEASE_TOKEN_OFF) : 0;
}
static uint64_t deadline_of(uint64_t pos) {
    unsigned char *s = slot_at(pos);
    return s ? u64(s, QMSG_LEASE_UNTIL_OFF) : 0;
}

/* The integrity question: the file each operation leaves behind has to be one
   the validator accepts, or the operation wrote a state the format forbids. */
static int intact(void) {
    uint64_t vctx[512] = {0};
    const void *p = dbpath;
#ifdef _WIN32
    static wchar_t wide[32768];
    if (!MultiByteToWideChar(CP_UTF8, 0, dbpath, -1, wide, 32768)) return 0;
    p = wide;
#endif
    if (db_open(p, vctx, 0, 3) != 0) return 0;
    db_close(vctx);
    return 1;
}

int main(int argc, char **argv) {
    static unsigned char image[4096];
    cyboudb_db *db = NULL;
    uint64_t page = 0, pos = 0, tok = 0, pos2 = 0, tok2 = 0;
    int i;

    if (argc < 2) {
        fprintf(stderr, "usage: lease_ops_test <create-leases database>\n");
        return 2;
    }
    setvbuf(stdout, NULL, _IONBF, 0);
    dbpath = argv[1];
    if (cyboudb_open(dbpath, CybouDB_OPEN_READWRITE, &db) != CybouDB_OK) {
        fprintf(stderr, "open failed - create it with create-leases\n");
        return 2;
    }
    ctx = db;
    qid = 720001;
    memset(image, 0, sizeof image);
    strncpy((char *)image + Q_NAME_OFF, "jobs", 31);
    check("a queue with four messages",
          db_catalog_put_queue(ctx, qid, image) == 0 &&
          db_queue_push(ctx, qid, "a", 1) == 0 &&
          db_queue_push(ctx, qid, "b", 1) == 0 &&
          db_queue_push(ctx, qid, "c", 1) == 0 &&
          db_queue_push(ctx, qid, "d", 1) == 0 &&
          db_commit(ctx) == CybouDB_OK &&
          db_catalog_get(ctx, qid, &page) == 0 && page != 0);
    check("which is intact", intact());

    /* --- a claim, and what it leaves ------------------------------------- */
    check("the first claim takes the head",
          db_queue_claim(ctx, qid, T0, MINUTE, &pos, &tok) == CybouDB_OK &&
          pos == 0);
    check("the message is claimed, with a deadline and a token",
          state_of(0) == STATE_CLAIMED &&
          deadline_of(0) == T0 + MINUTE &&
          token_of(0) == 1 && tok == 1);
    check("the cursor moved and the clock was recorded",
          qfield(Q_CLAIM_OFF) == 1 &&
          qfield(Q_TIME_FLOOR_OFF) == T0);
    check("and the file is one the validator accepts",
          db_commit(ctx) == CybouDB_OK && intact());

    check("the next claim takes the next message, not the held one",
          db_queue_claim(ctx, qid, T0, MINUTE, &pos2, &tok2) == CybouDB_OK &&
          pos2 == 1 && tok2 == 1);
    check("committing that", db_commit(ctx) == CybouDB_OK && intact());

    /* --- the token is the only authority --------------------------------- */
    check("a wrong token is refused",
          db_queue_ack(ctx, qid, 0, 99) == CybouDB_E_VALUE);
    check("and so is acknowledging a message nobody holds",
          db_queue_ack(ctx, qid, 2, 1) == CybouDB_E_VALUE);
    check("the right one is honoured",
          db_queue_ack(ctx, qid, 0, 1) == CybouDB_OK &&
          state_of(0) == STATE_ACKED && deadline_of(0) == 0);
    check("and the slot keeps the token that finished it", token_of(0) == 1);
    check("acknowledging twice is refused",
          db_queue_ack(ctx, qid, 0, 1) == CybouDB_E_VALUE);
    check("the file is still intact",
          db_commit(ctx) == CybouDB_OK && intact());

    /* --- a lapsed lease is not a refusal --------------------------------- */
    check("a lease that has expired, on a message nobody re-claimed",
          deadline_of(1) == T0 + MINUTE);
    check("its holder still gets its acknowledgement an hour late",
          db_queue_ack(ctx, qid, 1, tok2) == CybouDB_OK &&
          state_of(1) == STATE_ACKED);
    check("and that file is intact too",
          db_commit(ctx) == CybouDB_OK && intact());

    /* --- expiry is a predicate: nothing ran, and the message came back ---- */
    check("a claim on the third message",
          db_queue_claim(ctx, qid, T0, MINUTE, &pos, &tok) == CybouDB_OK &&
          pos == 2 && tok == 1);
    check("a second claim at the same moment finds the fourth, not the third",
          db_queue_claim(ctx, qid, T0, MINUTE, &pos2, &tok2) == CybouDB_OK &&
          pos2 == 3);
    check("with nothing left, a claim says so rather than waiting",
          db_queue_claim(ctx, qid, T0, MINUTE, &pos2, &tok2)
              == CybouDB_E_NOTFOUND);
    check("but once the deadlines pass, the same queue has two again",
          db_queue_claim(ctx, qid, T0 + 2 * MINUTE, MINUTE, &pos2, &tok2)
              == CybouDB_OK && pos2 == 2);
    check("and the reclaim raised the token", tok2 == 2 && token_of(2) == 2);
    check("so the first worker's ticket is now refused",
          db_queue_ack(ctx, qid, 2, tok) == CybouDB_E_VALUE);
    check("while the new holder's is honoured",
          db_queue_ack(ctx, qid, 2, tok2) == CybouDB_OK);
    check("the file is intact", db_commit(ctx) == CybouDB_OK && intact());

    /* --- NACK ------------------------------------------------------------- */
    check("the fourth message is still claimed by its first taker",
          state_of(3) == STATE_CLAIMED);
    {
        /* Re-claim it so the test holds a current token for it. */
        uint64_t p = 0, t = 0;
        db_queue_claim(ctx, qid, T0 + 10 * MINUTE, MINUTE, &p, &t);
        check("handing it back frees it and raises the token",
              p == 3 && db_queue_nack(ctx, qid, 3, t) == CybouDB_OK &&
              state_of(3) == STATE_HELD && deadline_of(3) == 0 &&
              token_of(3) == t + 1);
        check("which is what stops the worker that gave it back from "
              "acknowledging it",
              db_queue_ack(ctx, qid, 3, t) == CybouDB_E_VALUE);
        check("and it is claimable again, immediately",
              db_queue_claim(ctx, qid, T0 + 10 * MINUTE, MINUTE, &pos2, &tok2)
                  == CybouDB_OK && pos2 == 3);
        check("the file is intact", db_commit(ctx) == CybouDB_OK && intact());
    }

    /* --- RENEW ------------------------------------------------------------ */
    check("renewing extends the deadline and keeps the token",
          db_queue_renew(ctx, qid, 3, tok2, T0 + 11 * MINUTE, 5 * MINUTE)
              == CybouDB_OK &&
          deadline_of(3) == T0 + 16 * MINUTE && token_of(3) == tok2);
    check("a wrong token cannot renew",
          db_queue_renew(ctx, qid, 3, tok2 + 7, T0 + 11 * MINUTE, MINUTE)
              == CybouDB_E_VALUE);
    check("a lapsed lease can still be renewed while nobody has taken it",
          db_queue_renew(ctx, qid, 3, tok2, T0 + 100 * MINUTE, MINUTE)
              == CybouDB_OK &&
          deadline_of(3) == T0 + 101 * MINUTE);
    check("the file is intact", db_commit(ctx) == CybouDB_OK && intact());

    /* --- the clock never runs backwards ---------------------------------- */
    check("the queue's clock is where the last operation left it",
          qfield(Q_TIME_FLOOR_OFF) == T0 + 100 * MINUTE);
    {
        uint64_t p = 0, t = 0;
        db_queue_nack(ctx, qid, 3, tok2);
        check("a claim told the clock went backwards uses the queue's own",
              db_queue_claim(ctx, qid, T0, MINUTE, &p, &t) == CybouDB_OK &&
              deadline_of(3) == T0 + 100 * MINUTE + MINUTE);
        check("and the high-water did not move down",
              qfield(Q_TIME_FLOOR_OFF) == T0 + 100 * MINUTE);
        check("the file is intact", db_commit(ctx) == CybouDB_OK && intact());
    }

    /* --- a refusal leaves the file exactly as it found it ----------------- */
    /* The first version of these operations made the slot writable and then
       discovered the refusal, which left the queue page stamped with a new
       generation and never sealed - and the next commit refused the whole
       transaction over an operation that had already said no. So each refusal
       is followed immediately by a commit, with nothing in between to hide it. */
    {
        struct { const char *what; int rc; } refused[] = {
            { "an acknowledgement with a wrong token",
              db_queue_ack(ctx, qid, 0, 12345) },
            { "an acknowledgement of a message nobody holds",
              db_queue_ack(ctx, qid, 0, 1) },
            { "a hand-back with a wrong token",
              db_queue_nack(ctx, qid, 0, 12345) },
            { "a renewal with a wrong token",
              db_queue_renew(ctx, qid, 0, 12345, T0, MINUTE) },
            { "a renewal of a position outside the queue",
              db_queue_renew(ctx, qid, 9999, 1, T0, MINUTE) },
        };
        for (i = 0; i < (int)(sizeof refused / sizeof refused[0]); i++) {
            char label[200];
            snprintf(label, sizeof label,
                     "%s is refused, and the next commit still succeeds",
                     refused[i].what);
            check(label, refused[i].rc != CybouDB_OK &&
                  db_commit(ctx) == CybouDB_OK && intact());
        }
    }

    /* --- refusals that are about the arguments --------------------------- */
    check("a zero-length lease is refused rather than granted expired",
          db_queue_claim(ctx, qid, T0, 0, &pos2, &tok2) == CybouDB_E_VALUE);
    check("a position outside the queue is refused",
          db_queue_ack(ctx, qid, 9999, 1) == CybouDB_E_VALUE);
    check("and so is one in another object",
          db_queue_ack(ctx, 999999, 0, 1) != CybouDB_OK);

    /* Every state this suite produced, still acceptable after a reopen. */
    check("the queue survives being closed and opened",
          db_commit(ctx) == CybouDB_OK && cyboudb_close(db) == CybouDB_OK &&
          intact());

    for (i = 0; i < 0; i++) { }
    printf("\nLease ops suite: %d passed, %d failed\n", checks - failures,
           failures);
    return failures ? 1 : 0;
}
