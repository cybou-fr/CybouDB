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
 * the probe varies the *shape* at a fixed depth as well. Five shapes, each
 * breaking a different plausible answer, measured across a depth axis:
 *
 *   front      a fresh HELD message at the head - the ordinary claim
 *   live       many live claims before the first available one
 *   stuck      one stuck head with everything behind it acknowledged
 *   lapsed     an expired claim far behind the claim cursor
 *   empty      nothing claimable at all - a bounded *no* matters as much as a
 *              bounded *yes*, because a worker asks far more often than it is
 *              answered
 *
 * Depth is the other axis and not a sixth shape.
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

#define QSEG_READY_AT_OFF 40
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

/* Every segment the queue names: its summary written from the slots it now
   holds, then resealed. The engine maintains QSEG_READY_AT where it is already
   rewriting the page, so a probe that left it at zero would be measuring a
   queue no engine produces - and measuring it favourably, since a zero summary
   is always safe and always costs a full walk. */
static void seal_all(uint64_t depth) {
    uint64_t head = u64(qpage, Q_HEAD_OFF), tail = u64(qpage, Q_TAIL_OFF);
    uint64_t segs = (depth + QUEUE_SEG_SLOTS - 1) / QUEUE_SEG_SLOTS;
    for (uint64_t i = 0; i < segs; i++) {
        unsigned char *page = db_queue_seg_addr(ctx, u64(qpage, Q_ENTRIES_OFF
                                                         + (int)i * 8));
        uint64_t lo, hi, p, best = UINT64_MAX;
        uint32_t c;
        if (!page) continue;
        lo = i * QUEUE_SEG_SLOTS;
        hi = lo + QUEUE_SEG_SLOTS;
        if (lo < head) lo = head;
        if (hi > tail) hi = tail;
        for (p = lo; p < hi; p++) {
            unsigned char *s = page + QSEG_SLOTS_OFF
                             + (p % QUEUE_SEG_SLOTS) * QUEUE_SLOT_SIZE;
            uint32_t st;
            memcpy(&st, s + QMSG_STATE_OFF, 4);
            if (st == STATE_HELD) { best = 0; break; }
            if (st == STATE_CLAIMED) {
                uint64_t d = u64(s, QMSG_LEASE_UNTIL_OFF);
                if (d < best) best = d;
            }
        }
        put64(page, QSEG_READY_AT_OFF, best);
        c = crc32c(page, QSEG_CRC_OFF);
        memcpy(page + QSEG_CRC_OFF, &c, 4);
    }
}

static void reset_shape(uint64_t depth) {
    for (uint64_t p = 0; p < depth; p++) set_state(p, STATE_HELD, 0, 0);
    put64(qpage, Q_CLAIM_OFF, u64(qpage, Q_HEAD_OFF));
    db_catalog_seal(qpage);
    seal_all(depth);
}

/* The five shapes. Each leaves the queue valid; see tests/lease_state_test.c.
 *
 * Each also carries the claim cursor its history would have left, which the
 * naive walk never reads and a cursor-aware candidate will. A fixture whose
 * cursor is merely legal rather than truthful would hand the challenger a
 * different queue from the one the baseline was taken on, and the comparison
 * would be between two states rather than two strategies.
 *
 * Q_CLAIM is one past the highest position ever handed out, so it follows from
 * which slots have been claimed at some point - CLAIMED and ACKED both have
 * been, HELD with a zero token has not. */
