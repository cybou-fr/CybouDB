//! Python bindings for the CybouDB embedded database engine.

use cyboudb_core::{Database, Error, Result as CybouResult, ToParam, Value};
use pyo3::create_exception;
use pyo3::exceptions::{PyException, PyMemoryError};
use pyo3::prelude::*;
use pyo3::types::{PyBool, PyBytes, PySequence, PyTuple};
use std::ffi::c_int;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;

// Custom Python Exception Hierarchy
create_exception!(cyboudb, DatabaseError, PyException);
create_exception!(cyboudb, BusyError, DatabaseError);
create_exception!(cyboudb, LockedError, DatabaseError);
create_exception!(cyboudb, SqlError, DatabaseError);
create_exception!(cyboudb, ConstraintError, DatabaseError);
create_exception!(cyboudb, NotFoundError, DatabaseError);
create_exception!(cyboudb, CorruptError, DatabaseError);

fn to_py_err(err: Error) -> PyErr {
    match err {
        Error::Busy => BusyError::new_err(err.to_string()),
        Error::SqlError(msg) => SqlError::new_err(msg),
        Error::NoMem => PyMemoryError::new_err(err.to_string()),
        _ => DatabaseError::new_err(err.to_string()),
    }
}

/// Dynamic SQL parameter supporting Python types.
enum PyParam {
    Null,
    Bool(bool),
    Int(i64),
    Float(f64),
    Text(String),
    Blob(Vec<u8>),
    Vector(Vec<f32>),
}

impl ToParam for PyParam {
    fn bind(&self, stmt: *mut cyboudb_sys::cyboudb_stmt, idx: c_int) -> CybouResult<()> {
        match self {
            PyParam::Null => {
                let rc = unsafe { cyboudb_sys::cyboudb_bind_null(stmt, idx) };
                if rc == cyboudb_sys::CYBOUDB_OK {
                    Ok(())
                } else {
                    Err(Error::Misuse("Failed to bind NULL parameter".into()))
                }
            }
            PyParam::Bool(b) => {
                let rc = unsafe { cyboudb_sys::cyboudb_bind_bool(stmt, idx, if *b { 1 } else { 0 }) };
                if rc == cyboudb_sys::CYBOUDB_OK {
                    Ok(())
                } else {
                    Err(Error::Misuse("Failed to bind BOOL parameter".into()))
                }
            }
            PyParam::Int(i) => {
                // Try INT32 first if it fits, fallback to INT64
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
                    Err(Error::Misuse(format!("Failed to bind INT parameter at index {}", idx)))
                }
            }
            PyParam::Float(f) => {
                let rc = unsafe { cyboudb_sys::cyboudb_bind_float(stmt, idx, *f as f32) };
                if rc == cyboudb_sys::CYBOUDB_OK {
                    Ok(())
                } else {
                    Err(Error::Misuse(format!("Failed to bind FLOAT parameter at index {}", idx)))
                }
            }
            PyParam::Text(s) => {
                let rc = unsafe {
                    cyboudb_sys::cyboudb_bind_text(stmt, idx, s.as_ptr() as *const _, s.len() as i64)
                };
                if rc == cyboudb_sys::CYBOUDB_OK {
                    Ok(())
                } else {
                    Err(Error::Misuse(format!("Failed to bind TEXT parameter at index {}", idx)))
                }
            }
            PyParam::Blob(b) => {
                let rc = unsafe {
                    cyboudb_sys::cyboudb_bind_blob(stmt, idx, b.as_ptr() as *const _, b.len() as i64)
                };
                if rc == cyboudb_sys::CYBOUDB_OK {
                    Ok(())
                } else {
                    Err(Error::Misuse(format!("Failed to bind BLOB parameter at index {}", idx)))
                }
            }
            PyParam::Vector(v) => {
                let rc = unsafe {
                    cyboudb_sys::cyboudb_bind_vector_f32(stmt, idx, v.as_ptr(), v.len() as c_int)
                };
                if rc == cyboudb_sys::CYBOUDB_OK {
                    Ok(())
                } else {
                    Err(Error::Misuse(format!("Failed to bind VECTOR parameter at index {}", idx)))
                }
            }
        }
    }
}

fn extract_param(obj: &Bound<'_, PyAny>) -> PyResult<PyParam> {
    if obj.is_none() {
        Ok(PyParam::Null)
    } else if let Ok(b) = obj.extract::<bool>() {
        // bool must be checked before int because bool subclasses int in Python
        Ok(PyParam::Bool(b))
    } else if let Ok(i) = obj.extract::<i64>() {
        Ok(PyParam::Int(i))
    } else if let Ok(f) = obj.extract::<f64>() {
        Ok(PyParam::Float(f))
    } else if let Ok(s) = obj.extract::<String>() {
        Ok(PyParam::Text(s))
    } else if let Ok(bytes) = obj.extract::<&[u8]>() {
        Ok(PyParam::Blob(bytes.to_vec()))
    } else if let Ok(vec) = obj.extract::<Vec<f32>>() {
        Ok(PyParam::Vector(vec))
    } else {
        Err(PyErr::new::<pyo3::exceptions::PyTypeError, _>(
            format!("Unsupported CybouDB parameter type: {:?}", obj)
        ))
    }
}

