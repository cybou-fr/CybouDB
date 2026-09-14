/* tests/validator_attack_test.c - trying to publish a graph the validator
 * wrongly believes it has proved.
 *
 * The other suites damage a database and ask whether the damage is noticed.
 * This one attacks the reasoning instead. Incremental commit validation rests
 * on one claim:
 *
 *     base proof + registered transaction delta = valid candidate proof
 *
 * so the interesting attacks are the ones where every part looks right - the
 * transition is registered the way the engine registers its own, the map leaf
 * is resealed, the checksums verify - and the conclusion is still false.
 *
 * The first case here is the one that matters most, and it was a real hole
 * when it was written: proof inheritance skips an object whose directory entry
 * has not moved, and nothing then stopped the same transaction retiring a page
 * that object still reaches. The candidate claimed both "this queue reaches
 * page X" and "page X is retired". Before inheritance the graph walk caught it,
 * because db_bitmap_candidate_payload refuses a retired page; inheriting the
 * subtree stopped anyone from asking.
 *
 * Every case has its opposite beside it. A rule that refuses everything is not
 * a rule, and the positive controls are what say these refusals are about what
 * they claim to be about.
 *
 *   build/validator_attack_test <database>
 *
 * SPDX-License-Identifier: Apache-2.0
 * Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
 */
#include "cyboudb.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#ifdef _WIN32
#include <windows.h>
#endif

#define CAT_OWNER_OFF   24
#define CAT_TYPE_OFF    32
#define CAT_QUEUE_TYPE  4
#define Q_SEGMENTS_OFF  36
#define Q_ENTRIES_OFF   128
#define QSEG_OWNER_OFF  24
#define QSEG_FIRST_OFF  32

/* --c-tests builds the library with allocation injection, and anything that
 * prepares a statement - cyboudb_exec does - needs these. */
void *cyboudb_test_mem_alloc(size_t size) { return malloc(size); }
void cyboudb_test_mem_free(void *ptr, size_t size) { (void)size; free(ptr); }

extern int db_catalog_get(void *ctx, uint64_t id, uint64_t *out_page);
extern int db_catalog_edit(void *ctx, uint64_t id, void **out);
extern void db_catalog_seal(void *page);
extern unsigned char *db_queue_seg_addr(void *ctx, uint64_t page);
extern int db_commit(void *ctx);
extern int db_rollback(void *ctx);
extern int db_bitmap_retire(void *ctx, uint64_t page);
extern int db_bitmap_is_payload(void *ctx, uint64_t page);
extern int db_open(const void *path, void *ctx, uint64_t writable,
                   uint64_t verify);
extern int db_close(void *ctx);

/* `cyboudb check`: deep, and asking about integrity rather than
 * recoverability. docs/RECOVERY.md. */
