/* tests/stream_page_test.c - the catalog page that defines a stream.
 *
 * Nothing appends yet. What exists is the page, its place in the catalog
 * directory alongside tables, indexes and queues, and what a commit proves
 * about it. The queue's suite established that a malformed object page must
 * stop a commit rather than be written out; this one adds the part a stream
 * has and a queue does not, which is its cursors.
 *
 * A cursor is a durable named reader. The two things that can be wrong with
 * one are that it stands outside the stream and that two of them are the same
 * reader, and each has a case below - as does the slot no cursor is using,
 * which must hold nothing, because a name and a position sitting past the
 * count would be read by nothing and refused by nothing.
 *
 * Usage: stream_page_test <database created with create-large>
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
#define CAT_TYPE_OFF      32
#define CAT_STREAM_TYPE   5
#define S_SEGMENTS_OFF    36
#define S_FIRST_OFF       40
#define S_END_OFF         48
#define S_RESERVED_OFF    56
#define S_NAME_OFF        64
#define S_FIRST_SEG_OFF   96
#define S_CURSORS_OFF     104
#define S_RESERVED2_OFF   112
#define S_CURSOR_TABLE    128
#define S_ENTRIES_OFF     384
#define SCUR_SIZE         32
#define SCUR_NAME_OFF     0
#define SCUR_POSITION_OFF 24

extern int db_catalog_put_stream(void *ctx, uint64_t id, const void *image);
extern int db_catalog_put_queue(void *ctx, uint64_t id, const void *image);
extern int db_catalog_get(void *ctx, uint64_t id, uint64_t *out_page);
extern int db_catalog_drop(void *ctx, uint64_t id);
extern unsigned char *db_queue_seg_addr(void *ctx, uint64_t page);
extern int db_commit(void *ctx);
extern int db_rollback(void *ctx);

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

/* What a caller hands db_catalog_put_stream: a zeroed page with a name in it.
   Everything else the core stamps, and the shape check is what says so. */
static void stream_image(unsigned char *image, const char *name) {
    memset(image, 0, 4096);
    strncpy((char *)image + S_NAME_OFF, name, 31);
}

/* Publishing a probe and trying to commit is how a damaged page is asked
   about: the commit validates everything the live generation reaches, so
   damage anywhere in it has to stop the commit. */
/* The integrity question, which is not the recovery question: `cyboudb check`
 * opens with CybouDB_VERIFY_DEEP | CybouDB_VERIFY_INTEGRITY and reports a
 * damaged newest generation rather than quietly using the one before it.
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
    uint64_t vctx[64] = {0};          /* well past CybouDB_DB_SIZE on purpose */
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