static void shape(const char *name, uint64_t depth) {
    uint64_t p, claim = 0;
    reset_shape(depth);
    if (!strcmp(name, "front")) {
        /* Nothing was ever handed out: the head is a fresh message. */
        claim = 0;
    } else if (!strcmp(name, "live")) {
        /* Every message but the last is claimed and still held. */
        for (p = 0; p + 1 < depth; p++) set_state(p, STATE_CLAIMED, FUTURE, p + 1);
        claim = depth - 1;
    } else if (!strcmp(name, "stuck")) {
        /* One slow worker at the head, everything behind it acknowledged, one
           fresh message at the end. This is the pathological case. */
        set_state(0, STATE_CLAIMED, FUTURE, 1);
        for (p = 1; p + 1 < depth; p++) set_state(p, STATE_ACKED, 0, p + 1);
        claim = depth - 1;
    } else if (!strcmp(name, "lapsed")) {
        /* The claimable one is a lapsed claim near the end, behind a wall of
           acknowledged messages - a cursor that only moves forward loses it. */
        set_state(0, STATE_CLAIMED, FUTURE, 1);
        for (p = 1; p + 1 < depth; p++) set_state(p, STATE_ACKED, 0, p + 1);
        set_state(depth - 1, STATE_CLAIMED, PAST, 7);
        claim = depth;
    } else if (!strcmp(name, "empty")) {
        /* Nothing to find, which a strategy may answer slowly if it only
           bounds the cost of success. */
        for (p = 0; p < depth; p++) set_state(p, STATE_CLAIMED, FUTURE, p + 1);
        claim = depth;
    }
    put64(qpage, Q_CLAIM_OFF, claim);
    db_catalog_seal(qpage);
    seal_all(depth);
}


/* --- the challenger: a ready-at tree -----------------------------------------
 *
 * One u64 per segment answers the only question a search asks:
 *
 *     ready_at = 0            the segment holds a HELD message
 *                min(deadline of its CLAIMED messages)
 *                UINT64_MAX   it holds neither
 *
 *     ready_at <= now   <=>   this segment has something claimable
 *
 * Expiry needs no write, which is what makes this fit the design: a deadline
 * recorded in the past is exactly what says the segment may now have
 * something, so time passing changes the answer without anything touching the
 * page. That was the property a forward-only cursor could not have.
 *
 * Internal nodes are the minimum of their children, fanout 8 over 512 leaves:
 * 64 + 8 + 1 = 73 u64, 584 bytes, which is a corner of one page. The search
 * descends taking the *first* child with ready_at <= now rather than the
 * smallest, so FIFO order among claimable messages is preserved: a segment
 * with a lapsed deadline is taken before a later segment full of fresh ones.
 *
 * Leaves are a ring - leaf = absolute segment & 511 - because the directory
 * shifts entries down when leading segments retire, and a tree indexed by
 * directory position would have to shift with it, which is a new O(backlog)
 * operation hiding inside the fix for one. A queue holds at most 495 segments
 * at once, so two live segments never share a leaf.
 *
 * What is counted: an internal node read is a summary node, a leaf read is a
 * segment page (that is where ready_at would live - QSEG_RESERVED has room),
 * and the slots of the chosen segment are slots. Building the tree is not
 * counted, because in the engine the summary is maintained where the segment
 * page is already being rewritten; it is not work a claim does.
 */
#define TREE_LEAVES 512
static uint64_t t_leaf[TREE_LEAVES];
static uint64_t t_l2[64];       /* each over 8 leaves */
static uint64_t t_l1[8];        /* each over 64 */
static uint64_t t_l0;           /* the root, over 512 */

static unsigned long long summary_nodes_inspected;
static unsigned long long tree_segments_inspected;
static unsigned long long tree_slots_inspected;

/* The summary a segment page would carry, computed from the slots it holds. */
static uint64_t segment_ready_at(uint64_t seg, uint64_t head, uint64_t tail) {
    uint64_t lo = seg * QUEUE_SEG_SLOTS, hi = lo + QUEUE_SEG_SLOTS, p;
    uint64_t best = UINT64_MAX;
    if (lo < head) lo = head;
    if (hi > tail) hi = tail;
    for (p = lo; p < hi; p++) {
        unsigned char *s = slot_at(p);
        uint32_t st;
        if (!s) continue;
        memcpy(&st, s + QMSG_STATE_OFF, 4);
        if (st == STATE_HELD) return 0;
        if (st == STATE_CLAIMED) {
            uint64_t d = u64(s, QMSG_LEASE_UNTIL_OFF);
            if (d < best) best = d;
        }
    }
    return best;
}

