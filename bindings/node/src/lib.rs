use cyboudb_core::{Error as CybouError, Result as CybouResult, ToParam, Value};
use napi::bindgen_prelude::*;
use napi_derive::napi;
use std::ffi::c_int;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

fn to_napi_err(err: CybouError) -> napi::Error {
    napi::Error::new(napi::Status::GenericFailure, err.to_string())
}

enum NodeParam {
    Null,
    Bool(bool),
    Int(i64),
    Float(f64),
    Text(String),
    Blob(Vec<u8>),
    Vector(Vec<f32>),
}

impl ToParam for NodeParam {
    fn bind(&self, stmt: *mut cyboudb_sys::cyboudb_stmt, idx: c_int) -> CybouResult<()> {
        match self {
            NodeParam::Null => {
                let rc = unsafe { cyboudb_sys::cyboudb_bind_null(stmt, idx) };
                if rc == cyboudb_sys::CYBOUDB_OK {
                    Ok(())
                } else {
                    Err(CybouError::Misuse("Failed to bind NULL parameter".into()))
                }
            }
            NodeParam::Bool(b) => {
                let rc = unsafe { cyboudb_sys::cyboudb_bind_bool(stmt, idx, if *b { 1 } else { 0 }) };
                if rc == cyboudb_sys::CYBOUDB_OK {
                    Ok(())
                } else {
                    Err(CybouError::Misuse("Failed to bind BOOL parameter".into()))
                }
            }
            NodeParam::Int(i) => {
                if *i >= i32::MIN as i64 && *i <= i32::MAX as i64 {
                    let rc = unsafe { cyboudb_sys::cyboudb_bind_int32(stmt, idx, *i as i32) };
                    if rc == cyboudb_sys::CYBOUDB_OK {
                        return Ok(());
                    }
                }
                let rc = unsafe { cyboudb_sys::cyboudb_bind_int64(stmt, idx, *i) };
                if rc == cyboudb_sys::CYBOUDB_OK {
                    Ok(())
                } else {
                    Err(CybouError::Misuse(format!("Failed to bind INT parameter at index {}", idx)))
                }
            }
            NodeParam::Float(f) => {
                let rc = unsafe { cyboudb_sys::cyboudb_bind_float(stmt, idx, *f as f32) };
                if rc == cyboudb_sys::CYBOUDB_OK {
                    Ok(())
                } else {
                    Err(CybouError::Misuse(format!("Failed to bind FLOAT parameter at index {}", idx)))
                }
            }
            NodeParam::Text(s) => {
                let rc = unsafe {
                    cyboudb_sys::cyboudb_bind_text(stmt, idx, s.as_ptr() as *const _, s.len() as i64)
                };
                if rc == cyboudb_sys::CYBOUDB_OK {
                    Ok(())
                } else {
                    Err(CybouError::Misuse(format!("Failed to bind TEXT parameter at index {}", idx)))
                }
            }
            NodeParam::Blob(b) => {
                let rc = unsafe {
                    cyboudb_sys::cyboudb_bind_blob(stmt, idx, b.as_ptr() as *const _, b.len() as i64)
                };
                if rc == cyboudb_sys::CYBOUDB_OK {
                    Ok(())
                } else {
                    Err(CybouError::Misuse(format!("Failed to bind BLOB parameter at index {}", idx)))
                }
            }
            NodeParam::Vector(v) => {
                let rc = unsafe {
                    cyboudb_sys::cyboudb_bind_vector_f32(stmt, idx, v.as_ptr(), v.len() as c_int)
                };
                if rc == cyboudb_sys::CYBOUDB_OK {
                    Ok(())
                } else {
                    Err(CybouError::Misuse(format!("Failed to bind VECTOR parameter at index {}", idx)))
                }
            }
        }
    }
}

fn extract_param(val: &serde_json::Value) -> napi::Result<NodeParam> {
    match val {
        serde_json::Value::Null => Ok(NodeParam::Null),
        serde_json::Value::Bool(b) => Ok(NodeParam::Bool(*b)),
        serde_json::Value::Number(n) => {
            if let Some(i) = n.as_i64() {
                Ok(NodeParam::Int(i))
            } else if let Some(f) = n.as_f64() {
                Ok(NodeParam::Float(f))
            } else {
                Err(napi::Error::new(napi::Status::InvalidArg, "Invalid number parameter"))
            }
        }
        serde_json::Value::String(s) => Ok(NodeParam::Text(s.clone())),
        serde_json::Value::Array(arr) => {
            let mut floats = Vec::with_capacity(arr.len());
            for item in arr {
                if let Some(f) = item.as_f64() {
                    floats.push(f as f32);
                } else {
                    return Err(napi::Error::new(
                        napi::Status::InvalidArg,
                        "Vector array items must be numbers",
                    ));
                }
            }
            Ok(NodeParam::Vector(floats))
        }
        _ => Err(napi::Error::new(
            napi::Status::InvalidArg,
            "Unsupported parameter type",
        )),
    }
}

