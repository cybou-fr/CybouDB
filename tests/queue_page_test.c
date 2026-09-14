/* tests/queue_page_test.c - the catalog page that defines a queue.
 *
 * Nothing enqueues yet. What exists is the page, its place in the catalog
 * directory, and what a commit proves about it - which is the part worth
 * getting right first, because it is where the last subsystem's bugs hid.
 *
 * The refusals are the point. A queue page reaches the engine through a
 * directory entry, and a build that accepted a malformed one would be reading
 * a file some other writer produced and trusting it. So each case damages one
 * field of a page that was already accepted, and requires the generation
 * holding it to stop being selectable - which is recovery working, not an
 * error path.
 *
 * Usage: queue_page_test <database created with create-large>
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

/* Offsets, spelled here rather than included, so that a change to the layout
   has to be made in two places on purpose. */
#define CAT_TYPE_OFF    32
#define CAT_QUEUE_TYPE  4
#define Q_SEGMENTS_OFF  36
#define Q_HEAD_OFF      40
#define Q_TAIL_OFF      48
#define Q_CLAIM_OFF     56
#define Q_NAME_OFF      64
#define Q_FIRST_SEG_OFF 96
#define Q_RESERVED2_OFF 104
#define Q_TIME_FLOOR_OFF 120
#define Q_ENTRIES_OFF   128

/* A segment page, and a slot inside one. */
#define QSEG_MAGIC_OFF     0
#define QSEG_MAGIC_VALUE   0x51515341u
#define QSEG_VERSION_OFF   4
#define QSEG_PAGE_ID_OFF   8
#define QSEG_OWNER_OFF     24
#define QSEG_FIRST_OFF     32
#define QSEG_READY_AT_OFF   40
#define QSEG_RESERVED_OFF  48
#define QSEG_SLOTS_OFF     64
#define QSEG_CRC_OFF       4092
#define QMSG_LENGTH_OFF    0
#define QMSG_FLAGS_OFF     4
#define QMSG_STATE_OFF     8
#define QMSG_LEASE_UNTIL_OFF 16

extern int db_catalog_put_queue(void *ctx, uint64_t id, const void *image);
extern int db_catalog_get(void *ctx, uint64_t id, uint64_t *out_page);
extern int db_catalog_drop(void *ctx, uint64_t id);
extern unsigned char *db_queue_seg_addr(void *ctx, uint64_t page);
extern int db_commit(void *ctx);
extern int db_rollback(void *ctx);
extern unsigned long long queue_segments_walked;
extern int db_queue_push(void *ctx, uint64_t id, const void *bytes,
                         uint64_t length);
extern int db_queue_pop(void *ctx, uint64_t id, void *out, uint64_t *out_len,
                        uint64_t capacity);

/* The integrity question, which is not the recovery question: `cyboudb check`
 * opens with CybouDB_VERIFY_DEEP | CybouDB_VERIFY_INTEGRITY and reports a
 * damaged newest generation instead of quietly using the one before it.
 * docs/RECOVERY.md. */
extern void db_catalog_seal(void *page);

/* Damage written straight into a live page leaves its checksum stale, and a
 * deep check refuses a stale checksum without ever reaching the rule the case
 * is about. Resealing is what makes these cases prove what their names say:
 * the page checksums correctly and is refused anyway, for what it says rather
 * than for being torn. */
extern int db_open(const void *path, void *ctx, uint64_t writable,
                   uint64_t verify);
extern int db_close(void *ctx);

static int integrity_check_refuses(const char *path) {
    /* 4 KiB, which is what the library allocates for a cyboudb_db handle,
     * so this cannot be outgrown without the library noticing first. It was
     * uint64_t[64] until the descriptor grew past 512 bytes and the stack
     * protector caught it. */
    uint64_t vctx[512] = {0};          /* well past CybouDB_DB_SIZE on purpose */
    const void *p = path;
#ifdef _WIN32
    static wchar_t wide[32768];
    if (!MultiByteToWideChar(CP_UTF8, 0, path, -1, wide, 32768)) return 0;
    p = wide;
#endif
    if (db_open(p, vctx, 0, 3) != 0) return 1;
    db_close(vctx);
    return 0;
}

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