static void tree_build(uint64_t head, uint64_t tail) {
    uint64_t first, last, s;
    int i, c;
    for (i = 0; i < TREE_LEAVES; i++) t_leaf[i] = UINT64_MAX;
    if (head != tail) {
        first = head / QUEUE_SEG_SLOTS;
        last = (tail - 1) / QUEUE_SEG_SLOTS;
        for (s = first; s <= last; s++)
            t_leaf[s & (TREE_LEAVES - 1)] = segment_ready_at(s, head, tail);
    }
    for (i = 0; i < 64; i++) {
        uint64_t m = UINT64_MAX;
        for (c = 0; c < 8; c++) if (t_leaf[i * 8 + c] < m) m = t_leaf[i * 8 + c];
        t_l2[i] = m;
    }
    for (i = 0; i < 8; i++) {
        uint64_t m = UINT64_MAX;
        for (c = 0; c < 8; c++) if (t_l2[i * 8 + c] < m) m = t_l2[i * 8 + c];
        t_l1[i] = m;
    }
    t_l0 = UINT64_MAX;
    for (i = 0; i < 8; i++) if (t_l1[i] < t_l0) t_l0 = t_l1[i];
}

/* level 0 root, 1 -> t_l1, 2 -> t_l2, 3 -> leaves. */
static uint64_t node_value(int level, int idx) {
    switch (level) {
    case 0: return t_l0;
    case 1: return t_l1[idx];
    case 2: return t_l2[idx];
    default: return t_leaf[idx];
    }
}

/* The first leaf in [lo, hi] whose ready_at is not in the future, or -1.
   Children are tried in order, so the answer is the leftmost one. */
static long node_search(int level, int idx, int lo, int hi, uint64_t now) {
    int span = 1 << (3 * (3 - level));
    int base = idx * span;
    int c;
    if (base > hi || base + span - 1 < lo) return -1;
    if (level == 3) tree_segments_inspected++;
    else summary_nodes_inspected++;
    if (node_value(level, idx) > now) return -1;
    if (level == 3) return base;
    for (c = 0; c < 8; c++) {
        long r = node_search(level + 1, idx * 8 + c, lo, hi, now);
        if (r >= 0) return r;
    }
    return -1;
}

/* The same question db_queue_scan_claimable answers, asked of the tree. */
static int tree_scan(uint64_t now, uint64_t *out_position) {
    uint64_t head = u64(qpage, Q_HEAD_OFF), tail = u64(qpage, Q_TAIL_OFF);
    uint64_t first, last, seg, lo, hi, p;
    int a, b;
    long leaf = -1;
    if (head == tail) return 0;
    first = head / QUEUE_SEG_SLOTS;
    last = (tail - 1) / QUEUE_SEG_SLOTS;
    a = (int)(first & (TREE_LEAVES - 1));
    b = (int)(last & (TREE_LEAVES - 1));
    /* The live segments are contiguous in absolute order and may wrap the
       ring, in which case they are two contiguous leaf ranges, searched in
       the order the positions run. */
    if (a <= b) {
        leaf = node_search(0, 0, a, b, now);
    } else {
        leaf = node_search(0, 0, a, TREE_LEAVES - 1, now);
        if (leaf < 0) leaf = node_search(0, 0, 0, b, now);
    }
    if (leaf < 0) return 0;
    seg = first + (((uint64_t)leaf - (uint64_t)a) & (TREE_LEAVES - 1));
    if (seg > last) return 0;

    lo = seg * QUEUE_SEG_SLOTS;
    hi = lo + QUEUE_SEG_SLOTS;
    if (lo < head) lo = head;
    if (hi > tail) hi = tail;
    for (p = lo; p < hi; p++) {
        unsigned char *s = slot_at(p);
        uint32_t st;
        if (!s) continue;
        tree_slots_inspected++;
        memcpy(&st, s + QMSG_STATE_OFF, 4);
        if (st == STATE_HELD ||
            (st == STATE_CLAIMED && u64(s, QMSG_LEASE_UNTIL_OFF) <= now)) {
            if (out_position) *out_position = p;
            return 1;
        }
    }
    return 0;
}