fn extract_params(params: Option<Vec<serde_json::Value>>) -> napi::Result<Vec<NodeParam>> {
    match params {
        None => Ok(Vec::new()),
        Some(list) => {
            let mut out = Vec::with_capacity(list.len());
            for item in list.iter() {
                out.push(extract_param(item)?);
            }
            Ok(out)
        }
    }
}

fn value_to_json(val: Value) -> serde_json::Value {
    match val {
        Value::Null => serde_json::Value::Null,
        Value::Int32(v) => serde_json::Value::Number(v.into()),
        Value::Int64(v) => serde_json::Value::Number(v.into()),
        Value::Float(v) => {
            if let Some(n) = serde_json::Number::from_f64(v as f64) {
                serde_json::Value::Number(n)
            } else {
                serde_json::Value::Null
            }
        }
        Value::Bool(v) => serde_json::Value::Bool(v),
        Value::Text(v) => serde_json::Value::String(v),
        Value::Blob(v) => {
            let arr = v.into_iter().map(serde_json::Value::from).collect();
            serde_json::Value::Array(arr)
        }
        Value::Vector(v) => {
            let arr = v
                .into_iter()
                .filter_map(|f| serde_json::Number::from_f64(f as f64))
                .map(serde_json::Value::Number)
                .collect();
            serde_json::Value::Array(arr)
        }
    }
}

#[napi]
pub struct Database {
    inner: Arc<Mutex<Option<cyboudb_core::Database>>>,
    in_transaction: Arc<AtomicBool>,
}

#[napi]
impl Database {
    /// Create a new database file sized in 4096-byte pages and open it read-write.
    #[napi(factory)]
    pub fn create(path: String, pages: Option<i64>) -> napi::Result<Self> {
        let p = pages.unwrap_or(512).max(16) as u64;
        let db = cyboudb_core::Database::create(path, p).map_err(to_napi_err)?;
        Ok(Self {
            inner: Arc::new(Mutex::new(Some(db))),
            in_transaction: Arc::new(AtomicBool::new(false)),
        })
    }

    /// Open an existing database file.
    #[napi(factory)]
    pub fn open(path: String, read_only: Option<bool>) -> napi::Result<Self> {
        let ro = read_only.unwrap_or(false);
        let db = if ro {
            cyboudb_core::Database::open_with_flags(path, cyboudb_sys::CYBOUDB_OPEN_READONLY)
        } else {
            cyboudb_core::Database::open(path)
        }
        .map_err(to_napi_err)?;

        Ok(Self {
            inner: Arc::new(Mutex::new(Some(db))),
            in_transaction: Arc::new(AtomicBool::new(false)),
        })
    }

    /// Execute a SQL statement (DDL or DML) with optional parameters.
    #[napi]
    pub fn execute(&self, sql: String, params: Option<Vec<serde_json::Value>>) -> napi::Result<()> {
        let mut guard = self
            .inner
            .lock()
            .map_err(|e| napi::Error::new(napi::Status::GenericFailure, e.to_string()))?;
        let db = guard
            .as_mut()
            .ok_or_else(|| napi::Error::new(napi::Status::GenericFailure, "Database is closed"))?;

        let parsed = extract_params(params)?;
        if parsed.is_empty() {
            db.execute(&sql).map_err(to_napi_err)?;
        } else {
            let mut stmt = db.prepare(&sql).map_err(to_napi_err)?;
            let refs: Vec<&dyn ToParam> = parsed.iter().map(|p| p as &dyn ToParam).collect();
            stmt.execute(&refs).map_err(to_napi_err)?;
        }
        Ok(())
    }

    /// Query rows matching a SQL SELECT query with optional parameters.
    #[napi]
    pub fn query(
        &self,
        sql: String,
        params: Option<Vec<serde_json::Value>>,
    ) -> napi::Result<Vec<Vec<serde_json::Value>>> {
        let mut guard = self
            .inner
            .lock()
            .map_err(|e| napi::Error::new(napi::Status::GenericFailure, e.to_string()))?;
        let db = guard
            .as_mut()
            .ok_or_else(|| napi::Error::new(napi::Status::GenericFailure, "Database is closed"))?;

        let parsed = extract_params(params)?;
        let mut stmt = db.prepare(&sql).map_err(to_napi_err)?;
        let refs: Vec<&dyn ToParam> = parsed.iter().map(|p| p as &dyn ToParam).collect();
        let mut rows = stmt.query(&refs).map_err(to_napi_err)?;

        let mut results = Vec::new();
        while let Some(row_res) = rows.next() {
            let row = row_res.map_err(to_napi_err)?;
            let col_count = row.column_count();
            let mut row_arr = Vec::with_capacity(col_count);
            for col_idx in 0..col_count {
                let val = row.get::<Value>(col_idx).map_err(to_napi_err)?;
                row_arr.push(value_to_json(val));
            }
            results.push(row_arr);
        }

        Ok(results)
    }

