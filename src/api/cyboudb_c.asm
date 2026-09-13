; Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
; SPDX-License-Identifier: Apache-2.0
; =============================================================================
;  src/api/cyboudb_c.asm - Public Opaque C ABI Implementation for CybouDB
; =============================================================================

%include "api.inc"

; Fault injection is linked only by --c-tests, never by --lib.
%ifdef CybouDB_API_TEST_ALLOC
%define os_mem_alloc cyboudb_test_mem_alloc
%define os_mem_free cyboudb_test_mem_free
%endif

BITS 64
default rel

; --- External engine functions -----------------------------------------------
extern db_open, db_close, db_commit, db_rollback
extern db_catalog_put, db_catalog_drop, db_catalog_truncate_data, db_pax_insert
extern db_var_read_chain
extern sql_select_open, sql_select_next
extern sql_arena_init, sql_arena_alloc
extern sql_parse, sql_bind, sql_execute_batch
extern os_mem_alloc, os_mem_free

%ifdef CybouDB_WINDOWS
extern os_utf8_to_wide
%endif

; --- Public C API exports ----------------------------------------------------
global cyboudb_open
global cyboudb_close
global cyboudb_errmsg
global cyboudb_errcode
global cyboudb_prepare
global cyboudb_step
global cyboudb_step_batch
global cyboudb_batch_column
global cyboudb_batch_bytes
global cyboudb_batch_vector_f32
global cyboudb_reset
global cyboudb_finalize
global cyboudb_column_count
global cyboudb_column_type
global cyboudb_column_name
global cyboudb_column_is_null
global cyboudb_column_int64
global cyboudb_column_int32
global cyboudb_column_float
global cyboudb_column_bool
global cyboudb_column_bytes, cyboudb_message
global cyboudb_column_vector_dimensions
global cyboudb_column_vector_f32
global cyboudb_exec

section .rodata
str_ok:         db "ok", 0
str_misuse:     db "misuse: invalid argument or closed handle", 0
str_count_star: db "count(*)", 0
str_empty:      db 0
str_busy:       db "busy: finalize all statements before closing the database", 0
str_nomem:      db "out of memory preparing statement", 0
str_tx_active:  db "cannot BEGIN inside active transaction", 0
str_no_tx_commit: db "no active transaction to COMMIT", 0
str_no_tx_rollback: db "no active transaction to ROLLBACK", 0
str_readonly:   db "database is read-only", 0

section .text

; =============================================================================
;  cyboudb_open(const char *path, uint32_t flags, cyboudb_db **out_db) -> int
; =============================================================================
cyboudb_open:
%ifdef CybouDB_WINDOWS
    FRAME_BEGIN 2128, 0                 ; [rbp - 2048]: wide path buffer, [rbp - 2080]: locals
%else
    FRAME_BEGIN 48, 0
%endif
    mov     [rbp - 8], ARG1             ; path
    mov     [rbp - 16], ARG2d           ; flags
    mov     [rbp - 24], ARG3            ; out_db

    ; Validate pointers
    test    ARG1, ARG1
    jz      .open_misuse
    test    ARG3, ARG3
    jz      .open_misuse
    mov     qword [ARG3], 0

    ; Allocate connection structure (4096 bytes)
    mov     ARG1, CybouDB_DB_H_SIZE
    call    os_mem_alloc
    test    rax, rax
    jz      .open_nomem
    mov     [rbp - 32], rax             ; cyboudb_db ptr

    ; Zero-initialize structure without clobbering callee-saved registers
    mov     r8, rax
    mov     ecx, CybouDB_DB_H_SIZE / 8
.open_zero:
    mov     qword [r8], 0
    add     r8, 8
    dec     ecx
    jnz     .open_zero

    ; Store flags
    mov     r10, [rbp - 32]
    mov     eax, [rbp - 16]
    mov     [r10 + DB_H_FLAGS], eax

    ; Determine writable mode and preserve on stack
    mov     edx, eax
    and     edx, CybouDB_C_OPEN_READWRITE
    setnz   dl
    movzx   edx, dl                     ; writable: 1 or 0
    mov     [rbp - 40], rdx

%ifdef CybouDB_WINDOWS
    ; Convert UTF-8 path to UTF-16 wide string
    mov     ARG1, [rbp - 8]
    lea     ARG2, [rbp - 2048]
    mov     ARG3d, 1024
    call    os_utf8_to_wide
    test    eax, eax
    jz      .open_fail_free

    ; Open database on Windows
    lea     ARG1, [rbp - 2048]
    mov     r10, [rbp - 32]
    lea     ARG2, [r10 + DB_H_CTX]
    mov     ARG3, [rbp - 40]            ; writable
    xor     ARG4, ARG4                  ; verify = 0
    call    db_open
%else
    ; Open database on Linux
    mov     ARG1, [rbp - 8]
    mov     r10, [rbp - 32]
    lea     ARG2, [r10 + DB_H_CTX]
    mov     ARG3, [rbp - 40]            ; writable
    xor     ARG4, ARG4                  ; verify = 0
    call    db_open
%endif

    test    eax, eax
    jnz     .open_fail_free

    ; Mark open and return handle
    mov     r10, [rbp - 32]
    mov     dword [r10 + DB_H_OPEN], 1
    mov     r11, [rbp - 24]
    mov     [r11], r10
    xor     eax, eax                    ; CybouDB_C_OK
    FRAME_END
    ret

.open_fail_free:
    mov     [rbp - 48], rax
    mov     ARG1, [rbp - 32]
    mov     ARG2, CybouDB_DB_H_SIZE
    call    os_mem_free
    cmp     qword [rbp - 48], CybouDB_E_BUSY
    je      .open_busy
    mov     eax, CybouDB_C_ERROR
    FRAME_END
    ret

.open_busy:
    mov     eax, CybouDB_C_BUSY
    FRAME_END
    ret

.open_nomem:
    mov     eax, CybouDB_C_NOMEM
    FRAME_END
    ret

.open_misuse:
    mov     eax, CybouDB_C_MISUSE
    FRAME_END
    ret


; =============================================================================
;  cyboudb_close(cyboudb_db *db) -> int
; =============================================================================
cyboudb_close:
    FRAME_BEGIN 16, 0
    test    ARG1, ARG1
    jz      .close_ok

    mov     r10, ARG1
    cmp     qword [r10 + DB_H_STMT_COUNT], 0
    jne     .close_busy
    cmp     dword [r10 + DB_H_OPEN], 1
    jne     .close_free

    ; Close database file and unmap
    mov     [rbp - 8], r10
    lea     ARG1, [r10 + DB_H_CTX]
    call    db_close
    mov     r10, [rbp - 8]
    mov     dword [r10 + DB_H_OPEN], 0

.close_free:
    mov     ARG1, r10
    mov     ARG2, CybouDB_DB_H_SIZE
    call    os_mem_free

.close_ok:
    xor     eax, eax                    ; CybouDB_C_OK
    FRAME_END
    ret

.close_busy:
    mov     dword [r10 + DB_H_ERRCODE], CybouDB_C_BUSY
    lea     r8, [str_busy]
    lea     r9, [r10 + DB_H_ERRMSG]
.busy_copy:
    mov     al, [r8]
    mov     [r9], al
    inc     r8
    inc     r9
    test    al, al
    jnz     .busy_copy
    mov     eax, CybouDB_C_BUSY
    FRAME_END
    ret


; =============================================================================
;  cyboudb_errmsg(cyboudb_db *db) -> const char *
; =============================================================================
cyboudb_errmsg:
    test    ARG1, ARG1
    jz      .errmsg_misuse
    lea     rax, [ARG1 + DB_H_ERRMSG]
    cmp     byte [rax], 0
    je      .errmsg_ok
    ret
.errmsg_ok:
    lea     rax, [str_ok]
    ret
.errmsg_misuse:
    lea     rax, [str_misuse]
    ret


; =============================================================================
;  cyboudb_errcode(cyboudb_db *db) -> int
; =============================================================================
cyboudb_errcode:
    test    ARG1, ARG1
    jz      .errcode_misuse
    mov     eax, [ARG1 + DB_H_ERRCODE]
    ret
.errcode_misuse:
    mov     eax, CybouDB_C_MISUSE
    ret


