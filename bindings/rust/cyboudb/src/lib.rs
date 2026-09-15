//! # CybouDB
//!
//! Safe, idiomatic Rust bindings for the **CybouDB** embedded database engine.
//!
//! CybouDB unifies relational tables, secondary B+Tree indexes, exact vector search,
//! durable queues, and replayable streams into a single `.cdb` file sharing a single
//! transaction engine.
//!
//! ## Quick Start
//!
//! ```no_run
//! use cyboudb::{Database, Result};
//!
//! fn main() -> Result<()> {
//!     let mut db = Database::create("app.cdb", 512)?;
//!
//!     db.execute("CREATE TABLE users (id INT32 NOT NULL, name TEXT, balance FLOAT32);")?;
//!
//!     let mut stmt = db.prepare("INSERT INTO users VALUES (?, ?, ?);")?;
//!     stmt.execute(&[&101, &"Alice", &250.50f32])?;
//!
//!     let mut query = db.prepare("SELECT id, name, balance FROM users WHERE id = ?;")?;
//!     let mut rows = query.query(&[&101])?;
//!
//!     if let Some(row) = rows.next() {
//!         let row = row?;
//!         let id: i32 = row.get(0)?;
//!         let name: String = row.get(1)?;
//!         let balance: f32 = row.get(2)?;
//!         println!("User: id={}, name={}, balance={}", id, name, balance);
//!     }
//!
//!     Ok(())
//! }
//! ```

pub mod database;
pub mod error;
pub mod statement;
pub mod transaction;
pub mod value;

pub use database::Database;
pub use error::{Error, Result};
pub use statement::{Row, Rows, Statement};
pub use transaction::Transaction;
pub use value::{FromColumn, ToParam, Type, Value};
