/* benchmarks/lease_probe.c - what a naive search for a claimable message costs.
 *
 * The clock is decided, the operations are designed, the validator knows which
 * lease states are legal. What is not decided is how a CLAIM finds a message,
 * and `docs/QUEUE.md` says why the obvious answer is wrong: walking forward
 * from the head is bounded by the retained queue and not by the work, so one
 * slow worker turns every claim into a walk over everything acknowledged
 * behind it. That is the disease preview.2 was spent curing on the commit path.
 *
 * This measures it rather than assuming it. `db_queue_scan_claimable` is the
 * naive walk, deliberately: it writes nothing and only counts what it reads,
 * so the number it produces is the cost of the strategy and not of a
 * half-finished implementation of a better one.
 *
 * Depth alone would let almost any strategy look constant on a tidy queue, so
 * the probe varies the *shape* at a fixed depth as well. Six scenarios, each
 * breaking a different plausible answer:
 *
 *   front      a fresh HELD message at the head - the ordinary claim
 *   live       many live claims before the first available one
 *   stuck      one stuck head with everything behind it acknowledged
 *   lapsed     an expired claim far behind the claim cursor
 *   empty      nothing claimable at all - a bounded *no* matters as much as a
 *              bounded *yes*, because a worker asks far more often than it is
 *              answered
 *   depth      the same shape at 100, 10k and 1M, which is the preview.2 axis
 *
 * Nothing in the engine writes a lease state yet, so the shapes are written by
 * hand into committed pages and resealed with an independent CRC-32C. The
 * validator accepts every state written here; tests/lease_state_test.c is what
 * says so.
 *
 * Usage: lease_probe <path> <pages> <depth> [scenario]
 *        scenario: front | live | stuck | lapsed | empty | all
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

#define Q_HEAD_OFF      40
#define Q_TAIL_OFF      48
#define Q_CLAIM_OFF     56
#define Q_NAME_OFF      64
#define Q_FIRST_SEG_OFF 96
#define Q_ENTRIES_OFF   128

#define QSEG_SLOTS_OFF  64
#define QSEG_CRC_OFF    4092
#define QUEUE_SLOT_SIZE 64
#define QUEUE_SEG_SLOTS 62
#define QMSG_STATE_OFF        8
#define QMSG_LEASE_UNTIL_OFF 16
#define QMSG_LEASE_TOKEN_OFF 24

#define STATE_HELD    0
#define STATE_CLAIMED 1
#define STATE_ACKED   2

#define NOW      1700000000000ULL
#define FUTURE   (NOW + 60000ULL)
#define PAST     (NOW - 60000ULL)

extern int db_catalog_put_queue(void *ctx, uint64_t id, const void *image);
extern int db_catalog_get(void *ctx, uint64_t id, uint64_t *out_page);
extern unsigned char *db_queue_seg_addr(void *ctx, uint64_t page);
extern int db_commit(void *ctx);
extern void db_catalog_seal(void *page);
extern int db_queue_push(void *ctx, uint64_t id, const void *bytes,
                         uint64_t length);
extern int db_queue_scan_claimable(void *ctx, uint64_t id, uint64_t now,
                                   uint64_t *out_position);
extern unsigned long long lease_slots_inspected;
extern unsigned long long lease_segments_inspected;

static uint32_t crc32c(const unsigned char *data, size_t n) {
    uint32_t crc = 0xFFFFFFFFu;
    for (size_t i = 0; i < n; i++) {
        crc ^= data[i];
        for (int b = 0; b < 8; b++)
            crc = (crc & 1) ? (crc >> 1) ^ 0x82F63B78u : crc >> 1;
    }
    return crc ^ 0xFFFFFFFFu;
}

static uint64_t u64(const unsigned char *p, int off) {
    uint64_t v; memcpy(&v, p + off, 8); return v;
}
static void put64(unsigned char *p, int off, uint64_t v) {
    memcpy(p + off, &v, 8);
}
static void put32(unsigned char *p, int off, uint32_t v) {
    memcpy(p + off, &v, 4);
}

static void *ctx;
static uint64_t qid = 900001;
static unsigned char *qpage;

/* The segment page holding a position, and the slot inside it. */
static unsigned char *slot_at(uint64_t pos) {
    uint64_t seg = pos / QUEUE_SEG_SLOTS;
    uint64_t idx = pos % QUEUE_SEG_SLOTS;
    uint64_t entry = seg - u64(qpage, Q_FIRST_SEG_OFF);
    unsigned char *page = db_queue_seg_addr(ctx, u64(qpage, Q_ENTRIES_OFF
                                                     + (int)entry * 8));
    return page ? page + QSEG_SLOTS_OFF + idx * QUEUE_SLOT_SIZE : NULL;
}

static void set_state(uint64_t pos, uint32_t state, uint64_t dl, uint64_t tok) {
    unsigned char *s = slot_at(pos);
    if (!s) return;
    put32(s, QMSG_STATE_OFF, state);
    put64(s, QMSG_LEASE_UNTIL_OFF, dl);
    put64(s, QMSG_LEASE_TOKEN_OFF, tok);
}

