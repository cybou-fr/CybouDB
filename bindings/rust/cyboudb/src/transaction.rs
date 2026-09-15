use crate::database::Database;
use crate::error::Result;
use crate::statement::Statement;

/// Represents an active ACID transaction on a CybouDB database.
pub struct Transaction<'a> {
    db: &'a mut Database,
    finished: bool,
}

impl<'a> Transaction<'a> {
    pub(crate) fn new(db: &'a mut Database) -> Result<Self> {
        db.execute("BEGIN")?;
        Ok(Self {
            db,
            finished: false,
        })
    }

    /// Execute a SQL statement within this transaction.
    pub fn execute(&self, sql: &str) -> Result<()> {
        self.db.execute(sql)
    }

    /// Prepare a statement within this transaction.
    pub fn prepare<'tx>(&'tx self, sql: &str) -> Result<Statement<'tx>> {
        self.db.prepare(sql)
    }

    /// Enqueue a message into a durable FIFO queue.
    pub fn enqueue(&self, queue: &str, payload: &str) -> Result<()> {
        let escaped = payload.replace('\'', "''");
        let sql = format!("ENQUEUE INTO {} VALUES ('{}')", queue, escaped);
        self.db.execute(&sql)
    }

    /// Append an event record to a durable stream.
    pub fn append(&self, stream: &str, payload: &str) -> Result<()> {
        let escaped = payload.replace('\'', "''");
        let sql = format!("APPEND TO {} VALUES ('{}')", stream, escaped);
        self.db.execute(&sql)
    }

    /// Manually commit the transaction.
    pub fn commit(mut self) -> Result<()> {
        self.finished = true;
        self.db.execute("COMMIT")
    }

    /// Manually rollback the transaction.
    pub fn rollback(mut self) -> Result<()> {
        self.finished = true;
        self.db.execute("ROLLBACK")
    }
}

impl<'a> Drop for Transaction<'a> {
    fn drop(&mut self) {
        if !self.finished {
            let _ = self.db.execute("ROLLBACK");
            self.finished = true;
        }
    }
}
