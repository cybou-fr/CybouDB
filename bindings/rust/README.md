# CybouDB Rust Bindings

Idiomatic, memory-safe Rust bindings for [CybouDB](https://github.com/cybou-fr/CybouDB), the dependency-free zero-libc embedded multi-model database engine written in x86-64 assembly.

## Architecture

The Rust workspace consists of two crates:

- **`cyboudb-sys`**: Direct FFI declarations matching `include/cyboudb.h`. Automatically links against `cyboudb.lib` (Windows) or `libcyboudb.a` (Linux).
- **`cyboudb`**: High-level, safe, ergonomic wrapper with automatic RAII resource management (`Drop`), typed parameter binding (`ToParam`), row decoding (`FromColumn`), and closure-based ACID transactions.

## Quick Start

Add to your `Cargo.toml`:

```toml
[dependencies]
cyboudb = { path = "bindings/rust/cyboudb" }
```

*(Or via crates.io once published: `cyboudb = "0.5.0"`)*

### Example

```rust
use cyboudb::{Database, Result};

fn main() -> Result<()> {
    // 1. Create a database (512 pages = 2 MiB)
    let mut db = Database::create("app.cdb", 512)?;

    // 2. Define schema
    db.execute("CREATE TABLE workers (id INT32 NOT NULL, name TEXT, completed INT32);")?;
    db.execute("CREATE UNIQUE INDEX idx_workers_id ON workers (id);")?;
    db.execute("CREATE QUEUE tasks;")?;
    db.execute("CREATE STREAM audit_log;")?;
    db.execute("CREATE CURSOR monitor ON audit_log;")?;

    // 3. Insert and enqueue
    {
        let mut insert = db.prepare("INSERT INTO workers VALUES (?, ?, ?);")?;
        insert.execute(&[&1, &"Alpha", &0])?;
    }
    db.enqueue("tasks", "sync_embeddings")?;

    // 4. Atomic transaction across Queue + Table + Stream
    db.transaction(|tx| {
        // Dequeue task
        let mut deq = tx.prepare("DEQUEUE FROM tasks;")?;
        if let Some(task_bytes) = deq.dequeue()? {
            let task = String::from_utf8(task_bytes).unwrap();
            println!("Processing task: {}", task);
        }

        // Update table
        tx.execute("UPDATE workers SET completed = 1 WHERE id = 1;")?;

        // Append to audit stream
        tx.append("audit_log", "Task completed by worker 1")?;

        Ok(()) // Transaction commits on Ok, rolls back automatically on Err or panic
    })?;

    // 5. Query results with prepared statement
    let mut select = db.prepare("SELECT id, name, completed FROM workers WHERE id = ?;")?;
    let mut rows = select.query(&[&1])?;
    if let Some(row) = rows.next() {
        let row = row?;
        let id: i32 = row.get(0)?;
        let name: String = row.get(1)?;
        let completed: i32 = row.get(2)?;
        println!("Worker #{}: {} (completed: {})", id, name, completed);
    }

    Ok(())
}
```

## Running Examples and Tests

Ensure CybouDB's native static library is built first:

```sh
# On Windows
build.bat --lib

# On Linux
./build.sh --lib
```

Then run tests and examples:

```sh
# Run integration tests
cargo test --workspace --manifest-path bindings/rust/Cargo.toml

# Run quickstart demo
cargo run --example quickstart --manifest-path bindings/rust/cyboudb/Cargo.toml
```

## Features & Safety Guarantees

- **No C Runtime Dependency**: CybouDB native engine executes directly without libc.
- **Zero-Copy / Borrowed Data**: String slices (`&str`), byte slices (`&[u8]`), and vector slices (`&[f32]`) borrow directly when binding parameters.
- **Strict Lifetimes**: Prepared statements borrow the database (`Statement<'db>`) preventing use-after-free or close-while-busy errors at compile time.
- **Automatic Cleanup**: Connections, statements, and uncommitted transactions are cleanly finalized on `Drop`.
- **Cross-Primitive ACID**: Coordinate relational queries, secondary index updates, FIFO queue pops, and stream events in one single transaction block.