/* --- what the summary costs to keep -----------------------------------------
 *
 * The search is bounded. The question that could still sink the design is the
 * other one: a summary cheap to read and expensive to keep is not a win.
 *
 * Two costs per operation, and they are different in kind:
 *
 *   slots re-read   to recompute a segment's ready_at, when the change could
 *                   have *raised* the minimum. A change that can only lower it
 *                   needs no scan at all - enqueueing or handing back a message
 *                   makes the segment's ready_at zero, and zero is already the
 *                   floor.
 *   nodes written   climbing from the segment to the root, stopping as soon as
 *                   a parent's minimum does not move. Three levels, so three is
 *                   the ceiling.
 *
 * The asymmetry is the whole of it. Only two transitions can raise a segment's
 * minimum - claiming the last free message in it, and acknowledging the claim
 * that held the earliest deadline - and only those pay for a rescan.
 */
static unsigned long long maint_slots, maint_nodes, maint_leaf_pages;
static unsigned long long maint_ops, maint_slots_max, maint_nodes_max;

/* Climb from a leaf, stopping where the minimum stops moving.
 *
 * Asymmetric on purpose, and this is where a design doc could have been
 * optimistic. A leaf whose value *fell* can only lower its parent, so the
 * parent takes min(parent, value) and no sibling is read. A leaf whose value
 * *rose* may or may not have been the minimum, and nothing short of the other
 * seven siblings can say - and a sibling leaf is a segment page, so those
 * reads are real work that the first version of this measurement did not
 * count. Only the bottom level pays it: the levels above it are nodes in one
 * page, already in hand. */
static void tree_propagate(int leaf, int rose) {
    int i2 = leaf / 8, i1 = i2 / 8, c;
    uint64_t m;

    if (!rose) {
        if (t_leaf[leaf] >= t_l2[i2]) return;
        t_l2[i2] = t_leaf[leaf];
    } else {
        m = UINT64_MAX;
        for (c = 0; c < 8; c++) {
            if (t_leaf[i2 * 8 + c] != UINT64_MAX) maint_leaf_pages++;
            if (t_leaf[i2 * 8 + c] < m) m = t_leaf[i2 * 8 + c];
        }
        if (m == t_l2[i2]) return;
        t_l2[i2] = m;
    }
    maint_nodes++;

    m = UINT64_MAX;
    for (c = 0; c < 8; c++) if (t_l2[i1 * 8 + c] < m) m = t_l2[i1 * 8 + c];
    if (m == t_l1[i1]) return;
    t_l1[i1] = m;
    maint_nodes++;

    m = UINT64_MAX;
    for (c = 0; c < 8; c++) if (t_l1[c] < m) m = t_l1[c];
    if (m == t_l0) return;
    t_l0 = m;
    maint_nodes++;
}

/* A change that can only lower the minimum: no scan, just take it. */
static void tree_lower(uint64_t seg, uint64_t value) {
    int leaf = (int)(seg & (TREE_LEAVES - 1));
    if (value >= t_leaf[leaf]) return;
    t_leaf[leaf] = value;
    tree_propagate(leaf, 0);
}

/* A change that may have raised it: the segment has to be read again. */
static void tree_rescan(uint64_t seg, uint64_t head, uint64_t tail) {
    int leaf = (int)(seg & (TREE_LEAVES - 1));
    uint64_t lo = seg * QUEUE_SEG_SLOTS, hi = lo + QUEUE_SEG_SLOTS, p;
    uint64_t best = UINT64_MAX;
    if (lo < head) lo = head;
    if (hi > tail) hi = tail;
    for (p = lo; p < hi; p++) {
        unsigned char *s = slot_at(p);
        uint32_t st;
        if (!s) continue;
        maint_slots++;
        memcpy(&st, s + QMSG_STATE_OFF, 4);
        if (st == STATE_HELD) { best = 0; break; }   /* the floor; stop early */
        if (st == STATE_CLAIMED) {
            uint64_t d = u64(s, QMSG_LEASE_UNTIL_OFF);
            if (d < best) best = d;
        }
    }
    if (best == t_leaf[leaf]) return;
    {
        int rose = best > t_leaf[leaf];
        t_leaf[leaf] = best;
        tree_propagate(leaf, rose);
    }
}