; =============================================================================
;  cyboudb_prepare(cyboudb_db *db, const char *sql, cyboudb_stmt **out_stmt) -> int
; =============================================================================
cyboudb_prepare:
    FRAME_BEGIN 256, 1                  ; locals: [rbp-64]=ast, [rbp-192]=err, STKARG(0)
    mov     [rbp - 232], r12            ; preserve callee-saved r12
    mov     [rbp - 200], ARG1           ; db
    mov     [rbp - 208], ARG2           ; sql
    mov     [rbp - 216], ARG3           ; out_stmt

    ; Validate pointers
    test    ARG1, ARG1
    jz      .prep_misuse
    test    ARG2, ARG2
    jz      .prep_misuse
    test    ARG3, ARG3
    jz      .prep_misuse
    mov     qword [ARG3], 0

    ; Verify db is open
    mov     r10, ARG1
    cmp     dword [r10 + DB_H_OPEN], 1
    jne     .prep_misuse

    mov     qword [rbp - 240], CybouDB_STMT_INITIAL_SIZE
.prep_allocate:
    ; No externally visible pointers exist until prepare succeeds. Rebuild
    ; AST and bound plan after growth rather than relocating pointer graphs.
    mov     ARG1, [rbp - 240]
    call    os_mem_alloc
    test    rax, rax
    jz      .prep_nomem
    mov     [rbp - 224], rax            ; stmt

    ; Initialize the header, including statement-owned result metadata.
    mov     r8, rax
    mov     ecx, STMT_H_ARENA_BUF / 8
.prep_zero:
    mov     qword [r8], 0
    add     r8, 8
    dec     ecx
    jnz     .prep_zero

    ; Initialize statement header
    mov     r12, [rbp - 224]
    mov     rax, [rbp - 240]
    mov     [r12 + STMT_H_ALLOC_SIZE], rax
    mov     rax, [rbp - 200]
    mov     [r12 + STMT_H_DB], rax
    mov     rax, STMT_MAGIC_VAL
    mov     [r12 + STMT_H_MAGIC], rax
    mov     dword [r12 + STMT_H_STATE], STMT_STATE_INIT

    ; Initialize statement arena
    lea     ARG1, [r12 + STMT_H_ARENA]
    lea     ARG2, [r12 + STMT_H_ARENA_BUF]
    mov     ARG3, [r12 + STMT_H_ALLOC_SIZE]
    sub     ARG3, STMT_H_ARENA_BUF
    call    sql_arena_init

    ; Compute length of SQL string
    mov     r8, [rbp - 208]             ; sql
    xor     ecx, ecx
.sql_len_loop:
    cmp     byte [r8 + rcx], 0
    je      .sql_len_done
    inc     rcx
    jmp     .sql_len_loop
.sql_len_done:

    ; Parse SQL statement: sql_parse(sql_src, sql_len, arena, out_stmt, out_err)
    mov     ARG2, rcx                   ; sql_len (must set ARG2 before ARG1 overwrites rcx on Win64)
    mov     ARG1, [rbp - 208]           ; sql_src
    lea     ARG3, [r12 + STMT_H_ARENA]  ; arena
    lea     ARG4, [rbp - 64]            ; out_ast_stmt
    lea     rax, [rbp - 192]            ; out_err
    PASS_ARG5 rax
    call    sql_parse
    test    eax, eax
    jnz     .prep_fail

    ; Bind SQL statement: sql_bind(db_ctx, ast_stmt, arena, out_bound_plan, out_err)
    mov     r10, [rbp - 200]
    lea     ARG1, [r10 + DB_H_CTX]
    mov     ARG2, [rbp - 64]            ; ast_stmt ptr returned by sql_parse
    lea     ARG3, [r12 + STMT_H_ARENA]
    lea     ARG4, [r12 + STMT_H_PLAN]   ; out_bound_plan (writes bound_plan ptr)
    lea     rax, [rbp - 192]
    PASS_ARG5 rax                       ; out_err
    call    sql_bind
    test    eax, eax
    jnz     .prep_fail

    ; Snapshot result metadata while the bound schema page is current.
    mov     r10, [r12 + STMT_H_PLAN]
    cmp     qword [r10 + PLAN_TYPE], STMT_SELECT
    jne     .metadata_done
    test    qword [r10 + PLAN_FLAGS], PLAN_FLAG_COUNT_STAR
    jnz     .metadata_count
    mov     rax, [r10 + PLAN_DATA1]
    mov     [r12 + STMT_H_RESULT_COUNT], rax
    mov     r8, [r10 + PLAN_DATA2]
    mov     r9, [r10 + PLAN_DATA3]
    mov     r11, [r10 + PLAN_SCHEMA_PAGE]
    xor     ecx, ecx
.metadata_loop:
    cmp     rcx, [r12 + STMT_H_RESULT_COUNT]
    jae     .metadata_repoint
    mov     eax, [r8 + rcx * 4]
    mov     [r12 + STMT_H_RESULT_INDICES + rcx * 4], eax
    mov     r10, [r12 + STMT_H_PLAN]
    mov     r11, [r10 + PLAN_SCHEMA_PAGE]
    cmp     qword [r10 + PLAN_JOIN_TYPE], 0
    je      .metadata_column_ready
    mov     r10, [r10 + PLAN_JOIN_PROJECTIONS]
    mov     eax, [r10 + rcx * 4]
    test    eax, PLAN_PROJ_RIGHT_BIT
    jz      .metadata_column_ready
    and     eax, 0x7fffffff
    mov     r10, [r12 + STMT_H_PLAN]
    mov     r11, [r10 + PLAN_RIGHT_SCHEMA]
.metadata_column_ready:
    shl     rax, 5
    lea     rax, [r11 + CAT_COLUMNS + rax + 8]
    imul    rdx, rcx, 24
    mov     r10, [rax]
    mov     [r12 + STMT_H_RESULT_NAMES + rdx], r10
    mov     r10, [rax + 8]
    mov     [r12 + STMT_H_RESULT_NAMES + rdx + 8], r10
    mov     r10, [rax + 16]
    mov     [r12 + STMT_H_RESULT_NAMES + rdx + 16], r10
    mov     eax, [r9 + rcx * 4]
    mov     [r12 + STMT_H_RESULT_TYPES + rcx * 4], eax
    inc     ecx
    jmp     .metadata_loop
.metadata_repoint:
    mov     r10, [r12 + STMT_H_PLAN]
    lea     rax, [r12 + STMT_H_RESULT_INDICES]
    mov     [r10 + PLAN_DATA2], rax
    lea     rax, [r12 + STMT_H_RESULT_TYPES]
    mov     [r10 + PLAN_DATA3], rax
    jmp     .metadata_done
.metadata_count:
    mov     qword [r12 + STMT_H_RESULT_COUNT], 1
    mov     dword [r12 + STMT_H_RESULT_TYPES], CAT_INT64
    lea     r8, [str_count_star]
    xor     ecx, ecx
.metadata_count_name:
    mov     al, [r8 + rcx]
    mov     [r12 + STMT_H_RESULT_NAMES + rcx], al
    inc     ecx
    test    al, al
    jnz     .metadata_count_name
.metadata_done:
    ; Count only successfully prepared handles; failed prepare owns no ref.
    mov     r10, [rbp - 200]
    inc     qword [r10 + DB_H_STMT_COUNT]
    ; Output statement handle
    mov     r10, [rbp - 216]
    mov     [r10], r12
    xor     eax, eax                    ; CybouDB_C_OK
    jmp     .prep_exit

.prep_fail:
    cmp     qword [r12 + STMT_H_ARENA + ARENA_FAILED], 0
    jne     .prep_grow
    ; Record error in db
    mov     r10, [rbp - 200]
    mov     [r10 + DB_H_ERRCODE], eax
    lea     r8, [rbp - 192 + SQL_ERR_MSG]
    lea     r9, [r10 + DB_H_ERRMSG]
    mov     ecx, 72                    ; SQL_ERR_MSG is 72 bytes, not 256
.prep_err_copy:
    mov     al, [r8]
    mov     [r9], al
    inc     r8
    inc     r9
    test    al, al
    jz      .prep_err_copied
    dec     ecx
    jnz     .prep_err_copy
    mov     byte [r9 - 1], 0
.prep_err_copied:

    ; Free allocated statement
    mov     ARG1, [rbp - 224]
    mov     ARG2, [rbp - 240]
    call    os_mem_free
    mov     eax, CybouDB_C_ERROR
    jmp     .prep_exit

.prep_grow:
    mov     ARG1, [rbp - 224]
    mov     ARG2, [rbp - 240]
    call    os_mem_free
    mov     rax, [rbp - 240]
    add     rax, rax
    jo      .prep_nomem
    mov     [rbp - 240], rax
    jmp     .prep_allocate

.prep_nomem:
    mov     r10, [rbp - 200]
    mov     dword [r10 + DB_H_ERRCODE], CybouDB_C_NOMEM
    lea     r8, [str_nomem]
    lea     r9, [r10 + DB_H_ERRMSG]
.nomem_copy:
    mov     al, [r8]
    mov     [r9], al
    inc     r8
    inc     r9
    test    al, al
    jnz     .nomem_copy
    mov     eax, CybouDB_C_NOMEM
    jmp     .prep_exit

