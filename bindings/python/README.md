# CybouDB Python Bindings

Official, high-performance Python bindings for [CybouDB](https://github.com/cybou-fr/CybouDB), the zero-dependency embedded columnar database engine written from scratch in x86-64 assembly.

CybouDB uniquely consolidates **relational tables**, **secondary B+tree indexes**, **exact vector search**, **durable FIFO queues**, and **replayable event streams** into a single `.cdb` file under one ACID transaction boundary.

## Installation

```bash
pip install cyboudb
```

*(Or build locally from source with `maturin build`)*

## Quick Start

```python
import cyboudb

# 1. Create a database file (512 pages = 2 MiB)
db = cyboudb.Database.create("app.cdb", pages=512)

# 2. Define schema
db.execute("CREATE TABLE workers (id INT32 NOT NULL, name TEXT, tasks INT32);")
db.execute("CREATE UNIQUE INDEX idx_worker_id ON workers (id);")
db.execute("CREATE QUEUE tasks;")
db.execute("CREATE STREAM audit_log;")
db.execute("CREATE CURSOR monitor ON audit_log;")

# 3. Populate data with typed parameters
db.execute("INSERT INTO workers VALUES (?, ?, ?);", [1, "Worker Alpha", 0])
db.execute("INSERT INTO workers VALUES (?, ?, ?);", [2, "Worker Beta", 0])
db.enqueue("tasks", "compute_embeddings")

# 4. Atomic transaction across Queue + Table + Stream
with db.transaction() as tx:
    # Pop job from FIFO queue
    task = tx.dequeue("tasks")
    if task:
        print(f"Processing: {task.decode('utf-8')}")

    # Update relational state
    tx.execute("UPDATE workers SET tasks = 1 WHERE id = 1;")

    # Append audit trail event to stream
    tx.append("audit_log", "Worker Alpha completed compute_embeddings")
    # Automatically COMMITS on exiting block, or ROLLS BACK on exception

# 5. Query relational records
rows = db.query("SELECT id, name, tasks FROM workers WHERE id = ?;", [1])
for row in rows:
    print(f"Worker #{row[0]}: {row[1]} (tasks: {row[2]})")

# 6. Read from stream
event = db.read_stream("audit_log", "monitor")
if event:
    print(f"Stream Event: {event.decode('utf-8')}")

# 7. Close connection
db.close()
```

## Features

- **Zero-Copy / Native Speed**: Powered by CybouDB's x86-64 assembly engine and PyO3.
- **Python Context Managers**: `with db.transaction():` ensures automatic rollback on unhandled exceptions.
- **Dynamic Parameter Binding**: Supports Python `int`, `float`, `str`, `bytes`, and vectors (`list[float]`).
- **Single Commit Boundary**: Tables, vector indexes, worker queues, and event logs always stay strictly in sync across process crashes.
