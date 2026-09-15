/* Production encrypted-commit control flow under durability failures. */
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define PAGE 4096
#define DB_HANDLE 0
#define DB_GENERATION 40
#define DB_SB_PAGE 48
#define DB_MODE 88
#define DB_CACHE 760
#define DB_SEAL_EPOCH (DB_CACHE + 56)
#define DB_SEAL_DIR (DB_SEAL_EPOCH + 8)
#define DB_SEAL_LEAVES (DB_SEAL_DIR + 8)
#define DB_ENC_ERROR (DB_SEAL_LEAVES + 8)
#define DB_META_KEY (DB_ENC_ERROR + 8)
#define DB_TREE_KEY (DB_META_KEY + 32)
#define DB_SEAL_PAGES (DB_TREE_KEY + 32)
#define DB_SEAL_DEPTH (DB_SEAL_PAGES + 8)
#define DB_SEAL_ROOT (DB_SEAL_DEPTH + 8)
#define DB_DIRTY_LEAF_N (DB_SEAL_ROOT + 16)
#define DB_DIRTY_LEAF_OVF (DB_DIRTY_LEAF_N + 8)
#define DB_DIRTY_LEAVES (DB_DIRTY_LEAF_OVF + 8)
#define CTX_BYTES 4096
#define E_SYNC 19

static int checks, failures, sync_calls, fail_sync;
static int read_calls, write_calls, nodes_differ;
static int dirty_frames;
static uint64_t stub_leaves = 1;
static uint64_t differ_page;            /* a page the two copies disagree on */

static uint64_t rd64(const uint8_t *p, int off) {
    uint64_t v; memcpy(&v, p + off, 8); return v;
}
static void wr64(uint8_t *p, int off, uint64_t v) {
    memcpy(p + off, &v, 8);
}
static void check(const char *what, int ok) {
    checks++;
    if (ok) printf("ok   %s\n", what);
    else { failures++; printf("FAIL %s\n", what); }
}

int db_encrypted_commit(uint8_t *ctx);

int db_pages_flush(uint8_t *ctx) { (void)ctx; return 0; }
/* The staged allocation map's own checksum. Nothing in this test has a map. */
void db_bitmap_seal(uint8_t *ctx) { (void)ctx; }
uint64_t cyboudb_pcache_frames(const uint8_t *cache) {
    (void)cache; return (uint64_t)dirty_frames;
}
uint64_t cyboudb_pcache_dirty_at(const uint8_t *cache, uint64_t slot) {
    (void)cache; return slot < (uint64_t)dirty_frames ? slot + 1 : UINT64_MAX;
}
int64_t vfs_read_at(int64_t h, void *buf, uint64_t bytes, uint64_t offset) {
    (void)h; read_calls++; memset(buf, 0, (size_t)bytes);
    if (nodes_differ && offset == 6 * PAGE) ((uint8_t *)buf)[64] = 1;
    if (differ_page && offset == differ_page * PAGE) ((uint8_t *)buf)[64] = 1;
    return (int64_t)bytes;
}
int64_t vfs_write_at(int64_t h, const void *buf, uint64_t bytes,
                     uint64_t offset) {
    (void)h; (void)buf; (void)offset; write_calls++; return (int64_t)bytes;
}
int64_t vfs_sync_file(int64_t h) {
    (void)h; sync_calls++; return sync_calls == fail_sync ? -1 : 0;
}
uint32_t crc32c(const uint8_t *buf, uint64_t len) {
    (void)buf; (void)len; return 0;
}
void cyboudb_seal_leaf_mac(uint8_t *out, const uint8_t *key,
                           const uint8_t *page) {
    (void)key; (void)page; memset(out, 0x11, 16);
}
int cyboudb_seal_level(uint64_t *out, uint64_t total_pages, uint64_t level) {
    (void)total_pages;
    /* Level zero is the leaf array; every level above it is one node here. */
    out[0] = level == 0 ? 0 : stub_leaves + (level - 1);
    out[1] = level == 0 ? stub_leaves : 1;
    return 0;
}
void cyboudb_seal_node_init(uint8_t *page, uint64_t index, uint64_t level,
                            uint64_t generation, uint64_t epoch) {
    (void)index; (void)level; (void)generation; (void)epoch;
    memset(page, 0, PAGE);
}
int cyboudb_seal_node_set_child(uint8_t *page, uint64_t slot,
                                const uint8_t *mac) {
    (void)page; (void)slot; (void)mac; return 0;
}
void cyboudb_seal_node_mac(uint8_t *out, const uint8_t *key,
                           const uint8_t *page) {
    (void)key; (void)page; memset(out, 0x22, 16);
}
int cyboudb_kmac256_init(uint8_t *ctx, const uint8_t *key, uint64_t key_len,
                         const uint8_t *custom, uint64_t custom_len) {
    (void)ctx; (void)key; (void)key_len; (void)custom; (void)custom_len;
    return 0;
}
void cyboudb_kmac256_update(uint8_t *ctx, const uint8_t *in, uint64_t len) {
    (void)ctx; (void)in; (void)len;
}
void cyboudb_kmac256_final(uint8_t *ctx, uint8_t *out, uint64_t out_len) {
    (void)ctx; memset(out, 0x33, (size_t)out_len);
}