.prep_misuse:
    mov     eax, CybouDB_C_MISUSE
    jmp     .prep_exit

.prep_exit:
    mov     r12, [rbp - 232]            ; restore callee-saved r12
    FRAME_END
    ret


; =============================================================================
;  cyboudb_step(cyboudb_stmt *stmt) -> int
; =============================================================================
cyboudb_step:
    FRAME_BEGIN 96, 2
    mov     [rbp - 8], r12              ; preserve callee-saved r12
    test    ARG1, ARG1
    jz      .step_misuse

    mov     r12, ARG1                   ; stmt
    mov     [rbp - 16], r12
    mov     rax, STMT_MAGIC_VAL
    cmp     [r12 + STMT_H_MAGIC], rax
    jne     .step_misuse

    mov     rax, [r12 + STMT_H_PLAN]
    mov     [rbp - 24], rax             ; plan
    test    rax, rax
    jz      .step_misuse

    mov     rcx, [rax + PLAN_TYPE]
    cmp     rcx, STMT_CREATE_TABLE
    je      .step_create
    cmp     rcx, STMT_DROP_TABLE
    je      .step_drop
    cmp     rcx, STMT_DELETE
    je      .step_delete
    cmp     rcx, STMT_INSERT
    je      .step_insert
    cmp     rcx, STMT_SELECT
    je      .step_select
    cmp     rcx, STMT_BEGIN
    je      .step_begin
    cmp     rcx, STMT_COMMIT
    je      .step_commit
    cmp     rcx, STMT_ROLLBACK
    je      .step_rollback
    cmp     rcx, STMT_UPDATE
    je      .step_drop                  ; the executor knows about indexes
    cmp     rcx, STMT_CREATE_INDEX
    je      .step_drop                  ; both run through the executor
    cmp     rcx, STMT_DROP_INDEX
    je      .step_drop
    cmp     rcx, STMT_CREATE_QUEUE
    je      .step_drop
    cmp     rcx, STMT_DROP_QUEUE
    je      .step_drop                  ; and the fourth kind, the same way
    cmp     rcx, STMT_ENQUEUE
    je      .step_drop                  ; nothing to hand back
    cmp     rcx, STMT_DEQUEUE
    je      .step_dequeue

    mov     eax, CybouDB_C_ERROR
    jmp     .step_exit

; --- DDL / Mutating execution ------------------------------------------------
.step_begin:
    cmp     dword [r12 + STMT_H_STATE], STMT_STATE_DONE
    je      .step_done_ret
    mov     r10, [r12 + STMT_H_DB]
    test    dword [r10 + DB_H_FLAGS], CybouDB_C_OPEN_READWRITE
    jz      .step_begin_readonly
    cmp     qword [r10 + DB_H_CTX + DB_TX_ACTIVE], 0
    jne     .step_begin_active
    mov     qword [r10 + DB_H_CTX + DB_TX_ACTIVE], 1
    inc     qword [r10 + DB_H_CTX + DB_TX_ID]
    mov     dword [r12 + STMT_H_STATE], STMT_STATE_DONE
    mov     eax, CybouDB_C_DONE
    jmp     .step_exit

.step_begin_readonly:
    mov     dword [r12 + STMT_H_STATE], STMT_STATE_ERROR
    mov     r10, [r12 + STMT_H_DB]
    mov     dword [r10 + DB_H_ERRCODE], CybouDB_C_ERROR
    lea     r11, [str_readonly]
    jmp     .step_copy_errmsg

.step_begin_active:
    mov     dword [r12 + STMT_H_STATE], STMT_STATE_ERROR
    mov     r10, [r12 + STMT_H_DB]
    mov     dword [r10 + DB_H_ERRCODE], CybouDB_C_ERROR
    lea     r11, [str_tx_active]
    jmp     .step_copy_errmsg

.step_commit:
    cmp     dword [r12 + STMT_H_STATE], STMT_STATE_DONE
    je      .step_done_ret
    mov     r10, [r12 + STMT_H_DB]
    cmp     qword [r10 + DB_H_CTX + DB_TX_ACTIVE], 0
    je      .step_commit_no_active
    lea     ARG1, [r10 + DB_H_CTX]
    call    db_commit
    mov     r10, [r12 + STMT_H_DB]
    mov     qword [r10 + DB_H_CTX + DB_TX_ACTIVE], 0
    test    eax, eax
    jnz     .step_commit_failed
    mov     dword [r12 + STMT_H_STATE], STMT_STATE_DONE
    mov     eax, CybouDB_C_DONE
    jmp     .step_exit

.step_commit_failed:
    ; A refused commit leaves its pages staged and the transaction over.
    ; Discard them here, or the next statement - which autocommits - would
    ; publish them alongside its own work. The rollback's own result must
    ; not displace the code that says why the commit failed.
    mov     [rbp - 32], eax
    mov     r10, [r12 + STMT_H_DB]
    lea     ARG1, [r10 + DB_H_CTX]
    call    db_rollback
    mov     eax, [rbp - 32]
    jmp     .step_mutation_error

.step_commit_no_active:
    mov     dword [r12 + STMT_H_STATE], STMT_STATE_ERROR
    mov     r10, [r12 + STMT_H_DB]
    mov     dword [r10 + DB_H_ERRCODE], CybouDB_C_ERROR
    lea     r11, [str_no_tx_commit]
    jmp     .step_copy_errmsg

.step_rollback:
    cmp     dword [r12 + STMT_H_STATE], STMT_STATE_DONE
    je      .step_done_ret
    mov     r10, [r12 + STMT_H_DB]
    cmp     qword [r10 + DB_H_CTX + DB_TX_ACTIVE], 0
    je      .step_rollback_no_active
    lea     ARG1, [r10 + DB_H_CTX]
    call    db_rollback
    mov     r10, [r12 + STMT_H_DB]
    mov     qword [r10 + DB_H_CTX + DB_TX_ACTIVE], 0
    test    eax, eax
    jnz     .step_mutation_error
    mov     dword [r12 + STMT_H_STATE], STMT_STATE_DONE
    mov     eax, CybouDB_C_DONE
    jmp     .step_exit

.step_rollback_no_active:
    mov     dword [r12 + STMT_H_STATE], STMT_STATE_ERROR
    mov     r10, [r12 + STMT_H_DB]
    mov     dword [r10 + DB_H_ERRCODE], CybouDB_C_ERROR
    lea     r11, [str_no_tx_rollback]
    jmp     .step_copy_errmsg

.step_copy_errmsg:
    lea     rdi, [r10 + DB_H_ERRMSG]
    lea     rdx, [r12 + STMT_H_ERRMSG]
.copy_err_loop:
    mov     al, [r11]
    mov     [rdi], al
    mov     [rdx], al
    inc     r11
    inc     rdi
    inc     rdx
    test    al, al
    jnz     .copy_err_loop
    mov     eax, CybouDB_C_ERROR
    jmp     .step_exit

.step_create:
    cmp     dword [r12 + STMT_H_STATE], STMT_STATE_DONE
    je      .step_done_ret

    mov     r9, [rbp - 24]              ; plan
    mov     r10, [r12 + STMT_H_DB]
    lea     ARG1, [r10 + DB_H_CTX]
    mov     ARG2, [r9 + PLAN_TABLE_ID]
    mov     ARG3, [r9 + PLAN_DATA1]
    call    db_catalog_put
    test    eax, eax
    jnz     .step_mutation_error

    ; Auto-commit if opened read-write and not in explicit transaction
    mov     r10, [r12 + STMT_H_DB]
    test    dword [r10 + DB_H_FLAGS], CybouDB_C_OPEN_READWRITE
    jz      .step_create_done
    cmp     qword [r10 + DB_H_CTX + DB_TX_ACTIVE], 0
    jne     .step_create_done
    lea     ARG1, [r10 + DB_H_CTX]
    call    db_commit
    test    eax, eax
    jnz     .step_mutation_error

.step_create_done:
    mov     dword [r12 + STMT_H_STATE], STMT_STATE_DONE
    mov     eax, CybouDB_C_DONE
    jmp     .step_exit

