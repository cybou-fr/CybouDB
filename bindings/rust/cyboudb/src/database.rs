use crate::error::{check_rc, Error, Result};
use crate::statement::Statement;
use crate::transaction::Transaction;
use cyboudb_sys as ffi;
use std::ffi::{CStr, CString};
use std::path::Path;

/// High-level connection handle to a CybouDB database file.
pub struct Database {
    raw: *mut ffi::cyboudb_db,
}

unsafe impl Send for Database {}

impl Database {
    /// Create a new database file sized in 4096-byte pages and open it read-write.
    ///
    /// Fails if the file already exists at `path`.
    pub fn create<P: AsRef<Path>>(path: P, pages: u64) -> Result<Self> {
        let path_str = path
            .as_ref()
            .to_str()
            .ok_or_else(|| Error::Io("Path contains non-UTF-8 characters".into()))?;
        let c_path = CString::new(path_str).map_err(|_| Error::Io("Path contains null byte".into()))?;

        let mut raw_db: *mut ffi::cyboudb_db = std::ptr::null_mut();
        let rc = unsafe { ffi::cyboudb_create(c_path.as_ptr(), pages, &mut raw_db) };

        if rc != ffi::CYBOUDB_OK {
            check_rc(rc, raw_db)?;
        }

        Ok(Self { raw: raw_db })
    }

    /// Open an existing database in read-write mode.
    pub fn open<P: AsRef<Path>>(path: P) -> Result<Self> {
        Self::open_with_flags(path, ffi::CYBOUDB_OPEN_READWRITE)
    }

    /// Open an existing database with specific flags (e.g. `CYBOUDB_OPEN_READONLY`).
    pub fn open_with_flags<P: AsRef<Path>>(path: P, flags: u32) -> Result<Self> {
        let path_str = path
            .as_ref()
            .to_str()
            .ok_or_else(|| Error::Io("Path contains non-UTF-8 characters".into()))?;
        let c_path = CString::new(path_str).map_err(|_| Error::Io("Path contains null byte".into()))?;

        let mut raw_db: *mut ffi::cyboudb_db = std::ptr::null_mut();
        let rc = unsafe { ffi::cyboudb_open(c_path.as_ptr(), flags, &mut raw_db) };

        if rc != ffi::CYBOUDB_OK {
            check_rc(rc, raw_db)?;
        }

        Ok(Self { raw: raw_db })
    }

    /// Return the raw database connection pointer.
    pub fn as_raw(&self) -> *mut ffi::cyboudb_db {
        self.raw
    }

    /// Execute a single SQL statement directly.
    pub fn execute(&self, sql: &str) -> Result<()> {
        let c_sql = CString::new(sql).map_err(|_| Error::Misuse("SQL contains null byte".into()))?;
        let rc = unsafe { ffi::cyboudb_exec(self.raw, c_sql.as_ptr()) };
        check_rc(rc, self.raw)
    }

    /// Compile a SQL statement into a prepared statement.
    pub fn prepare<'db>(&'db self, sql: &str) -> Result<Statement<'db>> {
        let c_sql = CString::new(sql).map_err(|_| Error::Misuse("SQL contains null byte".into()))?;
        let mut raw_stmt: *mut ffi::cyboudb_stmt = std::ptr::null_mut();
        let rc = unsafe { ffi::cyboudb_prepare(self.raw, c_sql.as_ptr(), &mut raw_stmt) };
        check_rc(rc, self.raw)?;
        Ok(Statement::new(raw_stmt, self.raw))
    }

    /// Enqueue a payload string into a durable FIFO queue.
    pub fn enqueue(&self, queue: &str, payload: &str) -> Result<()> {
        let escaped = payload.replace('\'', "''");
        let sql = format!("ENQUEUE INTO {} VALUES ('{}')", queue, escaped);
        self.execute(&sql)
    }

    /// Append an event payload string to an append-only stream.
    pub fn append(&self, stream: &str, payload: &str) -> Result<()> {
        let escaped = payload.replace('\'', "''");
        let sql = format!("APPEND TO {} VALUES ('{}')", stream, escaped);
        self.execute(&sql)
    }

    /// Execute operations within an ACID transaction block.
    ///
    /// Automatically commits if the closure returns `Ok`, or rolls back on `Err`.
    pub fn transaction<F, R>(&mut self, f: F) -> Result<R>
    where
        F: FnOnce(&mut Transaction) -> Result<R>,
    {
        let mut tx = Transaction::new(self)?;
        match f(&mut tx) {
            Ok(val) => {
                tx.commit()?;
                Ok(val)
            }
            Err(err) => {
                let _ = tx.rollback();
                Err(err)
            }
        }
    }

    /// Retrieve the message describing the last error on this connection.
    pub fn last_error(&self) -> String {
        unsafe {
            let ptr = ffi::cyboudb_errmsg(self.raw);
            if ptr.is_null() {
                String::new()
            } else {
                CStr::from_ptr(ptr).to_string_lossy().into_owned()
            }
        }
    }

    /// Retrieve the internal numeric error code of the last failure.
    pub fn last_error_code(&self) -> i32 {
        unsafe { ffi::cyboudb_errcode(self.raw) }
    }
}

impl Drop for Database {
    fn drop(&mut self) {
        if !self.raw.is_null() {
            unsafe {
                ffi::cyboudb_close(self.raw);
            }
            self.raw = std::ptr::null_mut();
        }
    }
}
