use cyboudb::{Database, Result};
use tempfile::tempdir;

#[test]
fn test_basic_crud_and_index() -> Result<()> {
    let dir = tempdir().unwrap();
    let db_path = dir.path().join("test_crud.cdb");

    let db = Database::create(&db_path, 512)?;

    // Create table with integer, float, bool, text
    db.execute(
        "CREATE TABLE users (id INT32 NOT NULL, name TEXT, balance FLOAT32, active BOOL);",
    )?;

    // Create index
    db.execute("CREATE UNIQUE INDEX idx_users_id ON users (id);")?;

    // Insert with parameters
    {
        let mut insert = db.prepare("INSERT INTO users VALUES (?, ?, ?, ?);")?;
        insert.execute(&[&1, &"Alice", &150.25f32, &true])?;
        insert.execute(&[&2, &"Bob", &42.00f32, &false])?;
        insert.execute(&[&3, &"Charlie", &999.99f32, &true])?;
    }

    // Query with filter
    {
        let mut select =
            db.prepare("SELECT id, name, balance, active FROM users WHERE active = true;")?;
        let mut rows = select.query(&[])?;

        let row1 = rows.next().unwrap()?;
        assert_eq!(row1.get::<i32>(0)?, 1);
        assert_eq!(row1.get::<String>(1)?, "Alice");
        assert!((row1.get::<f32>(2)? - 150.25f32).abs() < 1e-4);
        assert_eq!(row1.get::<bool>(3)?, true);

        let row2 = rows.next().unwrap()?;
        assert_eq!(row2.get::<i32>(0)?, 3);
        assert_eq!(row2.get::<String>(1)?, "Charlie");
        assert_eq!(row2.get::<bool>(3)?, true);

        assert!(rows.next().is_none());
    }

    // Query with parameter placeholder in WHERE clause
    {
        let mut select = db.prepare("SELECT name, balance FROM users WHERE id = ?;")?;
        let mut rows = select.query(&[&2])?;
        let row = rows.next().unwrap()?;
        assert_eq!(row.get::<String>(0)?, "Bob");
        assert!((row.get::<f32>(1)? - 42.0f32).abs() < 1e-4);
        assert!(rows.next().is_none());
    }

    Ok(())
}

#[test]
fn test_queues_and_streams() -> Result<()> {
    let dir = tempdir().unwrap();
    let db_path = dir.path().join("test_qs.cdb");

    let db = Database::create(&db_path, 512)?;

    db.execute("CREATE QUEUE jobs")?;
    db.execute("ENQUEUE INTO jobs VALUES ('task_1_payload')")?;
    db.execute("ENQUEUE INTO jobs VALUES ('task_2_payload')")?;

    let mut dequeue = db.prepare("DEQUEUE FROM jobs")?;
    let msg1 = dequeue.dequeue()?.expect("message 1 expected");
    assert_eq!(String::from_utf8(msg1).unwrap(), "task_1_payload");

    let msg2 = dequeue.dequeue()?.expect("message 2 expected");
    assert_eq!(String::from_utf8(msg2).unwrap(), "task_2_payload");

    let empty = dequeue.dequeue()?;
    assert!(empty.is_none());

    // Stream test
    db.execute("CREATE STREAM audit")?;
    db.execute("CREATE CURSOR reader_1 ON audit")?;
    db.execute("APPEND TO audit VALUES ('event_alpha')")?;
    db.execute("APPEND TO audit VALUES ('event_beta')")?;

    let mut read = db.prepare("READ FROM audit AS reader_1")?;
    let event1 = read.dequeue()?.expect("event 1 expected");
    assert_eq!(String::from_utf8(event1).unwrap(), "event_alpha");

    let event2 = read.dequeue()?.expect("event 2 expected");
    assert_eq!(String::from_utf8(event2).unwrap(), "event_beta");

    Ok(())
}

#[test]
fn test_transactions_atomic_and_rollback() -> Result<()> {
    let dir = tempdir().unwrap();
    let db_path = dir.path().join("test_tx.cdb");

    let mut db = Database::create(&db_path, 512)?;
    db.execute("CREATE TABLE accounts (id INT32 NOT NULL, balance FLOAT32);")?;
    db.execute("CREATE QUEUE outbox;")?;

    // Transaction that succeeds (commit)
    db.transaction(|tx| {
        tx.execute("INSERT INTO accounts VALUES (1, 500.0);")?;
        tx.enqueue("outbox", "account 1 created")?;
        Ok(())
    })?;

    // Verify committed state
    {
        let mut select = db.prepare("SELECT balance FROM accounts WHERE id = 1;")?;
        let mut rows = select.query(&[])?;
        let row = rows.next().unwrap()?;
        assert!((row.get::<f32>(0)? - 500.0f32).abs() < 1e-4);
    }

    // Transaction that fails (rollback)
    let res: Result<()> = db.transaction(|tx| {
        tx.execute("INSERT INTO accounts VALUES (2, 999.0);")?;
        tx.enqueue("outbox", "account 2 created")?;
        Err(cyboudb::Error::SqlError("simulated business error".into()))
    });
    assert!(res.is_err());

    // Verify account 2 was rolled back
    {
        let mut select = db.prepare("SELECT balance FROM accounts WHERE id = 2;")?;
        let mut rows = select.query(&[])?;
        assert!(rows.next().is_none());
    }

    // Verify only the first message is in the queue
    {
        let mut dequeue = db.prepare("DEQUEUE FROM outbox;")?;
        let msg = dequeue.dequeue()?.expect("msg 1 expected");
        assert_eq!(String::from_utf8(msg).unwrap(), "account 1 created");
        assert!(dequeue.dequeue()?.is_none());
    }

    Ok(())
}