/* Every segment the queue names, resealed once after a shape is written. */
static void seal_all(uint64_t depth) {
    uint64_t segs = (depth + QUEUE_SEG_SLOTS - 1) / QUEUE_SEG_SLOTS;
    for (uint64_t i = 0; i < segs; i++) {
        unsigned char *page = db_queue_seg_addr(ctx, u64(qpage, Q_ENTRIES_OFF
                                                         + (int)i * 8));
        if (page) {
            uint32_t c = crc32c(page, QSEG_CRC_OFF);
            memcpy(page + QSEG_CRC_OFF, &c, 4);
        }
    }
}

static void reset_shape(uint64_t depth) {
    for (uint64_t p = 0; p < depth; p++) set_state(p, STATE_HELD, 0, 0);
    put64(qpage, Q_CLAIM_OFF, u64(qpage, Q_HEAD_OFF));
    db_catalog_seal(qpage);
    seal_all(depth);
}

/* The six shapes. Each leaves the queue valid; see tests/lease_state_test.c. */
static void shape(const char *name, uint64_t depth) {
    uint64_t p;
    reset_shape(depth);
    if (!strcmp(name, "front")) {
        /* Nothing to skip: the head is a fresh message. */
    } else if (!strcmp(name, "live")) {
        /* Every message but the last is claimed and still held. */
        for (p = 0; p + 1 < depth; p++) set_state(p, STATE_CLAIMED, FUTURE, p + 1);
    } else if (!strcmp(name, "stuck")) {
        /* One slow worker at the head, everything behind it acknowledged, one
           fresh message at the end. This is the pathological case. */
        set_state(0, STATE_CLAIMED, FUTURE, 1);
        for (p = 1; p + 1 < depth; p++) set_state(p, STATE_ACKED, 0, p + 1);
    } else if (!strcmp(name, "lapsed")) {
        /* The claimable one is a lapsed claim near the end, behind a wall of
           acknowledged messages - a cursor that only moves forward loses it. */
        set_state(0, STATE_CLAIMED, FUTURE, 1);
        for (p = 1; p + 1 < depth; p++) set_state(p, STATE_ACKED, 0, p + 1);
        set_state(depth - 1, STATE_CLAIMED, PAST, 7);
        put64(qpage, Q_CLAIM_OFF, depth);
        db_catalog_seal(qpage);
    } else if (!strcmp(name, "empty")) {
        /* Nothing to find, which a strategy may answer slowly if it only
           bounds the cost of success. */
        for (p = 0; p < depth; p++) set_state(p, STATE_CLAIMED, FUTURE, p + 1);
    }
    seal_all(depth);
}

int main(int argc, char **argv) {
    cyboudb_db *db = NULL;
    static unsigned char image[4096];
    const char *scenarios[] = { "front", "live", "stuck", "lapsed", "empty" };
    uint64_t page = 0, depth;
    const char *want;
    int i;

    if (argc < 4) {
        fprintf(stderr,
                "usage: lease_probe <path> <pages> <depth> [scenario]\n");
        return 2;
    }
    depth = strtoull(argv[3], NULL, 10);
    want = argc > 4 ? argv[4] : "all";

    if (cyboudb_open(argv[1], CybouDB_OPEN_READWRITE, &db) != CybouDB_OK) {
        fprintf(stderr, "open failed - create it with create-leases\n");
        return 2;
    }
    ctx = db;
    memset(image, 0, sizeof image);
    strncpy((char *)image + Q_NAME_OFF, "probe", 31);
    if (db_catalog_put_queue(ctx, qid, image) != 0) {
        fprintf(stderr, "could not create the queue\n");
        return 2;
    }
    for (uint64_t p = 0; p < depth; p++) {
        if (db_queue_push(ctx, qid, "x", 1) != 0) {
            fprintf(stderr, "the queue filled at %llu of %llu - more pages\n",
                    (unsigned long long)p, (unsigned long long)depth);
            return 2;
        }
    }
    if (db_commit(ctx) != CybouDB_OK) { fprintf(stderr, "commit failed\n"); return 2; }
    if (db_catalog_get(ctx, qid, &page) != 0 || !page) return 2;
    qpage = db_queue_seg_addr(ctx, page);

    printf("| scenario | depth | found | slots inspected | segments |\n");
    printf("| :--- | ---: | :--- | ---: | ---: |\n");
    for (i = 0; i < 5; i++) {
        uint64_t pos = 0;
        int found;
        if (strcmp(want, "all") && strcmp(want, scenarios[i])) continue;
        shape(scenarios[i], depth);
        lease_slots_inspected = 0;
        lease_segments_inspected = 0;
        found = db_queue_scan_claimable(ctx, qid, NOW, &pos);
        printf("| %s | %llu | %s | %llu | %llu |\n", scenarios[i],
               (unsigned long long)depth,
               found ? "yes" : "no",
               lease_slots_inspected, lease_segments_inspected);
    }
    cyboudb_close(db);
    return 0;
}
