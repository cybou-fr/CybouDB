"""
CybouDB Python Quickstart Example

Demonstrates:
- Creating a unified .cdb database file
- Relational tables and secondary B+tree indexes
- Durable FIFO queues
- Replayable event streams
- Unified cross-primitive ACID transactions
"""

import os
import cyboudb

DB_PATH = "quickstart_demo.cdb"

def main():
    # Clean up old demo file if present
    if os.path.exists(DB_PATH):
        os.remove(DB_PATH)

    print("=== CybouDB Python Quickstart Demo ===")
    print(f"-> Engine Version: {cyboudb.version()}")

    # 1. Create a database (512 pages = 2 MiB)
    print(f"-> Creating database: {DB_PATH}")
    db = cyboudb.Database.create(DB_PATH, pages=512)

    try:
        # 2. Schema definition
        print("-> Creating schema (Table, Index, Queue, Stream, Cursor)...")
        db.execute("CREATE TABLE workers (id INT32 NOT NULL, name TEXT, completed INT32);")
        db.execute("CREATE UNIQUE INDEX idx_workers_id ON workers (id);")
        db.execute("CREATE QUEUE tasks;")
        db.execute("CREATE STREAM audit_log;")
        db.execute("CREATE CURSOR monitor ON audit_log;")

        # 3. Populate data
        print("-> Populating workers with parameterized statements...")
        db.execute("INSERT INTO workers VALUES (?, ?, ?);", [1, "Worker Alpha", 0])
        db.execute("INSERT INTO workers VALUES (?, ?, ?);", [2, "Worker Beta", 0])

        # 4. Enqueue jobs
        print("-> Enqueueing tasks into 'tasks' FIFO queue...")
        db.enqueue("tasks", "sync_embeddings")
        db.enqueue("tasks", "generate_summary")

        # 5. Atomic cross-primitive transaction
        print("-> Executing atomic transaction across Queue + Table + Stream...")
        with db.transaction() as tx:
            # Dequeue next task
            task_bytes = tx.dequeue("tasks")
            task_str = task_bytes.decode("utf-8") if task_bytes else "unknown"
            print(f"   [Tx] Dequeued job: '{task_str}'")

            # Update relational worker record
            tx.execute("UPDATE workers SET completed = 1 WHERE id = 1;")
            print("   [Tx] Updated completed count for Worker #1")

            # Append audit event to stream
            tx.append("audit_log", f"Worker Alpha completed '{task_str}'")
            print("   [Tx] Appended audit log event to stream")

            # Block commits automatically at exit; rolls back on exception
            print("   [Tx] Committing transaction atomically...")

        # 6. Query updated state
        print("-> Querying workers from table:")
        rows = db.query("SELECT id, name, completed FROM workers WHERE id = ?;", [1])
        for row in rows:
            print(f"   Worker #{row[0]}: Name='{row[1]}', Completed={row[2]}")

        # 7. Read stream events
        print("-> Reading audit event from stream as cursor 'monitor':")
        event = db.read_stream("audit_log", "monitor")
        if event:
            print(f"   Stream Event: {event.decode('utf-8')}")

    finally:
        db.close()
        if os.path.exists(DB_PATH):
            os.remove(DB_PATH)

    print("=== Demo completed successfully! ===")

if __name__ == "__main__":
    main()