static void fresh(uint8_t *ctx) {
    memset(ctx, 0, CTX_BYTES);
    wr64(ctx, DB_HANDLE, 1);
    wr64(ctx, DB_GENERATION, 7);
    wr64(ctx, DB_SB_PAGE, 1);
    wr64(ctx, DB_MODE, 1);
    wr64(ctx, DB_CACHE, 1);
    wr64(ctx, DB_SEAL_EPOCH, 3);
    wr64(ctx, DB_SEAL_DIR, 5);
    wr64(ctx, DB_SEAL_LEAVES, 1);
    sync_calls = read_calls = write_calls = 0;
}

int main(void) {
    uint8_t ctx[CTX_BYTES];
    int journalled_writes;
    printf("CybouDB encrypted commit engine test\n\n");

    fresh(ctx); fail_sync = 0;
    check("a complete production commit succeeds", db_encrypted_commit(ctx) == 0);
    check("and adopts the new generation and superblock",
          rd64(ctx, DB_GENERATION) == 8 && rd64(ctx, DB_SB_PAGE) == 2);
    check("without poisoning the handle", rd64(ctx, DB_MODE) == 1);
    check("and does not copy an unchanged inactive leaf",
          read_calls == 3 && write_calls == 2);

    fresh(ctx); fail_sync = 0; nodes_differ = 1;
    check("a commit with a divergent leaf succeeds",
          db_encrypted_commit(ctx) == 0);
    check("and catches up exactly that leaf",
          read_calls == 4 && write_calls == 3);
    nodes_differ = 0;

    fresh(ctx); fail_sync = 0; dirty_frames = 2;
    check("two dirty pages in one leaf commit",
          db_encrypted_commit(ctx) == 0);
    check("and cause one leaf read for one child MAC update",
          read_calls == 4 && write_calls == 2);
    dirty_frames = 0;

    fresh(ctx); fail_sync = 1;
    check("a failure at the first barrier reports sync",
          db_encrypted_commit(ctx) == E_SYNC);
    check("and poisons the handle", rd64(ctx, DB_MODE) == UINT64_MAX);
    check("without adopting the unpublished generation",
          rd64(ctx, DB_GENERATION) == 7 && rd64(ctx, DB_SB_PAGE) == 1);

    fresh(ctx); fail_sync = 2;
    check("a failure at the second barrier reports sync",
          db_encrypted_commit(ctx) == E_SYNC);
    check("and also poisons the handle", rd64(ctx, DB_MODE) == UINT64_MAX);
    check("because the durable generation is uncertain",
          rd64(ctx, DB_GENERATION) == 7 && rd64(ctx, DB_SB_PAGE) == 1);

    /* --- a deeper tree, and the journal that says which paths to rebuild ----
       Three leaves, one of which this transaction changed. The journal names
       it, so the commit rebuilds one path per level. */
    stub_leaves = 3;
    fresh(ctx); fail_sync = 0;
    wr64(ctx, DB_SEAL_LEAVES, 3);
    wr64(ctx, DB_SEAL_PAGES, 5);
    wr64(ctx, DB_SEAL_DEPTH, 2);
    wr64(ctx, DB_DIRTY_LEAF_N, 1);
    wr64(ctx, DB_DIRTY_LEAVES, 2);
    check("a deep commit driven by the journal succeeds",
          db_encrypted_commit(ctx) == 0);
    journalled_writes = write_calls;
    /* Two node writes and one superblock. Nothing else: the two copies of the
       tree already agreed, so the catch-up compared the root pair and stopped.
       Copying the copy would have been five reads and five writes here, and
       75,904 of each on a file of six million pages. */
    check("and copies nothing when the two copies already agree",
          write_calls == 3);

    /* And when the flush could not record them, every leaf is a path. The
       transaction is still published; it just costs what it used to. */
    fresh(ctx); fail_sync = 0;
    wr64(ctx, DB_SEAL_LEAVES, 3);
    wr64(ctx, DB_SEAL_PAGES, 5);
    wr64(ctx, DB_SEAL_DEPTH, 2);
    wr64(ctx, DB_DIRTY_LEAF_N, 0);
    wr64(ctx, DB_DIRTY_LEAF_OVF, 1);
    check("an overflowed journal still publishes the generation",
          db_encrypted_commit(ctx) == 0);
    check("by walking every leaf instead of the ones it could not name",
          write_calls > journalled_writes);

    /* And when they do not agree, it descends to the difference rather than
       to the bottom. The inactive root differs; the child it names does not. */
    fresh(ctx); fail_sync = 0;
    wr64(ctx, DB_SEAL_LEAVES, 3);
    wr64(ctx, DB_SEAL_PAGES, 5);
    wr64(ctx, DB_SEAL_DEPTH, 2);
    wr64(ctx, DB_DIRTY_LEAF_N, 1);
    wr64(ctx, DB_DIRTY_LEAVES, 2);
    differ_page = 14;                   /* the inactive copy's root */
    check("a divergent root is caught up too",
          db_encrypted_commit(ctx) == 0);
    check("by copying the nodes that differ and not the copy",
          write_calls == journalled_writes + 1);
    differ_page = 0;
    stub_leaves = 1;

    printf("\nencrypted commit engine suite: %d checks, %d failed\n",
           checks, failures);
    return failures ? 1 : 0;
}
