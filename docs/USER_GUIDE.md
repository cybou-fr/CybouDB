# CybouDB User Guide

CybouDB is an embedded database engine that unifies relational tables, secondary
indexes, exact vector search, durable FIFO queues, and replayable event streams
into a single `.cdb` file sharing a single ACID transaction boundary.

Implemented from scratch in x86-64 assembly with zero external dependencies (no
libc, no C runtime), CybouDB is designed for local-first desktop software, edge
devices, autonomous background workers, and AI applications that require tabular
records, embeddings, and job queues to stay strictly synchronized across system
crashes.

---

## Table of Contents

1. [Mental Model & Architecture](#1-mental-model--architecture)
2. [Building & Installation](#2-building--installation)
3. [Command-Line Interface (CLI) & REPL](#3-command-line-interface-cli--repl)
4. [Relational Data & SQL Dialect](#4-relational-data--sql-dialect)
5. [Secondary B+Tree Indexes](#5-secondary-btree-indexes)
6. [Exact Vector Search](#6-exact-vector-search)
7. [Durable Queues & Worker Leases](#7-durable-queues--worker-leases)
8. [Replayable Event Streams](#8-replayable-event-streams)
9. [Unified Cross-Primitive Transactions](#9-unified-cross-primitive-transactions)
10. [Embedding CybouDB with the C API](#10-embedding-cyboudb-with-the-c-api)
11. [Performance & Operational Best Practices](#11-performance--operational-best-practices)

---

## 1. Mental Model & Architecture

### One File, One Commit Boundary

In a traditional architecture, combining tabular records, vector embeddings,
worker queues, and an audit trail requires four distinct services (e.g., SQLite +
Qdrant + Redis + Kafka). Coordinating state transitions across them requires an
outbox table, distributed transactions, or background reconciliation loops to
recover when one service crashes mid-operation.

```text
Traditional architecture:           CybouDB architecture:

  SQLite (relational)
  + Vector DB (embeddings)            tables + vectors + queues + streams
  + Redis (worker queue)                            ↓
  + Kafka (event stream)                   one ACID transaction
        ↓                                           ↓
  4 distinct systems,                             .cdb
  4 commit boundaries,                      (single file)
  and an outbox pattern
```

In CybouDB, all four primitives live within the same `.cdb` file. An `INSERT` into
a table, an `ENQUEUE` onto a job queue, an `APPEND` to an audit stream, and the
maintenance of secondary indexes commit together or roll back together.

### Copy-on-Write & Generation-Based Crash Recovery

CybouDB uses memory-mapped I/O with 4096-byte logical pages and a dual-superblock
Copy-on-Write (COW) design:

* **Page 0 (File Header)**: Immutable metadata (format version, page size,
  incompatible feature flags, CRC-32C). Written once at creation.
* **Pages 1 & 2 (Superblocks A and B)**: Ping-pong alternating superblocks
  holding the active generation counter, root catalog pointer, and allocation
  maps.
* **Commit Sequence**:
  1. Dirty payload pages are written to newly allocated or free-listed pages.
  2. Data pages are synced to persistent storage (`fsync` / `FlushFileBuffers`).
  3. The inactive superblock copy is written with `generation + 1` and a fresh
     Castagnoli CRC-32C checksum.
  4. The superblock page is synced to persistent storage.

If power is lost at any point during steps 1 through 3, the previous generation's
superblock remains completely intact. Opening the database transparently detects
the uncommitted generation and falls back to the previous intact generation.

> [!IMPORTANT]
> CybouDB employs a **Single-Writer, Concurrent-Reader** concurrency model.
> An advisory file lock (`fcntl` on Linux, `LockFileEx` on Windows) guarantees that
> at most one process mutates a `.cdb` file at a time. Readers do not block writers,
> and readers are pinned against page reclamation during active scans.

---

## 2. Building & Installation

CybouDB requires only NASM and a platform linker. It links against no standard C
library.

### Linux (x86-64)

Install the dependencies via your package manager:
```sh
# Debian / Ubuntu
sudo apt install nasm binutils

# Fedora / RHEL
sudo dnf install nasm binutils

# Arch Linux
sudo pacman -S nasm binutils
```

Build the CLI binary and the static library:
```sh
sh build.sh            # Builds ./cyboudb
sh build.sh --lib      # Builds ./build/libcyboudb.a
```

### Windows (x64)

Install NASM (e.g., via winget):
```cmd
winget install NASM.NASM
```

Run `build.bat`. The script automatically discovers NASM and your linker (preferring
[GoLink](https://godevtool.com/) if installed, or MSVC `link.exe` via Visual Studio's `vswhere`):
```cmd
build.bat              rem Builds cyboudb.exe
build.bat --lib        rem Builds build\cyboudb.lib
```

---

## 3. Command-Line Interface (CLI) & REPL

The `cyboudb` executable provides database creation, ad-hoc querying, interactive
REPL inspection, and structural integrity checking.

### Creating a Database

```sh
cyboudb create <path> <pages> [--force]
```
Files are sized in 4096-byte logical pages. For example, 4,000 pages creates a
16 MiB database:
```sh
cyboudb create app.cdb 4000
```
By default, `cyboudb create` refuses to overwrite an existing file. Add `--force` to
truncate and overwrite.

### Running Ad-Hoc SQL Queries

Execute one or more SQL statements directly from the command line:
```sh
cyboudb query app.cdb "CREATE TABLE items (id INT32 NOT NULL, name TEXT, price FLOAT32)"
cyboudb query app.cdb "INSERT INTO items VALUES (1, 'Widget', 19.99), (2, 'Gadget', 42.50)"
cyboudb query app.cdb "SELECT id, name, price FROM items WHERE price > 20.0"
```

Output:
```text
id | name | price
-------- | -------- | --------
2 | Gadget | 42.50
(1 row)
```

Mutating queries (`INSERT`, `UPDATE`, `DELETE`, DDL) autocommit immediately when
run outside an explicit transaction block. Read-only queries open the file in
read-only mode.

### Interactive Console (REPL)

Start the interactive console by passing the database file path:
```sh
cyboudb app.cdb
```

Inside the console, statements can span multiple lines and end with a semicolon (`;`).
Meta-commands start with a dot (`.`):

| Meta-Command | Description |
| :--- | :--- |
| `.tables` | List all user tables in the catalog |
| `.schema [table]` | Display column names, types, and nullability |
| `.indexes` | List all secondary B+tree indexes |
| `.queues` | List all active FIFO queues |
| `.streams` | List all active append-only streams and cursors |
| `.info` | Display database file header, active generation, and page usage |
| `.help` | Display available console commands |
| `.quit` or `.exit` | Exit the REPL |

You can also pipe SQL scripts into the console via standard input:
```sh
cyboudb app.cdb < migration.sql
```
If any statement fails, the process terminates with a non-zero exit code.

### Validating Database Integrity

To verify every page of every generation, check allocation maps, and recalculate
all CRC-32C checksums:
```sh
cyboudb check app.cdb
```
If any generation contains invalid pages, corrupt headers, or orphaned extents,
`check` prints a diagnostic report and exits with a non-zero status.

---

## 4. Relational Data & SQL Dialect

CybouDB stores tabular data in a **PAX (Partition Attributes Across)** columnar
format. Data is grouped into 64-row leaf groups, where each column's values are
stored contiguously alongside a 64-bit NULL bitmask.

### Supported Data Types

| CybouDB Type | Standard SQL Equivalent | Storage Size | Notes |
| :--- | :--- | :--- | :--- |
| `INT32` | `INTEGER` | 4 bytes | 32-bit signed integer |
| `INT64` | `BIGINT` | 8 bytes | 64-bit signed integer |
| `FLOAT32` | `REAL` | 4 bytes | IEEE 754 single-precision float |
| `BOOL` | `BOOLEAN` | 1 byte | Stored as 0 (FALSE) or 1 (TRUE) |
| `TEXT` | `VARCHAR` / `TEXT` | Extent chain | UTF-8 byte string |
| `BLOB` | `VARBINARY` / `BLOB` | Extent chain | Arbitrary binary data (`X'00FF'`) |
| `VECTOR` | `VECTOR(FLOAT32, n)` | Extent/Arena | Float array of dimension $n$ (1..4096) |

### Table DDL

Tables support 1 to 64 columns. Names are case-insensitive and can be up to 31
characters long. Columns default to `NULL` unless marked `NOT NULL`.

```sql
CREATE TABLE products (
    id INT64 NOT NULL,
    title TEXT NOT NULL,
    sku TEXT,
    price FLOAT32 NOT NULL,
    in_stock BOOL,
    embedding VECTOR(FLOAT32, 4)
);

DROP TABLE products;
```

### Multi-Row Inserts

You can insert up to 256 rows in a single `INSERT` statement:

```sql
INSERT INTO products VALUES
    (1, 'Mechanical Keyboard', 'KB-01', 129.99, true, '[0.12, 0.45, -0.22, 0.89]'),
    (2, 'Gaming Mouse', 'MS-02', 59.50, true, '[0.05, 0.31, 0.81, -0.10]'),
    (3, 'Desk Mat', null, 24.00, false, null);
```

### Querying & Filtering

`SELECT` expressions support projection, arithmetic predicates, and three-valued
logic (3VL):

```sql
SELECT id, title, price
FROM products
WHERE in_stock = true AND price < 100.0;
```

#### Three-Valued Logic & NULL Handling

Comparisons with `NULL` evaluate to *unknown*. To check for nullability, use
`IS NULL` or `IS NOT NULL`:

```sql
SELECT title FROM products WHERE sku IS NOT NULL;
```

#### Sorting & Pagination

Use `ORDER BY`, `LIMIT`, and `OFFSET` for deterministic pagination:

```sql
SELECT id, title, price
FROM products
ORDER BY price
LIMIT 5 OFFSET 10;
```

#### Equi-Joins

CybouDB supports `INNER JOIN` and `LEFT JOIN` on integer keys (`INT32` or `INT64`):

```sql
SELECT o.id, c.name, o.amount
FROM orders o
INNER JOIN customers c ON o.customer_id = c.id
WHERE o.amount > 50.0;
```

### Updates & Deletions

`UPDATE` statements modify values in-place within the copy-on-write leaf:

```sql
UPDATE products
SET price = 119.99, in_stock = true
WHERE id = 1;
```

`DELETE` utilizes a per-row tombstone reservation, marking rows as deleted
without having to immediately rewrite the whole table. Deleted rows are skipped
during sequential and index scans, and reclaimed during subsequent compaction:

```sql
DELETE FROM products WHERE in_stock = false;
```

---

## 5. Secondary B+Tree Indexes

CybouDB supports copy-on-write B+tree secondary indexes over `INT32` and `INT64`
columns. Indexes can be declared unique or non-unique:

```sql
CREATE UNIQUE INDEX idx_products_id ON products (id);
CREATE INDEX idx_products_instock ON products (in_stock);
```

### How the Planner Uses Indexes

When a query predicate filters on an indexed column using equality (`=`) or range
comparisons (`<`, `<=`, `>`, `>=`), the query planner performs a B+tree seek
rather than a full columnar table scan:

```sql
-- Uses index seek on idx_products_id:
SELECT title, price FROM products WHERE id = 42;

-- Uses index range scan:
SELECT title, price FROM products WHERE id >= 100 AND id < 200;
```

Every `INSERT`, `UPDATE`, and `DELETE` automatically updates associated B+trees
within the same transaction.

---

## 6. Exact Vector Search

For semantic search, recommendation systems, and AI embeddings, CybouDB supports
native vector columns and exact Top-K similarity queries.

### Vector Schema & Insertion

Declare vector dimensions (up to 4096 dimensions) with `VECTOR(FLOAT32, dim)`:

```sql
CREATE TABLE documents (
    id INT64 NOT NULL,
    content TEXT,
    embedding VECTOR(FLOAT32, 3)
);

INSERT INTO documents VALUES
    (1, 'Database internals', '[0.9, 0.1, 0.0]'),
    (2, 'Kernel development', '[0.8, 0.3, 0.1]'),
    (3, 'Cooking recipes', '[0.0, 0.1, 0.9]');
```

### Top-K Queries in SQL

CybouDB supports Euclidean distance (`<->`) and Cosine distance (`<=>`). Combine
distance ordering with `LIMIT k` to perform exact Top-K retrieval:

```sql
-- Retrieve the 2 documents most similar to the query vector:
SELECT id, content
FROM documents
ORDER BY embedding <=> '[0.85, 0.2, 0.05]'
LIMIT 2;
```

Vector scans leverage SIMD vectorization (AVX2 + FMA) and skip rows pruned by
tabular `WHERE` filters before computing dot products.

---

## 7. Durable Queues & Worker Leases

CybouDB includes a built-in transactional FIFO queue mechanism directly in the
`.cdb` file.

```sql
CREATE QUEUE task_queue;
DROP QUEUE task_queue;
```

### Producing Messages (`ENQUEUE`)

Messages can contain arbitrary binary or text payloads:

```sql
ENQUEUE INTO task_queue VALUES ('{"task": "render_video", "id": 1042}');
```

### Basic Consumption (`DEQUEUE`)

`DEQUEUE` removes the message at the head of the queue inside the current
transaction:

```sql
DEQUEUE FROM task_queue;
```

When called via the C API or CLI, `DEQUEUE` yields the message payload as raw
bytes and advances the queue head cursor.

### Worker Leases (`CLAIM`, `ACK`, `NACK`, `RENEW`)

For long-running background tasks, consuming with immediate deletion is dangerous:
if the worker process dies midway through processing, the job is lost forever.

CybouDB provides **Queue Leases**, enabling worker pools to claim jobs with a
deadline. A claim returns a **ticket** - a position and a token - and every
other lease statement names it:

```sql
-- 1. Take the next claimable message and hold it for 30,000 ms (30s).
CLAIM FROM task_queue FOR 30000;
-- Prints the payload, then the ticket:  AT 41 TOKEN 3

-- 2a. On success: finish it, in the same transaction as the work's own writes.
ACK   FROM task_queue AT 41 TOKEN 3;

-- 2b. On failure: hand it back for immediate retry, rather than after a timeout.
NACK  FROM task_queue AT 41 TOKEN 3;

-- 2c. If the work runs long: extend the deadline before it passes.
RENEW FROM task_queue AT 41 TOKEN 3 FOR 30000;
```

A database must be created for leases - `cyboudb create-leases`, or
`cyboudb_create_with_options` with `CybouDB_CREATE_QUEUE_LEASES`. It is decided
when the file is made and never afterwards, so a database created without it
stays readable by builds that predate leases. In C the payload comes out
through `cyboudb_message` the way a `DEQUEUE`'s does, and `cyboudb_claim_ticket`
hands back the two numbers;
[`examples/leased_worker.c`](../examples/leased_worker.c) is the whole loop.

#### Lease Guarantees:
* A claimed message is hidden from all other workers until its deadline expires or
  it is `NACK`ed.
* If a worker crashes, the lease expires automatically based on the high-water
  wall clock. The message becomes immediately claimable by another worker without
  requiring explicit recovery cleanup.
* **The deadline decides when a message becomes claimable again; the token
  decides whose acknowledgement counts.** A lapsed lease is not by itself a
  refusal - if nobody re-claimed the message, the late `ACK` is accepted. If
  somebody did, the reclaim raised the token, so the late `ACK` is refused and
  the job cannot be finished twice. No clock error of any size can cost the
  queue's integrity.
* Nothing is written when a lease lapses: expiry is a predicate, not an event,
  so recovering a dead worker's message costs no sweeper and no write.

---

## 8. Replayable Event Streams

Streams provide durable, append-only event logs (analogous to Kafka topics) with
named consumer group cursors.

```sql
CREATE STREAM audit_log;
DROP STREAM audit_log;
```

### Appending Events

```sql
APPEND TO audit_log VALUES ('user_login: uid=42 ip=192.168.1.1');
APPEND TO audit_log VALUES ('order_placed: order_id=9872');
```

### Consuming with Named Durable Cursors

Each stream supports up to 8 named persistent cursors. Reading advances the
cursor position durably on commit:

```sql
-- Read the next unread event for consumer "indexer":
READ FROM audit_log AS indexer;
```

### Trimming & Retention

To prevent unbounded disk growth, streams can be trimmed:

```sql
TRIM STREAM audit_log BEFORE 1000;
```

> [!CAUTION]
> **Cursor Protection:** `TRIM STREAM` will refuse to prune past the position of
> the slowest registered consumer cursor. A fast consumer cannot truncate events
> that a lagging consumer has yet to process.

---

## 9. Unified Cross-Primitive Transactions

The defining feature of CybouDB is that transactions span **all** data primitives:

```sql
BEGIN;

-- 1. Take a task from the inbox queue
DEQUEUE FROM inbox;

-- 2. Update relational status
UPDATE jobs SET status = 'completed', completed_at = 1726344000 WHERE id = 1042;

-- 3. Append to the audit stream
APPEND TO audit_log VALUES ('job 1042 marked completed by worker-3');

-- 4. Publish next downstream task
ENQUEUE INTO notifications VALUES ('send_email: job 1042 ready');

COMMIT;
```

If the host machine loses power before `COMMIT` completes:
* The inbox message remains in the queue.
* The job status remains untouched.
* The audit log event is not appended.
* The downstream notification is not queued.

No partial state can leak.

---

## 10. Embedding CybouDB with the C API

The public C interface is declared in [`include/cyboudb.h`](file:///c:/Users/cybou/Documents/CybouDB/include/cyboudb.h).
Link against `libcyboudb.a` (Linux) or `cyboudb.lib` (Windows).

### Complete C Example

```c
#include <stdio.h>
#include <stdint.h>
#include "cyboudb.h"

int main(void) {
    cyboudb_db *db = NULL;
    cyboudb_stmt *stmt = NULL;

    // 1. Create or open database (512 pages = 2 MiB)
    int rc = cyboudb_create("app.cdb", 512, &db);
    if (rc != CybouDB_OK) {
        // If file exists, open read-write
        rc = cyboudb_open("app.cdb", CybouDB_OPEN_READWRITE, &db);
        if (rc != CybouDB_OK) {
            fprintf(stderr, "Failed to open database: %s\n", cyboudb_errmsg(db));
            return 1;
        }
    }

    // 2. Execute schema setup
    cyboudb_exec(db, "CREATE TABLE users (id INT32 NOT NULL, name TEXT, balance FLOAT32)");

    // 3. Insert using parameterized prepared statement
    rc = cyboudb_prepare(db, "INSERT INTO users VALUES (?, ?, ?)", &stmt);
    if (rc == CybouDB_OK) {
        // Bind parameters: 0-indexed
        cyboudb_bind_int32(stmt, 0, 101);
        cyboudb_bind_text(stmt, 1, "Alice", -1);  // -1 for null-terminated string
        cyboudb_bind_float(stmt, 2, 250.75f);

        if (cyboudb_step(stmt) != CybouDB_DONE) {
            fprintf(stderr, "Insert failed: %s\n", cyboudb_errmsg(db));
        }
        cyboudb_finalize(stmt);
    }

    // 4. Query data
    rc = cyboudb_prepare(db, "SELECT id, name, balance FROM users WHERE id = ?", &stmt);
    if (rc == CybouDB_OK) {
        cyboudb_bind_int32(stmt, 0, 101);

        while (cyboudb_step(stmt) == CybouDB_ROW) {
            int32_t id = cyboudb_column_int32(stmt, 0);
            float balance = cyboudb_column_float(stmt, 2);

            char name[64];
            uint64_t name_len = 0;
            cyboudb_column_bytes(stmt, 1, name, sizeof(name) - 1, &name_len);
            name[name_len] = '\0';

            printf("User: id=%d, name=%s, balance=%.2f\n", id, name, balance);
        }
        cyboudb_finalize(stmt);
    }

    // 5. Close connection
    cyboudb_close(db);
    return 0;
}
```

### Parameter Binding Rules

* Placeholders use the standard `?` syntax.
* Parameters are 0-indexed.
* Parameter types are strictly checked against column definitions:
  * `cyboudb_bind_int32(stmt, idx, val)`
  * `cyboudb_bind_int64(stmt, idx, val)`
  * `cyboudb_bind_float(stmt, idx, val)`
  * `cyboudb_bind_bool(stmt, idx, val)`
  * `cyboudb_bind_text(stmt, idx, str, len)`
  * `cyboudb_bind_blob(stmt, idx, buf, len)`
  * `cyboudb_bind_vector_f32(stmt, idx, floats, dim)`
  * `cyboudb_bind_null(stmt, idx)`
* Text, Blob, and Vector values are copied by the engine into statement-local
  memory during bind. The caller does not need to maintain the buffer lifetime.
* Re-executing queries: call `cyboudb_reset(stmt)` to rerun with the same or new
  bindings. Call `cyboudb_clear_bindings(stmt)` to unbind all parameters.

> [!WARNING]
> Always call `cyboudb_finalize(stmt)` on all prepared statements before calling
> `cyboudb_close(db)`. If active statements remain, `cyboudb_close` returns
> `CybouDB_BUSY` and keeps the database open.

### High-Throughput Columnar Batch Reading

For analytical scans, avoid row-by-row overhead using `cyboudb_step_batch`:

```c
const cyboudb_batch_view *batch = NULL;
uint64_t lane_mask = 0;

while (cyboudb_step_batch(stmt, &batch, &lane_mask) == CybouDB_ROW) {
    // batch->row_count holds number of active rows in this run (up to 64)
    const cyboudb_colview *col = cyboudb_batch_column(stmt, batch, 0);
    const int32_t *ids = (const int32_t *)col->values_ptr;

    for (uint64_t i = 0; i < batch->row_count; ++i) {
        if ((lane_mask & (1ULL << i)) && !(col->null_mask & (1ULL << i))) {
            // Process ids[i] directly from mmap storage
        }
    }
}
```

---

## 11. Performance & Operational Best Practices

### 1. Batch Write Operations
CybouDB enforces durability by issuing two storage flushes (`vfs_sync`) per
commit. Committing a single row or message in isolation incurs the full latency
of disk sync (~1 millisecond on NVMe).
* **Single message per commit**: ~1,120 μs.
* **100 messages per commit**: ~20.75 μs per message (50x throughput improvement).
* **Recommendation**: Wrap multiple `INSERT` or `ENQUEUE` statements inside an
  explicit `BEGIN ... COMMIT` block.

### 2. Take Advantage of Zone Map Pruning
CybouDB automatically maintains Min/Max zone maps for every 64-row PAX group on
numeric columns. Inserting data roughly sorted by time or sequence key allows
scans with range predicates (`WHERE timestamp > ?`) to skip reading up to 99% of
pages entirely.

### 3. Sizing Your Database
Database size is fixed in 4096-byte pages at creation time:
* 1,000 pages = 4 MiB
* 25,000 pages = 100 MiB
* 250,000 pages = 1 GiB
Size your database generously upfront. Allocation within the file is dynamic, and
unused pages cost no physical memory until touched.

### 4. When to Use CybouDB (and When Not To)

**Ideal Use Cases:**
* Embedded apps, desktop clients (Electron, Tauri, native), and local-first software.
* Autonomous background agents and worker processes needing queues + relational storage.
* Edge devices requiring high analytical query speed without server administration.
* Multi-modal AI pipelines storing embeddings alongside source metadata.

**Not Suitable For:**
* Multi-writer server workloads (CybouDB allows only one writer process at a time).
* Distributed databases requiring horizontal multi-node sharding.
* Massive vector collections (millions of vectors) requiring approximate ANN graphs (HNSW/IVF).