fn extract_params(params: Option<&Bound<'_, PyAny>>) -> PyResult<Vec<PyParam>> {
    match params {
        None => Ok(Vec::new()),
        Some(p) => {
            if p.is_none() {
                Ok(Vec::new())
            } else if let Ok(seq) = p.cast::<PySequence>() {
                let len = seq.len()?;
                let mut out = Vec::with_capacity(len);
                for i in 0..len {
                    let item = seq.get_item(i)?;
                    out.push(extract_param(&item)?);
                }
                Ok(out)
            } else {
                Err(PyErr::new::<pyo3::exceptions::PyTypeError, _>(
                    "Parameters must be a list, tuple, or sequence"
                ))
            }
        }
    }
}

fn value_to_py(py: Python<'_>, val: Value) -> PyResult<Py<PyAny>> {
    match val {
        Value::Null => Ok(py.None()),
        Value::Int32(v) => Ok(v.into_pyobject(py)?.into_any().unbind()),
        Value::Int64(v) => Ok(v.into_pyobject(py)?.into_any().unbind()),
        Value::Float(v) => Ok(v.into_pyobject(py)?.into_any().unbind()),
        Value::Bool(v) => Ok(PyBool::new(py, v).to_owned().into_any().unbind()),
        Value::Text(v) => Ok(v.into_pyobject(py)?.into_any().unbind()),
        Value::Blob(v) => Ok(PyBytes::new(py, &v).into_any().unbind()),
        Value::Vector(v) => Ok(v.into_pyobject(py)?.into_any().unbind()),
    }
}

/// A connection to a CybouDB embedded database.
#[pyclass(name = "Database")]
pub struct PyDatabase {
    inner: Mutex<Option<Database>>,
    in_transaction: AtomicBool,
}

#[pymethods]
impl PyDatabase {
    /// Create a new database file sized in 4096-byte pages and open it read-write.
    #[staticmethod]
    #[pyo3(signature = (path, pages=512))]
    pub fn create(path: &str, pages: u64) -> PyResult<Self> {
        let db = Database::create(path, pages).map_err(to_py_err)?;
        Ok(Self {
            inner: Mutex::new(Some(db)),
            in_transaction: AtomicBool::new(false),
        })
    }

    /// Open an existing database file.
    #[staticmethod]
    #[pyo3(signature = (path, read_only=false))]
    pub fn open(path: &str, read_only: bool) -> PyResult<Self> {
        let db = if read_only {
            Database::open_with_flags(path, cyboudb_sys::CYBOUDB_OPEN_READONLY)
        } else {
            Database::open(path)
        }
        .map_err(to_py_err)?;

        Ok(Self {
            inner: Mutex::new(Some(db)),
            in_transaction: AtomicBool::new(false),
        })
    }

    /// Execute a SQL statement (DDL or DML) with optional parameters.
    #[pyo3(signature = (sql, params=None))]
    pub fn execute(&self, sql: &str, params: Option<&Bound<'_, PyAny>>) -> PyResult<()> {
        let mut guard = self.inner.lock().map_err(|e| DatabaseError::new_err(e.to_string()))?;
        let db = guard.as_mut().ok_or_else(|| DatabaseError::new_err("Database is closed"))?;
        let parsed_params = extract_params(params)?;

        if parsed_params.is_empty() {
            db.execute(sql).map_err(to_py_err)?;
        } else {
            let mut stmt = db.prepare(sql).map_err(to_py_err)?;
            let refs: Vec<&dyn ToParam> = parsed_params.iter().map(|p| p as &dyn ToParam).collect();
            stmt.execute(&refs).map_err(to_py_err)?;
        }
        Ok(())
    }