    /// Enqueue a message payload string into a durable FIFO queue.
    #[napi]
    pub fn enqueue(&self, queue: String, payload: String) -> napi::Result<()> {
        let guard = self
            .inner
            .lock()
            .map_err(|e| napi::Error::new(napi::Status::GenericFailure, e.to_string()))?;
        let db = guard
            .as_ref()
            .ok_or_else(|| napi::Error::new(napi::Status::GenericFailure, "Database is closed"))?;
        db.enqueue(&queue, &payload).map_err(to_napi_err)
    }

    /// Dequeue the next available message payload from a FIFO queue.
    #[napi]
    pub fn dequeue(&self, queue: String) -> napi::Result<Option<Buffer>> {
        let guard = self
            .inner
            .lock()
            .map_err(|e| napi::Error::new(napi::Status::GenericFailure, e.to_string()))?;
        let db = guard
            .as_ref()
            .ok_or_else(|| napi::Error::new(napi::Status::GenericFailure, "Database is closed"))?;

        let sql = format!("DEQUEUE FROM {};", queue);
        let mut stmt = db.prepare(&sql).map_err(to_napi_err)?;
        let res = stmt.dequeue().map_err(to_napi_err)?;
        Ok(res.map(Buffer::from))
    }

    /// Append an event record to an append-only stream.
    #[napi]
    pub fn append(&self, stream: String, payload: String) -> napi::Result<()> {
        let guard = self
            .inner
            .lock()
            .map_err(|e| napi::Error::new(napi::Status::GenericFailure, e.to_string()))?;
        let db = guard
            .as_ref()
            .ok_or_else(|| napi::Error::new(napi::Status::GenericFailure, "Database is closed"))?;
        db.append(&stream, &payload).map_err(to_napi_err)
    }

    /// Read the next event from a stream using a durable named cursor.
    #[napi]
    pub fn read_stream(&self, stream: String, cursor: String) -> napi::Result<Option<Buffer>> {
        let guard = self
            .inner
            .lock()
            .map_err(|e| napi::Error::new(napi::Status::GenericFailure, e.to_string()))?;
        let db = guard
            .as_ref()
            .ok_or_else(|| napi::Error::new(napi::Status::GenericFailure, "Database is closed"))?;

        let sql = format!("READ FROM {} AS {};", stream, cursor);
        let mut stmt = db.prepare(&sql).map_err(to_napi_err)?;
        let res = stmt.dequeue().map_err(to_napi_err)?;
        Ok(res.map(Buffer::from))
    }

    /// Start a transaction block returning a Transaction controller.
    #[napi]
    pub fn begin_transaction(&self) -> napi::Result<Transaction> {
        if self.in_transaction.swap(true, Ordering::SeqCst) {
            return Err(napi::Error::new(
                napi::Status::GenericFailure,
                "Transaction is already active",
            ));
        }

        self.execute("BEGIN".to_string(), None)?;

        Ok(Transaction {
            db_inner: self.inner.clone(),
            in_transaction: self.in_transaction.clone(),
            finished: AtomicBool::new(false),
        })
    }

    /// Close the database connection.
    #[napi]
    pub fn close(&self) -> napi::Result<()> {
        let mut guard = self
            .inner
            .lock()
            .map_err(|e| napi::Error::new(napi::Status::GenericFailure, e.to_string()))?;
        guard.take();
        Ok(())
    }
}

#[napi]
pub struct Transaction {
    db_inner: Arc<Mutex<Option<cyboudb_core::Database>>>,
    in_transaction: Arc<AtomicBool>,
    finished: AtomicBool,
}

#[napi]
impl Transaction {
    #[napi]
    pub fn execute(&self, sql: String, params: Option<Vec<serde_json::Value>>) -> napi::Result<()> {
        let mut guard = self
            .db_inner
            .lock()
            .map_err(|e| napi::Error::new(napi::Status::GenericFailure, e.to_string()))?;
        let db = guard
            .as_mut()
            .ok_or_else(|| napi::Error::new(napi::Status::GenericFailure, "Database is closed"))?;

        let parsed = extract_params(params)?;
        if parsed.is_empty() {
            db.execute(&sql).map_err(to_napi_err)?;
        } else {
            let mut stmt = db.prepare(&sql).map_err(to_napi_err)?;
            let refs: Vec<&dyn ToParam> = parsed.iter().map(|p| p as &dyn ToParam).collect();
            stmt.execute(&refs).map_err(to_napi_err)?;
        }
        Ok(())
    }

