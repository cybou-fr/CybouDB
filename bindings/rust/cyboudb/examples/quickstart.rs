use cyboudb::{Database, Result};
use std::fs;
use std::path::Path;

fn main() -> Result<()> {
    let db_path = "quickstart_demo.cdb";
    if Path::new(db_path).exists() {
        let _ = fs::remove_file(db_path);
    }

    println!("=== CybouDB Rust Quickstart Demo ===");

    // 1. Create a database (512 pages = 2 MiB)
    println!("-> Creating database: {}", db_path);
    let mut db = Database::create(db_path, 512)?;

    // 2. Create tables, queues, streams
    println!("-> Creating schema...");
    db.execute("CREATE TABLE workers (id INT32 NOT NULL, name TEXT, tasks_completed INT32);")?;
    db.execute("CREATE UNIQUE INDEX idx_workers_id ON workers (id);")?;
    db.execute("CREATE QUEUE tasks;")?;
    db.execute("CREATE STREAM audit_log;")?;
    db.execute("CREATE CURSOR app_monitor ON audit_log;")?;

    // 3. Populate workers
    println!("-> Populating workers...");
    {
        let mut insert = db.prepare("INSERT INTO workers VALUES (?, ?, ?);")?;
        insert.execute(&[&1, &"Worker Alpha", &0])?;
        insert.execute(&[&2, &"Worker Beta", &0])?;
    }

    // 4. Enqueue initial tasks
    println!("-> Enqueueing jobs into 'tasks' queue...");
    db.enqueue("tasks", "compress_images")?;
    db.enqueue("tasks", "sync_embeddings")?;

    // 5. Execute an atomic cross-primitive transaction
    println!("-> Executing atomic transaction across Queue + Table + Stream...");
    db.transaction(|tx| {
        // a. Take task from queue
        let task_name = {
            let mut deq = tx.prepare("DEQUEUE FROM tasks;")?;
            let task_bytes = deq.dequeue()?.expect("task should be present");
            String::from_utf8(task_bytes).unwrap()
        };
        println!("   [Tx] Dequeued task: '{}'", task_name);

        // b. Update worker stats
        tx.execute("UPDATE workers SET tasks_completed = 1 WHERE id = 1;")?;
        println!("   [Tx] Updated tasks_completed for worker 1 to 1");

        // c. Append audit record to stream
        let log_msg = format!("Task '{}' processed by Worker Alpha", task_name);
        tx.append("audit_log", &log_msg)?;
        println!("   [Tx] Appended audit event to stream");

        Ok(())
    })?;

    // 6. Query results
    println!("-> Querying current workers:");
    {
        let mut select = db.prepare("SELECT id, name, tasks_completed FROM workers WHERE id = ?;")?;
        let mut rows = select.query(&[&1])?;
        if let Some(row) = rows.next() {
            let row = row?;
            println!(
                "   ID: {}, Name: {}, Completed: {}",
                row.get::<i32>(0)?,
                row.get::<String>(1)?,
                row.get::<i32>(2)?
            );
        }
    }

    // 7. Read from audit stream
    println!("-> Reading from 'audit_log' stream as cursor 'app_monitor':");
    {
        let mut read = db.prepare("READ FROM audit_log AS app_monitor;")?;
        if let Some(msg_bytes) = read.dequeue()? {
            println!("   Stream Event: {}", String::from_utf8(msg_bytes).unwrap());
        }
    }

    // Clean up demo file
    drop(db);
    let _ = fs::remove_file(db_path);

    println!("=== Demo completed successfully! ===");
    Ok(())
}