static void maint_begin(void) {
    maint_slots = 0; maint_nodes = 0; maint_leaf_pages = 0;
}
static void maint_end(void) {
    maint_ops++;
    if (maint_slots > maint_slots_max) maint_slots_max = maint_slots;
    if (maint_nodes > maint_nodes_max) maint_nodes_max = maint_nodes;
}

/* One operation each, with the maintenance a real implementation would do. */
static void op_enqueue_like(uint64_t pos, uint64_t head, uint64_t tail) {
    (void)head; (void)tail;
    maint_begin();
    set_state(pos, STATE_HELD, 0, 0);
    tree_lower(pos / QUEUE_SEG_SLOTS, 0);       /* a free message is the floor */
    maint_end();
}

static void op_nack(uint64_t pos, uint64_t head, uint64_t tail) {
    (void)head; (void)tail;
    maint_begin();
    set_state(pos, STATE_HELD, 0, 9);           /* NACK raises the token */
    tree_lower(pos / QUEUE_SEG_SLOTS, 0);
    maint_end();
}

static void op_claim(uint64_t pos, uint64_t head, uint64_t tail) {
    maint_begin();
    /* Distinct deadlines, because workers claim at different moments and a
       summary that only ever sees one deadline is a fixture, not a workload. */
    set_state(pos, STATE_CLAIMED, FUTURE + pos, 5);
    /* Taking the last free message in a segment raises its minimum, and
       nothing short of reading the segment can tell whether it was the last -
       though the scan stops at the first free one it finds, which is why this
       is cheap while the segment still has any. */
    tree_rescan(pos / QUEUE_SEG_SLOTS, head, tail);
    maint_end();
}

