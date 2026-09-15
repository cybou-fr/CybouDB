use crate::error::{check_rc, Error, Result};
use crate::value::{FromColumn, ToParam};
use cyboudb_sys as ffi;
use std::ffi::{c_int, c_void, CStr};
use std::marker::PhantomData;

/// Represents a compiled SQL prepared statement.
pub struct Statement<'db> {
    raw: *mut ffi::cyboudb_stmt,
    db_raw: *mut ffi::cyboudb_db,
    _marker: PhantomData<&'db ()>,
}

impl<'db> Statement<'db> {
    pub(crate) fn new(raw: *mut ffi::cyboudb_stmt, db_raw: *mut ffi::cyboudb_db) -> Self {
        Self {
            raw,
            db_raw,
            _marker: PhantomData,
        }
    }

    /// Return the raw statement pointer.
    pub fn as_raw(&self) -> *mut ffi::cyboudb_stmt {
        self.raw
    }

    /// Return the number of parameters expected by the statement (`?` count).
    pub fn parameter_count(&self) -> usize {
        unsafe { ffi::cyboudb_bind_parameter_count(self.raw).max(0) as usize }
    }

    /// Bind a single parameter at a 0-based index.
    pub fn bind<T: ToParam>(&mut self, idx: usize, param: T) -> Result<()> {
        param.bind(self.raw, idx as c_int)
    }

    /// Clear all bound parameter values.
    pub fn clear_bindings(&mut self) -> Result<()> {
        let rc = unsafe { ffi::cyboudb_clear_bindings(self.raw) };
        check_rc(rc, self.db_raw)
    }

    /// Reset the statement back to its initial state to execute again.
    pub fn reset(&mut self) -> Result<()> {
        let rc = unsafe { ffi::cyboudb_reset(self.raw) };
        check_rc(rc, self.db_raw)
    }

    /// Return the number of projected columns in the result set.
    pub fn column_count(&self) -> usize {
        unsafe { ffi::cyboudb_column_count(self.raw).max(0) as usize }
    }

    /// Return the name of the column at a 0-based index.
    pub fn column_name(&self, idx: usize) -> Option<&str> {
        unsafe {
            let ptr = ffi::cyboudb_column_name(self.raw, idx as c_int);
            if ptr.is_null() {
                None
            } else {
                CStr::from_ptr(ptr).to_str().ok()
            }
        }
    }

    /// Advance statement execution by one step.
    ///
    /// Returns `Ok(true)` if another row is ready, or `Ok(false)` if finished (`DONE`).
    pub fn step(&mut self) -> Result<bool> {
        let rc = unsafe { ffi::cyboudb_step(self.raw) };
        match rc {
            ffi::CYBOUDB_ROW => Ok(true),
            ffi::CYBOUDB_DONE => Ok(false),
            other => {
                check_rc(other, self.db_raw)?;
                Ok(false)
            }
        }
    }

    /// Execute a mutating statement (e.g. INSERT, UPDATE, DELETE, DDL).
    pub fn execute(&mut self, params: &[&dyn ToParam]) -> Result<()> {
        self.reset()?;
        for (i, p) in params.iter().enumerate() {
            p.bind(self.raw, i as c_int)?;
        }
        let rc = unsafe { ffi::cyboudb_step(self.raw) };
        if rc == ffi::CYBOUDB_DONE || rc == ffi::CYBOUDB_ROW {
            self.reset()?;
            Ok(())
        } else {
            let err = check_rc(rc, self.db_raw);
            let _ = self.reset();
            err
        }
    }

    /// Execute query and return an iterator over matching rows.
    pub fn query<'stmt>(&'stmt mut self, params: &[&dyn ToParam]) -> Result<Rows<'stmt, 'db>> {
        self.reset()?;
        for (i, p) in params.iter().enumerate() {
            p.bind(self.raw, i as c_int)?;
        }
        let raw = self.raw;
        Ok(Rows {
            stmt: self,
            stmt_raw: raw,
            done: false,
        })
    }

    /// Helper for consuming from a queue using `DEQUEUE FROM queue`.
    ///
    /// Steps the statement and copies the message payload. Returns `Ok(None)` if the queue is empty.
    pub fn dequeue(&mut self) -> Result<Option<Vec<u8>>> {
        let has_row = self.step()?;
        if !has_row {
            self.reset()?;
            return Ok(None);
        }

        let mut length: u64 = 0;
        let mut buf = vec![0u8; 1024];

        let rc = unsafe {
            ffi::cyboudb_message(
                self.raw,
                buf.as_mut_ptr() as *mut c_void,
                buf.len() as u64,
                &mut length,
            )
        };

        let result = if rc == ffi::CYBOUDB_OK {
            if length > buf.len() as u64 {
                buf.resize(length as usize, 0);
                let rc2 = unsafe {
                    ffi::cyboudb_message(
                        self.raw,
                        buf.as_mut_ptr() as *mut c_void,
                        buf.len() as u64,
                        &mut length,
                    )
                };
                if rc2 != ffi::CYBOUDB_OK {
                    return Err(Error::SqlError("Failed to fetch message bytes".into()));
                }
            }
            buf.truncate(length as usize);
            Ok(Some(buf))
        } else {
            Err(Error::SqlError("Failed to read dequeued message".into()))
        };

        self.reset()?;
        result
    }
}

impl<'db> Drop for Statement<'db> {
    fn drop(&mut self) {
        if !self.raw.is_null() {
            unsafe {
                ffi::cyboudb_finalize(self.raw);
            }
            self.raw = std::ptr::null_mut();
        }
    }
}

/// Iterator over rows returned by a query.
pub struct Rows<'stmt, 'db> {
    stmt: &'stmt mut Statement<'db>,
    stmt_raw: *mut ffi::cyboudb_stmt,
    done: bool,
}

impl<'stmt, 'db> Iterator for Rows<'stmt, 'db> {
    type Item = Result<Row<'stmt>>;

    fn next(&mut self) -> Option<Self::Item> {
        if self.done {
            return None;
        }

        match self.stmt.step() {
            Ok(true) => Some(Ok(Row {
                raw: self.stmt_raw,
                _marker: PhantomData,
            })),
            Ok(false) => {
                self.done = true;
                None
            }
            Err(e) => {
                self.done = true;
                Some(Err(e))
            }
        }
    }
}

/// View into the current row of an active query.
pub struct Row<'stmt> {
    raw: *mut ffi::cyboudb_stmt,
    _marker: PhantomData<&'stmt ()>,
}

impl<'stmt> Row<'stmt> {
    /// Return the number of columns in the row.
    pub fn column_count(&self) -> usize {
        unsafe { ffi::cyboudb_column_count(self.raw).max(0) as usize }
    }

    /// Check if the column value is NULL.
    pub fn is_null(&self, idx: usize) -> bool {
        unsafe { ffi::cyboudb_column_is_null(self.raw, idx as c_int) != 0 }
    }

    /// Read a typed column value at a 0-based index.
    pub fn get<T: FromColumn>(&self, idx: usize) -> Result<T> {
        let count = self.column_count();
        if idx >= count {
            return Err(Error::ColumnIndexOutOfBounds { index: idx, count });
        }
        T::from_column(self.raw, idx as c_int)
    }
}
