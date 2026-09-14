//! Raw FFI bindings to the CybouDB embedded database engine.

#![allow(non_camel_case_types)]
#![allow(non_snake_case)]

use std::ffi::{c_char, c_int, c_void};

pub const CYBOUDB_VERSION: &str = "0.5.0-preview.2";

// Return & Status Codes
pub const CYBOUDB_OK: c_int = 0;
pub const CYBOUDB_ROW: c_int = 100;
pub const CYBOUDB_DONE: c_int = 101;
pub const CYBOUDB_ERROR: c_int = -1;
pub const CYBOUDB_BUSY: c_int = -2;
pub const CYBOUDB_MISUSE: c_int = -3;
pub const CYBOUDB_NOMEM: c_int = -4;

// Data Types
pub const CYBOUDB_TYPE_INT32: u32 = 1;
pub const CYBOUDB_TYPE_INT64: u32 = 2;
pub const CYBOUDB_TYPE_FLOAT32: u32 = 3;
pub const CYBOUDB_TYPE_BOOL: u32 = 4;
pub const CYBOUDB_TYPE_TEXT: u32 = 5;
pub const CYBOUDB_TYPE_BLOB: u32 = 6;
pub const CYBOUDB_TYPE_VECTOR: u32 = 7;

// Open Flags
pub const CYBOUDB_OPEN_READONLY: u32 = 0x0001;
pub const CYBOUDB_OPEN_READWRITE: u32 = 0x0002;

// Opaque Types
#[repr(C)]
pub struct cyboudb_db {
    _unused: [u8; 0],
}

#[repr(C)]
pub struct cyboudb_stmt {
    _unused: [u8; 0],
}

// Column Batch View
#[repr(C)]
#[derive(Debug, Copy, Clone)]
pub struct cyboudb_colview {
    pub values_ptr: *const c_void,
    pub null_mask: u64,
    pub type_: u32,
    pub width: u32,
}

#[repr(C)]
#[derive(Debug, Copy, Clone)]
pub struct cyboudb_batch_view {
    pub row_count: u64,
    pub columns: [cyboudb_colview; 64],
}

extern "C" {
    // Database Connection Lifecycle
    pub fn cyboudb_open(
        path: *const c_char,
        flags: u32,
        out_db: *mut *mut cyboudb_db,
    ) -> c_int;

    pub fn cyboudb_create(
        path: *const c_char,
        pages: u64,
        out_db: *mut *mut cyboudb_db,
    ) -> c_int;

    pub fn cyboudb_close(db: *mut cyboudb_db) -> c_int;

    pub fn cyboudb_errmsg(db: *mut cyboudb_db) -> *const c_char;
    pub fn cyboudb_errcode(db: *mut cyboudb_db) -> c_int;

    pub fn cyboudb_exec(db: *mut cyboudb_db, sql: *const c_char) -> c_int;

    // Prepared Statement Lifecycle
    pub fn cyboudb_prepare(
        db: *mut cyboudb_db,
        sql: *const c_char,
        out_stmt: *mut *mut cyboudb_stmt,
    ) -> c_int;

    pub fn cyboudb_step(stmt: *mut cyboudb_stmt) -> c_int;

    pub fn cyboudb_step_batch(
        stmt: *mut cyboudb_stmt,
        out_batch: *mut *const cyboudb_batch_view,
        out_mask: *mut u64,
    ) -> c_int;

    pub fn cyboudb_batch_column(
        stmt: *mut cyboudb_stmt,
        batch: *const cyboudb_batch_view,
        result_col: c_int,
    ) -> *const cyboudb_colview;

    pub fn cyboudb_batch_bytes(
        stmt: *mut cyboudb_stmt,
        batch: *const cyboudb_batch_view,
        result_col: c_int,
        row: u32,
        out: *mut c_void,
        capacity: u64,
    ) -> i64;

    pub fn cyboudb_batch_vector_f32(
        stmt: *mut cyboudb_stmt,
        batch: *const cyboudb_batch_view,
        result_col: c_int,
        row: u32,
        out: *mut f32,
        capacity_floats: u64,
    ) -> i64;

    pub fn cyboudb_reset(stmt: *mut cyboudb_stmt) -> c_int;
    pub fn cyboudb_finalize(stmt: *mut cyboudb_stmt) -> c_int;

    // Parameter Binding
    pub fn cyboudb_bind_parameter_count(stmt: *mut cyboudb_stmt) -> c_int;
    pub fn cyboudb_bind_int32(stmt: *mut cyboudb_stmt, idx: c_int, value: i32) -> c_int;
    pub fn cyboudb_bind_int64(stmt: *mut cyboudb_stmt, idx: c_int, value: i64) -> c_int;
    pub fn cyboudb_bind_float(stmt: *mut cyboudb_stmt, idx: c_int, value: f32) -> c_int;
    pub fn cyboudb_bind_bool(stmt: *mut cyboudb_stmt, idx: c_int, value: c_int) -> c_int;
    pub fn cyboudb_bind_text(stmt: *mut cyboudb_stmt, idx: c_int, text: *const c_char, len: i64) -> c_int;
    pub fn cyboudb_bind_blob(stmt: *mut cyboudb_stmt, idx: c_int, data: *const c_void, len: i64) -> c_int;
    pub fn cyboudb_bind_vector_f32(stmt: *mut cyboudb_stmt, idx: c_int, values: *const f32, dims: c_int) -> c_int;
    pub fn cyboudb_bind_null(stmt: *mut cyboudb_stmt, idx: c_int) -> c_int;
    pub fn cyboudb_clear_bindings(stmt: *mut cyboudb_stmt) -> c_int;

    // Column Accessors
    pub fn cyboudb_column_count(stmt: *mut cyboudb_stmt) -> c_int;
    pub fn cyboudb_column_type(stmt: *mut cyboudb_stmt, col_idx: c_int) -> c_int;
    pub fn cyboudb_column_name(stmt: *mut cyboudb_stmt, col_idx: c_int) -> *const c_char;
    pub fn cyboudb_column_is_null(stmt: *mut cyboudb_stmt, col_idx: c_int) -> c_int;
    pub fn cyboudb_column_int64(stmt: *mut cyboudb_stmt, col_idx: c_int) -> i64;
    pub fn cyboudb_column_int32(stmt: *mut cyboudb_stmt, col_idx: c_int) -> i32;
    pub fn cyboudb_column_float(stmt: *mut cyboudb_stmt, col_idx: c_int) -> f32;
    pub fn cyboudb_column_bool(stmt: *mut cyboudb_stmt, col_idx: c_int) -> c_int;
    pub fn cyboudb_column_bytes(
        stmt: *mut cyboudb_stmt,
        col_idx: c_int,
        out: *mut c_void,
        capacity: u64,
        out_length: *mut u64,
    ) -> c_int;

    pub fn cyboudb_column_vector_dimensions(stmt: *mut cyboudb_stmt, col_idx: c_int) -> c_int;
    pub fn cyboudb_column_vector_f32(
        stmt: *mut cyboudb_stmt,
        col_idx: c_int,
        out: *mut f32,
        capacity_floats: u64,
        out_dim: *mut u64,
    ) -> c_int;

    // Queue / Message Access
    pub fn cyboudb_message(
        stmt: *mut cyboudb_stmt,
        out: *mut c_void,
        capacity: u64,
        out_length: *mut u64,
    ) -> c_int;
}
