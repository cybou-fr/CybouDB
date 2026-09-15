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
#define E_SYNC 19

static int checks, failures, sync_calls, fail_sync;
static int read_calls, write_calls, nodes_differ;
static int dirty_frames;

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
uint64_t cyboudb_pcache_frames(const uint8_t *cache) {
    (void)cache; return (uint64_t)dirty_frames;
}
uint64_t cyboudb_pcache_dirty_at(const uint8_t *cache, uint64_t slot) {
    (void)cache; return slot < (uint64_t)dirty_frames ? slot + 1 : UINT64_MAX;
}
int64_t vfs_read_at(int64_t h, void *buf, uint64_t bytes, uint64_t offset) {
    (void)h; read_calls++; memset(buf, 0, (size_t)bytes);
    if (nodes_differ && offset == 6 * PAGE) ((uint8_t *)buf)[64] = 1;
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
    memset(ctx, 0, 1024);
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
    uint8_t ctx[1024];
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

    printf("\nencrypted commit engine suite: %d checks, %d failed\n",
           checks, failures);
    return failures ? 1 : 0;
}
