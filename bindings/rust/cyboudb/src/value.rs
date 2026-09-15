use crate::error::{Error, Result};
use cyboudb_sys as ffi;
use std::ffi::{c_int, c_void};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Type {
    Int32 = 1,
    Int64 = 2,
    Float32 = 3,
    Bool = 4,
    Text = 5,
    Blob = 6,
    Vector = 7,
}

impl Type {
    pub fn from_raw(raw: u32) -> Option<Self> {
        match raw {
            ffi::CYBOUDB_TYPE_INT32 => Some(Type::Int32),
            ffi::CYBOUDB_TYPE_INT64 => Some(Type::Int64),
            ffi::CYBOUDB_TYPE_FLOAT32 => Some(Type::Float32),
            ffi::CYBOUDB_TYPE_BOOL => Some(Type::Bool),
            ffi::CYBOUDB_TYPE_TEXT => Some(Type::Text),
            ffi::CYBOUDB_TYPE_BLOB => Some(Type::Blob),
            ffi::CYBOUDB_TYPE_VECTOR => Some(Type::Vector),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    Null,
    Int32(i32),
    Int64(i64),
    Float(f32),
    Bool(bool),
    Text(String),
    Blob(Vec<u8>),
    Vector(Vec<f32>),
}

/// Trait for types that can be bound as SQL query parameters.
pub trait ToParam {
    fn bind(&self, stmt: *mut ffi::cyboudb_stmt, idx: c_int) -> Result<()>;
}

impl ToParam for i32 {
    fn bind(&self, stmt: *mut ffi::cyboudb_stmt, idx: c_int) -> Result<()> {
        let rc = unsafe { ffi::cyboudb_bind_int32(stmt, idx, *self) };
        if rc != ffi::CYBOUDB_OK {
            Err(Error::Misuse(format!("Failed to bind i32 parameter at index {}", idx)))
        } else {
            Ok(())
        }
    }
}

impl ToParam for i64 {
    fn bind(&self, stmt: *mut ffi::cyboudb_stmt, idx: c_int) -> Result<()> {
        let rc = unsafe { ffi::cyboudb_bind_int64(stmt, idx, *self) };
        if rc != ffi::CYBOUDB_OK {
            Err(Error::Misuse(format!("Failed to bind i64 parameter at index {}", idx)))
        } else {
            Ok(())
        }
    }
}

impl ToParam for f32 {
    fn bind(&self, stmt: *mut ffi::cyboudb_stmt, idx: c_int) -> Result<()> {
        let rc = unsafe { ffi::cyboudb_bind_float(stmt, idx, *self) };
        if rc != ffi::CYBOUDB_OK {
            Err(Error::Misuse(format!("Failed to bind f32 parameter at index {}", idx)))
        } else {
            Ok(())
        }
    }
}

impl ToParam for bool {
    fn bind(&self, stmt: *mut ffi::cyboudb_stmt, idx: c_int) -> Result<()> {
        let val = if *self { 1 } else { 0 };
        let rc = unsafe { ffi::cyboudb_bind_bool(stmt, idx, val) };
        if rc != ffi::CYBOUDB_OK {
            Err(Error::Misuse(format!("Failed to bind bool parameter at index {}", idx)))
        } else {
            Ok(())
        }
    }
}

impl ToParam for str {
    fn bind(&self, stmt: *mut ffi::cyboudb_stmt, idx: c_int) -> Result<()> {
        let rc = unsafe {
            ffi::cyboudb_bind_text(
                stmt,
                idx,
                self.as_ptr() as *const std::ffi::c_char,
                self.len() as i64,
            )
        };
        if rc != ffi::CYBOUDB_OK {
            Err(Error::Misuse(format!("Failed to bind text parameter at index {}", idx)))
        } else {
            Ok(())
        }
    }
}

impl ToParam for &str {
    fn bind(&self, stmt: *mut ffi::cyboudb_stmt, idx: c_int) -> Result<()> {
        (*self).bind(stmt, idx)
    }
}

impl ToParam for String {
    fn bind(&self, stmt: *mut ffi::cyboudb_stmt, idx: c_int) -> Result<()> {
        self.as_str().bind(stmt, idx)
    }
}

impl ToParam for [u8] {
    fn bind(&self, stmt: *mut ffi::cyboudb_stmt, idx: c_int) -> Result<()> {
        let rc = unsafe {
            ffi::cyboudb_bind_blob(
                stmt,
                idx,
                self.as_ptr() as *const c_void,
                self.len() as i64,
            )
        };
        if rc != ffi::CYBOUDB_OK {
            Err(Error::Misuse(format!("Failed to bind blob parameter at index {}", idx)))
        } else {
            Ok(())
        }
    }
}

impl ToParam for Vec<u8> {
    fn bind(&self, stmt: *mut ffi::cyboudb_stmt, idx: c_int) -> Result<()> {
        self.as_slice().bind(stmt, idx)
    }
}

impl ToParam for [f32] {
    fn bind(&self, stmt: *mut ffi::cyboudb_stmt, idx: c_int) -> Result<()> {
        let rc = unsafe {
            ffi::cyboudb_bind_vector_f32(
                stmt,
                idx,
                self.as_ptr(),
                self.len() as c_int,
            )
        };
        if rc != ffi::CYBOUDB_OK {
            Err(Error::Misuse(format!("Failed to bind vector parameter at index {}", idx)))
        } else {
            Ok(())
        }
    }
}

impl ToParam for Vec<f32> {
    fn bind(&self, stmt: *mut ffi::cyboudb_stmt, idx: c_int) -> Result<()> {
        self.as_slice().bind(stmt, idx)
    }
}

impl<T: ToParam> ToParam for Option<T> {
    fn bind(&self, stmt: *mut ffi::cyboudb_stmt, idx: c_int) -> Result<()> {
        match self {
            Some(v) => v.bind(stmt, idx),
            None => {
                let rc = unsafe { ffi::cyboudb_bind_null(stmt, idx) };
                if rc != ffi::CYBOUDB_OK {
                    Err(Error::Misuse(format!("Failed to bind null parameter at index {}", idx)))
                } else {
                    Ok(())
                }
            }
        }
    }
}

impl ToParam for Value {
    fn bind(&self, stmt: *mut ffi::cyboudb_stmt, idx: c_int) -> Result<()> {
        match self {
            Value::Null => Option::<i32>::None.bind(stmt, idx),
            Value::Int32(v) => v.bind(stmt, idx),
            Value::Int64(v) => v.bind(stmt, idx),
            Value::Float(v) => v.bind(stmt, idx),
            Value::Bool(v) => v.bind(stmt, idx),
            Value::Text(v) => v.bind(stmt, idx),
            Value::Blob(v) => v.bind(stmt, idx),
            Value::Vector(v) => v.bind(stmt, idx),
        }
    }
}

/// Trait for deserializing a column value from the current row.
pub trait FromColumn: Sized {
    fn from_column(stmt: *mut ffi::cyboudb_stmt, idx: c_int) -> Result<Self>;
}

impl FromColumn for i32 {
    fn from_column(stmt: *mut ffi::cyboudb_stmt, idx: c_int) -> Result<Self> {
        if unsafe { ffi::cyboudb_column_is_null(stmt, idx) } != 0 {
            return Err(Error::NullValue);
        }
        Ok(unsafe { ffi::cyboudb_column_int32(stmt, idx) })
    }
}

impl FromColumn for i64 {
    fn from_column(stmt: *mut ffi::cyboudb_stmt, idx: c_int) -> Result<Self> {
        if unsafe { ffi::cyboudb_column_is_null(stmt, idx) } != 0 {
            return Err(Error::NullValue);
        }
        Ok(unsafe { ffi::cyboudb_column_int64(stmt, idx) })
    }
}

impl FromColumn for f32 {
    fn from_column(stmt: *mut ffi::cyboudb_stmt, idx: c_int) -> Result<Self> {
        if unsafe { ffi::cyboudb_column_is_null(stmt, idx) } != 0 {
            return Err(Error::NullValue);
        }
        Ok(unsafe { ffi::cyboudb_column_float(stmt, idx) })
    }
}

impl FromColumn for bool {
    fn from_column(stmt: *mut ffi::cyboudb_stmt, idx: c_int) -> Result<Self> {
        if unsafe { ffi::cyboudb_column_is_null(stmt, idx) } != 0 {
            return Err(Error::NullValue);
        }
        Ok(unsafe { ffi::cyboudb_column_bool(stmt, idx) != 0 })
    }
}

impl FromColumn for String {
    fn from_column(stmt: *mut ffi::cyboudb_stmt, idx: c_int) -> Result<Self> {
        let bytes: Vec<u8> = FromColumn::from_column(stmt, idx)?;
        String::from_utf8(bytes).map_err(|_| Error::InvalidUtf8)
    }
}

impl FromColumn for Vec<u8> {
    fn from_column(stmt: *mut ffi::cyboudb_stmt, idx: c_int) -> Result<Self> {
        if unsafe { ffi::cyboudb_column_is_null(stmt, idx) } != 0 {
            return Err(Error::NullValue);
        }

        let mut length: u64 = 0;
        // Probe capacity with initial buffer
        let mut buf = vec![0u8; 1024];
        let rc = unsafe {
            ffi::cyboudb_column_bytes(
                stmt,
                idx,
                buf.as_mut_ptr() as *mut c_void,
                buf.len() as u64,
                &mut length,
            )
        };

        if rc == ffi::CYBOUDB_OK {
            if length > buf.len() as u64 {
                // Resize to actual length and fetch again
                buf.resize(length as usize, 0);
                let rc2 = unsafe {
                    ffi::cyboudb_column_bytes(
                        stmt,
                        idx,
                        buf.as_mut_ptr() as *mut c_void,
                        buf.len() as u64,
                        &mut length,
                    )
                };
                if rc2 != ffi::CYBOUDB_OK {
                    return Err(Error::SqlError("Failed to fetch column bytes".into()));
                }
            }
            buf.truncate(length as usize);
            Ok(buf)
        } else {
            Err(Error::SqlError("Failed to read column bytes".into()))
        }
    }
}

impl FromColumn for Vec<f32> {
    fn from_column(stmt: *mut ffi::cyboudb_stmt, idx: c_int) -> Result<Self> {
        if unsafe { ffi::cyboudb_column_is_null(stmt, idx) } != 0 {
            return Err(Error::NullValue);
        }

        let dims = unsafe { ffi::cyboudb_column_vector_dimensions(stmt, idx) };
        if dims < 0 {
            return Err(Error::Misuse("Column is not a vector".into()));
        }

        let mut out = vec![0.0f32; dims as usize];
        let mut actual_dims: u64 = 0;
        let rc = unsafe {
            ffi::cyboudb_column_vector_f32(
                stmt,
                idx,
                out.as_mut_ptr(),
                out.len() as u64,
                &mut actual_dims,
            )
        };

        if rc == ffi::CYBOUDB_OK {
            out.truncate(actual_dims as usize);
            Ok(out)
        } else {
            Err(Error::SqlError("Failed to read vector column".into()))
        }
    }
}

impl<T: FromColumn> FromColumn for Option<T> {
    fn from_column(stmt: *mut ffi::cyboudb_stmt, idx: c_int) -> Result<Self> {
        if unsafe { ffi::cyboudb_column_is_null(stmt, idx) } != 0 {
            Ok(None)
        } else {
            T::from_column(stmt, idx).map(Some)
        }
    }
}

impl FromColumn for Value {
    fn from_column(stmt: *mut ffi::cyboudb_stmt, idx: c_int) -> Result<Self> {
        if unsafe { ffi::cyboudb_column_is_null(stmt, idx) } != 0 {
            return Ok(Value::Null);
        }

        let col_type = unsafe { ffi::cyboudb_column_type(stmt, idx) } as u32;
        match col_type {
            ffi::CYBOUDB_TYPE_INT32 => i32::from_column(stmt, idx).map(Value::Int32),
            ffi::CYBOUDB_TYPE_INT64 => i64::from_column(stmt, idx).map(Value::Int64),
            ffi::CYBOUDB_TYPE_FLOAT32 => f32::from_column(stmt, idx).map(Value::Float),
            ffi::CYBOUDB_TYPE_BOOL => bool::from_column(stmt, idx).map(Value::Bool),
            ffi::CYBOUDB_TYPE_TEXT => String::from_column(stmt, idx).map(Value::Text),
            ffi::CYBOUDB_TYPE_BLOB => Vec::<u8>::from_column(stmt, idx).map(Value::Blob),
            ffi::CYBOUDB_TYPE_VECTOR => Vec::<f32>::from_column(stmt, idx).map(Value::Vector),
            other => Err(Error::InvalidType {
                expected: "known CybouDB type",
                actual: other,
            }),
        }
    }
}