    /// Query rows matching a SQL SELECT query with optional parameters.
    #[pyo3(signature = (sql, params=None))]
    pub fn query<'py>(
        &self,
        py: Python<'py>,
        sql: &str,
        params: Option<&Bound<'_, PyAny>>,
    ) -> PyResult<Vec<Py<PyTuple>>> {
        let mut guard = self.inner.lock().map_err(|e| DatabaseError::new_err(e.to_string()))?;
        let db = guard.as_mut().ok_or_else(|| DatabaseError::new_err("Database is closed"))?;
        let parsed_params = extract_params(params)?;

        let mut stmt = db.prepare(sql).map_err(to_py_err)?;
        let refs: Vec<&dyn ToParam> = parsed_params.iter().map(|p| p as &dyn ToParam).collect();
        let mut rows = stmt.query(&refs).map_err(to_py_err)?;

        let mut results = Vec::new();
        while let Some(row_res) = rows.next() {
            let row = row_res.map_err(to_py_err)?;
            let col_count = row.column_count();
            let mut row_values = Vec::with_capacity(col_count);
            for col_idx in 0..col_count {
                let val = row.get::<Value>(col_idx).map_err(to_py_err)?;
                row_values.push(value_to_py(py, val)?);
            }
            let tuple = PyTuple::new(py, row_values)?;
            results.push(tuple.unbind());
        }

        Ok(results)
    }

    /// Enqueue a message payload string into a durable FIFO queue.
    pub fn enqueue(&self, queue: &str, payload: &str) -> PyResult<()> {
        let guard = self.inner.lock().map_err(|e| DatabaseError::new_err(e.to_string()))?;
        let db = guard.as_ref().ok_or_else(|| DatabaseError::new_err("Database is closed"))?;
        db.enqueue(queue, payload).map_err(to_py_err)
    }

    /// Dequeue the next available message payload from a FIFO queue.
    pub fn dequeue<'py>(&self, py: Python<'py>, queue: &str) -> PyResult<Option<Py<PyBytes>>> {
        let guard = self.inner.lock().map_err(|e| DatabaseError::new_err(e.to_string()))?;
        let db = guard.as_ref().ok_or_else(|| DatabaseError::new_err("Database is closed"))?;
        let sql = format!("DEQUEUE FROM {};", queue);
        let mut stmt = db.prepare(&sql).map_err(to_py_err)?;
        let res: Option<Vec<u8>> = stmt.dequeue().map_err(to_py_err)?;
        if let Some(bytes) = res {
            Ok(Some(PyBytes::new(py, bytes.as_slice()).unbind()))
        } else {
            Ok(None)
        }
    }

    /// Append an event record to an append-only stream.
    pub fn append(&self, stream: &str, payload: &str) -> PyResult<()> {
        let guard = self.inner.lock().map_err(|e| DatabaseError::new_err(e.to_string()))?;
        let db = guard.as_ref().ok_or_else(|| DatabaseError::new_err("Database is closed"))?;
        db.append(stream, payload).map_err(to_py_err)
    }

    /// Read the next event from a stream using a durable named cursor.
    pub fn read_stream<'py>(
        &self,
        py: Python<'py>,
        stream: &str,
        cursor: &str,
    ) -> PyResult<Option<Py<PyBytes>>> {
        let guard = self.inner.lock().map_err(|e| DatabaseError::new_err(e.to_string()))?;
        let db = guard.as_ref().ok_or_else(|| DatabaseError::new_err("Database is closed"))?;
        let sql = format!("READ FROM {} AS {};", stream, cursor);
        let mut stmt = db.prepare(&sql).map_err(to_py_err)?;
        let res: Option<Vec<u8>> = stmt.dequeue().map_err(to_py_err)?;
        if let Some(bytes) = res {
            Ok(Some(PyBytes::new(py, bytes.as_slice()).unbind()))
        } else {
            Ok(None)
        }
    }

    /// Open an ACID transaction context manager.
    pub fn transaction(slf: Py<Self>) -> PyTransaction {
        PyTransaction {
            db: slf,
            finished: AtomicBool::new(false),
        }
    }

    /// Close the database connection.
    pub fn close(&self) -> PyResult<()> {
        let mut guard = self.inner.lock().map_err(|e| DatabaseError::new_err(e.to_string()))?;
        guard.take();
        Ok(())
    }

    pub fn __enter__(slf: Py<Self>) -> Py<Self> {
        slf
    }

    pub fn __exit__(
        &self,
        _exc_type: Option<&Bound<'_, PyAny>>,
        _exc_val: Option<&Bound<'_, PyAny>>,
        _exc_tb: Option<&Bound<'_, PyAny>>,
    ) -> PyResult<()> {
        self.close()
    }
}

/// An ACID transaction context manager on an open CybouDB database.
#[pyclass(name = "Transaction")]
pub struct PyTransaction {
    db: Py<PyDatabase>,
    finished: AtomicBool,
}

#[pymethods]
impl PyTransaction {
    pub fn __enter__(&self, py: Python<'_>) -> PyResult<Py<Self>> {
        let db_bound = self.db.bind(py);
        let db = db_bound.borrow();
        if db.in_transaction.swap(true, Ordering::SeqCst) {
            return Err(DatabaseError::new_err("Transaction is already active"));
        }
        db.execute("BEGIN", None)?;
        Py::new(py, PyTransaction {
            db: self.db.clone_ref(py),
            finished: AtomicBool::new(false),
        })
    }