; DROP TABLE, CREATE INDEX and DROP INDEX: one path, because all three are
; a statement the executor runs and an autocommit afterwards.
.step_drop:
    cmp     dword [r12 + STMT_H_STATE], STMT_STATE_DONE
    je      .step_done_ret

    ; Likewise: dropping a table takes its indexes with it, an UPDATE moves
    ; the keys of every index over the column it writes, and only the
    ; executor knows either.
    lea     ARG1, [rbp - 96]
    lea     ARG2, [r12 + STMT_H_SELECT]
    mov     ARG3, STMT_H_ARENA_BUF - STMT_H_SELECT
    call    sql_arena_init
    mov     r10, [r12 + STMT_H_DB]
    lea     ARG1, [r10 + DB_H_CTX]
    mov     ARG2, [rbp - 24]            ; plan
    lea     ARG3, [rbp - 96]
    xor     ARG4, ARG4
    xor     eax, eax
    PASS_ARG5 rax
    xor     eax, eax
    PASS_ARG6 rax
    call    sql_execute_batch
    test    eax, eax
    jnz     .step_mutation_error

    ; Auto-commit if opened read-write and not in explicit transaction
    mov     r10, [r12 + STMT_H_DB]
    test    dword [r10 + DB_H_FLAGS], CybouDB_C_OPEN_READWRITE
    jz      .step_drop_done
    cmp     qword [r10 + DB_H_CTX + DB_TX_ACTIVE], 0
    jne     .step_drop_done
    lea     ARG1, [r10 + DB_H_CTX]
    call    db_commit
    test    eax, eax
    jnz     .step_mutation_error

.step_drop_done:
    mov     dword [r12 + STMT_H_STATE], STMT_STATE_DONE
    mov     eax, CybouDB_C_DONE
    jmp     .step_exit

; DELETE-V1 through the ABI: the whole table, or nothing to do at all.
.step_delete:
    cmp     dword [r12 + STMT_H_STATE], STMT_STATE_DONE
    je      .step_done_ret

    ; DELETE runs through the shared executor: a predicate needs the scan,
    ; the kernels and the rewrite that only sql_execute_batch has.
    ;
    ; It executes against its own arena laid over the pull-select state and
    ; decode buffer, which a DELETE plan never steps through. The prepare
    ; arena still holds the plan and is left alone: it is sized for what
    ; binding needed, not for what a rewrite scratch costs.
    lea     ARG1, [rbp - 96]
    lea     ARG2, [r12 + STMT_H_SELECT]
    mov     ARG3, STMT_H_ARENA_BUF - STMT_H_SELECT
    call    sql_arena_init
    mov     r10, [r12 + STMT_H_DB]
    lea     ARG1, [r10 + DB_H_CTX]
    mov     ARG2, [rbp - 24]            ; plan
    lea     ARG3, [rbp - 96]
    xor     ARG4, ARG4                  ; no row sink
    xor     eax, eax
    PASS_ARG5 rax
    xor     eax, eax
    PASS_ARG6 rax
    call    sql_execute_batch
    test    eax, eax
    jnz     .step_mutation_error

    ; Nothing was staged when the predicate matched no rows.
    mov     r9, [rbp - 24]
    cmp     qword [r9 + PLAN_DELETE_ROWS], 0
    je      .step_delete_done

    ; Auto-commit if opened read-write and not in explicit transaction
    mov     r10, [r12 + STMT_H_DB]
    test    dword [r10 + DB_H_FLAGS], CybouDB_C_OPEN_READWRITE
    jz      .step_delete_done
    cmp     qword [r10 + DB_H_CTX + DB_TX_ACTIVE], 0
    jne     .step_delete_done
    lea     ARG1, [r10 + DB_H_CTX]
    call    db_commit
    test    eax, eax
    jnz     .step_mutation_error

.step_delete_done:
    mov     dword [r12 + STMT_H_STATE], STMT_STATE_DONE
    mov     eax, CybouDB_C_DONE
    jmp     .step_exit

.step_insert:
    cmp     dword [r12 + STMT_H_STATE], STMT_STATE_DONE
    je      .step_done_ret

    ; Through the shared executor rather than straight to db_pax_insert. The
    ; second copy of what a statement does is a second place to forget part
    ; of it, and this one had forgotten the indexes: two hundred rows went
    ; into a table and none of them into the tree over it.
    lea     ARG1, [rbp - 96]
    lea     ARG2, [r12 + STMT_H_SELECT]
    mov     ARG3, STMT_H_ARENA_BUF - STMT_H_SELECT
    call    sql_arena_init
    mov     r10, [r12 + STMT_H_DB]
    lea     ARG1, [r10 + DB_H_CTX]
    mov     ARG2, [rbp - 24]            ; plan
    lea     ARG3, [rbp - 96]
    xor     ARG4, ARG4                  ; no row sink
    xor     eax, eax
    PASS_ARG5 rax
    xor     eax, eax
    PASS_ARG6 rax
    call    sql_execute_batch
    test    eax, eax
    jnz     .step_mutation_error

    ; Auto-commit if opened read-write and not in explicit transaction
    mov     r10, [r12 + STMT_H_DB]
    test    dword [r10 + DB_H_FLAGS], CybouDB_C_OPEN_READWRITE
    jz      .step_insert_done
    cmp     qword [r10 + DB_H_CTX + DB_TX_ACTIVE], 0
    jne     .step_insert_done
    lea     ARG1, [r10 + DB_H_CTX]
    call    db_commit
    test    eax, eax
    jnz     .step_mutation_error

.step_insert_done:
    mov     dword [r12 + STMT_H_STATE], STMT_STATE_DONE
    mov     eax, CybouDB_C_DONE
    jmp     .step_exit

.step_mutation_error:
    mov     dword [r12 + STMT_H_STATE], STMT_STATE_ERROR
    mov     r10, [r12 + STMT_H_DB]
    mov     [r10 + DB_H_ERRCODE], eax
    mov     eax, CybouDB_C_ERROR
    jmp     .step_exit

; --- SELECT execution --------------------------------------------------------
.step_select:
    cmp dword [r12 + STMT_H_STATE], STMT_STATE_SCANNING
    jne .step_fetch_batch
    mov r10, [r12 + STMT_H_DB]
    mov rax, [r10 + DB_H_CTX + DB_GENERATION]
    cmp rax, [r12 + STMT_H_SELECT + SEL_SCAN + SCAN_GENERATION]
    jne .step_stale
    mov rax, [r12 + STMT_H_ACT_MASK]
    test rax, rax
    jnz .step_take_lane
.step_fetch_batch:
    mov ARG1, r12
    call api_select_next
    cmp eax, CybouDB_C_ROW
    jne .step_exit
    mov rax, rdx
.step_take_lane:
    bsf rcx, rax
    btr rax, rcx
    mov [r12 + STMT_H_ACT_MASK], rax
    mov [r12 + STMT_H_CUR_ROW], ecx
    mov eax, CybouDB_C_ROW
    jmp .step_exit
.step_done_ret:
    mov eax, CybouDB_C_DONE
    jmp .step_exit
.step_stale:
    mov eax, CybouDB_E_STATE
    jmp .step_mutation_error

; DEQUEUE answers with one value rather than with rows, so it does not come
; back through a batch view - there is no schema to describe and no column to
; describe it as. What it does use is the vocabulary a step already has: ROW
; when a message came back, DONE when the queue was empty. The bytes are then
; read with cyboudb_message.
;
; The state is deliberately not latched to DONE. A queue is not a result set
; that runs out: stepping again asks again, and a message enqueued in between
; is there to be taken.
.step_dequeue:
    lea     ARG1, [rbp - 96]
    lea     ARG2, [r12 + STMT_H_SELECT]
    mov     ARG3, STMT_H_ARENA_BUF - STMT_H_SELECT
    call    sql_arena_init
    mov     r10, [r12 + STMT_H_DB]
    lea     ARG1, [r10 + DB_H_CTX]
    mov     ARG2, [rbp - 24]            ; plan
    lea     ARG3, [rbp - 96]
    xor     ARG4, ARG4
    xor     eax, eax
    PASS_ARG5 rax
    xor     eax, eax
    PASS_ARG6 rax
    call    sql_execute_batch
    test    eax, eax
    jnz     .step_mutation_error

    ; Each step is its own transaction, which is the commit-then-work order
    ; docs/QUEUE.md calls at-most-once. A caller that needs the other order
    ; opens a transaction of its own around the step.
    mov     r10, [r12 + STMT_H_DB]
    test    dword [r10 + DB_H_FLAGS], CybouDB_C_OPEN_READWRITE
    jz      .step_dequeue_answer
    cmp     qword [r10 + DB_H_CTX + DB_TX_ACTIVE], 0
    jne     .step_dequeue_answer
    lea     ARG1, [r10 + DB_H_CTX]
    call    db_commit
    test    eax, eax
    jnz     .step_mutation_error
.step_dequeue_answer:
    mov     r10, [rbp - 24]
    cmp     qword [r10 + PLAN_DATA3], 0
    je      .step_dequeue_empty
    mov     eax, CybouDB_C_ROW
    jmp     .step_exit
.step_dequeue_empty:
    mov     eax, CybouDB_C_DONE
    jmp     .step_exit