    #[napi]
    pub fn query(
        &self,
        sql: String,
        params: Option<Vec<serde_json::Value>>,
    ) -> napi::Result<Vec<Vec<serde_json::Value>>> {
        let mut guard = self
            .db_inner
            .lock()
            .map_err(|e| napi::Error::new(napi::Status::GenericFailure, e.to_string()))?;
        let db = guard
            .as_mut()
            .ok_or_else(|| napi::Error::new(napi::Status::GenericFailure, "Database is closed"))?;

        let parsed = extract_params(params)?;
        let mut stmt = db.prepare(&sql).map_err(to_napi_err)?;
        let refs: Vec<&dyn ToParam> = parsed.iter().map(|p| p as &dyn ToParam).collect();
        let mut rows = stmt.query(&refs).map_err(to_napi_err)?;

        let mut results = Vec::new();
        while let Some(row_res) = rows.next() {
            let row = row_res.map_err(to_napi_err)?;
            let col_count = row.column_count();
            let mut row_arr = Vec::with_capacity(col_count);
            for col_idx in 0..col_count {
                let val = row.get::<Value>(col_idx).map_err(to_napi_err)?;
                row_arr.push(value_to_json(val));
            }
            results.push(row_arr);
        }

        Ok(results)
    }

    #[napi]
    pub fn enqueue(&self, queue: String, payload: String) -> napi::Result<()> {
        let guard = self
            .db_inner
            .lock()
            .map_err(|e| napi::Error::new(napi::Status::GenericFailure, e.to_string()))?;
        let db = guard
            .as_ref()
            .ok_or_else(|| napi::Error::new(napi::Status::GenericFailure, "Database is closed"))?;
        db.enqueue(&queue, &payload).map_err(to_napi_err)
    }

    #[napi]
    pub fn dequeue(&self, queue: String) -> napi::Result<Option<Buffer>> {
        let guard = self
            .db_inner
            .lock()
            .map_err(|e| napi::Error::new(napi::Status::GenericFailure, e.to_string()))?;
        let db = guard
            .as_ref()
            .ok_or_else(|| napi::Error::new(napi::Status::GenericFailure, "Database is closed"))?;

        let sql = format!("DEQUEUE FROM {};", queue);
        let mut stmt = db.prepare(&sql).map_err(to_napi_err)?;
        let res = stmt.dequeue().map_err(to_napi_err)?;
        Ok(res.map(Buffer::from))
    }

    #[napi]
    pub fn append(&self, stream: String, payload: String) -> napi::Result<()> {
        let guard = self
            .db_inner
            .lock()
            .map_err(|e| napi::Error::new(napi::Status::GenericFailure, e.to_string()))?;
        let db = guard
            .as_ref()
            .ok_or_else(|| napi::Error::new(napi::Status::GenericFailure, "Database is closed"))?;
        db.append(&stream, &payload).map_err(to_napi_err)
    }

    #[napi]
    pub fn commit(&self) -> napi::Result<()> {
        if self.finished.swap(true, Ordering::SeqCst) {
            return Err(napi::Error::new(
                napi::Status::GenericFailure,
                "Transaction already finished",
            ));
        }

        let mut guard = self
            .db_inner
            .lock()
            .map_err(|e| napi::Error::new(napi::Status::GenericFailure, e.to_string()))?;
        let db = guard
            .as_mut()
            .ok_or_else(|| napi::Error::new(napi::Status::GenericFailure, "Database is closed"))?;

        db.execute("COMMIT").map_err(to_napi_err)?;
        self.in_transaction.store(false, Ordering::SeqCst);
        Ok(())
    }

    #[napi]
    pub fn rollback(&self) -> napi::Result<()> {
        if self.finished.swap(true, Ordering::SeqCst) {
            return Err(napi::Error::new(
                napi::Status::GenericFailure,
                "Transaction already finished",
            ));
        }

        let mut guard = self
            .db_inner
            .lock()
            .map_err(|e| napi::Error::new(napi::Status::GenericFailure, e.to_string()))?;
        let db = guard
            .as_mut()
            .ok_or_else(|| napi::Error::new(napi::Status::GenericFailure, "Database is closed"))?;

        db.execute("ROLLBACK").map_err(to_napi_err)?;
        self.in_transaction.store(false, Ordering::SeqCst);
        Ok(())
    }
}

/// Returns the CybouDB native library version.
#[napi]
pub fn version() -> String {
    cyboudb_sys::CYBOUDB_VERSION.to_string()
}
