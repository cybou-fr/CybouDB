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
#include <time.h>
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
#define Q_SEGMENTS_OFF   36
#define Q_FIRST_SEG_OFF  96
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
/* A lease refusal has a code of its own: the message is not claimed, or the
   token is not the one the current claim has. Routine rather than a
   programming error - it is what a worker whose lease was reclaimed is told. */
#define CybouDB_E_LEASE    37

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
extern int db_queue_depth(void *ctx, uint64_t id, uint64_t *out);
extern uint64_t db_bitmap_headroom(void *ctx);
extern uint64_t os_wall_ms(void);

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
/* The feature mask a file was created with, read the way anything else reads
   it: eight bytes at offset 16 of the header. */
static int feature_mask(const char *path, uint64_t *out) {
    unsigned char head[24];
    FILE *f = fopen(path, "rb");
    if (!f) return 0;
    if (fread(head, 1, sizeof head, f) != sizeof head) { fclose(f); return 0; }
    fclose(f);
    memcpy(out, head + 16, 8);
    return 1;
}

#define FEATURE_QUEUE_LEASES 65536ULL

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

    /* --- the clock the deadlines are on ----------------------------------- */
    /* The one new platform primitive leases needed. Both sides have to answer
       with the same number for the same instant, or a database written on one
       is a database whose deadlines mean something else on the other - so the
       check is against the C library's idea of the time rather than against
       the other implementation. */
    {
        uint64_t a = os_wall_ms();
        time_t t = time(NULL);
        uint64_t b = os_wall_ms();
        uint64_t from_libc = (uint64_t)t * 1000ULL;
        check("the wall clock is a plausible millisecond timestamp",
              a > 1600000000000ULL && a < 4000000000000ULL);
        check("and agrees with the system clock to within a second",
              (a > from_libc ? a - from_libc : from_libc - a) < 2000ULL);
        check("and does not run backwards between two reads", b >= a);
    }

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
          db_queue_ack(ctx, qid, 0, 99) == CybouDB_E_LEASE);
    check("and so is acknowledging a message nobody holds",
          db_queue_ack(ctx, qid, 2, 1) == CybouDB_E_LEASE);
    check("the right one is honoured",
          db_queue_ack(ctx, qid, 0, 1) == CybouDB_OK &&
          state_of(0) == STATE_ACKED && deadline_of(0) == 0);
    check("and the slot keeps the token that finished it", token_of(0) == 1);
    check("acknowledging twice is refused",
          db_queue_ack(ctx, qid, 0, 1) == CybouDB_E_LEASE);
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
          db_queue_ack(ctx, qid, 2, tok) == CybouDB_E_LEASE);
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
              db_queue_ack(ctx, qid, 3, t) == CybouDB_E_LEASE);
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
              == CybouDB_E_LEASE);
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
          db_queue_ack(ctx, qid, 9999, 1) == CybouDB_E_LEASE);
    check("and so is one in another object",
          db_queue_ack(ctx, 999999, 0, 1) != CybouDB_OK);

    /* --- the head moves over what is finished ---------------------------- */
    /* Acknowledgement can arrive out of order, so the head moves over a *run*
       rather than one message at a time. And what the head passes is what the
       queue gives back: the bytes each message owned and the segments left
       entirely behind. Without that a queue reclaims nothing it acknowledges
       and fills up at 30,690 whatever a worker does. */
    {
        uint64_t qid2 = 720002, p0, p1, p2, t0, t1, t2;
        uint64_t after = 0;
        memset(image, 0, sizeof image);
        strncpy((char *)image + Q_NAME_OFF, "run", 31);
        check("a second queue with three messages",
              db_catalog_put_queue(ctx, qid2, image) == 0 &&
              db_queue_push(ctx, qid2, "x", 1) == 0 &&
              db_queue_push(ctx, qid2, "y", 1) == 0 &&
              db_queue_push(ctx, qid2, "z", 1) == 0 &&
              db_commit(ctx) == CybouDB_OK);
        qid = qid2;

        check("three claims take all three",
              db_queue_claim(ctx, qid2, T0, MINUTE, &p0, &t0) == CybouDB_OK &&
              db_queue_claim(ctx, qid2, T0, MINUTE, &p1, &t1) == CybouDB_OK &&
              db_queue_claim(ctx, qid2, T0, MINUTE, &p2, &t2) == CybouDB_OK &&
              p0 == 0 && p1 == 1 && p2 == 2);

        check("acknowledging the middle one leaves the head where it was",
              db_queue_ack(ctx, qid2, 1, t1) == CybouDB_OK &&
              qfield(Q_HEAD_OFF) == 0);
        check("and so does the last",
              db_queue_ack(ctx, qid2, 2, t2) == CybouDB_OK &&
              qfield(Q_HEAD_OFF) == 0);
        check("acknowledging the first moves it over all three at once",
              db_queue_ack(ctx, qid2, 0, t0) == CybouDB_OK &&
              qfield(Q_HEAD_OFF) == 3 && qfield(Q_TAIL_OFF) == 3);
        check("the drained queue names no segment",
              u32(qp(), Q_SEGMENTS_OFF) == 0);
        check("and reports itself empty",
              db_queue_depth(ctx, qid2, &after) == 0 && after == 0);
        check("the file is intact", db_commit(ctx) == CybouDB_OK && intact());
    }

    /* --- the segment pages themselves are given back --------------------- */
    /* The directory forgetting a segment and the file getting its page back
       are different facts, and the endurance run below only establishes the
       second for extent chains: there are too few segments among 2,400
       messages for leaking every one of them to exhaust anything.

       Asking whether a particular page is still payload does not separate them
       either, because copy-on-write retires the page a claim rewrote whether
       or not the head ever passes it - a check on that answers yes for the
       wrong reason.

       What does separate them is how much room the file has. Ten segments'
       worth of messages, all inline so that no extent chain clouds the
       arithmetic, drained in one go: headroom counts what is reusable, so it
       rises by the segments only if the segments came back. */
    {
        uint64_t qid4 = 720004, p4 = 0, t4 = 0, room_full = 0, room_empty = 0;
        int k4, ok4 = 1;
        memset(image, 0, sizeof image);
        strncpy((char *)image + Q_NAME_OFF, "tensegs", 31);
        check("a queue of ten segments",
              db_catalog_put_queue(ctx, qid4, image) == 0);
        qid = qid4;
        for (k4 = 0; k4 < 620 && ok4; k4++) {
            if (db_queue_push(ctx, qid4, "m", 1) != 0) ok4 = 0;
        }
        check("six hundred and twenty messages in it",
              ok4 && db_commit(ctx) == CybouDB_OK &&
              u32(qp(), Q_SEGMENTS_OFF) == 10);
        room_full = db_bitmap_headroom(ctx);

        for (k4 = 0; k4 < 620 && ok4; k4++) {
            if (db_queue_claim(ctx, qid4, T0, MINUTE, &p4, &t4) != 0) ok4 = 0;
            else if (db_queue_ack(ctx, qid4, p4, t4) != 0) ok4 = 0;
        }
        check("claimed and acknowledged, every one of them",
              ok4 && db_commit(ctx) == CybouDB_OK);
        check("leaves a queue holding nothing",
              qfield(Q_HEAD_OFF) == qfield(Q_TAIL_OFF) &&
              u32(qp(), Q_SEGMENTS_OFF) == 0);
        room_empty = db_bitmap_headroom(ctx);
        check("and the file with its ten segments' worth of room back",
              room_empty >= room_full + 10);
        check("the file is intact", intact());
    }

    /* --- and the extent chains come back --------------------------------- */
    /* The other half of what the head passes: a payload longer than a slot is
       a chain of pages, and the head passing the message is what frees it.

       Measured the same way the segments are, and for the reason the segment
       check taught. The first version of this ran the queue in circles until a
       file too small to hold what it allocated either survived or did not -
       which is a blunt instrument twice over. It could not tell a chain leak
       from a segment leak, and it was slow for a reason that has nothing to do
       with leases: a run whose whole point is to cycle more pages than the
       file holds spends its time in the allocator's reuse sweep, which
       restarts at the bottom after every commit.

       Headroom says it exactly and in a second. Forty messages of twelve
       kilobytes are a hundred and sixty pages of chains; drained, they come
       back. */
    {
        uint64_t qid5 = 720005, p5 = 0, t5 = 0, room_full = 0, room_empty = 0;
        char big[12000];
        int k5, ok5 = 1;
        memset(big, 'q', sizeof big);
        memset(image, 0, sizeof image);
        strncpy((char *)image + Q_NAME_OFF, "chains", 31);
        check("a queue of long messages",
              db_catalog_put_queue(ctx, qid5, image) == 0);
        qid = qid5;
        for (k5 = 0; k5 < 40 && ok5; k5++) {
            if (db_queue_push(ctx, qid5, big, sizeof big) != 0) ok5 = 0;
        }
        check("forty of them, each a chain of four pages",
              ok5 && db_commit(ctx) == CybouDB_OK);
        room_full = db_bitmap_headroom(ctx);

        for (k5 = 0; k5 < 40 && ok5; k5++) {
            if (db_queue_claim(ctx, qid5, T0, MINUTE, &p5, &t5) != 0) ok5 = 0;
            else if (db_queue_ack(ctx, qid5, p5, t5) != 0) ok5 = 0;
        }
        check("claimed and acknowledged, every one of them",
              ok5 && db_commit(ctx) == CybouDB_OK);
        check("leaves a queue holding nothing",
              qfield(Q_HEAD_OFF) == qfield(Q_TAIL_OFF) &&
              u32(qp(), Q_SEGMENTS_OFF) == 0);
        room_empty = db_bitmap_headroom(ctx);
        check("and the file with the chains' pages back",
              room_empty >= room_full + 120);
        check("the file is intact", intact());
    }

    /* --- what a failed statement says ------------------------------------ */
    /* An application can only act on a failure it can read. Until this, an
       execution-time error set a code and left cyboudb_errmsg saying "ok" -
       the same thing a caller sees after a statement that worked - while
       bind-time errors came through. A stale ticket is the most routine
       failure this release has, so it is the one that would have been read
       most often and said least.

       The contract, and the last check is what makes it usable: **errmsg
       describes the most recent call**, and is "ok" when that call succeeded.
       Otherwise a caller who logs it after a later, successful statement gets
       a message about something else with no way to tell. */
    {
        cyboudb_db *e = NULL;
        const char *m;
        char qpath[1024];
        snprintf(qpath, sizeof qpath, "%s.errors", dbpath);
        remove(qpath);
        {
            cyboudb_create_options o;
            memset(&o, 0, sizeof o);
            o.struct_size = (uint32_t)sizeof o;
            o.flags = CybouDB_CREATE_QUEUE_LEASES;
            check("a database to fail statements against",
                  cyboudb_create_with_options(qpath, 1000, &o, &e)
                      == CybouDB_OK &&
                  cyboudb_exec(e, "CREATE QUEUE q") == CybouDB_OK &&
                  cyboudb_exec(e, "ENQUEUE INTO q VALUES ('a')") == CybouDB_OK &&
                  cyboudb_exec(e, "CLAIM FROM q FOR 30000") == CybouDB_OK);
        }

        m = cyboudb_errmsg(e);
        check("a statement that worked says ok", strcmp(m, "ok") == 0);

        check("a syntax error says so rather than ok",
              cyboudb_exec(e, "SELEC 1") != CybouDB_OK &&
              strstr(cyboudb_errmsg(e), "syntax") != NULL);
        check("a missing table says so",
              cyboudb_exec(e, "SELECT a FROM nope") != CybouDB_OK &&
              strstr(cyboudb_errmsg(e), "not found") != NULL);
        check("a commit with no transaction says so",
              cyboudb_exec(e, "COMMIT") != CybouDB_OK &&
              strstr(cyboudb_errmsg(e), "transaction") != NULL);

        check("a stale ACK says the lease was reclaimed",
              cyboudb_exec(e, "ACK FROM q AT 0 TOKEN 99") != CybouDB_OK &&
              strstr(cyboudb_errmsg(e), "lease") != NULL);
        check("and so does a stale NACK",
              cyboudb_exec(e, "NACK FROM q AT 0 TOKEN 99") != CybouDB_OK &&
              strstr(cyboudb_errmsg(e), "lease") != NULL);
        check("and a stale RENEW",
              cyboudb_exec(e, "RENEW FROM q AT 0 TOKEN 99 FOR 100")
                  != CybouDB_OK &&
              strstr(cyboudb_errmsg(e), "lease") != NULL);

        /* The rule that makes any of it safe to read. */
        check("and a statement that works afterwards says ok again",
              cyboudb_exec(e, "CREATE QUEUE another") == CybouDB_OK &&
              strcmp(cyboudb_errmsg(e), "ok") == 0);

        cyboudb_close(e);
        remove(qpath);
    }

    /* --- asking for the capability from C -------------------------------- */
    /* `cyboudb create-leases` is a command line, and an embedded application
       should not have to shell out to one to make the file it needs. The
       options struct is one additive entry point rather than a function per
       creation-time capability, because 0.7 brings encryption on the same
       terms and a family that grows without bound is what that would start.

       The check that matters is the last: a flag this build does not
       implement is refused. A caller asking for a capability and quietly
       receiving a database without it is the one outcome worse than an
       error. */
    {
        char p1[1024], p2[1024], p3[1024];
        cyboudb_db *made = NULL;
        cyboudb_create_options opts;
        uint64_t mask = 0;
        int rc;

        snprintf(p1, sizeof p1, "%s.plain", dbpath);
        snprintf(p2, sizeof p2, "%s.leased", dbpath);
        snprintf(p3, sizeof p3, "%s.refused", dbpath);
        remove(p1); remove(p2); remove(p3);

        rc = cyboudb_create_with_options(p1, 1000, NULL, &made);
        check("no options is the profile a caller who was not asked gets",
              rc == CybouDB_OK && feature_mask(p1, &mask) &&
              (mask & FEATURE_QUEUE_LEASES) == 0);
        cyboudb_close(made);
        made = NULL;

        memset(&opts, 0, sizeof opts);
        opts.struct_size = (uint32_t)sizeof opts;
        opts.flags = CybouDB_CREATE_QUEUE_LEASES;
        rc = cyboudb_create_with_options(p2, 1000, &opts, &made);
        check("and asking for leases gives a database that has them",
              rc == CybouDB_OK && feature_mask(p2, &mask) &&
              (mask & FEATURE_QUEUE_LEASES) != 0);
        check("which claims are allowed on",
              made != NULL &&
              cyboudb_exec(made, "CREATE QUEUE j") == CybouDB_OK &&
              cyboudb_exec(made, "ENQUEUE INTO j VALUES ('x')") == CybouDB_OK);
        cyboudb_close(made);
        made = NULL;

        memset(&opts, 0, sizeof opts);
        opts.struct_size = 4;
        check("a struct smaller than its own fields is misuse",
              cyboudb_create_with_options(p3, 1000, &opts, &made)
                  == CybouDB_MISUSE);
        memset(&opts, 0, sizeof opts);
        opts.struct_size = (uint32_t)sizeof opts;
        opts.flags = 0x8000;
        check("and so is a flag this build does not implement",
              cyboudb_create_with_options(p3, 1000, &opts, &made)
                  == CybouDB_MISUSE);
        check("null handles are misuse rather than a crash",
              cyboudb_create_with_options(NULL, 1000, NULL, &made)
                  == CybouDB_MISUSE &&
              cyboudb_create_with_options(p3, 1000, NULL, NULL)
                  == CybouDB_MISUSE);
        remove(p1); remove(p2); remove(p3);
    }

    /* Every state this suite produced, still acceptable after a reopen. */
    check("the queue survives being closed and opened",
          db_commit(ctx) == CybouDB_OK && cyboudb_close(db) == CybouDB_OK &&
          intact());

    for (i = 0; i < 0; i++) { }
    printf("\nLease ops suite: %d passed, %d failed\n", checks - failures,
           failures);
    return failures ? 1 : 0;
}