.step_misuse:
    mov     eax, CybouDB_C_MISUSE
    jmp     .step_exit

.step_exit:
    mov     r12, [rbp - 8]              ; restore callee-saved r12
    FRAME_END
    ret


; =============================================================================
;  cyboudb_step_batch(cyboudb_stmt *stmt, const cyboudb_batch_view **out_batch,
;                  uint64_t *out_mask) -> int
; =============================================================================
cyboudb_step_batch:
    FRAME_BEGIN 48, 0
    mov     [rbp - 8], r12              ; preserve callee-saved r12
    test    ARG1, ARG1
    jz      .batch_misuse
    test    ARG2, ARG2
    jz      .batch_misuse
    test    ARG3, ARG3
    jz      .batch_misuse

    mov     r12, ARG1                   ; stmt
    mov     [rbp - 16], ARG2            ; out_batch
    mov     [rbp - 24], ARG3            ; out_mask
    mov     qword [ARG2], 0
    mov     qword [ARG3], 0
    mov     rax, STMT_MAGIC_VAL
    cmp     [r12 + STMT_H_MAGIC], rax
    jne     .batch_misuse

    mov     rax, [r12 + STMT_H_PLAN]
    mov     [rbp - 32], rax             ; plan
    test    rax, rax
    jz      .batch_misuse

    cmp qword [rax + PLAN_TYPE], STMT_SELECT
    jne .batch_misuse
    mov ARG1, r12
    call api_select_next
    cmp eax, CybouDB_C_ROW
    jne .batch_exit
    mov r10, [rbp - 16]
    lea r11, [r12 + STMT_H_BATCH_VIEW]
    mov [r10], r11
    mov r10, [rbp - 24]
    mov [r10], rdx
    mov [r12 + STMT_H_ACT_MASK], rdx
    jmp .batch_exit

.batch_misuse:
    mov     eax, CybouDB_C_MISUSE
    jmp     .batch_exit

.batch_exit:
    mov     r12, [rbp - 8]              ; restore callee-saved r12
    FRAME_END
    ret

; Shared C adapter: convert the core's storage status/mask to C return codes.
; SELECT planning, zone decisions, scanning and predicates live in one core.
api_select_next:
    FRAME_BEGIN 16, 1
    mov [rbp - 8], r12
    mov r12, ARG1
    cmp dword [r12 + STMT_H_STATE], STMT_STATE_ERROR
    je .failed
    cmp dword [r12 + STMT_H_STATE], STMT_STATE_DONE
    je .done
    cmp dword [r12 + STMT_H_STATE], STMT_STATE_INIT
    jne .next
    mov r10, [r12 + STMT_H_PLAN]
    cmp qword [r10 + PLAN_JOIN_TYPE], 0
    jne .join_pull_pending
    test qword [r10 + PLAN_FLAGS], PLAN_FLAG_ORDER
    jnz .join_pull_pending
    lea rax, [r12 + STMT_H_DECODE]
    PASS_ARG5 rax
    lea ARG1, [r12 + STMT_H_SELECT]
    mov ARG2, [r12 + STMT_H_DB]       ; DB_H_CTX is at offset zero
    mov ARG3, [r12 + STMT_H_PLAN]
    lea ARG4, [r12 + STMT_H_BATCH_VIEW]
    call sql_select_open
    test eax, eax
    jnz .error
    mov dword [r12 + STMT_H_STATE], STMT_STATE_SCANNING
.next:
    lea ARG1, [r12 + STMT_H_SELECT]
    call sql_select_next
    test eax, eax
    jnz .error
    test rdx, rdx
    jz .done
    mov r10, [r12 + STMT_H_PLAN]
    test qword [r10 + PLAN_FLAGS], PLAN_FLAG_COUNT_STAR
    jz .row
    mov rax, [r12 + STMT_H_SELECT + SEL_COUNT]
    mov [r12 + STMT_H_CNT_ACCUM], rax
    mov dword [r12 + STMT_H_STATE], STMT_STATE_COUNT_DELIVER
.row:
    mov eax, CybouDB_C_ROW
    jmp .exit
.join_pull_pending:
    mov eax, CybouDB_E_STATE
    jmp .error
.error:
    mov r10, [r12 + STMT_H_DB]
    mov [r10 + DB_H_ERRCODE], eax
    mov [r12 + STMT_H_ERRCODE], eax
    mov dword [r12 + STMT_H_STATE], STMT_STATE_ERROR
.failed:
    xor edx, edx
    mov eax, CybouDB_C_ERROR
    jmp .exit
.done:
    mov dword [r12 + STMT_H_STATE], STMT_STATE_DONE
    xor edx, edx
    mov eax, CybouDB_C_DONE
.exit:
    mov r12, [rbp - 8]
    FRAME_END
    ret

; Logical projection accessor. No copy of column values is needed, even for
; reordered or duplicate projections. Caller must pass this statement's current
; batch; its lifetime ends on stepping, reset, finalize or connection mutation.
cyboudb_batch_column:
    test    ARG1, ARG1
    jz      .invalid
    lea     r10, [ARG1 + STMT_H_BATCH_VIEW]
    cmp     ARG2, r10
    jne     .invalid
    mov     r11d, ARG3d                ; capture before touching Win64 ECX
    cmp     r11, [ARG1 + STMT_H_RESULT_COUNT]
    jae     .invalid
    mov     eax, [ARG1 + STMT_H_STATE]
    cmp     eax, STMT_STATE_SCANNING
    je      .ready
    cmp     eax, STMT_STATE_COUNT_DELIVER
    jne     .invalid
.ready:
    mov     eax, [ARG1 + STMT_H_RESULT_INDICES + r11 * 4]
    imul    rax, CybouDB_COLVIEW_SIZE
    lea     rax, [r10 + BATCH_VIEW_COLUMNS + rax]
    cmp     dword [rax + COLVIEW_TYPE], CAT_TEXT
    je      .invalid
    cmp     dword [rax + COLVIEW_TYPE], CAT_BLOB
    je      .invalid
    cmp     dword [rax + COLVIEW_TYPE], CAT_VECTOR
    je      .invalid
    ret
.invalid:
    xor     eax, eax
    ret


; cyboudb_batch_bytes(stmt, batch, result_col, row, out, capacity) -> length/error
cyboudb_batch_bytes:
    FRAME_BEGIN 96, 2
    mov     [rbp - 8], ARG1
    mov     [rbp - 16], ARG2
    mov     [rbp - 24], ARG3
    mov     [rbp - 32], ARG4
    mov     rax, IN_ARG5
    mov     [rbp - 40], rax
    mov     rax, IN_ARG6
    mov     [rbp - 48], rax
    test    ARG1, ARG1
    jz      .batch_bytes_misuse
    lea     r10, [ARG1 + STMT_H_BATCH_VIEW]
    cmp     ARG2, r10
    jne     .batch_bytes_misuse
    cmp     dword [ARG1 + STMT_H_STATE], STMT_STATE_SCANNING
    jne     .batch_bytes_misuse
    mov     r8, [rbp - 8]
    mov     rdx, [rbp - 24]
    cmp     rdx, [r8 + STMT_H_RESULT_COUNT]
    jae     .batch_bytes_misuse
    mov     rcx, [rbp - 32]
    cmp     rcx, [r10 + BATCH_VIEW_ROWS]
    jae     .batch_bytes_misuse
    bt      qword [r8 + STMT_H_ACT_MASK], rcx
    jnc     .batch_bytes_misuse
    mov     eax, [r8 + STMT_H_RESULT_INDICES + rdx * 4]
    mov     [rbp - 56], rax
    imul    rax, CybouDB_COLVIEW_SIZE
    lea     r11, [r10 + BATCH_VIEW_COLUMNS + rax]
    mov     eax, [r11 + COLVIEW_TYPE]
    cmp     eax, CAT_TEXT
    je      .batch_bytes_type
    cmp     eax, CAT_BLOB
    jne     .batch_bytes_misuse