static uint32_t u32(const unsigned char *p, int off) {
    uint32_t v;
    memcpy(&v, p + off, 4);
    return v;
}

static uint64_t u64(const unsigned char *p, int off) {
    uint64_t v;
    memcpy(&v, p + off, 8);
    return v;
}

/* What a caller hands db_catalog_put_queue: a zeroed page with a name in it.
   Everything else the core stamps, and the shape check is what says so. */
static void queue_image(unsigned char *image, const char *name) {
    memset(image, 0, 4096);
    strncpy((char *)image + Q_NAME_OFF, name, 31);
}

int main(int argc, char **argv) {
    static unsigned char image[4096];
    cyboudb_db *db = NULL;
    void *ctx;
    uint64_t page = 0;
    unsigned char *mapped;

    if (argc < 2) {
        fprintf(stderr, "usage: queue_page_test <database>\n");
        return 2;
    }
    setvbuf(stdout, NULL, _IONBF, 0);
    if (cyboudb_open(argv[1], CybouDB_OPEN_READWRITE, &db) != CybouDB_OK) {
        fprintf(stderr, "open failed\n");
        return 2;
    }
    ctx = db;

    /* --- a queue is a fourth kind of directory entry --------------------- */
    queue_image(image, "jobs");
    check("a queue goes into the catalog",
          db_catalog_put_queue(ctx, 700001, image) == 0);
    check("and is found there",
          db_catalog_get(ctx, 700001, &page) == 0 && page != 0);
    mapped = db_queue_seg_addr(ctx, page);
    check("as a queue page", u32(mapped, CAT_TYPE_OFF) == CAT_QUEUE_TYPE);
    check("holding nothing",
          u64(mapped, Q_HEAD_OFF) == 0 && u64(mapped, Q_TAIL_OFF) == 0 &&
          u32(mapped, Q_SEGMENTS_OFF) == 0);
    check("under the name it was given",
          strcmp((char *)mapped + Q_NAME_OFF, "jobs") == 0);

    {
        unsigned long long before = queue_segments_walked;
        check("an empty queue commits", db_commit(ctx) == CybouDB_OK);
        check("without reading a segment page, because it has none",
              queue_segments_walked == before);
    }

    check("close", cyboudb_close(db) == CybouDB_OK);
    check("it opens again",
          cyboudb_open(argv[1], CybouDB_OPEN_READWRITE, &db) == CybouDB_OK);
    if (!db) return 2;
    ctx = db;
    check("the queue is still there",
          db_catalog_get(ctx, 700001, &page) == 0 && page != 0);
    mapped = db_queue_seg_addr(ctx, page);
    check("with the name it was created with",
          strcmp((char *)mapped + Q_NAME_OFF, "jobs") == 0);

    /* --- the namespace is one ------------------------------------------- */
    check("a table cannot take a queue's name",
          cyboudb_exec(db, "CREATE TABLE jobs (a INT64)") != CybouDB_OK);
    db_rollback(ctx);

    /* --- what a caller may not ask the catalog to publish ---------------- */
    {
        struct { const char *what; int off; int width; uint64_t value; } bad[] = {
            { "a queue with no name",            Q_NAME_OFF,      1, 0 },
            { "a queue that already holds rows", Q_TAIL_OFF,      8, 4 },
            { "a queue whose head has moved",    Q_HEAD_OFF,      8, 1 },
            { "a queue that names a segment",    Q_SEGMENTS_OFF,  4, 1 },
            { "a queue starting past segment 0", Q_FIRST_SEG_OFF, 8, 1 },
        };
        for (size_t i = 0; i < sizeof bad / sizeof bad[0]; i++) {
            char label[128];
            queue_image(image, "second");
            memcpy(image + bad[i].off, &bad[i].value, (size_t)bad[i].width);
            snprintf(label, sizeof label, "%s is refused", bad[i].what);
            check(label, db_catalog_put_queue(ctx, 700002, image) != 0);
            db_rollback(ctx);
        }
    }

    /* --- and what a published one may not become ------------------------- */
    {
        struct { const char *what; int off; int width; uint64_t value; } damage[] = {
            { "a directory entry an empty queue has no room for", Q_ENTRIES_OFF, 8, 7 },
            { "a head that has passed its tail",   Q_HEAD_OFF,      8, 1 },
            { "a segment count with no segment",   Q_SEGMENTS_OFF,  4, 1 },
            { "a first segment the head is not in", Q_FIRST_SEG_OFF, 8, 1 },
            { "a claim cursor ahead of the head", Q_CLAIM_OFF,     8, 1 },
            { "a second reserved field",           Q_RESERVED2_OFF, 8, 1 },
            /* Where a lease clock's high-water will go. A version without
               leases must refuse a queue that has put something there, or the
               version that adds them cannot tell a file that left the field
               alone from one that meant something by it. */
            { "a lease clock on a queue with no leases", Q_TIME_FLOOR_OFF, 8, 1 },
            { "a page type nothing defines",       CAT_TYPE_OFF,    4, 9 },
        };
        for (size_t i = 0; i < sizeof damage / sizeof damage[0]; i++) {
            unsigned char saved[8];
            char label[160];
            int reported;
            check("a queue to damage",
                  db_catalog_get(ctx, 700001, &page) == 0 && page != 0);
            mapped = db_queue_seg_addr(ctx, page);
            /* Written straight into the page the live generation owns, and
               put back afterwards. This is case C of section 7 in
               docs/COMMIT_VALIDATION.md: the damaged object is one the
               transaction does not touch, its directory entry still names the
               page the published generation named, and the whole object is
               therefore inherited. The integrity check is what answers for it
               now; repairing the byte is what lets the next case start from a
               database that is still whole. */
            memcpy(saved, mapped + damage[i].off, (size_t)damage[i].width);
            memcpy(mapped + damage[i].off, &damage[i].value,
                   (size_t)damage[i].width);
            db_catalog_seal(mapped);
            reported = integrity_check_refuses(argv[1]);
            memcpy(mapped + damage[i].off, saved, (size_t)damage[i].width);
            db_catalog_seal(mapped);
            snprintf(label, sizeof label,
                     "%s is reported by the integrity check", damage[i].what);
            check(label, reported);
            check("and the queue is whole again",
                  db_catalog_get(ctx, 700001, &page) == 0 && page != 0);
        }
    }

    check("a commit with nothing wrong still goes through",
          db_commit(ctx) == CybouDB_OK);

    /* --- and now with segments under it ---------------------------------- */
    /* Everything above is a queue holding nothing, which is the easy half: no
       segment page exists to be wrong. These push messages first, so the walk
       has something to walk and the refusals are about what it finds there. */
    {
        uint64_t qpage = 0, segpage = 0;
        unsigned char *seg;
        queue_image(image, "held");
        check("a queue to fill", db_catalog_put_queue(ctx, 700010, image) == 0);
        check("three messages into it",
              db_queue_push(ctx, 700010, "one", 3) == 0 &&
              db_queue_push(ctx, 700010, "two", 3) == 0 &&
              db_queue_push(ctx, 700010, "three", 5) == 0);
        check("which commits", db_commit(ctx) == CybouDB_OK);
        check("and is found again",
              db_catalog_get(ctx, 700010, &qpage) == 0 && qpage != 0);
        mapped = db_queue_seg_addr(ctx, qpage);
        check("holding three, in one segment",
              u64(mapped, Q_TAIL_OFF) == 3 && u32(mapped, Q_SEGMENTS_OFF) == 1);
        segpage = u64(mapped, Q_ENTRIES_OFF);
        check("which names a page", segpage != 0);
        seg = db_queue_seg_addr(ctx, segpage);
        check("that says what it is",
              u32(seg, QSEG_MAGIC_OFF) == QSEG_MAGIC_VALUE &&
              u64(seg, QSEG_OWNER_OFF) == 700010 &&
              u64(seg, QSEG_FIRST_OFF) == 0);

        {
            struct { const char *what; int off; int width; uint64_t value;
                     int on_segment; } damage[] = {
              { "a segment with the wrong magic",     QSEG_MAGIC_OFF,    4, 1, 1 },
              { "a segment of a version nothing has", QSEG_VERSION_OFF,  4, 2, 1 },
              { "a segment that names another page",  QSEG_PAGE_ID_OFF,  8, 3, 1 },
              { "a segment owned by another queue",   QSEG_OWNER_OFF,    8, 5, 1 },
              { "a segment starting at another position", QSEG_FIRST_OFF, 8, 62, 1 },
              /* Where the claimable summary will live, and what is left
                 reserved beside it. Both must stay zero until an engine
                 builds the index - a field nothing requires to be zero is a
                 field the version that starts writing it cannot use. */
              { "a summary on a segment that has none", QSEG_READY_AT_OFF, 8, 1, 1 },
              { "a reserved field of a segment",      QSEG_RESERVED_OFF, 8, 1, 1 },
              { "a slot, which the checksum covers",  QSEG_SLOTS_OFF + QMSG_LENGTH_OFF, 4, 9, 1 },
              { "a directory entry naming nothing",   Q_ENTRIES_OFF,     8, 0, 0 },
              { "a tail past what the segment holds", Q_TAIL_OFF,        8, 200, 0 },
              { "a segment count the positions deny", Q_SEGMENTS_OFF,    4, 2, 0 },
            };
            /* Case C of docs/COMMIT_VALIDATION.md section 7: an object this
             * transaction does not touch. Its directory entry names the same
             * page the published generation named, so the whole object is
             * inherited - copy-on-write says the engine cannot have rewritten
             * it - and the commit does not read into it.
             *
             * So what is asserted is the integrity check, not the commit. A
             * commit may accept this file; that is the narrowing, taken
             * deliberately, and it is only honest because `check` reports the
             * damage. Asserting what the commit does here would be asserting
             * the absence of a guarantee, which is not a thing to hold code
             * to. */
            for (size_t i = 0; i < sizeof damage / sizeof damage[0]; i++) {
                unsigned char saved[8];
                unsigned char *target;
                char label[160];
                int reported;
                check("a filled queue to damage",
                      db_catalog_get(ctx, 700010, &qpage) == 0 && qpage != 0);
                mapped = db_queue_seg_addr(ctx, qpage);
                target = damage[i].on_segment
                       ? db_queue_seg_addr(ctx, u64(mapped, Q_ENTRIES_OFF))
                       : mapped;
                memcpy(saved, target + damage[i].off, (size_t)damage[i].width);
                memcpy(target + damage[i].off, &damage[i].value,
                       (size_t)damage[i].width);
                if (!damage[i].on_segment) db_catalog_seal(target);
                reported = integrity_check_refuses(argv[1]);
                memcpy(target + damage[i].off, saved, (size_t)damage[i].width);
                if (!damage[i].on_segment) db_catalog_seal(target);
                snprintf(label, sizeof label,
                         "%s is reported by the integrity check",
                         damage[i].what);
                check(label, reported);
            }

            /* And the same damage, undone, must stop being reported - so the
             * damage is what the check is answering rather than something
             * else about this file. */
            check("an undamaged file passes the same check",
                  !integrity_check_refuses(argv[1]));
        }

        check("after all of which the messages are still there",
              db_catalog_get(ctx, 700010, &qpage) == 0 && qpage != 0);
        {
            char out[64];
            uint64_t len = 0;
            int ok = db_queue_pop(ctx, 700010, out, &len, sizeof out) == 0 &&
                     len == 3 && memcmp(out, "one", 3) == 0;
            ok = ok && db_queue_pop(ctx, 700010, out, &len, sizeof out) == 0 &&
                 len == 3 && memcmp(out, "two", 3) == 0;
            ok = ok && db_queue_pop(ctx, 700010, out, &len, sizeof out) == 0 &&
                 len == 5 && memcmp(out, "three", 5) == 0;
            check("and come back in the order they went in", ok);
        }
        check("draining leaves no segment named",
              db_catalog_get(ctx, 700010, &qpage) == 0 &&
              u32(db_queue_seg_addr(ctx, qpage), Q_SEGMENTS_OFF) == 0);
        check("which commits", db_commit(ctx) == CybouDB_OK);
        check("tidy up", db_catalog_drop(ctx, 700010) == 0 &&
              db_commit(ctx) == CybouDB_OK);
    }


    /* --- the same queue, a new segment and an old one -------------------- */
    /* Cases A and B of docs/COMMIT_VALIDATION.md section 7, and the pair that
     * says what proof inheritance actually costs. The seven cases above are
     * about a queue the transaction does not touch; these are about the queue
     * it does.
     *
     *   A. the segment this ENQUEUE writes is not inherited - it carries the
     *      candidate generation - so damaging it must stop the commit. That
     *      is the guarantee that remains, and it is the one that matters:
     *      a transaction cannot publish a graph it has broken.
     *
     *   B. an older segment of that same queue is inherited even though the
     *      queue is being written to, because the edge naming it did not
     *      move. Damaging it does not stop the commit. This is the guarantee
     *      that moved, and nothing before it tested this case: the seven
     *      above all damage a queue nobody is touching.
     */
    {
        uint64_t qpage = 0, old_seg = 0, new_seg = 0;
        unsigned char *qp, *seg, saved[8];
        int i, accepted, reported;
        unsigned long long visited;

        queue_image(image, "twoseg");
        check("a queue that will outgrow one segment",
              db_catalog_put_queue(ctx, 700100, image) == 0);
        for (i = 0; i < 70; i++) {          /* 62 slots to a segment */
            if (db_queue_push(ctx, 700100, "filler", 6) != 0) break;
        }
        check("filled past one segment's worth", i == 70);
        check("which commits", db_commit(ctx) == CybouDB_OK);

        check("and now holds two segments",
              db_catalog_get(ctx, 700100, &qpage) == 0 && qpage != 0);
        qp = db_queue_seg_addr(ctx, qpage);
        check("two of them", u32(qp, Q_SEGMENTS_OFF) == 2);
        old_seg = u64(qp, Q_ENTRIES_OFF);
        check("the first of which is a page", old_seg != 0);

        /* B: the old segment of the queue being written to. */
        seg = db_queue_seg_addr(ctx, old_seg);
        memcpy(saved, seg + QSEG_MAGIC_OFF, 4);
        memset(seg + QSEG_MAGIC_OFF, 0x5a, 4);
        accepted = db_queue_push(ctx, 700100, "after", 5) == 0 &&
                   db_commit(ctx) == CybouDB_OK;
        check("B: an ENQUEUE into a queue whose old segment is damaged "
              "still commits", accepted);
        if (!accepted) db_rollback(ctx);
        reported = integrity_check_refuses(argv[1]);
        check("B: and the integrity check reports that damage", reported);
        check("B: the queue's first segment did not move",
              db_catalog_get(ctx, 700100, &qpage) == 0 &&
              u64(db_queue_seg_addr(ctx, qpage), Q_ENTRIES_OFF) == old_seg);
        seg = db_queue_seg_addr(ctx, old_seg);
        memcpy(seg + QSEG_MAGIC_OFF, saved, 4);
        check("B: and once repaired it is not reported",
              !integrity_check_refuses(argv[1]));

        /* A: the segment this transaction writes into. */
        check("a message that lands in the tail segment",
              db_queue_push(ctx, 700100, "tail", 4) == 0);
        check("the queue is still findable",
              db_catalog_get(ctx, 700100, &qpage) == 0 && qpage != 0);
        qp = db_queue_seg_addr(ctx, qpage);
        new_seg = u64(qp, Q_ENTRIES_OFF + 8);
        check("whose tail segment is a page", new_seg != 0);
        seg = db_queue_seg_addr(ctx, new_seg);
        memcpy(saved, seg + QSEG_MAGIC_OFF, 4);
        memset(seg + QSEG_MAGIC_OFF, 0x5a, 4);
        visited = queue_segments_walked;
        check("A: damaging the segment this transaction wrote stops the commit",
              db_commit(ctx) != CybouDB_OK);
        check("A: and the commit did look at a segment to find it",
              queue_segments_walked > visited);
        db_rollback(ctx);

        check("tidy up", db_catalog_drop(ctx, 700100) == 0 &&
              db_commit(ctx) == CybouDB_OK);
    }

    check("dropping it", db_catalog_drop(ctx, 700001) == 0);
    check("which commits", db_commit(ctx) == CybouDB_OK);
    check("and it is gone", db_catalog_get(ctx, 700001, &page) != 0);
    check("closing", cyboudb_close(db) == CybouDB_OK);

    printf("queue page suite: %d passed, %d failed\n", checks - failures,
           failures);
    return failures ? 1 : 0;
}
