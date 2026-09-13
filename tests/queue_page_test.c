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
#define Q_ENTRIES_OFF   128

/* A segment page, and a slot inside one. */
#define QSEG_MAGIC_OFF     0
#define QSEG_MAGIC_VALUE   0x51515341u
#define QSEG_VERSION_OFF   4
#define QSEG_PAGE_ID_OFF   8
#define QSEG_OWNER_OFF     24
#define QSEG_FIRST_OFF     32
#define QSEG_RESERVED_OFF  40
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
            { "a page type nothing defines",       CAT_TYPE_OFF,    4, 9 },
        };
        for (size_t i = 0; i < sizeof damage / sizeof damage[0]; i++) {
            unsigned char saved[8];
            char label[160];
            int refused;
            check("a queue to damage",
                  db_catalog_get(ctx, 700001, &page) == 0 && page != 0);
            mapped = db_queue_seg_addr(ctx, page);
            /* Written straight into the page the live generation owns, and
               put back afterwards. A commit validates what the generation
               reaches, so the damage has to stop the commit rather than be
               written out - and repairing it is what lets the next case start
               from a database that is still whole. */
            memcpy(saved, mapped + damage[i].off, (size_t)damage[i].width);
            memcpy(mapped + damage[i].off, &damage[i].value,
                   (size_t)damage[i].width);
            queue_image(image, "probe");
            refused = db_catalog_put_queue(ctx, 700003, image) != 0 ||
                      db_commit(ctx) != CybouDB_OK;
            db_rollback(ctx);
            memcpy(mapped + damage[i].off, saved, (size_t)damage[i].width);
            snprintf(label, sizeof label, "%s stops the commit", damage[i].what);
            check(label, refused);
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
              { "a reserved field of a segment",      QSEG_RESERVED_OFF, 8, 1, 1 },
              { "a slot, which the checksum covers",  QSEG_SLOTS_OFF + QMSG_LENGTH_OFF, 4, 9, 1 },
              { "a directory entry naming nothing",   Q_ENTRIES_OFF,     8, 0, 0 },
              { "a tail past what the segment holds", Q_TAIL_OFF,        8, 200, 0 },
              { "a segment count the positions deny", Q_SEGMENTS_OFF,    4, 2, 0 },
            };
            for (size_t i = 0; i < sizeof damage / sizeof damage[0]; i++) {
                unsigned char saved[8];
                unsigned char *target;
                char label[160];
                int refused;
                check("a filled queue to damage",
                      db_catalog_get(ctx, 700010, &qpage) == 0 && qpage != 0);
                mapped = db_queue_seg_addr(ctx, qpage);
                target = damage[i].on_segment
                       ? db_queue_seg_addr(ctx, u64(mapped, Q_ENTRIES_OFF))
                       : mapped;
                memcpy(saved, target + damage[i].off, (size_t)damage[i].width);
                memcpy(target + damage[i].off, &damage[i].value,
                       (size_t)damage[i].width);
                /* A fresh id for every case. Sharing one made the suite
                 * order-dependent in the worst way: the moment a case let a
                 * commit through, the queue existed, and every case after it
                 * was "refused" because the id was taken rather than because
                 * the damage was seen - a pass that proves nothing, and one
                 * that hides exactly the regression this suite is for. */
                queue_image(image, "probe2");
                refused = db_catalog_put_queue(ctx, 700011 + (uint64_t)i,
                                               image) != 0 ||
                          db_commit(ctx) != CybouDB_OK;
                db_rollback(ctx);
                memcpy(target + damage[i].off, saved, (size_t)damage[i].width);
                snprintf(label, sizeof label, "%s stops the commit",
                         damage[i].what);
                check(label, refused);
            }
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

    check("dropping it", db_catalog_drop(ctx, 700001) == 0);
    check("which commits", db_commit(ctx) == CybouDB_OK);
    check("and it is gone", db_catalog_get(ctx, 700001, &page) != 0);
    check("closing", cyboudb_close(db) == CybouDB_OK);

    printf("queue page suite: %d passed, %d failed\n", checks - failures,
           failures);
    return failures ? 1 : 0;
}