.batch_bytes_type:
    cmp     dword [r11 + COLVIEW_WIDTH], VAR_CELL_SIZE
    jne     .batch_bytes_misuse
    mov     rcx, [rbp - 32]
    bt      qword [r11 + COLVIEW_NULL_MASK], rcx
    jc      .batch_bytes_empty
    mov     rax, [r11 + COLVIEW_VALUES_PTR]
    shl     rcx, 4
    add     rax, rcx
    mov     [rbp - 64], rax
    mov     rdx, [rax + VAR_CELL_LENGTH]
    mov     [rbp - 72], rdx
    cmp     [rbp - 48], rdx
    jb      .batch_bytes_misuse
    test    rdx, rdx
    jz      .batch_bytes_empty
    cmp     qword [rbp - 40], 0
    je      .batch_bytes_misuse
    mov     r10, [rbp - 8]
    mov     r11, [r10 + STMT_H_DB]
    mov     ARG1, r11
    mov     ARG2, [r11 + DB_SB_PTR]
    mov     ARG3, [rbp - 64]
    mov     r10, [r10 + STMT_H_PLAN]
    mov     ARG4, [r10 + PLAN_TABLE_ID]
    mov     rax, [rbp - 40]
    PASS_ARG5 rax
    mov     rax, [rbp - 48]
    PASS_ARG6 rax
    call    db_var_read_chain
    test    eax, eax
    jz      .batch_bytes_length
    cmp     eax, CybouDB_E_VALUE
    je      .batch_bytes_misuse
    mov     rax, CybouDB_C_ERROR
    FRAME_END
    ret
.batch_bytes_length:
    mov     rax, [rbp - 72]
    FRAME_END
    ret
.batch_bytes_empty:
    xor     eax, eax
    FRAME_END
    ret
.batch_bytes_misuse:
    mov     rax, CybouDB_C_MISUSE
    FRAME_END
    ret


; =============================================================================
; cyboudb_batch_vector_f32(stmt, batch, result_col, row, out, capacity_floats) -> int64
; =============================================================================
cyboudb_batch_vector_f32:
    FRAME_BEGIN 96, 2
    mov     [rbp - 8], ARG1
    mov     [rbp - 16], ARG2
    mov     [rbp - 24], ARG3
    mov     [rbp - 32], ARG4
    mov     rax, IN_ARG5
    mov     [rbp - 40], rax             ; out
    mov     rax, IN_ARG6
    mov     [rbp - 48], rax             ; capacity_floats
    test    ARG1, ARG1
    jz      .batch_vec_misuse
    lea     r10, [ARG1 + STMT_H_BATCH_VIEW]
    cmp     ARG2, r10
    jne     .batch_vec_misuse
    cmp     dword [ARG1 + STMT_H_STATE], STMT_STATE_SCANNING
    jne     .batch_vec_misuse
    mov     r8, [rbp - 8]
    mov     rdx, [rbp - 24]             ; result_col
    cmp     rdx, [r8 + STMT_H_RESULT_COUNT]
    jae     .batch_vec_misuse
    mov     rcx, [rbp - 32]             ; row
    cmp     rcx, [r10 + BATCH_VIEW_ROWS]
    jae     .batch_vec_misuse
    bt      qword [r8 + STMT_H_ACT_MASK], rcx
    jnc     .batch_vec_misuse
    mov     eax, [r8 + STMT_H_RESULT_INDICES + rdx * 4]
    imul    rax, CybouDB_COLVIEW_SIZE
    lea     r11, [r10 + BATCH_VIEW_COLUMNS + rax]
    cmp     dword [r11 + COLVIEW_TYPE], CAT_VECTOR
    jne     .batch_vec_misuse
    cmp     dword [r11 + COLVIEW_WIDTH], VAR_CELL_SIZE
    jne     .batch_vec_misuse
    mov     rcx, [rbp - 32]             ; row
    bt      qword [r11 + COLVIEW_NULL_MASK], rcx
    jc      .batch_vec_null
    mov     rax, [r11 + COLVIEW_VALUES_PTR]
    shl     rcx, 4
    add     rax, rcx
    mov     [rbp - 64], rax             ; descriptor ptr
    mov     rdx, [rax + VAR_CELL_LENGTH]
    shr     rdx, 2                      ; dimension in floats
    mov     [rbp - 72], rdx
    cmp     [rbp - 48], rdx             ; capacity_floats < dim?
    jb      .batch_vec_misuse
    test    rdx, rdx
    jz      .batch_vec_null
    cmp     qword [rbp - 40], 0         ; out == NULL?
    je      .batch_vec_misuse
    mov     r10, [rbp - 8]              ; stmt
    mov     r11, [r10 + STMT_H_DB]
    mov     ARG1, r11
    mov     ARG2, [r11 + DB_SB_PTR]
    mov     ARG3, [rbp - 64]            ; descriptor
    mov     r10, [r10 + STMT_H_PLAN]
    mov     ARG4, [r10 + PLAN_TABLE_ID]
    mov     rax, [rbp - 40]             ; out
    PASS_ARG5 rax
    mov     rax, [rbp - 72]             ; dim
    shl     rax, 2                      ; bytes = dim * 4
    PASS_ARG6 rax
    call    db_var_read_chain
    test    eax, eax
    jz      .batch_vec_ok
    cmp     eax, CybouDB_E_VALUE
    je      .batch_vec_misuse
    mov     rax, CybouDB_C_ERROR
    FRAME_END
    ret
.batch_vec_ok:
    mov     rax, [rbp - 72]             ; return dim count
    FRAME_END
    ret
.batch_vec_null:
    xor     eax, eax                    ; return 0 for NULL
    FRAME_END
    ret
.batch_vec_misuse:
    mov     rax, CybouDB_C_MISUSE
    FRAME_END
    ret


; =============================================================================
;  cyboudb_reset(cyboudb_stmt *stmt) -> int
; =============================================================================
cyboudb_reset:
    test    ARG1, ARG1
    jz      .reset_misuse

    mov     rax, STMT_MAGIC_VAL
    cmp     [ARG1 + STMT_H_MAGIC], rax
    jne     .reset_misuse

    mov     dword [ARG1 + STMT_H_STATE], STMT_STATE_INIT
    mov     dword [ARG1 + STMT_H_CUR_ROW], 0
    mov     qword [ARG1 + STMT_H_ACT_MASK], 0
    mov     qword [ARG1 + STMT_H_CNT_ACCUM], 0
    xor     eax, eax                    ; CybouDB_C_OK
    ret

.reset_misuse:
    mov     eax, CybouDB_C_MISUSE
    ret


; =============================================================================
;  cyboudb_finalize(cyboudb_stmt *stmt) -> int
; =============================================================================
cyboudb_finalize:
    FRAME_BEGIN 16, 0
    test    ARG1, ARG1
    jz      .fin_ok

    mov     r10, ARG1
    mov     rax, STMT_MAGIC_VAL
    cmp     [r10 + STMT_H_MAGIC], rax
    jne     .fin_misuse

    mov     qword [r10 + STMT_H_MAGIC], 0
    mov     r11, [r10 + STMT_H_DB]
    dec     qword [r11 + DB_H_STMT_COUNT]
    mov     ARG1, r10
    mov     ARG2, [r10 + STMT_H_ALLOC_SIZE]
    call    os_mem_free

.fin_ok:
    xor     eax, eax
    FRAME_END
    ret

.fin_misuse:
    mov     eax, CybouDB_C_MISUSE
    FRAME_END
    ret


; =============================================================================
;  cyboudb_column_count(cyboudb_stmt *stmt) -> int
; =============================================================================
cyboudb_column_count:
    test    ARG1, ARG1
    jz      .cnt_zero
    mov     eax, [ARG1 + STMT_H_RESULT_COUNT]
    ret
.cnt_zero:
    xor     eax, eax
    ret


; =============================================================================
;  cyboudb_column_type(cyboudb_stmt *stmt, int col_idx) -> int
; =============================================================================
cyboudb_column_type:
    test    ARG1, ARG1
    jz      .type_zero
    mov     edx, ARG2d
    cmp     rdx, [ARG1 + STMT_H_RESULT_COUNT]
    jae     .type_zero
    mov     eax, [ARG1 + STMT_H_RESULT_TYPES + rdx * 4]
    ret

.type_zero:
    xor     eax, eax
    ret


; =============================================================================
;  cyboudb_column_name(cyboudb_stmt *stmt, int col_idx) -> const char *
; =============================================================================
cyboudb_column_name:
    test    ARG1, ARG1
    jz      .name_null
    mov     edx, ARG2d
    cmp     rdx, [ARG1 + STMT_H_RESULT_COUNT]
    jae     .name_null
    imul    rdx, 24
    lea     rax, [ARG1 + STMT_H_RESULT_NAMES + rdx]
    ret

.name_null:
    lea     rax, [str_empty]
    ret


