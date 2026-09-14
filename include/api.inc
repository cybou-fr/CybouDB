; Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
; SPDX-License-Identifier: Apache-2.0
; =============================================================================
;  include/api.inc - Internal definitions for the CybouDB C API implementation
; =============================================================================

%ifndef CybouDB_API_INC
%define CybouDB_API_INC

%include "cyboudb.inc"
%include "sql.inc"
%include "select_cursor.inc"

; --- Return codes matching cyboudb.h ---
%define CybouDB_C_OK               0
%define CybouDB_C_ROW              100
%define CybouDB_C_DONE             101
%define CybouDB_C_ERROR            -1
%define CybouDB_C_BUSY             -2
%define CybouDB_C_MISUSE           -3
%define CybouDB_C_NOMEM            -4

; --- Open Flags matching cyboudb.h ---
%define CybouDB_C_OPEN_READONLY    0x0001
%define CybouDB_C_OPEN_READWRITE   0x0002

; --- cyboudb_create_options --------------------------------------------------
; Two u32s, and room to grow. struct_size is how much of it the caller filled
; in, so a build that learns a new field later can tell whether this caller
; knew about it.
%define CybouDB_CREATE_OPT_SIZE    0    ; dword: sizeof the struct as filled in
%define CybouDB_CREATE_OPT_FLAGS   4    ; dword: CybouDB_CREATE_*
%define CybouDB_CREATE_QUEUE_LEASES 0x0001
%define CybouDB_CREATE_KNOWN       CybouDB_CREATE_QUEUE_LEASES

; A new field here may only change what is created if it comes with a flag of
; its own. struct_size widens the representation safely; flags declare the
; semantics, and only a flag is something an older build can refuse. See the
; contract in include/cyboudb.h.

; --- cyboudb_db structure layout (4096 bytes) ---
; The descriptor comes first and everything after it is placed relative to its
; size. Spelling these as literals meant that growing CybouDB_DB_SIZE silently
; overlapped the open flags with the tail of the descriptor - a bug with no
; symptom until something wrote through it.
%define DB_H_CTX                0               ; CybouDB_DB_SIZE bytes
%define DB_H_FLAGS              (CybouDB_DB_SIZE + 0)    ; dword: open flags
%define DB_H_OPEN               (CybouDB_DB_SIZE + 4)    ; dword: 1 if open, 0 if closed
%define DB_H_ERRCODE            (CybouDB_DB_SIZE + 8)    ; dword: internal error code
%define DB_H_ERRMSG             (CybouDB_DB_SIZE + 16)   ; 256 bytes: error message
%define DB_H_STMT_COUNT         (CybouDB_DB_SIZE + 272)  ; qword: live prepared statements
%define CybouDB_DB_H_SIZE          4096

; --- cyboudb_stmt header followed by a geometrically grown prepare arena ---
%define STMT_MAGIC_VAL          0x4C515341544D5453  ; 'STMTCybouDB'
%define STMT_H_DB               0               ; qword: cyboudb_db pointer
%define STMT_H_MAGIC            8               ; qword: magic value
%define STMT_H_STATE            16              ; dword: statement state
%define STMT_H_CUR_ROW          20              ; dword: active row index (0..63)
%define STMT_H_ACT_MASK         24              ; qword: active lanes mask remaining
%define STMT_H_CNT_ACCUM        32              ; qword: count(*) accumulator
%define STMT_H_ERRCODE          40              ; dword: error code
%define STMT_H_ERRMSG           44              ; 128 bytes: error string
%define STMT_H_PLAN             176             ; qword: pointer to BOUND_PLAN
%define STMT_H_CURSOR           184             ; CybouDB_SCAN_SIZE = 88 bytes
%define STMT_H_BATCH_VIEW       272             ; CybouDB_BATCH_VIEW_SIZE = 1544 bytes
%define STMT_H_ARENA            1816            ; SQL_ARENA_SIZE = 32 bytes
%define STMT_H_RESULT_COUNT     1848            ; qword: logical result column count
%define STMT_H_RESULT_INDICES   1856            ; 64 dword physical indices
%define STMT_H_RESULT_TYPES     2112            ; 64 dword types
%define STMT_H_RESULT_NAMES     2368            ; 64 names, 24 bytes each
%define STMT_H_ALLOC_SIZE       3904            ; qword: actual allocation length
%define STMT_H_SELECT           3912            ; shared pull execution state
%define STMT_H_DECODE           (STMT_H_SELECT + SQL_SELECT_SIZE)
%define STMT_H_ARENA_BUF        (STMT_H_DECODE + 32768)
%define CybouDB_STMT_INITIAL_SIZE  65536

; --- Statement States ---
%define STMT_STATE_INIT         0
%define STMT_STATE_SCANNING     1
%define STMT_STATE_DONE         2
%define STMT_STATE_ERROR        3
%define STMT_STATE_COUNT_DELIVER 4

%endif ; CybouDB_API_INC