    pub fn __exit__(
        &self,
        py: Python<'_>,
        exc_type: Option<&Bound<'_, PyAny>>,
        _exc_val: Option<&Bound<'_, PyAny>>,
        _exc_tb: Option<&Bound<'_, PyAny>>,
    ) -> PyResult<()> {
        if !self.finished.swap(true, Ordering::SeqCst) {
            let db_bound = self.db.bind(py);
            let db = db_bound.borrow();
            db.in_transaction.store(false, Ordering::SeqCst);
            if exc_type.is_some() {
                let _ = db.execute("ROLLBACK", None);
            } else {
                db.execute("COMMIT", None)?;
            }
        }
        Ok(())
    }

    /// Execute a SQL statement within this transaction.
    #[pyo3(signature = (sql, params=None))]
    pub fn execute(&self, py: Python<'_>, sql: &str, params: Option<&Bound<'_, PyAny>>) -> PyResult<()> {
        let db_bound = self.db.bind(py);
        let db = db_bound.borrow();
        db.execute(sql, params)
    }

    /// Query rows within this transaction.
    #[pyo3(signature = (sql, params=None))]
    pub fn query<'py>(
        &self,
        py: Python<'py>,
        sql: &str,
        params: Option<&Bound<'_, PyAny>>,
    ) -> PyResult<Vec<Py<PyTuple>>> {
        let db_bound = self.db.bind(py);
        let db = db_bound.borrow();
        db.query(py, sql, params)
    }

    /// Enqueue a message within this transaction.
    pub fn enqueue(&self, py: Python<'_>, queue: &str, payload: &str) -> PyResult<()> {
        let db_bound = self.db.bind(py);
        let db = db_bound.borrow();
        db.enqueue(queue, payload)
    }

    /// Dequeue a message within this transaction.
    pub fn dequeue<'py>(&self, py: Python<'py>, queue: &str) -> PyResult<Option<Py<PyBytes>>> {
        let db_bound = self.db.bind(py);
        let db = db_bound.borrow();
        db.dequeue(py, queue)
    }

    /// Append a stream event within this transaction.
    pub fn append(&self, py: Python<'_>, stream: &str, payload: &str) -> PyResult<()> {
        let db_bound = self.db.bind(py);
        let db = db_bound.borrow();
        db.append(stream, payload)
    }

    /// Manually commit the transaction.
    pub fn commit(&self, py: Python<'_>) -> PyResult<()> {
        if self.finished.swap(true, Ordering::SeqCst) {
            return Err(DatabaseError::new_err("Transaction already finished"));
        }
        let db_bound = self.db.bind(py);
        let db = db_bound.borrow();
        db.in_transaction.store(false, Ordering::SeqCst);
        db.execute("COMMIT", None)
    }

    /// Manually rollback the transaction.
    pub fn rollback(&self, py: Python<'_>) -> PyResult<()> {
        if self.finished.swap(true, Ordering::SeqCst) {
            return Err(DatabaseError::new_err("Transaction already finished"));
        }
        let db_bound = self.db.bind(py);
        let db = db_bound.borrow();
        db.in_transaction.store(false, Ordering::SeqCst);
        db.execute("ROLLBACK", None)
    }
}

/// Connect to or create a CybouDB database.
#[pyfunction]
#[pyo3(signature = (path, pages=512, create=false, read_only=false))]
fn connect(path: &str, pages: u64, create: bool, read_only: bool) -> PyResult<PyDatabase> {
    if create {
        PyDatabase::create(path, pages)
    } else {
        PyDatabase::open(path, read_only)
    }
}

/// Returns the CybouDB library version.
#[pyfunction]
fn version() -> &'static str {
    cyboudb_sys::CYBOUDB_VERSION
}

#[pymodule]
fn cyboudb(m: &Bound<'_, PyModule>) -> PyResult<()> {
    m.add_class::<PyDatabase>()?;
    m.add_class::<PyTransaction>()?;
    m.add_function(wrap_pyfunction!(connect, m)?)?;
    m.add_function(wrap_pyfunction!(version, m)?)?;

    // Exceptions
    m.add("DatabaseError", m.py().get_type::<DatabaseError>())?;
    m.add("BusyError", m.py().get_type::<BusyError>())?;
    m.add("LockedError", m.py().get_type::<LockedError>())?;
    m.add("SqlError", m.py().get_type::<SqlError>())?;
    m.add("ConstraintError", m.py().get_type::<ConstraintError>())?;
    m.add("NotFoundError", m.py().get_type::<NotFoundError>())?;
    m.add("CorruptError", m.py().get_type::<CorruptError>())?;

    Ok(())
}