; =============================================================================
;  cyboudb_column_is_null(cyboudb_stmt *stmt, int col_idx) -> int
; =============================================================================
cyboudb_column_is_null:
    test    ARG1, ARG1
    jz      .is_null_true
    mov     r9, [ARG1 + STMT_H_PLAN]
    test    r9, r9
    jz      .is_null_true
    test    qword [r9 + PLAN_FLAGS], PLAN_FLAG_COUNT_STAR
    jnz     .is_null_false

    mov     edx, ARG2d
    cmp     rdx, [r9 + PLAN_DATA1]
    jae     .is_null_true

    mov     r11, [r9 + PLAN_DATA2]      ; proj_indices
    mov     eax, [r11 + rdx * 4]        ; physical col_idx
    imul    rax, CybouDB_COLVIEW_SIZE
    lea     r10, [ARG1 + STMT_H_BATCH_VIEW + BATCH_VIEW_COLUMNS + rax]

    mov     ecx, [ARG1 + STMT_H_CUR_ROW]
    bt      qword [r10 + COLVIEW_NULL_MASK], rcx
    setc    al
    movzx   eax, al
    ret

.is_null_false:
    xor     eax, eax
    ret
.is_null_true:
    mov     eax, 1
    ret


; =============================================================================
;  cyboudb_column_int64(cyboudb_stmt *stmt, int col_idx) -> int64_t
; =============================================================================
cyboudb_column_int64:
    test    ARG1, ARG1
    jz      .i64_zero
    mov     r9, [ARG1 + STMT_H_PLAN]
    test    r9, r9
    jz      .i64_zero
    test    qword [r9 + PLAN_FLAGS], PLAN_FLAG_COUNT_STAR
    jnz     .i64_count_star

    mov     edx, ARG2d
    cmp     rdx, [r9 + PLAN_DATA1]
    jae     .i64_zero

    mov     r11, [r9 + PLAN_DATA2]      ; proj_indices
    mov     eax, [r11 + rdx * 4]        ; physical col_idx
    imul    rax, CybouDB_COLVIEW_SIZE
    lea     r10, [ARG1 + STMT_H_BATCH_VIEW + BATCH_VIEW_COLUMNS + rax]

    mov     ecx, [ARG1 + STMT_H_CUR_ROW]
    bt      qword [r10 + COLVIEW_NULL_MASK], rcx
    jc      .i64_zero

    mov     rax, [r10 + COLVIEW_VALUES_PTR]
    mov     edx, [r10 + COLVIEW_WIDTH]
    cmp     edx, 8
    je      .read_8
    cmp     edx, 4
    je      .read_4
    movzx   rax, byte [rax + rcx]
    ret
.read_8:
    mov     rax, [rax + rcx * 8]
    ret
.read_4:
    movsxd  rax, dword [rax + rcx * 4]
    ret

.i64_count_star:
    test    ARG2d, ARG2d
    jnz     .i64_zero
    mov     rax, [ARG1 + STMT_H_CNT_ACCUM]
    ret

.i64_zero:
    xor     eax, eax
    ret


; =============================================================================
;  cyboudb_column_int32(cyboudb_stmt *stmt, int col_idx) -> int32_t
; =============================================================================
cyboudb_column_int32:
    jmp     cyboudb_column_int64


; =============================================================================
;  cyboudb_column_float(cyboudb_stmt *stmt, int col_idx) -> float (returned in xmm0)
; =============================================================================
cyboudb_column_float:
    test    ARG1, ARG1
    jz      .f32_zero
    mov     r9, [ARG1 + STMT_H_PLAN]
    test    r9, r9
    jz      .f32_zero
    test    qword [r9 + PLAN_FLAGS], PLAN_FLAG_COUNT_STAR
    jnz     .f32_zero

    mov     edx, ARG2d
    cmp     rdx, [r9 + PLAN_DATA1]
    jae     .f32_zero

    mov     r11, [r9 + PLAN_DATA2]
    mov     eax, [r11 + rdx * 4]
    imul    rax, CybouDB_COLVIEW_SIZE
    lea     r10, [ARG1 + STMT_H_BATCH_VIEW + BATCH_VIEW_COLUMNS + rax]

    mov     ecx, [ARG1 + STMT_H_CUR_ROW]
    bt      qword [r10 + COLVIEW_NULL_MASK], rcx
    jc      .f32_zero

    mov     rax, [r10 + COLVIEW_VALUES_PTR]
    movss   xmm0, dword [rax + rcx * 4]
    ret

.f32_zero:
    xorps   xmm0, xmm0
    ret


; =============================================================================
;  cyboudb_column_bool(cyboudb_stmt *stmt, int col_idx) -> int
; =============================================================================
cyboudb_column_bool:
    test    ARG1, ARG1
    jz      .bool_zero
    mov     r9, [ARG1 + STMT_H_PLAN]
    test    r9, r9
    jz      .bool_zero
    test    qword [r9 + PLAN_FLAGS], PLAN_FLAG_COUNT_STAR
    jnz     .bool_zero

    mov     edx, ARG2d
    cmp     rdx, [r9 + PLAN_DATA1]
    jae     .bool_zero

    mov     r11, [r9 + PLAN_DATA2]
    mov     eax, [r11 + rdx * 4]
    imul    rax, CybouDB_COLVIEW_SIZE
    lea     r10, [ARG1 + STMT_H_BATCH_VIEW + BATCH_VIEW_COLUMNS + rax]

    mov     ecx, [ARG1 + STMT_H_CUR_ROW]
    bt      qword [r10 + COLVIEW_NULL_MASK], rcx
    jc      .bool_zero

    mov     rax, [r10 + COLVIEW_VALUES_PTR]
    movzx   eax, byte [rax + rcx]
    ret

.bool_zero:
    xor     eax, eax
    ret


; =============================================================================
; cyboudb_message(stmt, out, capacity, out_length) -> int
; =============================================================================
;  The message the last step of a DEQUEUE took. It is not a column and does
;  not pretend to be one: a queue holds bytes with no schema to say how to
;  read them, so a caller that wants them asks for them rather than being
;  handed a synthetic row to read them out of.
;
;  The bytes live in the statement's own arena and stay valid until the next
;  step or the finalize.
;
;  Local slots: [rbp-8]=stmt, [rbp-16]=out, [rbp-24]=capacity,
;               [rbp-32]=out_length, [rbp-40]=length
cyboudb_message:
    FRAME_BEGIN 64, 0
    mov     [rbp - 8], ARG1
    mov     [rbp - 16], ARG2
    mov     [rbp - 24], ARG3
    mov     [rbp - 32], ARG4
    test    ARG1, ARG1
    jz      .msg_misuse
    test    ARG4, ARG4
    jz      .msg_misuse
    mov     qword [ARG4], 0
    mov     r10, [ARG1 + STMT_H_PLAN]
    test    r10, r10
    jz      .msg_misuse
    cmp     qword [r10 + PLAN_TYPE], STMT_DEQUEUE
    jne     .msg_misuse
    cmp     qword [r10 + PLAN_DATA3], 0
    je      .msg_misuse                 ; the last step took nothing
    mov     rdx, [r10 + PLAN_DATA2]
    mov     [rbp - 40], rdx
    cmp     rdx, [rbp - 24]
    ja      .msg_misuse                 ; the buffer is not big enough
    mov     r9, [r10 + PLAN_DATA1]
    mov     r11, [rbp - 16]
    xor     ecx, ecx
.msg_byte:
    cmp     rcx, rdx
    jae     .msg_copied
    mov     al, [r9 + rcx]
    mov     [r11 + rcx], al
    inc     rcx
    jmp     .msg_byte
.msg_copied:
    mov     r11, [rbp - 32]
    mov     rax, [rbp - 40]
    mov     [r11], rax
    mov     eax, CybouDB_C_OK
    FRAME_END
    ret
.msg_misuse:
    mov     eax, CybouDB_C_MISUSE
    FRAME_END
    ret

; =============================================================================
; cyboudb_column_bytes(stmt, col_idx, out, capacity, out_length) -> int
; =============================================================================
cyboudb_column_bytes:
    FRAME_BEGIN 80, 2
    mov     [rbp - 8], ARG1
    mov     [rbp - 16], ARG3
    mov     [rbp - 24], ARG4
    mov     rax, IN_ARG5
    mov     [rbp - 32], rax
    test    ARG1, ARG1
    jz      .bytes_misuse
    test    rax, rax
    jz      .bytes_misuse
    mov     qword [rax], 0
    mov     r10, [ARG1 + STMT_H_PLAN]
    test    r10, r10
    jz      .bytes_misuse
    cmp     dword [ARG1 + STMT_H_STATE], STMT_STATE_SCANNING
    jne     .bytes_misuse
    mov     edx, ARG2d
    cmp     rdx, [r10 + PLAN_DATA1]
    jae     .bytes_misuse
    mov     r11, [r10 + PLAN_DATA2]
    mov     eax, [r11 + rdx * 4]
    mov     [rbp - 40], rax             ; physical column
    imul    rax, CybouDB_COLVIEW_SIZE
    lea     r11, [ARG1 + STMT_H_BATCH_VIEW + BATCH_VIEW_COLUMNS + rax]
    mov     eax, [r11 + COLVIEW_TYPE]
    cmp     eax, CAT_TEXT
    je      .bytes_type_ok
    cmp     eax, CAT_BLOB
    jne     .bytes_misuse