static int integrity_check_refuses(const char *path) {
    uint64_t vctx[64] = {0};
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
/* The change-set, written directly. Nothing outside the engine can reach this
 * - the point is not that a user could forge a transition, but that an engine
 * bug recording the wrong one must be refused rather than believed. The
 * change-set is part of what a commit now trusts, so it has to be checked. */
extern void cs_record(void *ctx, uint64_t page, uint64_t from, uint64_t to);

#define MAP_FREE     0
#define MAP_PAYLOAD  1
#define MAP_METADATA 2
#define MAP_RETIRED  3

static int failures = 0;
static int checks = 0;

static void check(const char *what, int ok) {
    checks++;
    if (!ok) { failures++; printf("FAIL %s\n", what); }
    else printf("ok   %s\n", what);
}

static uint64_t u64(const unsigned char *p, int off) {
    uint64_t v; memcpy(&v, p + off, 8); return v;
}
static uint32_t u32(const unsigned char *p, int off) {
    uint32_t v; memcpy(&v, p + off, 4); return v;
}

/* The id the engine gave a queue, found by its page rather than assumed. */
static uint64_t queue_id(void *ctx, const char *name, uint64_t *out_page) {
    uint64_t id;
    for (id = 1; id < 8192; id++) {
        uint64_t page = 0;
        unsigned char *p;
        if (db_catalog_get(ctx, id, &page) != 0 || page == 0) continue;
        p = db_queue_seg_addr(ctx, page);
        if (u32(p, CAT_TYPE_OFF) != CAT_QUEUE_TYPE) continue;
        if (strcmp((const char *)p + 64, name) != 0) continue;
        if (out_page) *out_page = page;
        return id;
    }
    return 0;
}

int main(int argc, char **argv) {
    cyboudb_db *db = NULL;
    void *ctx;
    uint64_t a_id, b_id, a_page = 0, b_page = 0, a_seg, b_seg;

    if (argc < 2) {
        fprintf(stderr, "usage: validator_attack_test <database>\n");
        return 2;
    }
    setvbuf(stdout, NULL, _IONBF, 0);
    if (cyboudb_open(argv[1], CybouDB_OPEN_READWRITE, &db) != CybouDB_OK) {
        fprintf(stderr, "open failed\n");
        return 2;
    }
    ctx = db;

    check("two queues and a table to work with",
          cyboudb_exec(db, "CREATE QUEUE alpha") == CybouDB_OK &&
          cyboudb_exec(db, "CREATE QUEUE beta") == CybouDB_OK &&
          cyboudb_exec(db, "CREATE TABLE elsewhere (a INT64)") == CybouDB_OK &&
          cyboudb_exec(db, "ENQUEUE INTO alpha VALUES ('one')") == CybouDB_OK &&
          cyboudb_exec(db, "ENQUEUE INTO beta VALUES ('two')") == CybouDB_OK);

    a_id = queue_id(ctx, "alpha", &a_page);
    b_id = queue_id(ctx, "beta", &b_page);
    check("both queues are findable", a_id != 0 && b_id != 0);
    if (!a_id || !b_id) return 1;
    a_seg = u64(db_queue_seg_addr(ctx, a_page), Q_ENTRIES_OFF);
    b_seg = u64(db_queue_seg_addr(ctx, b_page), Q_ENTRIES_OFF);
    check("and both name a segment", a_seg != 0 && b_seg != 0);

    /* --- retiring a page an inherited object still reaches ---------------- */
    /* The transaction touches a table, so alpha's directory entry does not
       move and alpha is inherited. Retiring one of its segments is registered
       in the change-set exactly as the engine would register it. */
    check("a transaction that touches something else",
          cyboudb_exec(db, "BEGIN") == CybouDB_OK &&
          cyboudb_exec(db, "INSERT INTO elsewhere VALUES (1)") == CybouDB_OK);
    check("retiring a segment of an untouched queue is allowed to be staged",
          db_bitmap_retire(ctx, a_seg) == 0);
    check("but the commit refuses to publish it",
          db_commit(ctx) != CybouDB_OK);
    db_rollback(ctx);

    /* The opposite: the same retire, of a page nothing reaches any more. A
       rule that refused every retire would pass the case above and mean
       nothing. */
    check("a queue to drop", cyboudb_exec(db, "CREATE QUEUE doomed")
          == CybouDB_OK &&
          cyboudb_exec(db, "ENQUEUE INTO doomed VALUES ('gone')")
          == CybouDB_OK);
    {
        uint64_t d_page = 0, d_seg;
        uint64_t d_id = queue_id(ctx, "doomed", &d_page);
        check("which is findable", d_id != 0);
        d_seg = u64(db_queue_seg_addr(ctx, d_page), Q_ENTRIES_OFF);
        check("dropping it retires its pages and commits",
              cyboudb_exec(db, "DROP QUEUE doomed") == CybouDB_OK);
        (void)d_seg;
    }

    /* And an ordinary transaction, which retires pages on every commit
       because copy-on-write replaces what it rewrites. */
    check("an ordinary ENQUEUE still commits",
          cyboudb_exec(db, "ENQUEUE INTO alpha VALUES ('three')")
          == CybouDB_OK);

    /* --- a segment that belongs to another queue -------------------------- */
    {
        unsigned char *page = NULL;
        uint64_t saved;
        check("alpha is still there",
              db_catalog_get(ctx, a_id, &a_page) == 0 && a_page != 0);
        check("and can be edited",
              db_catalog_edit(ctx, a_id, (void **)&page) == 0 && page != NULL);
        if (page) {
            saved = u64(page, Q_ENTRIES_OFF);
            memcpy(page + Q_ENTRIES_OFF, &b_seg, 8);
            db_catalog_seal(page);
            check("a queue naming another queue's segment is refused",
                  db_commit(ctx) != CybouDB_OK);
            db_rollback(ctx);
            (void)saved;
        }
    }

    /* --- one physical page in two logical positions ----------------------- */
    {
        unsigned char *page = NULL;
        check("alpha survived that", db_catalog_get(ctx, a_id, &a_page) == 0);
        db_catalog_edit(ctx, a_id, (void **)&page);
        if (page && u32(page, Q_SEGMENTS_OFF) >= 1) {
            uint64_t seg = u64(page, Q_ENTRIES_OFF);
            uint32_t two = 2;
            memcpy(page + Q_SEGMENTS_OFF, &two, 4);
            memcpy(page + Q_ENTRIES_OFF + 8, &seg, 8);   /* the same page twice */
            db_catalog_seal(page);
            check("one page in two positions is refused",
                  db_commit(ctx) != CybouDB_OK);
            db_rollback(ctx);
        } else {
            check("one page in two positions is refused", 0);
        }
    }

    /* --- a transition the log tells the wrong story about ----------------- */
    /* The published map has this page as PAYLOAD. A forged entry claiming it
       arrived from RETIRED ends in the right state and lies about how it got
       there - which is exactly what checking only the final state cannot
       tell apart from the truth. The commit has to follow the whole chain:
       where the published map has the page, every hop from there, and where
       the staged map leaves it. */
    {
        uint64_t g_page = 0, g_seg = 0, g_id;
        check("a queue to drop inside a transaction",
              cyboudb_exec(db, "CREATE QUEUE gamma") == CybouDB_OK &&
              cyboudb_exec(db, "ENQUEUE INTO gamma VALUES ('x')")
              == CybouDB_OK);
        g_id = queue_id(ctx, "gamma", &g_page);
        check("which is findable", g_id != 0 && g_page != 0);
        g_seg = u64(db_queue_seg_addr(ctx, g_page), Q_ENTRIES_OFF);
        check("and names a segment", g_seg != 0);

        /* Dropping it retires that segment for real, so the published map has
           the page as PAYLOAD, the staged map has it RETIRED, and the log
           holds the hop that did it. The forged entry then claims a second
           hop that does not continue from where the first ended. */
        check("dropping it inside a transaction",
              cyboudb_exec(db, "BEGIN") == CybouDB_OK &&
              cyboudb_exec(db, "DROP QUEUE gamma") == CybouDB_OK);
        cs_record(ctx, g_seg, MAP_FREE, MAP_RETIRED);
        check("a log that does not follow from itself is refused",
              db_commit(ctx) != CybouDB_OK);
        db_rollback(ctx);

        /* And the same drop without the forgery, which must go through - or
           the case above would be refusing the drop rather than the lie. */
        check("the same drop, with nothing forged, commits",
              cyboudb_exec(db, "DROP QUEUE gamma") == CybouDB_OK);
    }

    /* --- the page of a run that cannot say who owns it -------------------- */
    /* A leaf is a run of contiguous pages. The first carries the shared header
       - a magic, its own id, its owner - and the rest are row data all the way
       down, so a continuation page retired on its own cannot be attributed to
       an object and the commit cannot refuse it for reaching an inherited one.
       That is a real gap and it is bounded rather than closed:
       db_cow_copy_run retires a run in a loop over every page it holds, so no
       engine path retires a continuation without its header, and the header is
       attributed. Getting into this state needs db_bitmap_retire called on one
       page by hand, which is what this does.

       So the two halves are asserted separately: the commit may accept it, and
       the integrity check must refuse the result. The same place the queue's
       historical damage went when inheritance landed.

       Eight INT64 columns put 256 rows in 16 KiB, so a leaf is a four-page run
       and three of its pages are continuations. */
    {
        uint64_t p, header = 0, cont = 0;
        int i;
        char sql[256];

        check("a table whose leaves are multi-page runs",
              cyboudb_exec(db, "CREATE TABLE wide (a INT64, b INT64, c INT64, "
                           "d INT64, e INT64, f INT64, g INT64, h INT64)")
              == CybouDB_OK);
        for (i = 0; i < 300; i++) {
            snprintf(sql, sizeof sql,
                     "INSERT INTO wide VALUES (%d,%d,%d,%d,%d,%d,%d,%d)",
                     i, i, i, i, i, i, i, i);
            if (cyboudb_exec(db, sql) != CybouDB_OK) break;
        }
        check("filled past one run", i == 300);

        /* A payload page that does not name itself is a continuation page.
           Take the first one that follows a page which does. */
        for (p = 3; p < 8000; p++) {
            unsigned char *a;
            if (!db_bitmap_is_payload(ctx, p)) continue;
            a = db_queue_seg_addr(ctx, p);
            if (u64(a, 8) == p) { header = p; continue; }
            if (header && p == header + 1) { cont = p; break; }
        }
        check("a continuation page to retire", cont != 0);

        if (cont) {
            check("a transaction that touches something else",
                  cyboudb_exec(db, "BEGIN") == CybouDB_OK &&
                  cyboudb_exec(db, "INSERT INTO elsewhere VALUES (9)")
                  == CybouDB_OK &&
                  db_bitmap_retire(ctx, cont) == 0);
            check("the commit cannot attribute it, and accepts",
                  db_commit(ctx) == CybouDB_OK);
            check("but the integrity check refuses the result",
                  integrity_check_refuses(argv[1]));
        }
    }

    /* --- and after all of that the database is still usable --------------- */
    check("alpha still answers",
          cyboudb_exec(db, "ENQUEUE INTO alpha VALUES ('after')")
          == CybouDB_OK);
    check("closing", cyboudb_close(db) == CybouDB_OK);

    printf("validator attack suite: %d passed, %d failed\n",
           checks - failures, failures);
    return failures ? 1 : 0;
}