int main(int argc, char **argv) {
    static unsigned char image[4096];
    cyboudb_db *db = NULL;
    void *ctx;
    uint64_t page = 0;
    unsigned char *mapped;

    if (argc < 2) {
        fprintf(stderr, "usage: stream_page_test <database>\n");
        return 2;
    }
    setvbuf(stdout, NULL, _IONBF, 0);
    if (cyboudb_open(argv[1], CybouDB_OPEN_READWRITE, &db) != CybouDB_OK) {
        fprintf(stderr, "open failed\n");
        return 2;
    }
    ctx = db;

    /* --- a stream is a fifth kind of directory entry --------------------- */
    stream_image(image, "events");
    check("a stream goes into the catalog",
          db_catalog_put_stream(ctx, 800001, image) == 0);
    check("and is found there",
          db_catalog_get(ctx, 800001, &page) == 0 && page != 0);
    mapped = db_queue_seg_addr(ctx, page);
    check("as a stream page", u32(mapped, CAT_TYPE_OFF) == CAT_STREAM_TYPE);
    check("holding nothing, and read by nobody",
          u64(mapped, S_FIRST_OFF) == 0 && u64(mapped, S_END_OFF) == 0 &&
          u32(mapped, S_SEGMENTS_OFF) == 0 &&
          u64(mapped, S_CURSORS_OFF) == 0);
    check("under the name it was given",
          strcmp((char *)mapped + S_NAME_OFF, "events") == 0);
    check("an empty stream commits", db_commit(ctx) == CybouDB_OK);

    check("close", cyboudb_close(db) == CybouDB_OK);
    check("it opens again",
          cyboudb_open(argv[1], CybouDB_OPEN_READWRITE, &db) == CybouDB_OK);
    if (!db) return 2;
    ctx = db;
    check("the stream is still there",
          db_catalog_get(ctx, 800001, &page) == 0 && page != 0);
    mapped = db_queue_seg_addr(ctx, page);
    check("with the name it was created with",
          strcmp((char *)mapped + S_NAME_OFF, "events") == 0);

    /* --- the namespace is one, across all five kinds --------------------- */
    check("a table cannot take a stream's name",
          cyboudb_exec(db, "CREATE TABLE events (a INT64)") != CybouDB_OK);
    db_rollback(ctx);
    stream_image(image, "events");
    check("nor can a second stream",
          db_catalog_put_stream(ctx, 800002, image) != 0);
    db_rollback(ctx);
    {
        static unsigned char qimage[4096];
        memset(qimage, 0, sizeof qimage);
        strncpy((char *)qimage + S_NAME_OFF, "events", 31);
        check("nor a queue", db_catalog_put_queue(ctx, 800003, qimage) != 0);
        db_rollback(ctx);
    }

    /* --- what a caller may not ask the catalog to publish ---------------- */
    {
        struct { const char *what; int off; int width; uint64_t value; } bad[] = {
            { "a stream with no name",              S_NAME_OFF,      1, 0 },
            { "a stream that already holds records", S_END_OFF,      8, 4 },
            { "a stream already trimmed",           S_FIRST_OFF,     8, 1 },
            { "a stream that names a segment",      S_SEGMENTS_OFF,  4, 1 },
            { "a stream starting past segment 0",   S_FIRST_SEG_OFF, 8, 1 },
            { "a stream born with a reader",        S_CURSORS_OFF,   8, 1 },
        };
        for (size_t i = 0; i < sizeof bad / sizeof bad[0]; i++) {
            char label[128];
            stream_image(image, "second");
            memcpy(image + bad[i].off, &bad[i].value, (size_t)bad[i].width);
            snprintf(label, sizeof label, "%s is refused", bad[i].what);
            check(label, db_catalog_put_stream(ctx, 800004, image) != 0);
            db_rollback(ctx);
        }
    }

    /* --- and what a published one may not become ------------------------- */
    {
        struct { const char *what; int off; int width; uint64_t value; } damage[] = {
            { "a directory entry an empty stream has no room for", S_ENTRIES_OFF, 8, 7 },
            { "a first that has passed the end",    S_FIRST_OFF,     8, 1 },
            { "a segment count with no segment",    S_SEGMENTS_OFF,  4, 1 },
            { "a first segment the positions deny", S_FIRST_SEG_OFF, 8, 1 },
            { "a reserved field",                   S_RESERVED_OFF,  8, 1 },
            { "a second reserved field",            S_RESERVED2_OFF, 8, 1 },
            { "the rest of the second reserved field", S_RESERVED2_OFF + 8, 8, 1 },
            { "more readers than the format holds", S_CURSORS_OFF,   8, 9 },
            { "a reader nothing can name",          S_CURSORS_OFF,   8, 1 },
            { "a slot no cursor is using",          S_CURSOR_TABLE,  4, 1 },
            { "a page type nothing defines",        CAT_TYPE_OFF,    4, 9 },
        };
        for (size_t i = 0; i < sizeof damage / sizeof damage[0]; i++) {
            unsigned char saved[8];
            char label[160];
            int reported;
            check("a stream to damage",
                  db_catalog_get(ctx, 800001, &page) == 0 && page != 0);
            mapped = db_queue_seg_addr(ctx, page);
            /* Written straight into the page the live generation owns, and
               put back afterwards, so the next case starts from a database
               that is still whole.

               Case C of docs/COMMIT_VALIDATION.md section 7: this stream is
               not what the transaction touches, its directory entry still
               names the page the published generation named, and the whole
               object is therefore inherited. The integrity check is what
               answers for it now - the same move the queue suite made, for
               the same reason. */
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
            check("and the stream is whole again",
                  db_catalog_get(ctx, 800001, &page) == 0 && page != 0);
        }
    }

    /* --- the cases that need more than one field written ----------------- */
    {
        static unsigned char saved[S_ENTRIES_OFF - S_CURSOR_TABLE];
        uint64_t one = 1, two = 2, zero = 0;
        int reported;

        check("a stream to give readers",
              db_catalog_get(ctx, 800001, &page) == 0 && page != 0);
        mapped = db_queue_seg_addr(ctx, page);
        memcpy(saved, mapped + S_CURSOR_TABLE, sizeof saved);

        /* A cursor standing past what the stream has ever held. The stream is
           empty, so end is 0 and any position but 0 is outside it. */
        memcpy(mapped + S_CURSORS_OFF, &one, 8);
        strcpy((char *)mapped + S_CURSOR_TABLE + SCUR_NAME_OFF, "reader");
        memcpy(mapped + S_CURSOR_TABLE + SCUR_POSITION_OFF, &one, 8);
        db_catalog_seal(mapped);
        reported = integrity_check_refuses(argv[1]);
        check("a cursor standing outside the stream is reported", reported);

        /* Two readers, one name. Both are inside the stream and both are
           named; what is wrong is only that they are the same reader. */
        memcpy(mapped + S_CURSOR_TABLE + SCUR_POSITION_OFF, &zero, 8);
        memcpy(mapped + S_CURSORS_OFF, &two, 8);
        strcpy((char *)mapped + S_CURSOR_TABLE + SCUR_SIZE + SCUR_NAME_OFF,
               "reader");
        memcpy(mapped + S_CURSOR_TABLE + SCUR_SIZE + SCUR_POSITION_OFF,
               &zero, 8);
        db_catalog_seal(mapped);
        reported = integrity_check_refuses(argv[1]);
        check("two cursors with one name are reported", reported);

        /* The same two, told apart. Nothing is wrong with this one, which is
           what says the two cases above failed for the reason claimed. */
        strcpy((char *)mapped + S_CURSOR_TABLE + SCUR_SIZE + SCUR_NAME_OFF,
               "other");
        db_catalog_seal(mapped);
        check("two readers that are two readers are not reported",
              !integrity_check_refuses(argv[1]));
        stream_image(image, "alongside");
        check("two readers that are two readers commit",
              db_catalog_put_stream(ctx, 800008, image) == 0 &&
              db_commit(ctx) == CybouDB_OK);
        check("and the stream still has both",
              db_catalog_get(ctx, 800001, &page) == 0 &&
              u64(db_queue_seg_addr(ctx, page), S_CURSORS_OFF) == 2);

        mapped = db_queue_seg_addr(ctx, page);
        memcpy(mapped + S_CURSOR_TABLE, saved, sizeof saved);
        memcpy(mapped + S_CURSORS_OFF, &zero, 8);
        check("readers taken away again", db_commit(ctx) == CybouDB_OK);
        check("tidy up", db_catalog_drop(ctx, 800008) == 0 &&
              db_commit(ctx) == CybouDB_OK);
    }

    check("dropping it", db_catalog_drop(ctx, 800001) == 0);
    check("which commits", db_commit(ctx) == CybouDB_OK);
    check("and it is gone", db_catalog_get(ctx, 800001, &page) != 0);
    check("closing", cyboudb_close(db) == CybouDB_OK);

    printf("stream page suite: %d passed, %d failed\n", checks - failures,
           failures);
    return failures ? 1 : 0;
}
