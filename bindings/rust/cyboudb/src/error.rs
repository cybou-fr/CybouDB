use std::ffi::CStr;
use std::fmt;
use cyboudb_sys as ffi;

#[derive(Debug, PartialEq, Eq, Clone)]
pub enum Error {
    SqlError(String),
    Busy,
    Misuse(String),
    NoMem,
    NullValue,
    InvalidType { expected: &'static str, actual: u32 },
    ColumnIndexOutOfBounds { index: usize, count: usize },
    InvalidUtf8,
    Io(String),
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::SqlError(msg) => write!(f, "CybouDB SQL error: {}", msg),
            Error::Busy => write!(f, "CybouDB busy: active statements or locks held"),
            Error::Misuse(msg) => write!(f, "CybouDB misuse: {}", msg),
            Error::NoMem => write!(f, "CybouDB out of memory"),
            Error::NullValue => write!(f, "Unexpected NULL value"),
            Error::InvalidType { expected, actual } => {
                write!(f, "Invalid column type: expected {}, got type code {}", expected, actual)
            }
            Error::ColumnIndexOutOfBounds { index, count } => {
                write!(f, "Column index {} out of bounds (count: {})", index, count)
            }
            Error::InvalidUtf8 => write!(f, "Invalid UTF-8 string data"),
            Error::Io(msg) => write!(f, "I/O error: {}", msg),
        }
    }
}

impl std::error::Error for Error {}

pub type Result<T> = std::result::Result<T, Error>;

pub(crate) fn check_rc(rc: std::ffi::c_int, db: *mut ffi::cyboudb_db) -> Result<()> {
    match rc {
        ffi::CYBOUDB_OK => Ok(()),
        ffi::CYBOUDB_BUSY => Err(Error::Busy),
        ffi::CYBOUDB_NOMEM => Err(Error::NoMem),
        ffi::CYBOUDB_MISUSE => {
            let msg = if !db.is_null() {
                unsafe {
                    let ptr = ffi::cyboudb_errmsg(db);
                    if !ptr.is_null() {
                        CStr::from_ptr(ptr).to_string_lossy().into_owned()
                    } else {
                        "Invalid library call".to_string()
                    }
                }
            } else {
                "Invalid library call".to_string()
            };
            Err(Error::Misuse(msg))
        }
        _ => {
            let msg = if !db.is_null() {
                unsafe {
                    let ptr = ffi::cyboudb_errmsg(db);
                    if !ptr.is_null() {
                        CStr::from_ptr(ptr).to_string_lossy().into_owned()
                    } else {
                        "Unknown database error".to_string()
                    }
                }
            } else {
                "Unknown database error".to_string()
            };
            Err(Error::SqlError(msg))
        }
    }
}