static void op_ack(uint64_t pos, uint64_t head, uint64_t tail) {
    uint64_t seg = pos / QUEUE_SEG_SLOTS;
    int leaf = (int)(seg & (TREE_LEAVES - 1));
    unsigned char *s = slot_at(pos);
    uint64_t was = s ? u64(s, QMSG_LEASE_UNTIL_OFF) : 0;
    maint_begin();
    set_state(pos, STATE_ACKED, 0, 6);
    /* Only the claim that held the earliest deadline can raise the minimum.
       Acknowledging any other one changes nothing the summary can see. */
    if (was == t_leaf[leaf]) tree_rescan(seg, head, tail);
    maint_end();
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

    printf("| scenario | depth | strategy | found | slots | segments | summary |\n");
    printf("| :--- | ---: | :--- | :--- | ---: | ---: | ---: |\n");
    for (i = 0; i < 5; i++) {
        uint64_t pos_naive = 0, pos_tree = 0;
        int found_naive, found_tree;
        if (strcmp(want, "all") && strcmp(want, scenarios[i])) continue;
        shape(scenarios[i], depth);

        lease_slots_inspected = 0;
        lease_segments_inspected = 0;
        found_naive = db_queue_scan_claimable(ctx, qid, NOW, &pos_naive);
        printf("| %s | %llu | segment | %s | %llu | %llu | - |\n", scenarios[i],
               (unsigned long long)depth, found_naive ? "yes" : "no",
               lease_slots_inspected, lease_segments_inspected);

        /* Built outside the measured region: in the engine the summary is
           maintained where the segment page is already being rewritten, so it
           is not work a claim does. */
        tree_build(u64(qpage, Q_HEAD_OFF), u64(qpage, Q_TAIL_OFF));
        summary_nodes_inspected = 0;
        tree_segments_inspected = 0;
        tree_slots_inspected = 0;
        found_tree = tree_scan(NOW, &pos_tree);
        printf("| %s | %llu | tree | %s | %llu | %llu | %llu |\n", scenarios[i],
               (unsigned long long)depth, found_tree ? "yes" : "no",
               tree_slots_inspected, tree_segments_inspected,
               summary_nodes_inspected);

        /* The comparison is worth nothing unless both answer the same
           question. A strategy that is fast and wrong is not a candidate, and
           this is the check that would have caught the ring's order if the
           rotation had been got wrong. */
        if (found_naive != found_tree ||
            (found_naive && pos_naive != pos_tree)) {
            printf("MISMATCH: naive %s at %llu, tree %s at %llu\n",
                   found_naive ? "found" : "none",
                   (unsigned long long)pos_naive,
                   found_tree ? "found" : "none",
                   (unsigned long long)pos_tree);
            return 1;
        }
    }
    /* --- and what keeping the summary costs ---------------------------- */
    if (!strcmp(want, "all")) {
        uint64_t head, tail, n, slots[4], nodes[4], smax[4], nmax[4], count = 0;
        uint64_t sibs[4], sibmax[4];
        /* In the order seq[] runs them, which is the order a worker does:
           take a free message, claim it, hand it back, claim and finish. */
        const char *names[4] = { "enqueue", "claim", "nack", "ack" };
        int k;

        for (k = 0; k < 4; k++) {
            slots[k] = nodes[k] = smax[k] = nmax[k] = 0;
            sibs[k] = sibmax[k] = 0;
        }

        /* The cycle a worker actually runs, over a queue that starts with
           everything free: take a message, hand it back, take it again,
           finish it. Measuring each verb against a fixture built for it would
           measure the fixture. */
        shape("front", depth);
        head = u64(qpage, Q_HEAD_OFF);
        tail = u64(qpage, Q_TAIL_OFF);
        tree_build(head, tail);
        for (n = head; n < tail; n++) {
            void (*seq[4])(uint64_t, uint64_t, uint64_t) = {
                op_enqueue_like, op_claim, op_nack, op_ack };
            /* enqueue-like first so the slot is free, then claim, hand back,
               and claim-then-ack; nack is measured where it belongs. */
            for (k = 0; k < 4; k++) {
                if (k == 3) op_claim(n, head, tail);   /* ack needs a claim */
                maint_slots = 0; maint_nodes = 0; maint_leaf_pages = 0;
                seq[k](n, head, tail);
                slots[k] += maint_slots;
                nodes[k] += maint_nodes;
                sibs[k] += maint_leaf_pages;
                if (maint_slots > smax[k]) smax[k] = maint_slots;
                if (maint_nodes > nmax[k]) nmax[k] = maint_nodes;
                if (maint_leaf_pages > sibmax[k]) sibmax[k] = maint_leaf_pages;
            }
            count++;
        }

        printf("\n| operation | depth | ops | slots re-read | sibling segments | nodes written |\n");
        printf("| :--- | ---: | ---: | ---: | ---: | ---: |\n");
        for (k = 0; k < 4; k++) {
            printf("| %s | %llu | %llu | %.2f (%llu) | %.2f (%llu) | %.2f (%llu) |\n",
                   names[k], (unsigned long long)depth,
                   (unsigned long long)count,
                   count ? (double)slots[k] / (double)count : 0.0,
                   (unsigned long long)smax[k],
                   count ? (double)sibs[k] / (double)count : 0.0,
                   (unsigned long long)sibmax[k],
                   count ? (double)nodes[k] / (double)count : 0.0,
                   (unsigned long long)nmax[k]);
        }

        /* And the worst case for a summary keyed on a minimum: every claim in
           a segment sharing one deadline, so acknowledging any of them is
           acknowledging the minimum and forces a rescan every time. */
        {
            uint64_t s_total = 0, s_max = 0, ops = 0;
            shape("live", depth);
            head = u64(qpage, Q_HEAD_OFF);
            tail = u64(qpage, Q_TAIL_OFF);
            tree_build(head, tail);
            for (n = head; n + 1 < tail; n++) {
                maint_slots = 0; maint_nodes = 0;
                op_ack(n, head, tail);
                s_total += maint_slots;
                if (maint_slots > s_max) s_max = maint_slots;
                ops++;
            }
            printf("| ack, one shared deadline | %llu | %llu | %.2f (%llu) | - |\n",
                   (unsigned long long)depth, (unsigned long long)ops,
                   ops ? (double)s_total / (double)ops : 0.0,
                   (unsigned long long)s_max);
        }
    }

    cyboudb_close(db);
    return 0;
}