.bytes_type_ok:
    cmp     dword [r11 + COLVIEW_WIDTH], VAR_CELL_SIZE
    jne     .bytes_misuse
    mov     ecx, [ARG1 + STMT_H_CUR_ROW]
    bt      qword [r11 + COLVIEW_NULL_MASK], rcx
    jc      .bytes_ok
    mov     rax, [r11 + COLVIEW_VALUES_PTR]
    shl     rcx, 4
    add     rax, rcx
    mov     [rbp - 48], rax             ; persistent descriptor
    mov     rdx, [rax + VAR_CELL_LENGTH]
    mov     r10, [rbp - 32]
    mov     [r10], rdx
    cmp     [rbp - 24], rdx
    jb      .bytes_misuse
    test    rdx, rdx
    jz      .bytes_ok
    cmp     qword [rbp - 16], 0
    je      .bytes_misuse
    mov     r10, [rbp - 8]
    mov     r11, [r10 + STMT_H_DB]
    mov     ARG1, r11
    mov     ARG2, [r11 + DB_SB_PTR]
    mov     ARG3, [rbp - 48]
    mov     r10, [rbp - 8]
    mov     r10, [r10 + STMT_H_PLAN]
    mov     ARG4, [r10 + PLAN_TABLE_ID]
    mov     rax, [rbp - 16]
    PASS_ARG5 rax
    mov     rax, [rbp - 24]
    PASS_ARG6 rax
    call    db_var_read_chain
    test    eax, eax
    jz      .bytes_ok
    cmp     eax, CybouDB_E_VALUE
    je      .bytes_misuse
    mov     eax, CybouDB_C_ERROR
    FRAME_END
    ret
.bytes_ok:
    xor     eax, eax
    FRAME_END
    ret
.bytes_misuse:
    mov     eax, CybouDB_C_MISUSE
    FRAME_END
    ret


; =============================================================================
;  cyboudb_column_vector_dimensions(cyboudb_stmt *stmt, int col_idx) -> int
; =============================================================================
cyboudb_column_vector_dimensions:
    test    ARG1, ARG1
    jz      .dim_misuse
    mov     r10, [ARG1 + STMT_H_PLAN]
    test    r10, r10
    jz      .dim_misuse
    mov     edx, ARG2d
    cmp     rdx, [ARG1 + STMT_H_RESULT_COUNT]
    jae     .dim_misuse
    cmp     dword [ARG1 + STMT_H_RESULT_TYPES + rdx * 4], CAT_VECTOR
    jne     .dim_misuse
    mov     r11, [r10 + PLAN_SCHEMA_PAGE]
    mov     eax, [ARG1 + STMT_H_RESULT_INDICES + rdx * 4]
    cmp     qword [r10 + PLAN_JOIN_TYPE], 0
    je      .dim_read
    mov     r8, [r10 + PLAN_JOIN_PROJECTIONS]
    mov     eax, [r8 + rdx * 4]
    test    eax, PLAN_PROJ_RIGHT_BIT
    jz      .dim_read
    and     eax, 0x7fffffff
    mov     r11, [r10 + PLAN_RIGHT_SCHEMA]
.dim_read:
    shl     rax, 5
    mov     eax, [r11 + CAT_COLUMNS + rax + 4]
    shr     eax, 16                     ; dimension
    ret
.dim_misuse:
    mov     eax, CybouDB_C_MISUSE       ; -1
    ret


; =============================================================================
; cyboudb_column_vector_f32(stmt, col_idx, out, capacity_floats, out_dim) -> int
; =============================================================================
cyboudb_column_vector_f32:
    FRAME_BEGIN 80, 2
    mov     [rbp - 8], ARG1
    mov     [rbp - 16], ARG3            ; out
    mov     [rbp - 24], ARG4            ; capacity_floats
    mov     rax, IN_ARG5
    mov     [rbp - 32], rax             ; out_dim
    test    ARG1, ARG1
    jz      .colvec_misuse
    test    rax, rax
    jz      .colvec_misuse
    mov     qword [rax], 0
    mov     r10, [ARG1 + STMT_H_PLAN]
    test    r10, r10
    jz      .colvec_misuse
    cmp     dword [ARG1 + STMT_H_STATE], STMT_STATE_SCANNING
    jne     .colvec_misuse
    mov     edx, ARG2d
    cmp     rdx, [r10 + PLAN_DATA1]     ; proj_count
    jae     .colvec_misuse
    mov     r11, [r10 + PLAN_DATA2]     ; proj_indices
    mov     eax, [r11 + rdx * 4]        ; physical column
    mov     [rbp - 40], rax
    imul    rax, CybouDB_COLVIEW_SIZE
    lea     r11, [ARG1 + STMT_H_BATCH_VIEW + BATCH_VIEW_COLUMNS + rax]
    cmp     dword [r11 + COLVIEW_TYPE], CAT_VECTOR
    jne     .colvec_misuse
    cmp     dword [r11 + COLVIEW_WIDTH], VAR_CELL_SIZE
    jne     .colvec_misuse
    mov     ecx, [ARG1 + STMT_H_CUR_ROW]
    bt      qword [r11 + COLVIEW_NULL_MASK], rcx
    jc      .colvec_null
    mov     rax, [r11 + COLVIEW_VALUES_PTR]
    shl     rcx, 4
    add     rax, rcx
    mov     [rbp - 48], rax             ; persistent descriptor
    mov     rdx, [rax + VAR_CELL_LENGTH] ; length in bytes
    shr     rdx, 2                      ; dimension in floats
    mov     r10, [rbp - 32]             ; out_dim ptr
    mov     [r10], rdx
    cmp     [rbp - 24], rdx             ; capacity_floats < dim?
    jb      .colvec_misuse
    test    rdx, rdx
    jz      .colvec_ok
    cmp     qword [rbp - 16], 0         ; out == NULL?
    je      .colvec_misuse
    mov     r10, [rbp - 8]
    mov     r11, [r10 + STMT_H_DB]
    mov     ARG1, r11
    mov     ARG2, [r11 + DB_SB_PTR]
    mov     ARG3, [rbp - 48]            ; descriptor
    mov     r10, [r10 + STMT_H_PLAN]
    mov     ARG4, [r10 + PLAN_TABLE_ID]
    mov     rax, [rbp - 16]             ; out
    PASS_ARG5 rax
    mov     r10, [rbp - 32]             ; reload out_dim ptr
    mov     rax, [r10]                  ; dim
    shl     rax, 2                      ; bytes = dim * 4
    PASS_ARG6 rax
    call    db_var_read_chain
    test    eax, eax
    jz      .colvec_ok
    cmp     eax, CybouDB_E_VALUE
    je      .colvec_misuse
    mov     eax, CybouDB_C_ERROR
    FRAME_END
    ret
.colvec_ok:
    xor     eax, eax                    ; CybouDB_C_OK
    FRAME_END
    ret
.colvec_null:
    xor     eax, eax                    ; CybouDB_C_OK
    FRAME_END
    ret
.colvec_misuse:
    mov     eax, CybouDB_C_MISUSE
    FRAME_END
    ret


; =============================================================================
;  cyboudb_exec(cyboudb_db *db, const char *sql) -> int; discard a single result
; =============================================================================
cyboudb_exec:
    FRAME_BEGIN 48, 0
    mov     [rbp - 8], ARG1             ; db
    mov     [rbp - 16], ARG2            ; sql

    ; Prepare statement
    mov     ARG1, [rbp - 8]
    mov     ARG2, [rbp - 16]
    lea     ARG3, [rbp - 40]            ; stmt
    call    cyboudb_prepare
    test    eax, eax
    jnz     .exec_fail_prep

.exec_step_loop:
    mov     ARG1, [rbp - 40]
    call    cyboudb_step
    cmp     eax, CybouDB_C_ROW
    je      .exec_step_loop
    cmp     eax, CybouDB_C_DONE
    je      .exec_step_done
    ; Error during execution
    jmp     .exec_step_error

.exec_step_done:
    mov     ARG1, [rbp - 40]
    call    cyboudb_finalize
    xor     eax, eax                    ; CybouDB_C_OK
    FRAME_END
    ret

.exec_step_error:
    mov     [rbp - 48], eax
    mov     ARG1, [rbp - 40]
    call    cyboudb_finalize
    mov     eax, [rbp - 48]
    FRAME_END
    ret

.exec_fail_prep:
    FRAME_END
    ret

%ifdef CybouDB_LINUX
section .note.GNU-stack noalloc noexec nowrite progbits
%endif
