; Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
; SPDX-License-Identifier: Apache-2.0
; =============================================================================
;  src/sql/binder.asm - Catalog resolution and type checking
; =============================================================================

%include "sql.inc"

BITS 64
default rel

extern sql_arena_alloc, sql_kernel_resolve, vector_l2sq_f32_resolve, vector_cosine_normalized_f32_resolve
extern db_index_of_table
global sql_bind, catalog_find_table, catalog_find_index
global catalog_find_object, schema_find_col

section .data
    align 8
err_tbl_not_found:   db "table not found in catalog", 0
err_col_not_found:   db "column not found in schema", 0
err_dup_table:       db "table already exists", 0
err_dup_col:         db "duplicate column name in table definition", 0
err_type_mismatch:   db "type mismatch in expression or literal", 0
err_param_placement: db "a parameter is only allowed in INSERT ... VALUES", 0
err_not_nullable:    db "cannot insert NULL into non-nullable column", 0
err_val_count:       db "row value count does not match column count", 0
err_no_pax:          db "database does not have PAX table storage enabled", 0
err_tbl_name_len:    db "table name exceeds 31 characters", 0
err_col_name_len:    db "column name exceeds 23 characters", 0
err_unsupported_op:  db "unsupported expression comparison", 0
err_join_pending:    db "JOIN WHERE predicates are not implemented yet", 0
err_join_condition:  db "JOIN ON currently requires column = column", 0
err_join_projection: db "JOIN projections must be explicitly qualified", 0
err_no_index:        db "database was not created with index support", 0
err_index_type:      db "an index needs an INT32 or INT64 column", 0
err_index_missing:   db "index not found in catalog", 0
err_no_queue:        db "database was not created with queue support", 0
err_queue_missing:   db "queue not found in catalog", 0
err_no_stream:       db "database was not created with stream support", 0
err_stream_missing:  db "stream not found in catalog", 0
err_cursor_name:     db "a cursor name is 1 to 23 characters", 0

err_queue_payload:   db "a queue message is TEXT or BLOB", 0
err_queue_long:      db "message longer than four gigabytes", 0
err_join_key_type: db "JOIN keys currently require INT32 or INT64", 0
err_order_pending: db "ORDER BY execution is not implemented yet", 0
err_varlen_pending: db "TEXT/BLOB storage extents are not implemented yet", 0
err_vector_pending: db "VECTOR storage extents are not implemented yet", 0
err_vector_order_limit: db "vector distance ORDER BY requires LIMIT", 0
err_oom:             db "memory arena capacity exceeded", 0

section .text

; -----------------------------------------------------------------------------
;  set_binder_error(err_struct, code, offset, msg_ptr)
; -----------------------------------------------------------------------------
set_binder_error:
    test    ARG1, ARG1
    jz      .done
    mov     r10, ARG1
    mov     qword [r10 + SQL_ERR_DOMAIN], SQL_DOMAIN_SQL
    mov     [r10 + SQL_ERR_CODE], ARG2
    mov     [r10 + SQL_ERR_OFFSET], ARG3
    mov     dword [r10 + SQL_ERR_LINE], 1
    mov     dword [r10 + SQL_ERR_COL], 1
    test    ARG4, ARG4
    jz      .done
    mov     r8, ARG4
    lea     r9, [r10 + SQL_ERR_MSG]
    mov     ecx, 70
.msg_loop:
    mov     al, [r8]
    mov     [r9], al
    test    al, al
    jz      .done
    inc     r8
    inc     r9
    dec     ecx
    jnz     .msg_loop
    mov     byte [r9], 0
.done:
    mov     rax, ARG2
    ret

; -----------------------------------------------------------------------------
;  catalog_find_table(db_ctx, name_ptr, name_len, out_table_id) -> RAX: schema_ptr or 0
; -----------------------------------------------------------------------------
; catalog_find_object finds a directory entry by name whatever it is, which is
; what a name-is-free check wants: tables and indexes share one namespace.
; catalog_find_table and catalog_find_index find one of a kind, which is what
; every other caller wants - a resolver that can hand a SELECT an index page
; is not a resolver, it is a hole in the type boundary.
catalog_find_object:
    xor     r11d, r11d                  ; any type
    jmp     catalog_find_common
catalog_find_index:
    mov     r11d, CAT_INDEX
    jmp     catalog_find_common
catalog_find_queue:
    mov     r11d, CAT_QUEUE
    jmp     catalog_find_common
catalog_find_stream:
    mov     r11d, CAT_STREAM
    jmp     catalog_find_common
catalog_find_table:
    mov     r11d, CAT_SCHEMA
catalog_find_common:
    FRAME_BEGIN 80, 0
    mov     [rbp - 72], r11             ; the type this caller will accept
    mov     [rbp - 8], ARG1             ; db_ctx
    mov     [rbp - 16], ARG2            ; name_ptr
    mov     [rbp - 24], ARG3            ; name_len
    mov     [rbp - 32], ARG4            ; out_table_id

    mov     r10, ARG1
    mov     rax, [r10 + DB_ROOT]
    test    rax, rax
    jz      .not_found

    ; Mapped pointer to catalog directory
    shl     rax, CybouDB_PAGE_SHIFT
    add     rax, [r10 + DB_BASE]
    mov     [rbp - 48], rax             ; dir_ptr

    mov     ecx, [rax + CAT_COUNT]
    test    ecx, ecx
    jz      .not_found
    mov     [rbp - 56], rcx             ; table_count

    xor     edx, edx                    ; entry_idx = 0
.tbl_loop:
    mov     [rbp - 40], rdx             ; save entry_idx
    mov     r10, [rbp - 48]
    lea     r11, [r10 + CAT_DATA]
    mov     rax, rdx
    shl     rax, 4
    add     r11, rax                    ; entry_ptr

    mov     rax, [r11 + 0]
    mov     [rbp - 64], rax             ; table_id
    mov     rax, [r11 + 8]              ; schema_page_id
    shl     rax, CybouDB_PAGE_SHIFT
    mov     r10, [rbp - 8]
    add     rax, [r10 + DB_BASE]
    mov     r10, rax                    ; schema_ptr

    ; Compare schema_ptr + CAT_TABLE_NAME with name_ptr
    lea     r8, [r10 + CAT_TABLE_NAME]
    mov     r9, [rbp - 16]              ; query name_ptr
    mov     rcx, [rbp - 24]             ; query name_len
    cmp     rcx, 31
    ja      .next_tbl

.cmp_chars:
    test    rcx, rcx
    jz      .check_zero
    mov     al, [r8]
    mov     dl, [r9]
    cmp     al, dl
    je      .char_matched
    or      al, 0x20
    or      dl, 0x20
    cmp     al, dl
    jne     .next_tbl
    cmp     al, 'a'
    jb      .next_tbl
    cmp     al, 'z'
    ja      .next_tbl
.char_matched:
    inc     r8
    inc     r9
    dec     rcx
    jmp     .cmp_chars

.check_zero:
    cmp     byte [r8], 0               ; table name in schema must end with NUL
    jne     .next_tbl

    ; The name matches. Whether the object does is the caller's question.
    cmp     qword [rbp - 72], 0
    je      .type_ok
    mov     eax, [r10 + CAT_TYPE]
    cmp     rax, [rbp - 72]
    jne     .not_found                  ; the name is taken, but not by this
.type_ok:
    mov     r11, [rbp - 32]
    test    r11, r11
    jz      .found
    mov     rax, [rbp - 64]
    mov     [r11], rax

.found:
    mov     rax, r10                    ; return schema_ptr in RAX
    FRAME_END
    ret

.next_tbl:
    mov     rdx, [rbp - 40]
    inc     rdx
    cmp     rdx, [rbp - 56]
    jb      .tbl_loop

.not_found:
    xor     eax, eax
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  schema_find_col(schema_ptr, name_ptr, name_len, out_idx) -> RAX: col_rec or 0
; -----------------------------------------------------------------------------
schema_find_col:
    FRAME_BEGIN 64, 0
    mov     [rbp - 8], ARG1             ; schema_ptr
    mov     [rbp - 16], ARG2            ; name_ptr
    mov     [rbp - 24], ARG3            ; name_len
    mov     [rbp - 32], ARG4            ; out_idx

    mov     r10, ARG1
    mov     ecx, [r10 + CAT_COUNT]
    test    ecx, ecx
    jz      .not_found
    mov     [rbp - 56], rcx             ; col_count

    xor     eax, eax                    ; col_idx = 0
.col_loop:
    mov     [rbp - 40], rax             ; save col_idx
    mov     r10, [rbp - 8]
    lea     r11, [r10 + CAT_COLUMNS]
    shl     rax, 5                      ; * 32 bytes
    add     r11, rax                    ; col_rec

    lea     r8, [r11 + 8]               ; col name in record
    mov     r9, [rbp - 16]              ; query col name
    mov     rcx, [rbp - 24]             ; len
    cmp     rcx, 23
    ja      .next_col

.col_cmp_chars:
    test    rcx, rcx
    jz      .col_check_zero
    mov     al, [r8]
    mov     dl, [r9]
    cmp     al, dl
    je      .col_char_matched
    or      al, 0x20
    or      dl, 0x20
    cmp     al, dl
    jne     .next_col
    cmp     al, 'a'
    jb      .next_col
    cmp     al, 'z'
    ja      .next_col
.col_char_matched:
    inc     r8
    inc     r9
    dec     rcx
    jmp     .col_cmp_chars

.col_check_zero:
    cmp     byte [r8], 0
    jne     .next_col

    ; Found col!
    mov     r10, [rbp - 32]
    test    r10, r10
    jz      .col_found
    mov     rax, [rbp - 40]             ; col_idx
    mov     [r10], rax

.col_found:
    mov     rax, r11                    ; return col_rec in RAX
    FRAME_END
    ret

.next_col:
    mov     rax, [rbp - 40]
    inc     rax
    cmp     rax, [rbp - 56]
    jb      .col_loop

.not_found:
    xor     eax, eax
    FRAME_END
    ret

; qualifier_name_matches(qual_ptr, qual_len, target_ptr, target_len) -> EAX bool
; qual_ptr is followed by '.' in parser-approved input. qual_len is retained in
; the ABI for diagnostics; measuring to the dot avoids depending on termination.
qualifier_name_matches:
    FRAME_BEGIN 32, 0
    mov     [rbp - 8], ARG1
    mov     [rbp - 16], ARG3
    mov     [rbp - 24], ARG4
    mov     r10, ARG1
    mov     r11, ARG3
    xor     ecx, ecx
.qual_measure:
    cmp     byte [r10 + rcx], '.'
    je      .qual_measured
    cmp     byte [r10 + rcx], 0
    je      .qual_no
    inc     rcx
    jmp     .qual_measure
.qual_measured:
    cmp     rcx, [rbp - 24]
    jne     .qual_no
    test    rcx, rcx
    jz      .qual_no
.qual_loop:
    mov     al, [r10]
    mov     dl, [r11]
    cmp     al, dl
    je      .qual_next
    or      al, 0x20
    or      dl, 0x20
    cmp     al, dl
    jne     .qual_no
    cmp     al, 'a'
    jb      .qual_no
    cmp     al, 'z'
    ja      .qual_no
.qual_next:
    inc     r10
    inc     r11
    dec     rcx
    jnz     .qual_loop
.qual_yes:
    mov     eax, 1
    FRAME_END
    ret
.qual_no:
    xor     eax, eax
    FRAME_END
    ret

; slice_name_matches(a_ptr, a_len, b_ptr, b_len) -> EAX bool
slice_name_matches:
    cmp     ARG2, ARG4
    jne     .slice_no
    test    ARG2, ARG2
    jz      .slice_yes
    mov     r10, ARG1
    mov     r11, ARG3
    mov     rcx, ARG2
.slice_loop:
    mov     al, [r10]
    mov     dl, [r11]
    cmp     al, dl
    je      .slice_next
    or      al, 0x20
    or      dl, 0x20
    cmp     al, dl
    jne     .slice_no
    cmp     al, 'a'
    jb      .slice_no
    cmp     al, 'z'
    ja      .slice_no
.slice_next:
    inc     r10
    inc     r11
    dec     rcx
    jnz     .slice_loop
.slice_yes:
    mov     eax, 1
    ret
.slice_no:
    xor     eax, eax
    ret

; qualifier_matches(stmt_payload, qualifier_ptr, qualifier_len) -> EAX bool
; An explicit alias hides the base table name, matching normal SQL namespaces.
qualifier_matches:
    FRAME_BEGIN 48, 0
    mov     [rbp - 8], ARG1
    mov     [rbp - 16], ARG2
    mov     [rbp - 24], ARG3
    mov     r10, ARG1
    mov     r11, [r10 + SELECT_TABLE_ALIAS]
    test    r11, r11
    jz      .use_table_name
    mov     rax, [r11 + AST_NAME_PTR]
    mov     [rbp - 32], rax
    mov     rax, [r11 + AST_NAME_LEN]
    mov     [rbp - 40], rax
    jmp     .compare
.use_table_name:
    mov     r10, [rbp - 8]
    mov     rax, [r10 + SELECT_TABLE_NAME_PTR]
    mov     [rbp - 32], rax
    mov     rax, [r10 + SELECT_TABLE_NAME_LEN]
    mov     [rbp - 40], rax
.compare:
    mov     ARG1, [rbp - 16]
    mov     ARG2, [rbp - 24]
    mov     ARG3, [rbp - 32]
    mov     ARG4, [rbp - 40]
    call    qualifier_name_matches
    FRAME_END
    ret

; join_qualifier_matches(join_ast, qualifier_ptr, qualifier_len) -> EAX bool
join_qualifier_matches:
    FRAME_BEGIN 48, 0
    mov     [rbp - 8], ARG1
    mov     [rbp - 16], ARG2
    mov     [rbp - 24], ARG3
    mov     r10, ARG1
    mov     r11, [r10 + JOIN_TABLE_ALIAS]
    test    r11, r11
    jz      .use_join_table
    mov     rax, [r11 + AST_NAME_PTR]
    mov     [rbp - 32], rax
    mov     rax, [r11 + AST_NAME_LEN]
    mov     [rbp - 40], rax
    jmp     .compare_join
.use_join_table:
    mov     r10, [rbp - 8]
    mov     rax, [r10 + JOIN_TABLE_NAME_PTR]
    mov     [rbp - 32], rax
    mov     rax, [r10 + JOIN_TABLE_NAME_LEN]
    mov     [rbp - 40], rax
.compare_join:
    mov     ARG1, [rbp - 16]
    mov     ARG2, [rbp - 24]
    mov     ARG3, [rbp - 32]
    mov     ARG4, [rbp - 40]
    call    qualifier_name_matches
    FRAME_END
    ret

; validate_expr_namespace(expr, stmt_payload) -> EAX bool
validate_expr_namespace:
    FRAME_BEGIN 32, 0
    mov     [rbp - 8], ARG1
    mov     [rbp - 16], ARG2
    mov     r10, ARG1
    mov     rax, [r10 + EXPR_KIND]
    cmp     rax, EXPR_COLUMN
    je      .validate_column
    cmp     rax, EXPR_UNARY
    je      .validate_unary
    cmp     rax, EXPR_BINARY
    je      .validate_binary
    mov     eax, 1
    FRAME_END
    ret
.validate_column:
    mov     r10, [rbp - 8]
    ; The length goes in a register no argument aliases: ARG2 is RDX on one of
    ; the two conventions, and loading the pointer would take the length with
    ; it - so Windows passed the pointer where the length belonged.
    mov     r11, [r10 + EXPR_QUAL_LEN]
    test    r11, r11
    jz      .valid
    mov     ARG1, [rbp - 16]
    mov     ARG2, [r10 + EXPR_QUAL_PTR]
    mov     ARG3, r11
    call    qualifier_matches
    FRAME_END
    ret
.validate_unary:
    mov     r10, [rbp - 8]
    mov     ARG1, [r10 + EXPR_LEFT]
    mov     ARG2, [rbp - 16]
    call    validate_expr_namespace
    FRAME_END
    ret
.validate_binary:
    mov     r10, [rbp - 8]
    mov     ARG1, [r10 + EXPR_LEFT]
    mov     ARG2, [rbp - 16]
    call    validate_expr_namespace
    test    eax, eax
    jz      .invalid
    mov     r10, [rbp - 8]
    mov     ARG1, [r10 + EXPR_RIGHT]
    mov     ARG2, [rbp - 16]
    call    validate_expr_namespace
    FRAME_END
    ret
.valid:
    mov     eax, 1
    FRAME_END
    ret
.invalid:
    xor     eax, eax
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  bind_expr(ast_expr, schema_ptr, arena, out_err) -> RAX: BOUND_EXPR* or 0
; -----------------------------------------------------------------------------
bind_expr:
    FRAME_BEGIN 96, 2
    mov     [rbp - 8], ARG1             ; ast_expr
    mov     [rbp - 16], ARG2            ; schema_ptr
    mov     [rbp - 24], ARG3            ; arena
    mov     [rbp - 32], ARG4            ; out_err

    test    ARG1, ARG1
    jz      .null_expr

    mov     r10, ARG1
    mov     rax, [r10 + EXPR_KIND]

    cmp     rax, EXPR_UNARY
    je      .bind_unary
    cmp     rax, EXPR_BINARY
    je      .bind_binary

    ; A placeholder reaching a predicate. Only INSERT ... VALUES takes them in
    ; this release, and saying so is worth a message of its own: the type-
    ; mismatch one this would otherwise get is not what is wrong.
    cmp     rax, EXPR_PARAM
    je      .param_placement

    ; Direct primary boolean column or literal (not supported in simple MVP)
    jmp     .unsupported

.bind_unary:
    mov     r10, [rbp - 8]
    mov     rax, [r10 + EXPR_OP]
    cmp     rax, OP_IS_NULL
    je      .is_null_op
    cmp     rax, OP_IS_NOT_NULL
    je      .is_not_null_op
    cmp     rax, OP_NOT
    je      .not_op
    jmp     .unsupported

.not_op:
    ; Bind inner child expression
    mov     r10, [rbp - 8]
    mov     ARG1, [r10 + EXPR_LEFT]
    mov     ARG2, [rbp - 16]
    mov     ARG3, [rbp - 24]
    mov     ARG4, [rbp - 32]
    call    bind_expr
    test    rax, rax
    jz      .fail
    mov     [rbp - 48], rax             ; bound inner child

    ; Allocate BOUND_EXPR
    mov     ARG1, [rbp - 24]
    mov     ARG2, BOUND_EXPR_SIZE
    call    sql_arena_alloc
    test    rax, rax
    jz      .fail

    mov     qword [rax + BEXPR_KIND], BEXPR_NOT
    mov     rdx, [rbp - 48]
    mov     [rax + BEXPR_LEFT], rdx
    FRAME_END
    ret

.is_null_op:
    mov     qword [rbp - 40], BEXPR_IS_NULL
    jmp     .unary_child

.is_not_null_op:
    mov     qword [rbp - 40], BEXPR_IS_NOT_NULL

.unary_child:
    mov     r10, [rbp - 8]
    mov     r11, [r10 + EXPR_LEFT]
    test    r11, r11
    jz      .unsupported
    cmp     qword [r11 + EXPR_KIND], EXPR_COLUMN
    jne     .unsupported

    ; Resolve column
    mov     ARG1, [rbp - 16]            ; schema_ptr
    mov     ARG2, [r11 + EXPR_NAME_PTR]
    mov     ARG3, [r11 + EXPR_NAME_LEN]
    lea     ARG4, [rbp - 48]            ; col_idx
    call    schema_find_col
    test    rax, rax
    jz      .col_not_found

    mov     edx, [rax + 0]              ; col_type
    mov     [rbp - 56], rdx
    mov     edx, [rax + 4]              ; col_flags
    mov     [rbp - 64], rdx

    ; Allocate BOUND_EXPR
    mov     ARG1, [rbp - 24]
    mov     ARG2, BOUND_EXPR_SIZE
    call    sql_arena_alloc
    test    rax, rax
    jz      .fail

    mov     rdx, [rbp - 40]
    mov     [rax + BEXPR_KIND], rdx
    mov     rdx, [rbp - 48]
    mov     [rax + BEXPR_COL_IDX], rdx
    mov     rdx, [rbp - 56]
    mov     [rax + BEXPR_COL_TYPE], rdx
    FRAME_END
    ret

.bind_binary:
    mov     r10, [rbp - 8]
    mov     rax, [r10 + EXPR_OP]

    ; AND / OR
    cmp     rax, OP_AND
    je      .logical_and
    cmp     rax, OP_OR
    je      .logical_or

    ; Distance functions
    cmp     rax, OP_L2_DISTANCE
    je      .bind_distance
    cmp     rax, OP_COSINE_DISTANCE
    je      .bind_distance

    ; Comparison operators
    jmp     .bind_comparison

.logical_and:
    mov     qword [rbp - 40], BEXPR_AND
    jmp     .logical_common
.logical_or:
    mov     qword [rbp - 40], BEXPR_OR
    jmp     .logical_common

.bind_distance:
    mov     r10, [rbp - 8]
    mov     r11, [r10 + EXPR_LEFT]
    mov     r12, [r10 + EXPR_RIGHT]

    cmp     qword [r11 + EXPR_KIND], EXPR_COLUMN
    je      .dist_col_left
    cmp     qword [r12 + EXPR_KIND], EXPR_COLUMN
    jne     .unsupported
    xchg    r11, r12

.dist_col_left:
    cmp     qword [r12 + EXPR_KIND], EXPR_LITERAL
    jne     .unsupported
    cmp     dword [r12 + EXPR_LIT_TYPE], CAT_VECTOR
    jne     .type_mismatch

    ; Resolve column against schema
    mov     ARG1, [rbp - 16]            ; schema_ptr
    mov     ARG2, [r11 + EXPR_NAME_PTR]
    mov     ARG3, [r11 + EXPR_NAME_LEN]
    lea     ARG4, [rbp - 48]            ; col_idx
    call    schema_find_col
    test    rax, rax
    jz      .col_not_found

    cmp     dword [rax + 0], CAT_VECTOR
    jne     .type_mismatch

    ; Declared dimension is in [rax + 4] >> 16
    mov     edx, [rax + 4]
    shr     edx, 16
    cmp     rdx, [r12 + EXPR_LIT_VAL]
    jne     .type_mismatch

    ; Allocate BOUND_EXPR
    mov     ARG1, [rbp - 24]
    mov     ARG2, BOUND_EXPR_SIZE
    call    sql_arena_alloc
    test    rax, rax
    jz      .fail

    mov     [rbp - 56], rax             ; save BOUND_EXPR
    mov     r10, [rbp - 8]
    mov     rdx, [r10 + EXPR_OP]
    mov     [rax + BEXPR_OP], rdx
    mov     rdx, [rbp - 48]
    mov     [rax + BEXPR_COL_IDX], rdx
    mov     qword [rax + BEXPR_COL_TYPE], CAT_VECTOR
    mov     rdx, [r12 + EXPR_LIT_PTR]
    mov     [rax + BEXPR_LIT_VAL], rdx   ; query vector ptr
    mov     rdx, [r12 + EXPR_LIT_VAL]
    mov     [rax + BEXPR_RIGHT], rdx     ; dimension

    cmp     qword [r10 + EXPR_OP], OP_L2_DISTANCE
    je      .dist_resolve_l2
    call    vector_cosine_normalized_f32_resolve
    jmp     .dist_kernel_ready
.dist_resolve_l2:
    call    vector_l2sq_f32_resolve
.dist_kernel_ready:
    mov     r11, [rbp - 56]
    mov     [r11 + BEXPR_KERNEL], rax
    mov     rax, r11
    FRAME_END
    ret

.logical_common:
    ; Bind left
    mov     r10, [rbp - 8]
    mov     ARG1, [r10 + EXPR_LEFT]
    mov     ARG2, [rbp - 16]
    mov     ARG3, [rbp - 24]
    mov     ARG4, [rbp - 32]
    call    bind_expr
    test    rax, rax
    jz      .fail
    mov     [rbp - 48], rax             ; b_left

    ; Bind right
    mov     r10, [rbp - 8]
    mov     ARG1, [r10 + EXPR_RIGHT]
    mov     ARG2, [rbp - 16]
    mov     ARG3, [rbp - 24]
    mov     ARG4, [rbp - 32]
    call    bind_expr
    test    rax, rax
    jz      .fail
    mov     [rbp - 56], rax             ; b_right

    ; Allocate BOUND_EXPR
    mov     ARG1, [rbp - 24]
    mov     ARG2, BOUND_EXPR_SIZE
    call    sql_arena_alloc
    test    rax, rax
    jz      .fail

    mov     rdx, [rbp - 40]
    mov     [rax + BEXPR_KIND], rdx
    mov     rdx, [rbp - 48]
    mov     [rax + BEXPR_LEFT], rdx
    mov     rdx, [rbp - 56]
    mov     [rax + BEXPR_RIGHT], rdx
    FRAME_END
    ret

.bind_comparison:
    ; Left column, right literal OR right column, left literal
    mov     r10, [rbp - 8]
    mov     r11, [r10 + EXPR_LEFT]
    mov     r12, [r10 + EXPR_RIGHT]

    cmp     qword [r11 + EXPR_KIND], EXPR_COLUMN
    je      .col_on_left

    cmp     qword [r12 + EXPR_KIND], EXPR_COLUMN
    je      .col_on_right

    jmp     .unsupported

.col_on_left:
    cmp     qword [r12 + EXPR_KIND], EXPR_LITERAL
    jne     .unsupported

    mov     [rbp - 40], r11             ; col_expr
    mov     [rbp - 48], r12             ; lit_expr
    mov     rax, [r10 + EXPR_OP]
    mov     [rbp - 56], rax             ; op
    jmp     .resolve_comp_col

.col_on_right:
    cmp     qword [r11 + EXPR_KIND], EXPR_LITERAL
    jne     .unsupported

    mov     [rbp - 40], r12             ; col_expr
    mov     [rbp - 48], r11             ; lit_expr
    ; Flip operator
    mov     rax, [r10 + EXPR_OP]
    cmp     rax, OP_LT
    je      .flip_gt
    cmp     rax, OP_LTE
    je      .flip_gte
    cmp     rax, OP_GT
    je      .flip_lt
    cmp     rax, OP_GTE
    je      .flip_lte
    ; EQ, NEQ unchanged
    mov     [rbp - 56], rax
    jmp     .resolve_comp_col
.flip_gt:
    mov     qword [rbp - 56], OP_GT
    jmp     .resolve_comp_col
.flip_gte:
    mov     qword [rbp - 56], OP_GTE
    jmp     .resolve_comp_col
.flip_lt:
    mov     qword [rbp - 56], OP_LT
    jmp     .resolve_comp_col
.flip_lte:
    mov     qword [rbp - 56], OP_LTE

.resolve_comp_col:
    mov     r10, [rbp - 40]             ; col_expr
    mov     ARG1, [rbp - 16]            ; schema_ptr
    mov     ARG2, [r10 + EXPR_NAME_PTR]
    mov     ARG3, [r10 + EXPR_NAME_LEN]
    lea     ARG4, [rbp - 64]            ; col_idx
    call    schema_find_col
    test    rax, rax
    jz      .col_not_found

    mov     edx, [rax + 0]              ; col_type
    mov     [rbp - 72], rdx
    mov     edx, [rax + 4]              ; col_flags
    mov     [rbp - 80], rdx

    ; Coerce literal value to column type
    mov     r10, [rbp - 48]             ; lit_expr
    cmp     dword [r10 + EXPR_LIT_TYPE], 0 ; TYPE_NULL
    je      .comp_is_null_lit
    mov     rax, [r10 + EXPR_LIT_VAL]
    mov     rcx, [rbp - 72]             ; col_type

    cmp     rcx, CAT_INT32
    je      .comp_int32
    cmp     rcx, CAT_FLOAT32
    je      .comp_float32
    jmp     .comp_val_ready

.comp_is_null_lit:
    ; Allocate BOUND_EXPR for comparison with NULL literal
    mov     ARG1, [rbp - 24]
    mov     ARG2, BOUND_EXPR_SIZE
    call    sql_arena_alloc
    test    rax, rax
    jz      .fail

    mov     qword [rax + BEXPR_KIND], BEXPR_COMPARE_NULL_LIT
    mov     rdx, [rbp - 56]
    mov     [rax + BEXPR_OP], rdx
    mov     rdx, [rbp - 64]
    mov     [rax + BEXPR_COL_IDX], rdx
    mov     rdx, [rbp - 72]
    mov     [rax + BEXPR_COL_TYPE], rdx
    mov     qword [rax + BEXPR_LIT_VAL], 0
    FRAME_END
    ret


.comp_int32:
    cmp     dword [r10 + EXPR_LIT_TYPE], CAT_FLOAT32
    je      .type_mismatch
    movsxd  rdx, eax
    cmp     rax, rdx
    jne     .type_mismatch
    jmp     .comp_val_ready

.comp_float32:
    cmp     dword [r10 + EXPR_LIT_TYPE], CAT_FLOAT32
    je      .comp_val_ready
    ; Convert integer to float
    cvtsi2ss xmm0, rax
    movd    eax, xmm0

.comp_val_ready:
    mov     [rbp - 88], rax             ; final lit_val

    ; Allocate BOUND_EXPR
    mov     ARG1, [rbp - 24]
    mov     ARG2, BOUND_EXPR_SIZE
    call    sql_arena_alloc
    test    rax, rax
    jz      .fail

    mov     qword [rax + BEXPR_KIND], BEXPR_COMPARE_COL_LIT
    mov     rdx, [rbp - 56]
    mov     [rax + BEXPR_OP], rdx
    mov     rdx, [rbp - 64]
    mov     [rax + BEXPR_COL_IDX], rdx
    mov     rdx, [rbp - 72]
    mov     [rax + BEXPR_COL_TYPE], rdx
    mov     rdx, [rbp - 88]
    mov     [rax + BEXPR_LIT_VAL], rdx
    mov     [rbp - 96], rax             ; preserve bound node across resolution
    mov     ARG1, [rbp - 72]            ; physical scalar type
    mov     ARG2, [rbp - 56]            ; normalized comparison operator
    call    sql_kernel_resolve
    test    rax, rax
    jz      .unsupported
    mov     r10, [rbp - 96]
    mov     [r10 + BEXPR_KERNEL], rax
    mov     rax, r10
    FRAME_END
    ret

.null_expr:
    xor     eax, eax
    FRAME_END
    ret

.col_not_found:
    mov     ARG1, [rbp - 32]
    mov     ARG2, SQL_ERR_COLUMN_NOT_FOUND
    xor     ARG3, ARG3
    lea     ARG4, [err_col_not_found]
    call    set_binder_error
    xor     eax, eax
    FRAME_END
    ret

.param_placement:
    mov     ARG1, [rbp - 32]
    mov     ARG2, SQL_ERR_SYNTAX
    xor     ARG3, ARG3
    lea     ARG4, [err_param_placement]
    call    set_binder_error
    xor     eax, eax
    FRAME_END
    ret

.unsupported:
    mov     ARG1, [rbp - 32]
    mov     ARG2, SQL_ERR_SYNTAX
    xor     ARG3, ARG3
    lea     ARG4, [err_unsupported_op]
    call    set_binder_error
    xor     eax, eax
    FRAME_END
    ret

.type_mismatch:
    mov     ARG1, [rbp - 32]
    mov     ARG2, SQL_ERR_SYNTAX
    xor     ARG3, ARG3
    lea     ARG4, [err_type_mismatch]
    call    set_binder_error
    xor     eax, eax
    FRAME_END
    ret

.fail:
    xor     eax, eax
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  sql_bind(db_ctx, ast_stmt, arena, out_plan, out_err) -> RAX: SQL_OK / err
; -----------------------------------------------------------------------------
sql_bind:
    FRAME_BEGIN 256, 1
    mov     [rbp - 8], ARG1             ; db_ctx
    mov     [rbp - 16], ARG2            ; ast_stmt
    mov     [rbp - 24], ARG3            ; arena
    mov     [rbp - 32], ARG4            ; out_plan
    mov     rax, IN_ARG5
    mov     [rbp - 40], rax             ; out_err
    SQL_CLEAR_ERROR rax

    ; Save callee-saved registers
    mov     [rbp - 136], rbx
    mov     [rbp - 144], r12
    mov     [rbp - 152], r13
    mov     [rbp - 160], r14
    mov     [rbp - 168], r15
    mov     [rbp - 176], rsi
    mov     [rbp - 184], rdi

    ; Check if db supports PAX / CATALOG
    mov     r10, ARG1
    test    qword [r10 + DB_FEATURES], CybouDB_FEATURE_PAX
    jnz     .features_ok

    mov     ARG1, [rbp - 40]
    mov     ARG2, SQL_ERR_NO_STORAGE
    xor     ARG3, ARG3
    lea     ARG4, [err_no_pax]
    call    set_binder_error
    mov     eax, SQL_ERR_NO_STORAGE
    jmp     .binder_exit

.features_ok:
    ; Allocate BOUND_PLAN
    mov     ARG1, [rbp - 24]
    mov     ARG2, BOUND_PLAN_SIZE
    call    sql_arena_alloc
    test    rax, rax
    jz      .oom
    mov     [rbp - 48], rax             ; bound_plan
    mov     r11, [rbp - 32]
    mov     [r11], rax

    mov     r10, [rbp - 16]
    mov     rax, [r10 + AST_STMT_TYPE]
    mov     r11, [r10 + AST_STMT_PAYLOAD]
    ; How many placeholders the parser counted. Read here because the payload
    ; is about to be written over the slot the statement itself was in, and
    ; stored on the plan for every statement kind - a caller asking a SELECT
    ; how many parameters it has should be told, not left to guess from an
    ; error.
    mov     rdx, [r10 + AST_STMT_PARAMS]
    mov     r10, [rbp - 48]
    mov     [r10 + PLAN_PARAM_COUNT], rdx
    mov     [rbp - 16], r11             ; all binders consume the payload

    cmp     rax, STMT_CREATE_TABLE
    je      .bind_create
    cmp     rax, STMT_INSERT
    je      .bind_insert
    cmp     rax, STMT_SELECT
    je      .bind_select
    cmp     rax, STMT_UPDATE
    je      .bind_update
    cmp     rax, STMT_DROP_TABLE
    je      .bind_drop
    cmp     rax, STMT_DELETE
    je      .bind_delete
    cmp     rax, STMT_BEGIN
    je      .bind_begin
    cmp     rax, STMT_COMMIT
    je      .bind_commit
    cmp     rax, STMT_ROLLBACK
    je      .bind_rollback
    cmp     rax, STMT_CREATE_INDEX
    je      .bind_create_index
    cmp     rax, STMT_DROP_INDEX
    je      .bind_drop_index
    cmp     rax, STMT_CREATE_QUEUE
    je      .bind_create_queue
    cmp     rax, STMT_DROP_QUEUE
    je      .bind_drop_queue
    cmp     rax, STMT_ENQUEUE
    je      .bind_enqueue
    cmp     rax, STMT_DEQUEUE
    je      .bind_dequeue
    cmp     rax, STMT_CREATE_STREAM
    je      .bind_create_stream
    cmp     rax, STMT_DROP_STREAM
    je      .bind_drop_stream
    cmp     rax, STMT_APPEND
    je      .bind_append
    cmp     rax, STMT_READ
    je      .bind_read
    cmp     rax, STMT_TRIM
    je      .bind_trim
    cmp     rax, STMT_CREATE_CURSOR
    je      .bind_create_cursor
    cmp     rax, STMT_DROP_CURSOR
    je      .bind_drop_cursor

    mov     eax, SQL_ERR_SYNTAX
    jmp     .binder_exit

.bind_begin:
    mov     r10, [rbp - 48]
    mov     qword [r10 + PLAN_TYPE], STMT_BEGIN
    xor     eax, eax
    jmp     .binder_exit

.bind_commit:
    mov     r10, [rbp - 48]
    mov     qword [r10 + PLAN_TYPE], STMT_COMMIT
    xor     eax, eax
    jmp     .binder_exit

.bind_rollback:
    mov     r10, [rbp - 48]
    mov     qword [r10 + PLAN_TYPE], STMT_ROLLBACK
    xor     eax, eax
    jmp     .binder_exit

; --- BIND CREATE TABLE -------------------------------------------------------
.bind_create:
    mov     r10, [rbp - 48]
    mov     qword [r10 + PLAN_TYPE], STMT_CREATE_TABLE

    mov     r10, [rbp - 16]
    mov     rsi, [r10 + STMT_NAME_PTR]
    mov     rcx, [r10 + STMT_NAME_LEN]
    cmp     rcx, 31
    ja      .bad_tbl_len

    ; The name has to be free of every object, not only of tables.
    mov     ARG1, [rbp - 8]             ; db_ctx
    mov     ARG2, [r10 + STMT_NAME_PTR]
    mov     ARG3, [r10 + STMT_NAME_LEN]  ; ARG1 aliases rcx on Windows
    xor     ARG4, ARG4
    call    catalog_find_object
    test    rax, rax
    jnz     .dup_table

    ; Check columns for duplicates
    mov     r10, [rbp - 16]
    mov     rcx, [r10 + STMT_EXTRA1]    ; col_count
    mov     r11, [r10 + STMT_EXTRA2]    ; col_defs
    xor     rbx, rbx                    ; i = 0
.outer_col:
    imul    rax, rbx, AST_COLDEF_SIZE
    add     rax, r11
    cmp     dword [rax + COLDEF_TYPE], CAT_TEXT
    je      .varlen_schema
    cmp     dword [rax + COLDEF_TYPE], CAT_BLOB
    je      .varlen_schema
    cmp     dword [rax + COLDEF_TYPE], CAT_VECTOR
    je      .vector_schema
    jmp     .fixed_schema
.varlen_schema:
    mov     rdx, [rbp - 8]
    test    qword [rdx + DB_FEATURES], CybouDB_FEATURE_VARLEN
    jz      .varlen_pending
    jmp     .fixed_schema
.vector_schema:
    mov     rdx, [rbp - 8]
    test    qword [rdx + DB_FEATURES], CybouDB_FEATURE_VECTOR
    jz      .vector_pending
.fixed_schema:
    mov     r12, [rax + COLDEF_NAME_PTR]
    mov     r13, [rax + COLDEF_NAME_LEN]
    cmp     r13, 23
    ja      .bad_col_len

    xor     rdx, rdx                    ; j = 0
.inner_col:
    cmp     rdx, rbx
    jae     .next_outer
    imul    rsi, rdx, AST_COLDEF_SIZE
    add     rsi, r11
    mov     r14, [rsi + COLDEF_NAME_PTR]
    mov     r15, [rsi + COLDEF_NAME_LEN]
    cmp     r13, r15
    jne     .next_inner

    ; Compare characters
    push    rcx
    mov     rcx, r13
    mov     rsi, r12
    mov     rdi, r14
    repe cmpsb
    pop     rcx
    je      .dup_col

.next_inner:
    inc     rdx
    jmp     .inner_col

.next_outer:
    inc     rbx
    cmp     rbx, rcx
    jb      .outer_col

    ; Allocate 4096-byte schema image in arena
    mov     ARG1, [rbp - 24]
    mov     ARG2, CybouDB_PAGE_SIZE
    call    sql_arena_alloc
    test    rax, rax
    jz      .oom
    mov     [rbp - 56], rax             ; schema_image

    ; Zero 4096 bytes
    mov     rdi, rax
    xor     eax, eax
    mov     ecx, CybouDB_PAGE_SIZE / 8
    rep stosq

    ; Populate schema fields
    mov     rdi, [rbp - 56]
    mov     r10, [rbp - 16]
    mov     eax, [r10 + STMT_EXTRA1]
    mov     [rdi + CAT_COUNT], eax
    mov     qword [rdi + CAT_DATA_ROOT], 0
    mov     qword [rdi + CAT_TABLE_ROWS], 0

    ; Copy table name to rdi + CAT_TABLE_NAME (offset 64)
    mov     rsi, [r10 + STMT_NAME_PTR]
    mov     rcx, [r10 + STMT_NAME_LEN]
    lea     rdx, [rdi + CAT_TABLE_NAME]
.copy_tbl_name:
    test    rcx, rcx
    jz      .copy_tbl_done
    mov     al, [rsi]
    mov     [rdx], al
    inc     rsi
    inc     rdx
    dec     rcx
    jmp     .copy_tbl_name
.copy_tbl_done:
    mov     byte [rdx], 0

    ; Copy column definitions
    mov     r10, [rbp - 16]
    mov     rcx, [r10 + STMT_EXTRA1]    ; col_count
    mov     r11, [r10 + STMT_EXTRA2]    ; col_defs
    xor     rbx, rbx
.copy_cols:
    imul    rax, rbx, AST_COLDEF_SIZE
    add     rax, r11                    ; col_def
    lea     rdx, [rdi + CAT_COLUMNS]
    mov     r8, rbx
    shl     r8, 5
    add     rdx, r8                     ; target col_rec

    mov     r9d, [rax + COLDEF_TYPE]
    mov     [rdx + 0], r9d
    mov     r9d, [rax + COLDEF_FLAGS]
    mov     [rdx + 4], r9d

    ; Copy column name
    mov     rsi, [rax + COLDEF_NAME_PTR]
    mov     r12, [rax + COLDEF_NAME_LEN]
    lea     r13, [rdx + 8]
.copy_cname:
    test    r12, r12
    jz      .copy_cname_done
    mov     al, [rsi]
    mov     [r13], al
    inc     rsi
    inc     r13
    dec     r12
    jmp     .copy_cname
.copy_cname_done:
    mov     byte [r13], 0
    inc     rbx
    cmp     rbx, rcx
    jb      .copy_cols

    ; Allocate next table_id
    mov     r10, [rbp - 8]              ; db_ctx
    mov     rax, [r10 + DB_ROOT]
    test    rax, rax
    jz      .first_table_id
    shl     rax, CybouDB_PAGE_SHIFT
    add     rax, [r10 + DB_BASE]        ; dir_ptr
    mov     ecx, [rax + CAT_COUNT]
    test    ecx, ecx
    jz      .first_table_id
    dec     ecx
    shl     rcx, 4
    mov     rax, [rax + CAT_DATA + rcx] ; last table_id
    inc     rax
    jmp     .table_id_ready
.first_table_id:
    mov     rax, 1
.table_id_ready:
    mov     r10, [rbp - 48]
    mov     [r10 + PLAN_TABLE_ID], rax
    mov     rax, [rbp - 56]
    mov     [r10 + PLAN_DATA1], rax

    xor     eax, eax
    jmp     .binder_exit

; --- BIND INSERT -------------------------------------------------------------
.bind_insert:
    mov     r10, [rbp - 48]
    mov     qword [r10 + PLAN_TYPE], STMT_INSERT

    ; Resolve table
    mov     r10, [rbp - 16]
    mov     ARG1, [rbp - 8]             ; db_ctx
    mov     ARG2, [r10 + STMT_NAME_PTR]
    mov     ARG3, [r10 + STMT_NAME_LEN]
    lea     ARG4, [rbp - 56]            ; table_id
    call    catalog_find_table
    test    rax, rax
    jz      .tbl_not_found

    mov     [rbp - 64], rax             ; schema_ptr
    mov     r10, [rbp - 48]
    mov     rdx, [rbp - 56]
    mov     [r10 + PLAN_TABLE_ID], rdx
    mov     [r10 + PLAN_SCHEMA_PAGE], rax

    ; Verify column count
    mov     r12, [rbp - 64]             ; schema_ptr
    mov     ecx, [r12 + CAT_COUNT]      ; expected col_count
    mov     [rbp - 72], rcx

    mov     r10, [rbp - 16]
    cmp     qword [r10 + STMT_EXTRA1], rcx
    jne     .bad_val_count

    mov     r10, [rbp - 16]
    mov     r13, [r10 + STMT_EXTRA3]    ; row_count
    mov     [rbp - 80], r13
    mov     rcx, [rbp - 72]
    mov     r14, r13
    imul    r14, rcx                    ; total_cells

    ; Allocate batch values (total_cells * 8 bytes)
    mov     ARG1, [rbp - 24]
    mov     ARG2, r14
    shl     ARG2, 3
    call    sql_arena_alloc
    test    rax, rax
    jz      .oom
    mov     [rbp - 88], rax             ; values_ptr

    ; Allocate batch nulls (total_cells * 1 byte)
    mov     ARG1, [rbp - 24]
    mov     ARG2, r14
    call    sql_arena_alloc
    test    rax, rax
    jz      .oom
    mov     [rbp - 96], rax             ; nulls_ptr

    ; One length slot per cell. Fixed-width and NULL cells keep zero here;
    ; TEXT/BLOB cells pair it with their decoded-byte pointer in BATCH_VALUES.
    mov     ARG1, [rbp - 24]
    mov     ARG2, r14
    shl     ARG2, 3
    call    sql_arena_alloc
    test    rax, rax
    jz      .oom
    mov     [rbp - 128], rax             ; var_lengths_ptr
    mov     rdi, rax
    xor     eax, eax
    mov     rcx, r14
    rep stosq

    ; Allocate extended batch descriptor.
    mov     ARG1, [rbp - 24]
    mov     ARG2, CybouDB_BATCH_SIZE
    call    sql_arena_alloc
    test    rax, rax
    jz      .oom
    mov     [rbp - 104], rax            ; batch_ptr

    mov     r10, [rbp - 80]
    mov     [rax + BATCH_ROWS], r10
    mov     r10, [rbp - 88]
    mov     [rax + BATCH_VALUES], r10
    mov     r10, [rbp - 96]
    mov     [rax + BATCH_NULLS], r10
    mov     r10, [rbp - 128]
    mov     [rax + BATCH_VAR_LENGTHS], r10
    mov     qword [rax + BATCH_FLAGS], 0    ; VALUES carries bytes, not roots

    ; The parameter area, allocated before the cell loop starts so that filling
    ; a cell never has to call the arena with the loop's registers live. Only a
    ; statement that has placeholders pays for it.
    mov     qword [rbp - 232], 0
    mov     r10, [rbp - 48]
    mov     rax, [r10 + PLAN_PARAM_COUNT]
    test    rax, rax
    jz      .ins_no_params

    mov     ARG1, [rbp - 24]
    mov     ARG2, rax
    shl     ARG2, 6                     ; PARAM_SLOT_SIZE
    call    sql_arena_alloc
    test    rax, rax
    jz      .oom
    mov     [rbp - 232], rax
    mov     r10, [rbp - 48]
    mov     [r10 + PLAN_PARAM_SLOTS], rax

    mov     ARG1, [rbp - 24]
    mov     ARG2, PARAM_BUF_BYTES + CybouDB_PARAM_BUF_SIZE
    call    sql_arena_alloc
    test    rax, rax
    jz      .oom
    mov     r10, [rbp - 48]
    mov     [r10 + PLAN_PARAM_BUF], rax

.ins_no_params:
    ; Fill batch cells
    mov     r10, [rbp - 16]
    mov     r15, [r10 + STMT_EXTRA4]    ; rows array ptr

    xor     ebx, ebx                    ; r = 0
.ins_row:
    mov     r8, [r15 + rbx * 8]         ; row expressions array
    xor     ecx, ecx                    ; c = 0
.ins_col:
    mov     [rbp - 112], rcx
    mov     r9, [r8 + rcx * 8]          ; AST_EXPR

    ; Target cell index: r * col_count + c
    mov     rax, rbx
    imul    rax, [rbp - 72]
    add     rax, [rbp - 112]
    mov     [rbp - 120], rax            ; cell_idx

    ; Schema column record
    mov     rax, [rbp - 112]
    shl     rax, 5
    mov     r12, [rbp - 64]
    lea     rdx, [r12 + CAT_COLUMNS + rax]
    mov     r10d, [rdx + 0]             ; col_type
    mov     r11d, [rdx + 4]             ; col_flags

    ; VALUES accepts literals and placeholders. Identifiers have zeroed literal
    ; fields and must never be mistaken for NULL (including NaN/Inf spellings).
    ; The check is here rather than above because a placeholder records the
    ; column it is going into, which is not known until the schema is read.
    cmp     qword [r9 + EXPR_KIND], EXPR_PARAM
    je      .ins_param
    cmp     qword [r9 + EXPR_KIND], EXPR_LITERAL
    jne     .type_mismatch

    ; Check NULL
    cmp     dword [r9 + EXPR_LIT_TYPE], 0 ; TYPE_NULL
    jne     .ins_not_null

    test    r11d, CAT_NULLABLE
    jz      .not_nullable

    ; Store NULL cell
    mov     rdi, [rbp - 96]
    mov     rax, [rbp - 120]
    mov     byte [rdi + rax], 1
    mov     rdi, [rbp - 88]
    mov     qword [rdi + rax * 8], 0
    jmp     .ins_cell_done

.ins_not_null:
    mov     eax, [r9 + EXPR_LIT_TYPE]
    cmp     r10d, CAT_TEXT
    je      .store_varlen
    cmp     r10d, CAT_BLOB
    je      .store_varlen
    cmp     r10d, CAT_VECTOR
    je      .store_vector
    ; No variable-width literal may enter a fixed-width conversion branch.
    cmp     eax, CAT_BOOL
    ja      .type_mismatch

    mov     rdi, [rbp - 96]
    mov     rax, [rbp - 120]
    mov     byte [rdi + rax], 0

    mov     rax, [r9 + EXPR_LIT_VAL]

    cmp     r10d, CAT_INT32
    je      .store_int32
    cmp     r10d, CAT_FLOAT32
    je      .store_float32
    cmp     r10d, CAT_BOOL
    je      .store_bool

    ; INT64: store raw 64-bit value
    cmp     dword [r9 + EXPR_LIT_TYPE], CAT_FLOAT32
    je      .type_mismatch
    cmp     dword [r9 + EXPR_LIT_TYPE], CAT_BOOL
    je      .type_mismatch
    mov     rdi, [rbp - 88]
    mov     rdx, [rbp - 120]
    mov     [rdi + rdx * 8], rax
    jmp     .ins_cell_done

.store_int32:
    cmp     dword [r9 + EXPR_LIT_TYPE], CAT_FLOAT32
    je      .type_mismatch
    cmp     dword [r9 + EXPR_LIT_TYPE], CAT_BOOL
    je      .type_mismatch
    movsxd  rdx, eax
    cmp     rax, rdx
    jne     .type_mismatch
    mov     rdi, [rbp - 88]
    mov     rdx, [rbp - 120]
    mov     [rdi + rdx * 8], rax
    jmp     .ins_cell_done

.store_float32:
    cmp     dword [r9 + EXPR_LIT_TYPE], CAT_BOOL
    je      .type_mismatch
    cmp     dword [r9 + EXPR_LIT_TYPE], CAT_FLOAT32
    je      .flt_raw
    ; Convert int to float
    cvtsi2ss xmm0, rax
    movd    eax, xmm0
.flt_raw:
    mov     rdi, [rbp - 88]
    mov     rdx, [rbp - 120]
    mov     [rdi + rdx * 8], rax
    jmp     .ins_cell_done

.store_bool:
    cmp     dword [r9 + EXPR_LIT_TYPE], CAT_BOOL
    je      .bool_val_ok
    cmp     rax, 0
    je      .bool_val_ok
    cmp     rax, 1
    je      .bool_val_ok
    jmp     .type_mismatch
.bool_val_ok:
    movzx   eax, al
    mov     rdi, [rbp - 88]
    mov     rdx, [rbp - 120]
    mov     [rdi + rdx * 8], rax

    jmp     .ins_cell_done

.store_varlen:
    cmp     eax, r10d
    jne     .type_mismatch
    mov     rdi, [rbp - 96]
    mov     rdx, [rbp - 120]
    mov     byte [rdi + rdx], 0
    mov     rdi, [rbp - 88]
    mov     rax, [r9 + EXPR_LIT_PTR]
    mov     [rdi + rdx * 8], rax
    mov     rdi, [rbp - 128]
    mov     rax, [r9 + EXPR_LIT_LEN]
    mov     [rdi + rdx * 8], rax
    jmp     .ins_cell_done

.ins_param:
    ; What the binder knows about a placeholder is where its value goes and
    ; what that value has to be. Recording the type and flags here is what lets
    ; cyboudb_bind_* refuse a wrong type at the call rather than halfway
    ; through an insert, when a row is already staged.
    mov     rdi, [rbp - 232]
    test    rdi, rdi
    jz      .type_mismatch              ; a `?` the parser did not count
    mov     rax, [r9 + EXPR_LIT_VAL]    ; the index this `?` has
    shl     rax, 6                      ; PARAM_SLOT_SIZE
    add     rdi, rax
    mov     rax, [rbp - 120]            ; cell_idx
    mov     [rdi + PARAM_CELL], rax
    mov     [rdi + PARAM_TYPE], r10
    mov     [rdi + PARAM_FLAGS], r11
    mov     qword [rdi + PARAM_STATE], PARAM_UNBOUND

    ; The cell is left NULL. Nothing reads it in that state: execution refuses
    ; a statement with an unbound parameter, and a bound one writes over all
    ; three arrays before the row is built.
    mov     rdi, [rbp - 96]
    mov     rdx, [rbp - 120]
    mov     byte [rdi + rdx], 1
    mov     rdi, [rbp - 88]
    mov     qword [rdi + rdx * 8], 0
    mov     rdi, [rbp - 128]
    test    rdi, rdi
    jz      .ins_cell_done
    mov     qword [rdi + rdx * 8], 0
    jmp     .ins_cell_done

.store_vector:
    cmp     eax, r10d
    jne     .type_mismatch
    ; Verify dimension matches declared column flags >> 16
    mov     eax, r11d
    shr     eax, 16
    cmp     rax, [r9 + EXPR_LIT_VAL]
    jne     .type_mismatch
    mov     rdi, [rbp - 96]
    mov     rdx, [rbp - 120]
    mov     byte [rdi + rdx], 0
    mov     rdi, [rbp - 88]
    mov     rax, [r9 + EXPR_LIT_PTR]
    mov     [rdi + rdx * 8], rax
    mov     rdi, [rbp - 128]
    mov     rax, [r9 + EXPR_LIT_LEN]
    mov     [rdi + rdx * 8], rax

.ins_cell_done:
    mov     rcx, [rbp - 112]
    inc     rcx
    cmp     rcx, [rbp - 72]
    jb      .ins_col

    inc     rbx
    cmp     rbx, [rbp - 80]
    jb      .ins_row

    ; The copy execution restores from. Materialising a TEXT, BLOB or VECTOR
    ; cell writes its extent root over the pointer to the literal bytes, so
    ; without this a second step of the same prepared statement would read a
    ; page id as an address. Taken here, after every cell is filled, and never
    ; written to again.
    mov     ARG1, [rbp - 24]
    mov     ARG2, r14
    shl     ARG2, 3
    call    sql_arena_alloc
    test    rax, rax
    jz      .oom
    mov     [rbp - 224], rax
    mov     rdi, rax
    mov     rsi, [rbp - 88]
    mov     rcx, r14
    rep movsq

    ; Insert plan ready
    mov     r10, [rbp - 48]
    mov     rax, [rbp - 104]
    mov     [r10 + PLAN_DATA1], rax     ; batch_ptr
    mov     rax, [rbp - 224]
    mov     [r10 + PLAN_INSERT_PRISTINE], rax
    mov     [r10 + PLAN_INSERT_CELLS], r14

    xor     eax, eax
    jmp     .binder_exit

; --- BIND UPDATE -------------------------------------------------------------
; Lower a complete typed mutation contract; execution remains gated until the
; COW writer can publish the rewritten table atomically.
.bind_update:
    mov     r10, [rbp - 48]
    mov     qword [r10 + PLAN_TYPE], STMT_UPDATE
    mov     qword [r10 + PLAN_DATA1], 0
    mov     qword [r10 + PLAN_DATA2], 0
    mov     qword [r10 + PLAN_DATA3], 0

    mov     r10, [rbp - 16]
    mov     ARG1, [rbp - 8]
    mov     ARG2, [r10 + UPDATE_TABLE_NAME_PTR]
    mov     ARG3, [r10 + UPDATE_TABLE_NAME_LEN]
    lea     ARG4, [rbp - 56]
    call    catalog_find_table
    test    rax, rax
    jz      .tbl_not_found
    mov     [rbp - 64], rax
    mov     r10, [rbp - 48]
    mov     rdx, [rbp - 56]
    mov     [r10 + PLAN_TABLE_ID], rdx
    mov     [r10 + PLAN_SCHEMA_PAGE], rax
    mov     r11, [rbp - 8]
    mov     rax, [r11 + DB_GENERATION]
    mov     [r10 + PLAN_GENERATION], rax
    mov     rax, [r11 + DB_BASE]
    mov     [r10 + PLAN_DB_BASE], rax
    mov     rax, [r11 + DB_ROOT]
    mov     [r10 + PLAN_DB_ROOT], rax
    mov     [r10 + PLAN_CTX], r11
    mov     qword [r10 + PLAN_FLAGS], 0

    mov     r11, [rbp - 16]
    mov     ARG1, [rbp - 64]
    mov     ARG2, [r11 + UPDATE_COLUMN_NAME_PTR]
    mov     ARG3, [r11 + UPDATE_COLUMN_NAME_LEN]
    lea     ARG4, [rbp - 88]
    call    schema_find_col
    test    rax, rax
    jz      .col_not_found
    mov     [rbp - 80], rax
    mov     r10, [rbp - 48]
    mov     rdx, [rbp - 88]
    mov     [r10 + PLAN_UPDATE_COL_IDX], rdx
    mov     edx, [rax]
    mov     [r10 + PLAN_UPDATE_COL_TYPE], rdx
    mov     qword [r10 + PLAN_UPDATE_LENGTH], 0
    mov     qword [r10 + PLAN_UPDATE_IS_NULL], 0

    mov     r11, [rbp - 16]
    mov     r9, [r11 + UPDATE_VALUE_EXPR]
    mov     [rbp - 72], r9
    cmp     qword [r9 + EXPR_KIND], EXPR_LITERAL
    jne     .type_mismatch
    mov     rdx, [rbp - 80]
    mov     r10d, [rdx]
    mov     r11d, [rdx + 4]
    cmp     dword [r9 + EXPR_LIT_TYPE], 0
    jne     .upd_not_null
    test    r11d, CAT_NULLABLE
    jz      .not_nullable
    mov     r10, [rbp - 48]
    mov     qword [r10 + PLAN_UPDATE_VALUE], 0
    mov     qword [r10 + PLAN_UPDATE_IS_NULL], 1
    jmp     .upd_bind_where

.upd_not_null:
    mov     eax, [r9 + EXPR_LIT_TYPE]
    cmp     r10d, CAT_TEXT
    je      .upd_varlen
    cmp     r10d, CAT_BLOB
    je      .upd_varlen
    cmp     eax, CAT_BOOL
    ja      .type_mismatch
    mov     rax, [r9 + EXPR_LIT_VAL]
    cmp     r10d, CAT_INT32
    je      .upd_int32
    cmp     r10d, CAT_FLOAT32
    je      .upd_float32
    cmp     r10d, CAT_BOOL
    je      .upd_bool
    cmp     dword [r9 + EXPR_LIT_TYPE], CAT_FLOAT32
    je      .type_mismatch
    cmp     dword [r9 + EXPR_LIT_TYPE], CAT_BOOL
    je      .type_mismatch
    jmp     .upd_store_value
.upd_int32:
    cmp     dword [r9 + EXPR_LIT_TYPE], CAT_FLOAT32
    je      .type_mismatch
    cmp     dword [r9 + EXPR_LIT_TYPE], CAT_BOOL
    je      .type_mismatch
    movsxd  rdx, eax
    cmp     rax, rdx
    jne     .type_mismatch
    jmp     .upd_store_value
.upd_float32:
    cmp     dword [r9 + EXPR_LIT_TYPE], CAT_BOOL
    je      .type_mismatch
    cmp     dword [r9 + EXPR_LIT_TYPE], CAT_FLOAT32
    je      .upd_store_value
    cvtsi2ss xmm0, rax
    movd    eax, xmm0
    jmp     .upd_store_value
.upd_bool:
    cmp     dword [r9 + EXPR_LIT_TYPE], CAT_BOOL
    je      .upd_bool_ok
    cmp     rax, 0
    je      .upd_bool_ok
    cmp     rax, 1
    jne     .type_mismatch
.upd_bool_ok:
    movzx   eax, al
.upd_store_value:
    mov     r10, [rbp - 48]
    mov     [r10 + PLAN_UPDATE_VALUE], rax
    jmp     .upd_bind_where

.upd_varlen:
    cmp     eax, r10d
    jne     .type_mismatch
    mov     r10, [rbp - 48]
    mov     rax, [r9 + EXPR_LIT_PTR]
    mov     [r10 + PLAN_UPDATE_VALUE], rax
    mov     rax, [r9 + EXPR_LIT_LEN]
    mov     [r10 + PLAN_UPDATE_LENGTH], rax

.upd_bind_where:
    mov     r11, [rbp - 16]
    mov     ARG1, [r11 + UPDATE_WHERE_EXPR]
    mov     ARG2, [rbp - 64]
    mov     ARG3, [rbp - 24]
    mov     ARG4, [rbp - 40]
    call    bind_expr
    test    rax, rax
    jz      .fail
    mov     r10, [rbp - 48]
    mov     [r10 + PLAN_DATA4], rax
    mov     ARG1, rax
    call    required_expr_columns
    mov     r10, [rbp - 48]
    mov     [r10 + PLAN_REQUIRED_COLS], rax
    mov     [r10 + PLAN_REQUIRED_VALUES], rdx
    xor     eax, eax
    jmp     .binder_exit

; --- BIND DELETE -------------------------------------------------------------
; Without a predicate the whole table goes; with one, DELETE is bound exactly
; like the SELECT that decides which rows match, and the executor rewrites the
; survivors - TEXT, BLOB and VECTOR cells included, by carrying their extent
; roots across rather than rebuilding the chains. The row count is left to execution time: a prepared plan may be
; stepped again after other statements have changed the table.
.bind_delete:
    mov     r10, [rbp - 48]
    mov     qword [r10 + PLAN_TYPE], STMT_DELETE
    mov     qword [r10 + PLAN_DATA1], 0
    mov     qword [r10 + PLAN_DATA2], 0
    mov     qword [r10 + PLAN_DATA3], 0
    mov     qword [r10 + PLAN_DATA4], 0
    mov     qword [r10 + PLAN_FLAGS], 0
    mov     qword [r10 + PLAN_REQUIRED_COLS], 0
    mov     qword [r10 + PLAN_REQUIRED_VALUES], 0
    mov     qword [r10 + PLAN_DELETE_ROWS], 0

    mov     r10, [rbp - 16]
    mov     rcx, [r10 + DELETE_TABLE_NAME_LEN]
    cmp     rcx, 31
    ja      .bad_tbl_len

    mov     ARG1, [rbp - 8]             ; db_ctx
    mov     ARG2, [r10 + DELETE_TABLE_NAME_PTR]
    mov     ARG3, [r10 + DELETE_TABLE_NAME_LEN]
    lea     ARG4, [rbp - 56]            ; table_id
    call    catalog_find_table
    test    rax, rax
    jz      .tbl_not_found

    mov     [rbp - 64], rax             ; schema_ptr
    mov     r10, [rbp - 48]
    mov     rdx, [rbp - 56]
    mov     [r10 + PLAN_TABLE_ID], rdx
    mov     [r10 + PLAN_SCHEMA_PAGE], rax
    mov     r11, [rbp - 8]
    mov     rax, [r11 + DB_GENERATION]
    mov     [r10 + PLAN_GENERATION], rax
    mov     rax, [r11 + DB_BASE]
    mov     [r10 + PLAN_DB_BASE], rax
    mov     rax, [r11 + DB_ROOT]
    mov     [r10 + PLAN_DB_ROOT], rax
    mov     [r10 + PLAN_CTX], r11

    mov     r10, [rbp - 16]
    mov     ARG1, [r10 + DELETE_WHERE_EXPR]
    test    ARG1, ARG1
    jz      .delete_bound               ; whole-table DELETE needs nothing more

.delete_bind_where:
    mov     r10, [rbp - 16]
    mov     ARG1, [r10 + DELETE_WHERE_EXPR]
    mov     ARG2, [rbp - 64]
    mov     ARG3, [rbp - 24]
    mov     ARG4, [rbp - 40]
    call    bind_expr
    test    rax, rax
    jz      .fail
    mov     r10, [rbp - 48]
    mov     [r10 + PLAN_DATA4], rax
    mov     ARG1, rax
    call    required_expr_columns
    mov     r10, [rbp - 48]
    mov     [r10 + PLAN_REQUIRED_COLS], rax
    mov     [r10 + PLAN_REQUIRED_VALUES], rdx

.delete_bound:
    xor     eax, eax
    jmp     .binder_exit

; --- BIND CREATE INDEX -------------------------------------------------------
; Resolves three names and builds the page image the catalog will store, the
; way CREATE TABLE builds a schema image: the executor then has one call to
; make and no decisions left to take.
;
; Local slots borrowed here: [rbp-56]=table id, [rbp-64]=schema pointer,
; [rbp-72]=column index, [rbp-80]=page image.
.bind_create_index:
    mov     r10, [rbp - 48]
    mov     qword [r10 + PLAN_TYPE], STMT_CREATE_INDEX
    mov     r11, [rbp - 8]
    test    qword [r11 + DB_FEATURES], CybouDB_FEATURE_INDEX
    jz      .index_unsupported

    mov     r10, [rbp - 16]
    mov     rcx, [r10 + STMT_NAME_LEN]
    cmp     rcx, 31
    ja      .bad_tbl_len
    cmp     rcx, 0
    je      .bad_tbl_len

    ; The name has to be free, and tables and indexes share one namespace.
    mov     ARG1, [rbp - 8]
    mov     ARG2, [r10 + STMT_NAME_PTR]
    mov     ARG3, [r10 + STMT_NAME_LEN]
    xor     ARG4, ARG4
    call    catalog_find_object
    test    rax, rax
    jnz     .dup_table

    ; The table it is on, which has to be a table.
    mov     r10, [rbp - 16]
    mov     ARG1, [rbp - 8]
    mov     ARG2, [r10 + STMT_INDEX_TABLE_PTR]
    mov     ARG3, [r10 + STMT_INDEX_TABLE_LEN]
    lea     ARG4, [rbp - 56]
    call    catalog_find_table
    test    rax, rax
    jz      .tbl_not_found
    mov     [rbp - 64], rax

    ; The column it is on, which has to be one this version can order.
    mov     r10, [rbp - 16]
    mov     ARG1, [rbp - 64]
    mov     ARG2, [r10 + STMT_INDEX_COL_PTR]
    mov     ARG3, [r10 + STMT_INDEX_COL_LEN]
    lea     ARG4, [rbp - 72]
    call    schema_find_col
    test    rax, rax
    jz      .col_not_found
    ; The record lives in the schema page, where the type is the first
    ; field - not the AST shape a CREATE TABLE column arrives in.
    mov     ecx, [rax]
    cmp     ecx, CAT_INT32
    je      .index_type_ok
    cmp     ecx, CAT_INT64
    jne     .index_bad_type
.index_type_ok:

    ; The page image the catalog stores: what the index is, with the header
    ; left to the catalog to stamp.
    mov     ARG1, [rbp - 24]
    mov     ARG2, CybouDB_PAGE_SIZE
    call    sql_arena_alloc
    test    rax, rax
    jz      .oom
    mov     [rbp - 80], rax
    mov     r11, rax
    xor     ecx, ecx
.index_zero:
    mov     qword [r11 + rcx * 8], 0
    inc     ecx
    cmp     ecx, CybouDB_PAGE_SIZE / 8
    jb      .index_zero

    mov     r11, [rbp - 80]
    mov     rax, [rbp - 72]
    mov     [r11 + IDX_COLUMN], eax
    mov     r10, [rbp - 16]
    mov     rax, [r10 + STMT_INDEX_UNIQUE]
    mov     [r11 + IDX_FLAGS], eax
    mov     rax, [rbp - 56]
    mov     [r11 + IDX_TABLE], rax

    ; The name, padded with the zeroes already there.
    mov     rsi, [r10 + STMT_NAME_PTR]
    mov     rcx, [r10 + STMT_NAME_LEN]
    lea     r8, [r11 + IDX_NAME]
    xor     edx, edx
.index_name:
    cmp     rdx, rcx
    jae     .index_named
    mov     al, [rsi + rdx]
    mov     [r8 + rdx], al
    inc     rdx
    jmp     .index_name
.index_named:

    ; The id, one past the last the directory holds - the rule tables follow.
    mov     r10, [rbp - 8]
    mov     rax, [r10 + DB_ROOT]
    test    rax, rax
    jz      .first_index_id
    shl     rax, CybouDB_PAGE_SHIFT
    add     rax, [r10 + DB_BASE]
    mov     ecx, [rax + CAT_COUNT]
    test    ecx, ecx
    jz      .first_index_id
    dec     ecx
    shl     rcx, 4
    mov     rax, [rax + CAT_DATA + rcx]
    inc     rax
    jmp     .index_id_ready
.first_index_id:
    mov     rax, 1
.index_id_ready:
    mov     r10, [rbp - 48]
    mov     [r10 + PLAN_TABLE_ID], rax
    mov     rax, [rbp - 80]
    mov     [r10 + PLAN_DATA1], rax
    mov     rax, [rbp - 56]
    mov     [r10 + PLAN_DATA2], rax     ; the table to build it over
    mov     rax, [rbp - 72]
    mov     [r10 + PLAN_DATA3], rax     ; the column
    mov     rax, [rbp - 64]
    mov     [r10 + PLAN_SCHEMA_PAGE], rax
    mov     r11, [rbp - 8]
    mov     [r10 + PLAN_CTX], r11
    xor     eax, eax
    jmp     .binder_exit

; --- BIND CREATE QUEUE -------------------------------------------------------
; A queue has no columns and no table behind it, so binding one is the name
; check and the page image. It takes its id the way a table and an index do,
; because the three share a directory and an id space.
.bind_create_queue:
    mov     r11, [rbp - 8]
    test    qword [r11 + DB_FEATURES], CybouDB_FEATURE_QUEUE
    jz      .queue_unsupported
    mov     eax, STMT_CREATE_QUEUE
    jmp     .bind_create_object

; A stream is created the same way and out of the same bytes: a zeroed page
; with a name in it, at the offset a queue puts one, taking its id from the
; sequence all five kinds share. What differs is the feature bit, the statement
; it answers to, and which shape check the catalog applies - and not one of
; those is in the body below.
.bind_create_stream:
    mov     r11, [rbp - 8]
    test    qword [r11 + DB_FEATURES], CybouDB_FEATURE_STREAM
    jz      .stream_unsupported
    mov     eax, STMT_CREATE_STREAM

.bind_create_object:
    mov     r10, [rbp - 48]
    mov     [r10 + PLAN_TYPE], rax

    mov     r10, [rbp - 16]
    mov     rcx, [r10 + STMT_NAME_LEN]
    cmp     rcx, 31
    ja      .bad_tbl_len
    cmp     rcx, 0
    je      .bad_tbl_len

    ; One namespace: a queue may not take the name of a table or an index.
    mov     ARG1, [rbp - 8]
    mov     ARG2, [r10 + STMT_NAME_PTR]
    mov     ARG3, [r10 + STMT_NAME_LEN]
    xor     ARG4, ARG4
    call    catalog_find_object
    test    rax, rax
    jnz     .dup_table

    mov     ARG1, [rbp - 24]
    mov     ARG2, CybouDB_PAGE_SIZE
    call    sql_arena_alloc
    test    rax, rax
    jz      .oom
    mov     [rbp - 80], rax
    mov     r11, rax
    xor     ecx, ecx
.queue_zero:
    mov     qword [r11 + rcx * 8], 0
    inc     ecx
    cmp     ecx, CybouDB_PAGE_SIZE / 8
    jb      .queue_zero

    ; The name, padded with the zeroes already there. Head, tail, claim, the
    ; segment count and the directory stay zero, which is what an empty queue
    ; is and what the catalog's shape check requires of a new one.
    mov     r10, [rbp - 16]
    mov     r11, [rbp - 80]
    mov     rsi, [r10 + STMT_NAME_PTR]
    mov     rcx, [r10 + STMT_NAME_LEN]
    lea     r8, [r11 + Q_NAME]
    xor     edx, edx
.queue_name:
    cmp     rdx, rcx
    jae     .queue_named
    mov     al, [rsi + rdx]
    mov     [r8 + rdx], al
    inc     rdx
    jmp     .queue_name
.queue_named:

    ; The id, one past the last the directory holds.
    mov     r10, [rbp - 8]
    mov     rax, [r10 + DB_ROOT]
    test    rax, rax
    jz      .first_queue_id
    shl     rax, CybouDB_PAGE_SHIFT
    add     rax, [r10 + DB_BASE]
    mov     ecx, [rax + CAT_COUNT]
    test    ecx, ecx
    jz      .first_queue_id
    dec     ecx
    shl     rcx, 4
    mov     rax, [rax + CAT_DATA + rcx]
    inc     rax
    jmp     .queue_id_ready
.first_queue_id:
    mov     rax, 1
.queue_id_ready:
    mov     r10, [rbp - 48]
    mov     [r10 + PLAN_TABLE_ID], rax
    mov     rax, [rbp - 80]
    mov     [r10 + PLAN_DATA1], rax
    mov     r11, [rbp - 8]
    mov     [r10 + PLAN_CTX], r11
    xor     eax, eax
    jmp     .binder_exit

; --- BIND TRIM ---------------------------------------------------------------
; The stream, and the position carried through. Whether a reader would be left
; behind is a fact about the page, so db_stream_trim answers it.
.bind_trim:
    mov     r10, [rbp - 48]
    mov     qword [r10 + PLAN_TYPE], STMT_TRIM
    mov     r11, [rbp - 8]
    test    qword [r11 + DB_FEATURES], CybouDB_FEATURE_STREAM
    jz      .stream_unsupported
    mov     r10, [rbp - 16]
    mov     rcx, [r10 + QUEUE_NAME_LEN]
    cmp     rcx, 31
    ja      .bad_tbl_len
    mov     ARG1, [rbp - 8]
    mov     ARG2, [r10 + QUEUE_NAME_PTR]
    mov     ARG3, [r10 + QUEUE_NAME_LEN]
    lea     ARG4, [rbp - 56]
    call    catalog_find_stream
    test    rax, rax
    jz      .stream_not_found
    mov     r10, [rbp - 48]
    mov     rdx, [rbp - 56]
    mov     [r10 + PLAN_TABLE_ID], rdx
    mov     r11, [rbp - 16]
    mov     rax, [r11 + TRIM_POSITION]
    mov     [r10 + PLAN_DATA1], rax
    mov     r11, [rbp - 8]
    mov     [r10 + PLAN_CTX], r11
    xor     eax, eax
    jmp     .binder_exit

; --- BIND CREATE CURSOR / DROP CURSOR ----------------------------------------
; The stream is resolved here, because that is a name in the catalog. The
; reader is not: whether a stream already has a reader of that name, and
; whether it has room for another, are facts about the page, and the page is
; the core's to read. The binder carries the name; db_stream_cursor_add and
; db_stream_cursor_drop own the rules.
.bind_read:
    mov     r10, [rbp - 48]
    mov     qword [r10 + PLAN_TYPE], STMT_READ
    jmp     .bind_cursor_common
.bind_create_cursor:
    mov     r10, [rbp - 48]
    mov     qword [r10 + PLAN_TYPE], STMT_CREATE_CURSOR
    jmp     .bind_cursor_common
.bind_drop_cursor:
    mov     r10, [rbp - 48]
    mov     qword [r10 + PLAN_TYPE], STMT_DROP_CURSOR
.bind_cursor_common:
    mov     r11, [rbp - 8]
    test    qword [r11 + DB_FEATURES], CybouDB_FEATURE_STREAM
    jz      .stream_unsupported
    mov     r10, [rbp - 16]
    mov     rcx, [r10 + QUEUE_NAME_LEN]
    cmp     rcx, 31
    ja      .bad_tbl_len
    mov     rcx, [r10 + CURSOR_NAME_LEN]
    cmp     rcx, 23                     ; SCUR_NAME_MAX
    ja      .cursor_name_len
    test    rcx, rcx
    jz      .cursor_name_len
    mov     ARG1, [rbp - 8]
    mov     ARG2, [r10 + QUEUE_NAME_PTR]
    mov     ARG3, [r10 + QUEUE_NAME_LEN]
    lea     ARG4, [rbp - 56]
    call    catalog_find_stream
    test    rax, rax
    jz      .stream_not_found
    mov     r10, [rbp - 48]
    mov     rdx, [rbp - 56]
    mov     [r10 + PLAN_TABLE_ID], rdx
    mov     r11, [rbp - 16]
    mov     rax, [r11 + CURSOR_NAME_PTR]
    mov     [r10 + PLAN_READER_PTR], rax
    mov     rax, [r11 + CURSOR_NAME_LEN]
    mov     [r10 + PLAN_READER_LEN], rax
    mov     r11, [rbp - 8]
    mov     [r10 + PLAN_CTX], r11
    xor     eax, eax
    jmp     .binder_exit

; --- BIND DROP STREAM --------------------------------------------------------
.bind_drop_stream:
    mov     r10, [rbp - 48]
    mov     qword [r10 + PLAN_TYPE], STMT_DROP_STREAM
    mov     r11, [rbp - 8]
    test    qword [r11 + DB_FEATURES], CybouDB_FEATURE_STREAM
    jz      .stream_unsupported

    mov     r10, [rbp - 16]
    mov     rcx, [r10 + DROP_TABLE_NAME_LEN]
    cmp     rcx, 31
    ja      .bad_tbl_len
    mov     ARG1, [rbp - 8]
    mov     ARG2, [r10 + DROP_TABLE_NAME_PTR]
    mov     ARG3, [r10 + DROP_TABLE_NAME_LEN]
    lea     ARG4, [rbp - 56]
    call    catalog_find_stream
    test    rax, rax
    jz      .stream_not_found
    mov     r10, [rbp - 48]
    mov     rdx, [rbp - 56]
    mov     [r10 + PLAN_TABLE_ID], rdx
    xor     eax, eax
    jmp     .binder_exit

; --- BIND DROP QUEUE ---------------------------------------------------------
.bind_drop_queue:
    mov     r10, [rbp - 48]
    mov     qword [r10 + PLAN_TYPE], STMT_DROP_QUEUE
    mov     r11, [rbp - 8]
    test    qword [r11 + DB_FEATURES], CybouDB_FEATURE_QUEUE
    jz      .queue_unsupported

    mov     r10, [rbp - 16]
    mov     rcx, [r10 + DROP_TABLE_NAME_LEN]
    cmp     rcx, 31
    ja      .bad_tbl_len
    mov     ARG1, [rbp - 8]
    mov     ARG2, [r10 + DROP_TABLE_NAME_PTR]
    mov     ARG3, [r10 + DROP_TABLE_NAME_LEN]
    lea     ARG4, [rbp - 56]
    call    catalog_find_queue
    test    rax, rax
    jz      .queue_not_found
    mov     r10, [rbp - 48]
    mov     rdx, [rbp - 56]
    mov     [r10 + PLAN_TABLE_ID], rdx
    xor     eax, eax
    jmp     .binder_exit

; --- BIND ENQUEUE / DEQUEUE --------------------------------------------------
; Both resolve one name, and it has to be a queue: catalog_find_queue is what
; makes ENQUEUE INTO a table a refusal rather than a surprise.
;
; A payload is bytes. A TEXT or BLOB literal is already bytes and arrives with
; a pointer and a length; anything else is refused, because a queue has no
; column to say what an integer in it would mean.
.bind_enqueue:
    mov     r10, [rbp - 48]
    mov     qword [r10 + PLAN_TYPE], STMT_ENQUEUE
    mov     r11, [rbp - 8]
    test    qword [r11 + DB_FEATURES], CybouDB_FEATURE_QUEUE
    jz      .queue_unsupported
    mov     r10, [rbp - 16]
    mov     rcx, [r10 + QUEUE_NAME_LEN]
    cmp     rcx, 31
    ja      .bad_tbl_len
    mov     ARG1, [rbp - 8]
    mov     ARG2, [r10 + QUEUE_NAME_PTR]
    mov     ARG3, [r10 + QUEUE_NAME_LEN]
    lea     ARG4, [rbp - 56]
    call    catalog_find_queue
    test    rax, rax
    jz      .queue_not_found
    jmp     .bind_payload

; The same payload, resolved through the other half of the type boundary: a
; name that turns out to be a queue is not a stream, and APPEND says so rather
; than writing a record into it.
.bind_append:
    mov     r10, [rbp - 48]
    mov     qword [r10 + PLAN_TYPE], STMT_APPEND
    mov     r11, [rbp - 8]
    test    qword [r11 + DB_FEATURES], CybouDB_FEATURE_STREAM
    jz      .stream_unsupported
    mov     r10, [rbp - 16]
    mov     rcx, [r10 + QUEUE_NAME_LEN]
    cmp     rcx, 31
    ja      .bad_tbl_len
    mov     ARG1, [rbp - 8]
    mov     ARG2, [r10 + QUEUE_NAME_PTR]
    mov     ARG3, [r10 + QUEUE_NAME_LEN]
    lea     ARG4, [rbp - 56]
    call    catalog_find_stream
    test    rax, rax
    jz      .stream_not_found

.bind_payload:

    mov     r10, [rbp - 16]
    mov     r9, [r10 + QUEUE_VALUE_EXPR]
    mov     eax, [r9 + EXPR_LIT_TYPE]
    cmp     eax, CAT_TEXT
    je      .enqueue_bytes
    cmp     eax, CAT_BLOB
    jne     .queue_bad_payload
.enqueue_bytes:
    mov     rcx, [r9 + EXPR_LIT_LEN]
    mov     rax, rcx
    shr     rax, 32
    jnz     .queue_too_long             ; a length the slot cannot record
    mov     r10, [rbp - 48]
    mov     rdx, [rbp - 56]
    mov     [r10 + PLAN_TABLE_ID], rdx
    mov     rax, [r9 + EXPR_LIT_PTR]
    mov     [r10 + PLAN_DATA1], rax
    mov     [r10 + PLAN_DATA2], rcx
    mov     r11, [rbp - 8]
    mov     [r10 + PLAN_CTX], r11
    xor     eax, eax
    jmp     .binder_exit

.bind_dequeue:
    mov     r10, [rbp - 48]
    mov     qword [r10 + PLAN_TYPE], STMT_DEQUEUE
    mov     r11, [rbp - 8]
    test    qword [r11 + DB_FEATURES], CybouDB_FEATURE_QUEUE
    jz      .queue_unsupported
    mov     r10, [rbp - 16]
    mov     rcx, [r10 + QUEUE_NAME_LEN]
    cmp     rcx, 31
    ja      .bad_tbl_len
    mov     ARG1, [rbp - 8]
    mov     ARG2, [r10 + QUEUE_NAME_PTR]
    mov     ARG3, [r10 + QUEUE_NAME_LEN]
    lea     ARG4, [rbp - 56]
    call    catalog_find_queue
    test    rax, rax
    jz      .queue_not_found
    mov     r10, [rbp - 48]
    mov     rdx, [rbp - 56]
    mov     [r10 + PLAN_TABLE_ID], rdx
    mov     r11, [rbp - 8]
    mov     [r10 + PLAN_CTX], r11
    xor     eax, eax
    jmp     .binder_exit

; --- BIND DROP INDEX ---------------------------------------------------------
.bind_drop_index:
    mov     r10, [rbp - 48]
    mov     qword [r10 + PLAN_TYPE], STMT_DROP_INDEX
    mov     r11, [rbp - 8]
    test    qword [r11 + DB_FEATURES], CybouDB_FEATURE_INDEX
    jz      .index_unsupported

    mov     r10, [rbp - 16]
    mov     rcx, [r10 + DROP_TABLE_NAME_LEN]
    cmp     rcx, 31
    ja      .bad_tbl_len
    mov     ARG1, [rbp - 8]
    mov     ARG2, [r10 + DROP_TABLE_NAME_PTR]
    mov     ARG3, [r10 + DROP_TABLE_NAME_LEN]
    lea     ARG4, [rbp - 56]
    call    catalog_find_index
    test    rax, rax
    jz      .index_not_found
    mov     r10, [rbp - 48]
    mov     rdx, [rbp - 56]
    mov     [r10 + PLAN_TABLE_ID], rdx
    xor     eax, eax
    jmp     .binder_exit

; --- BIND DROP TABLE ---------------------------------------------------------
.bind_drop:
    mov     r10, [rbp - 48]
    mov     qword [r10 + PLAN_TYPE], STMT_DROP_TABLE

    mov     r10, [rbp - 16]
    mov     rsi, [r10 + DROP_TABLE_NAME_PTR]
    mov     rcx, [r10 + DROP_TABLE_NAME_LEN]
    cmp     rcx, 31
    ja      .bad_tbl_len

    ; Resolve table
    mov     ARG1, [rbp - 8]             ; db_ctx
    mov     ARG2, [r10 + DROP_TABLE_NAME_PTR]
    mov     ARG3, [r10 + DROP_TABLE_NAME_LEN]
    lea     ARG4, [rbp - 56]            ; table_id
    call    catalog_find_table
    test    rax, rax
    jz      .tbl_not_found

    mov     r10, [rbp - 48]
    mov     rdx, [rbp - 56]
    mov     [r10 + PLAN_TABLE_ID], rdx

    xor     eax, eax
    jmp     .binder_exit

; --- BIND SELECT -------------------------------------------------------------
.bind_select:
    mov     r10, [rbp - 48]
    mov     qword [r10 + PLAN_TYPE], STMT_SELECT

    ; Resolve table
    mov     r10, [rbp - 16]
    mov     ARG1, [rbp - 8]             ; db_ctx
    mov     ARG2, [r10 + STMT_NAME_PTR]
    mov     ARG3, [r10 + STMT_NAME_LEN]
    lea     ARG4, [rbp - 56]            ; table_id
    call    catalog_find_table
    test    rax, rax
    jz      .tbl_not_found

    mov     [rbp - 64], rax             ; schema_ptr
    mov     r10, [rbp - 48]
    mov     rdx, [rbp - 56]
    mov     [r10 + PLAN_TABLE_ID], rdx
    mov     [r10 + PLAN_SCHEMA_PAGE], rax
    mov     r11, [rbp - 8]              ; db_ctx
    mov     rax, [r11 + DB_GENERATION]
    mov     [r10 + PLAN_GENERATION], rax
    mov     rax, [r11 + DB_BASE]
    mov     [r10 + PLAN_DB_BASE], rax
    mov     rax, [r11 + DB_ROOT]
    mov     [r10 + PLAN_DB_ROOT], rax
    mov     [r10 + PLAN_CTX], r11
    mov     qword [r10 + PLAN_FLAGS], 0
    mov     qword [r10 + PLAN_JOIN_TYPE], 0
    mov     qword [r10 + PLAN_RIGHT_TABLE_ID], 0
    mov     qword [r10 + PLAN_RIGHT_SCHEMA], 0
    mov     qword [r10 + PLAN_JOIN_AST], 0
    mov     qword [r10 + PLAN_JOIN_LEFT_COL], 0
    mov     qword [r10 + PLAN_JOIN_RIGHT_COL], 0
    mov     qword [r10 + PLAN_JOIN_KEY_TYPE], 0
    mov     qword [r10 + PLAN_JOIN_PROJECTIONS], 0
    mov     qword [r10 + PLAN_LIMIT_VALUE], 0
    mov     qword [r10 + PLAN_OFFSET_VALUE], 0
    mov     qword [r10 + PLAN_ORDER_ORDINAL], 0
    mov     qword [r10 + PLAN_ORDER_TYPE], 0
    mov     qword [r10 + PLAN_ORDER_DESC], 0
    mov     qword [r10 + PLAN_VECTOR_TOPK_EXPR], 0
    mov     r11, [rbp - 16]
    cmp     qword [r11 + SELECT_LIMIT_VALUE], -1
    je      .select_limit_bound
    or      qword [r10 + PLAN_FLAGS], PLAN_FLAG_LIMIT
    mov     rax, [r11 + SELECT_LIMIT_VALUE]
    mov     [r10 + PLAN_LIMIT_VALUE], rax
    mov     rax, [r11 + SELECT_OFFSET_VALUE]
    mov     [r10 + PLAN_OFFSET_VALUE], rax
.select_limit_bound:

    ; Resolve both catalog inputs and validate the executable equi-join AST so
    ; namespace, column, and type errors are reported before feature gates.
    mov     r10, [rbp - 16]
    cmp     qword [r10 + SELECT_JOIN_COUNT], 0
    je      .join_bound
    mov     r11, [r10 + SELECT_JOIN_HEAD]
    test    r11, r11
    jz      .join_condition_bad
    mov     [rbp - 200], r11

    mov     ARG1, [rbp - 8]
    mov     ARG2, [r11 + JOIN_TABLE_NAME_PTR]
    mov     ARG3, [r11 + JOIN_TABLE_NAME_LEN]
    lea     ARG4, [rbp - 192]
    call    catalog_find_table
    test    rax, rax
    jz      .tbl_not_found
    mov     r11, [rbp - 200]
    mov     r10, [rbp - 48]
    mov     rdx, [r11 + JOIN_TYPE]
    cmp     rdx, JOIN_INNER
    je      .join_type_ok
    cmp     rdx, JOIN_LEFT
    jne     .join_condition_bad
.join_type_ok:
    mov     [r10 + PLAN_JOIN_TYPE], rdx
    mov     rdx, [rbp - 192]
    mov     [r10 + PLAN_RIGHT_TABLE_ID], rdx
    mov     [r10 + PLAN_RIGHT_SCHEMA], rax
    mov     [r10 + PLAN_JOIN_AST], r11

    mov     rax, [r11 + JOIN_ON_EXPR]
    test    rax, rax
    jz      .join_condition_bad
    cmp     qword [rax + EXPR_KIND], EXPR_BINARY
    jne     .join_condition_bad
    cmp     qword [rax + EXPR_OP], OP_EQ
    jne     .join_condition_bad
    mov     rdx, [rax + EXPR_LEFT]
    mov     r8, [rax + EXPR_RIGHT]
    test    rdx, rdx
    jz      .join_condition_bad
    test    r8, r8
    jz      .join_condition_bad
    cmp     qword [rdx + EXPR_KIND], EXPR_COLUMN
    jne     .join_condition_bad
    cmp     qword [r8 + EXPR_KIND], EXPR_COLUMN
    jne     .join_condition_bad

    ; Both keys must be explicitly qualified so their table ownership is
    ; deterministic. Accept either textual order in the equality.
    cmp     qword [rdx + EXPR_QUAL_LEN], 0
    je      .join_namespace_bad
    cmp     qword [r8 + EXPR_QUAL_LEN], 0
    je      .join_namespace_bad
    mov     [rbp - 208], rdx            ; first column AST
    mov     [rbp - 216], r8             ; second column AST

    mov     r10, rdx
    mov     ARG1, [rbp - 16]
    mov     ARG3, [r10 + EXPR_QUAL_LEN]
    mov     ARG2, [r10 + EXPR_QUAL_PTR]
    call    qualifier_matches
    test    eax, eax
    jz      .join_first_maybe_right
    mov     r8, [rbp - 216]
    mov     r11, [rbp - 200]
    mov     r10, r8
    mov     ARG1, r11
    mov     ARG3, [r10 + EXPR_QUAL_LEN]
    mov     ARG2, [r10 + EXPR_QUAL_PTR]
    call    join_qualifier_matches
    test    eax, eax
    jz      .join_namespace_bad
    jmp     .join_keys_ordered

.join_first_maybe_right:
    mov     rdx, [rbp - 208]
    mov     r11, [rbp - 200]
    mov     r10, rdx
    mov     ARG1, r11
    mov     ARG3, [r10 + EXPR_QUAL_LEN]
    mov     ARG2, [r10 + EXPR_QUAL_PTR]
    call    join_qualifier_matches
    test    eax, eax
    jz      .join_namespace_bad
    mov     r8, [rbp - 216]
    mov     r10, r8
    mov     ARG1, [rbp - 16]
    mov     ARG3, [r10 + EXPR_QUAL_LEN]
    mov     ARG2, [r10 + EXPR_QUAL_PTR]
    call    qualifier_matches
    test    eax, eax
    jz      .join_namespace_bad
    mov     rax, [rbp - 208]
    mov     rdx, [rbp - 216]
    mov     [rbp - 208], rdx            ; normalize: left key first
    mov     [rbp - 216], rax

.join_keys_ordered:
    mov     rdx, [rbp - 208]
    mov     r10, rdx
    mov     ARG1, [rbp - 64]
    mov     ARG3, [r10 + EXPR_NAME_LEN]
    mov     ARG2, [r10 + EXPR_NAME_PTR]
    lea     ARG4, [rbp - 232]
    call    schema_find_col
    test    rax, rax
    jz      .col_not_found
    mov     edx, [rax]
    mov     [rbp - 248], rdx

    mov     r8, [rbp - 216]
    mov     r10, [rbp - 48]
    mov     ARG1, [r10 + PLAN_RIGHT_SCHEMA]
    mov     r10, r8
    mov     ARG3, [r10 + EXPR_NAME_LEN]
    mov     ARG2, [r10 + EXPR_NAME_PTR]
    lea     ARG4, [rbp - 240]
    call    schema_find_col
    test    rax, rax
    jz      .col_not_found
    mov     edx, [rax]
    cmp     rdx, [rbp - 248]
    jne     .type_mismatch
    cmp     edx, CAT_INT32
    je      .join_key_type_ok
    cmp     edx, CAT_INT64
    jne     .join_key_type_bad
.join_key_type_ok:

    mov     r10, [rbp - 48]
    mov     rax, [rbp - 232]
    mov     [r10 + PLAN_JOIN_LEFT_COL], rax
    mov     rax, [rbp - 240]
    mov     [r10 + PLAN_JOIN_RIGHT_COL], rax
    mov     rax, [rbp - 248]
    mov     [r10 + PLAN_JOIN_KEY_TYPE], rax
    jmp     .join_bound

.join_bound:

    ; Projections
    mov     r10, [rbp - 16]
    mov     rax, [r10 + STMT_EXTRA1]    ; proj_count
    mov     r11, [rbp - 48]
    cmp     qword [r11 + PLAN_JOIN_TYPE], 0
    je      .projection_shape_ok
    cmp     rax, 0
    jle     .join_projection_bad
.projection_shape_ok:
    cmp     rax, PROJ_COUNT_STAR
    je      .proj_count_star
    test    rax, rax
    jz      .proj_all

    ; Specific projections
    mov     [rbp - 72], rax             ; proj_count
    shl     rax, 2                      ; * 4 bytes for u32 indices
    mov     ARG1, [rbp - 24]
    mov     ARG2, rax
    call    sql_arena_alloc
    test    rax, rax
    jz      .oom
    mov     [rbp - 80], rax             ; proj_indices

    mov     rax, [rbp - 72]
    shl     rax, 2
    mov     ARG1, [rbp - 24]
    mov     ARG2, rax
    call    sql_arena_alloc
    test    rax, rax
    jz      .oom
    mov     [rbp - 88], rax             ; proj_types

    mov     r10, [rbp - 16]
    mov     r11, [r10 + STMT_EXTRA2]    ; proj names array
    xor     rbx, rbx                    ; p = 0
.proj_loop:
    mov     r10, [rbp - 16]
    mov     r11, [r10 + STMT_EXTRA2]    ; reload proj names array
    mov     rax, rbx
    imul    rax, AST_NAME_SIZE
    add     r11, rax
    mov     rsi, [r11 + AST_NAME_PTR]
    mov     r8, [r11 + AST_NAME_LEN]

    mov     qword [rbp - 112], 0        ; encoded projection source bit
    mov     rax, [rbp - 64]
    mov     [rbp - 120], rax            ; selected schema

    ; A JOIN projection must choose a namespace. Single-table SELECT retains
    ; its existing optional qualifier behavior.
    mov     r10, [rbp - 48]
    cmp     qword [r10 + PLAN_JOIN_TYPE], 0
    jne     .proj_join_namespace
    cmp     qword [r11 + AST_NAME_QUAL_LEN], 0
    je      .proj_qualifier_ok
    mov     [rbp - 96], rbx
    mov     ARG1, [rbp - 16]
    mov     ARG2, [r11 + AST_NAME_QUAL_PTR]
    mov     ARG3, [r11 + AST_NAME_QUAL_LEN]
    call    qualifier_matches
    test    eax, eax
    jz      .col_not_found
    mov     rbx, [rbp - 96]
    mov     r10, [rbp - 16]
    mov     r11, [r10 + STMT_EXTRA2]
    mov     rax, rbx
    imul    rax, AST_NAME_SIZE
    add     r11, rax
    mov     rsi, [r11 + AST_NAME_PTR]
    mov     r8, [r11 + AST_NAME_LEN]
    jmp     .proj_qualifier_ok

.proj_join_namespace:
    cmp     qword [r11 + AST_NAME_QUAL_LEN], 0
    je      .join_projection_bad
    mov     [rbp - 96], rbx
    mov     ARG1, [rbp - 16]
    mov     ARG2, [r11 + AST_NAME_QUAL_PTR]
    mov     ARG3, [r11 + AST_NAME_QUAL_LEN]
    call    qualifier_matches
    test    eax, eax
    jnz      .proj_join_left

    mov     rbx, [rbp - 96]
    mov     r10, [rbp - 16]
    mov     r11, [r10 + STMT_EXTRA2]
    mov     rax, rbx
    imul    rax, AST_NAME_SIZE
    add     r11, rax
    mov     r10, [rbp - 48]
    mov     ARG1, [r10 + PLAN_JOIN_AST]
    mov     ARG2, [r11 + AST_NAME_QUAL_PTR]
    mov     ARG3, [r11 + AST_NAME_QUAL_LEN]
    call    join_qualifier_matches
    test    eax, eax
    jz      .col_not_found
    mov     eax, PLAN_PROJ_RIGHT_BIT
    mov     [rbp - 112], rax
    mov     r10, [rbp - 48]
    mov     rax, [r10 + PLAN_RIGHT_SCHEMA]
    mov     [rbp - 120], rax
.proj_join_left:
    mov     rbx, [rbp - 96]
    mov     r10, [rbp - 16]
    mov     r11, [r10 + STMT_EXTRA2]
    mov     rax, rbx
    imul    rax, AST_NAME_SIZE
    add     r11, rax
    mov     rsi, [r11 + AST_NAME_PTR]
    mov     r8, [r11 + AST_NAME_LEN]
.proj_qualifier_ok:

    mov     [rbp - 96], rbx
    mov     ARG1, [rbp - 120]           ; selected schema_ptr
    mov     ARG2, rsi
    mov     ARG3, r8
    lea     ARG4, [rbp - 104]           ; col_idx
    call    schema_find_col
    test    rax, rax
    jz      .col_not_found

    mov     rbx, [rbp - 96]
    mov     rdi, [rbp - 80]
    mov     edx, [rbp - 104]
    or      rdx, [rbp - 112]
    mov     [rdi + rbx * 4], edx
    mov     rdi, [rbp - 88]
    mov     edx, [rax + 0]              ; col_type from col_rec
    mov     [rdi + rbx * 4], edx

    inc     rbx
    cmp     rbx, [rbp - 72]
    jb      .proj_loop

    jmp     .projs_ready

.proj_count_star:
    mov     r10, [rbp - 48]
    or      qword [r10 + PLAN_FLAGS], PLAN_FLAG_COUNT_STAR
    mov     qword [rbp - 72], 1         ; proj_count = 1

    ; Allocate 1 entry for proj_indices (4 bytes)
    mov     ARG1, [rbp - 24]
    mov     ARG2, 4
    call    sql_arena_alloc
    test    rax, rax
    jz      .oom
    mov     [rbp - 80], rax
    mov     dword [rax], 0

    ; Allocate 1 entry for proj_types (4 bytes)
    mov     ARG1, [rbp - 24]
    mov     ARG2, 4
    call    sql_arena_alloc
    test    rax, rax
    jz      .oom
    mov     [rbp - 88], rax
    mov     dword [rax], CAT_INT64

    jmp     .projs_ready

.proj_all:
    ; Project all schema columns
    mov     r12, [rbp - 64]
    mov     ecx, [r12 + CAT_COUNT]
    mov     [rbp - 72], rcx             ; proj_count

    shl     rcx, 2
    mov     ARG2, rcx
    mov     ARG1, [rbp - 24]
    call    sql_arena_alloc
    test    rax, rax
    jz      .oom
    mov     [rbp - 80], rax             ; proj_indices

    mov     rcx, [rbp - 72]
    shl     rcx, 2
    mov     ARG2, rcx
    mov     ARG1, [rbp - 24]
    call    sql_arena_alloc
    test    rax, rax
    jz      .oom
    mov     [rbp - 88], rax             ; proj_types

    xor     ebx, ebx
.all_loop:
    mov     rdi, [rbp - 80]
    mov     [rdi + rbx * 4], ebx
    mov     r12, [rbp - 64]
    mov     rax, rbx
    shl     rax, 5
    mov     edx, [r12 + CAT_COLUMNS + rax]
    mov     rdi, [rbp - 88]
    mov     [rdi + rbx * 4], edx
    inc     rbx
    cmp     rbx, [rbp - 72]
    jb      .all_loop

.projs_ready:
    mov     r10, [rbp - 48]
    mov     rax, [rbp - 72]
    mov     [r10 + PLAN_DATA1], rax     ; proj_count
    mov     rax, [rbp - 80]
    mov     [r10 + PLAN_DATA2], rax     ; proj_indices
    mov     rax, [rbp - 88]
    mov     [r10 + PLAN_DATA3], rax     ; proj_types

    ; ORDER BY can be a vector distance expression or a projected result column.
    mov     r11, [rbp - 16]
    mov     r12, [r11 + SELECT_ORDER_EXPR]
    test    r12, r12
    jnz     .bind_order_vector_expr
    mov     r12, [r11 + SELECT_ORDER_NAME]
    test    r12, r12
    jz      .order_bound
    jmp     .order_name_bind

.bind_order_vector_expr:
    mov     r10, [rbp - 48]             ; plan
    test    qword [r10 + PLAN_FLAGS], PLAN_FLAG_LIMIT
    jz      .err_vector_order_limit
    cmp     qword [r10 + PLAN_LIMIT_VALUE], 0
    jle     .err_vector_order_limit

    mov     ARG1, r12                   ; expr
    mov     ARG2, [rbp - 64]            ; schema_ptr
    mov     ARG3, [rbp - 24]            ; arena
    mov     ARG4, [rbp - 40]            ; out_err
    call    bind_expr
    test    rax, rax
    jz      .fail

    mov     r10, [rbp - 48]             ; plan
    mov     [r10 + PLAN_VECTOR_TOPK_EXPR], rax
    or      qword [r10 + PLAN_FLAGS], PLAN_FLAG_VECTOR_TOPK

    mov     r11, [rbp - 16]             ; ast_select
    mov     rdx, [r11 + SELECT_ORDER_DESC]
    mov     [r10 + PLAN_ORDER_DESC], rdx

    mov     rcx, [rax + BEXPR_COL_IDX]
    bts     qword [r10 + PLAN_REQUIRED_COLS], rcx
    bts     qword [r10 + PLAN_REQUIRED_VALUES], rcx
    jmp     .order_bound

.order_name_bind:
    test    qword [r10 + PLAN_FLAGS], PLAN_FLAG_COUNT_STAR
    jnz     .order_pending
    cmp     qword [r11 + SELECT_PROJ_COUNT], 0
    je      .order_pending
    cmp     qword [r10 + PLAN_JOIN_TYPE], 0
    jne     .order_projection_loop_start
    cmp     qword [r12 + AST_NAME_QUAL_LEN], 0
    je      .order_projection_loop_start
    mov     ARG1, r11
    mov     ARG2, [r12 + AST_NAME_QUAL_PTR]
    mov     ARG3, [r12 + AST_NAME_QUAL_LEN]
    call    qualifier_matches
    test    eax, eax
    jz      .col_not_found
.order_projection_loop_start:
    xor     ebx, ebx
.order_projection_loop:
    cmp     rbx, [rbp - 72]
    jae     .col_not_found
    mov     r11, [rbp - 16]
    mov     rax, rbx
    imul    rax, AST_NAME_SIZE
    add     rax, [r11 + SELECT_PROJECTIONS_PTR]
    mov     [rbp - 96], rax
    mov     ARG1, [r12 + AST_NAME_PTR]
    mov     ARG2, [r12 + AST_NAME_LEN]
    mov     ARG3, [rax + AST_NAME_PTR]
    mov     ARG4, [rax + AST_NAME_LEN]
    call    slice_name_matches
    test    eax, eax
    jz      .order_projection_next
    mov     r10, [rbp - 48]
    cmp     qword [r10 + PLAN_JOIN_TYPE], 0
    je      .order_projection_found
    mov     rax, [rbp - 96]
    mov     ARG1, [r12 + AST_NAME_QUAL_PTR]
    mov     ARG2, [r12 + AST_NAME_QUAL_LEN]
    mov     ARG3, [rax + AST_NAME_QUAL_PTR]
    mov     ARG4, [rax + AST_NAME_QUAL_LEN]
    call    qualifier_name_matches
    test    eax, eax
    jz      .order_projection_next
.order_projection_found:
    mov     r10, [rbp - 48]
    or      qword [r10 + PLAN_FLAGS], PLAN_FLAG_ORDER
    mov     [r10 + PLAN_ORDER_ORDINAL], rbx
    mov     rax, [rbp - 88]
    mov     eax, [rax + rbx * 4]
    mov     [r10 + PLAN_ORDER_TYPE], rax
    mov     r11, [rbp - 16]
    mov     rax, [r11 + SELECT_ORDER_DESC]
    mov     [r10 + PLAN_ORDER_DESC], rax
    cmp     qword [r10 + PLAN_JOIN_TYPE], 0
    jne     .order_pending
    jmp     .order_bound
.order_projection_next:
    inc     rbx
    jmp     .order_projection_loop
.order_bound:

    cmp     qword [r10 + PLAN_JOIN_TYPE], 0
    je      .bind_where

    ; Preserve source-aware descriptors for the join producer, while exposing
    ; compact ordinal slots to the existing result-sink ABI.
    mov     rax, [r10 + PLAN_DATA2]
    mov     [r10 + PLAN_JOIN_PROJECTIONS], rax
    mov     rax, [rbp - 72]
    shl     rax, 2
    mov     ARG1, [rbp - 24]
    mov     ARG2, rax
    call    sql_arena_alloc
    test    rax, rax
    jz      .oom
    mov     r10, [rbp - 48]
    mov     [r10 + PLAN_DATA2], rax
    xor     ecx, ecx
.join_projection_ordinals:
    cmp     rcx, [rbp - 72]
    jae     .join_projection_done
    mov     [rax + rcx * 4], ecx
    inc     rcx
    jmp     .join_projection_ordinals
.join_projection_done:
    mov     r10, [rbp - 48]
    mov     r11, [rbp - 16]
    cmp     qword [r11 + SELECT_WHERE_EXPR], 0
    jne     .join_pending
    mov     qword [r10 + PLAN_DATA4], 0
    mov     qword [r10 + PLAN_REQUIRED_COLS], 0
    mov     qword [r10 + PLAN_REQUIRED_VALUES], 0
    xor     eax, eax
    jmp     .binder_exit

    ; Bind WHERE expression if present
.bind_where:
    mov     r10, [rbp - 16]
    mov     rax, [r10 + STMT_EXTRA3]    ; where_expr AST
    test    rax, rax
    jz      .no_where_bound

    mov     ARG1, rax
    mov     ARG2, [rbp - 16]
    call    validate_expr_namespace
    test    eax, eax
    jz      .col_not_found

    mov     r10, [rbp - 16]
    mov     rax, [r10 + STMT_EXTRA3]

    mov     ARG1, rax
    mov     ARG2, [rbp - 64]            ; schema_ptr
    mov     ARG3, [rbp - 24]            ; arena
    mov     ARG4, [rbp - 40]            ; out_err
    call    bind_expr
    test    rax, rax
    jz      .fail
    mov     r10, [rbp - 48]
    mov     [r10 + PLAN_DATA4], rax     ; bound_expr ptr
    jmp     .select_done

.no_where_bound:
    mov     r10, [rbp - 48]
    mov     qword [r10 + PLAN_DATA4], 0

.select_done:
    ; A lookup returns the rows of a range in key order rather than in row
    ; order. A query that did not ask for an order is not owed one, but an
    ; ORDER BY, a LIMIT and a vector top-K each turn an unstated order into a
    ; different answer, so those keep the scan. A COUNT(*) does not care what
    ; order it counts in.
    mov     r10, [rbp - 48]
    mov     qword [r10 + PLAN_INDEX_ID], 0
    mov     rax, [r10 + PLAN_FLAGS]
    test    rax, PLAN_FLAG_LIMIT | PLAN_FLAG_ORDER | PLAN_FLAG_VECTOR_TOPK
    jnz     .index_not_chosen
    cmp     qword [r10 + PLAN_JOIN_TYPE], 0
    jne     .index_not_chosen
    mov     ARG1, [rbp - 8]
    mov     ARG2, r10
    mov     ARG3, [r10 + PLAN_DATA4]
    call    plan_index_eq
.index_not_chosen:

    mov     r10, [rbp - 48]
    mov     ARG1, [r10 + PLAN_DATA4]
    call    required_expr_columns
    mov     r8, rdx                    ; value references, separately from NULLs
    mov     r10, [rbp - 48]
    test    qword [r10 + PLAN_FLAGS], PLAN_FLAG_COUNT_STAR
    jnz     .count_star_req_done
    mov     r11, [r10 + PLAN_DATA2]
    xor     ecx, ecx
.required_projection:
    mov     edx, [r11 + rcx * 4]
    bts     rax, rdx
    bts     r8, rdx
    inc     rcx
    cmp     rcx, [r10 + PLAN_DATA1]
    jb      .required_projection
.count_star_req_done:
    test    qword [r10 + PLAN_FLAGS], PLAN_FLAG_VECTOR_TOPK
    jz      .req_vector_done
    mov     r11, [r10 + PLAN_VECTOR_TOPK_EXPR]
    mov     rcx, [r11 + BEXPR_COL_IDX]
    bts     rax, rcx
    bts     r8, rcx
.req_vector_done:
    mov     [r10 + PLAN_REQUIRED_COLS], rax
    mov     [r10 + PLAN_REQUIRED_VALUES], r8
    xor     eax, eax
    jmp     .binder_exit

; --- Error Dispatches --------------------------------------------------------
.err_vector_order_limit:
    mov     ARG1, [rbp - 40]
    mov     ARG2, SQL_ERR_SYNTAX
    xor     ARG3, ARG3
    lea     ARG4, [err_vector_order_limit]
    call    set_binder_error
    mov     eax, SQL_ERR_SYNTAX
    jmp     .binder_exit

.join_pending:
    mov     ARG1, [rbp - 40]
    mov     ARG2, SQL_ERR_SYNTAX
    xor     ARG3, ARG3
    lea     ARG4, [err_join_pending]
    call    set_binder_error
    mov     eax, SQL_ERR_SYNTAX
    jmp     .binder_exit

.join_condition_bad:
    mov     ARG1, [rbp - 40]
    mov     ARG2, SQL_ERR_SYNTAX
    xor     ARG3, ARG3
    lea     ARG4, [err_join_condition]
    call    set_binder_error
    mov     eax, SQL_ERR_SYNTAX
    jmp     .binder_exit

.join_namespace_bad:
    mov     ARG1, [rbp - 40]
    mov     ARG2, SQL_ERR_COLUMN_NOT_FOUND
    xor     ARG3, ARG3
    lea     ARG4, [err_col_not_found]
    call    set_binder_error
    mov     eax, SQL_ERR_COLUMN_NOT_FOUND
    jmp     .binder_exit

.join_projection_bad:
    mov     ARG1, [rbp - 40]
    mov     ARG2, SQL_ERR_SYNTAX
    xor     ARG3, ARG3
    lea     ARG4, [err_join_projection]
    call    set_binder_error
    mov     eax, SQL_ERR_SYNTAX
    jmp     .binder_exit

.join_key_type_bad:
    mov     ARG1, [rbp - 40]
    mov     ARG2, SQL_ERR_SYNTAX
    xor     ARG3, ARG3
    lea     ARG4, [err_join_key_type]
    call    set_binder_error
    mov     eax, SQL_ERR_SYNTAX
    jmp     .binder_exit

.order_pending:
    mov     ARG1, [rbp - 40]
    mov     ARG2, SQL_ERR_SYNTAX
    xor     ARG3, ARG3
    lea     ARG4, [err_order_pending]
    call    set_binder_error
    mov     eax, SQL_ERR_SYNTAX
    jmp     .binder_exit

.varlen_pending:
    mov     ARG1, [rbp - 40]
    mov     ARG2, SQL_ERR_SYNTAX
    xor     ARG3, ARG3
    lea     ARG4, [err_varlen_pending]
    call    set_binder_error
    mov     eax, SQL_ERR_SYNTAX
    jmp     .binder_exit

.vector_pending:
    mov     ARG1, [rbp - 40]
    mov     ARG2, SQL_ERR_SYNTAX
    xor     ARG3, ARG3
    lea     ARG4, [err_vector_pending]
    call    set_binder_error
    mov     eax, SQL_ERR_SYNTAX
    jmp     .binder_exit

.bad_tbl_len:
    mov     ARG1, [rbp - 40]
    mov     ARG2, SQL_ERR_SYNTAX
    xor     ARG3, ARG3
    lea     ARG4, [err_tbl_name_len]
    call    set_binder_error
    mov     eax, SQL_ERR_SYNTAX
    jmp     .binder_exit

.bad_col_len:
    mov     ARG1, [rbp - 40]
    mov     ARG2, SQL_ERR_SYNTAX
    xor     ARG3, ARG3
    lea     ARG4, [err_col_name_len]
    call    set_binder_error
    mov     eax, SQL_ERR_SYNTAX
    jmp     .binder_exit

.dup_table:
    mov     ARG1, [rbp - 40]
    mov     ARG2, SQL_ERR_DUPLICATE_TABLE
    xor     ARG3, ARG3
    lea     ARG4, [err_dup_table]
    call    set_binder_error
    mov     eax, SQL_ERR_DUPLICATE_TABLE
    jmp     .binder_exit

.dup_col:
    mov     ARG1, [rbp - 40]
    mov     ARG2, SQL_ERR_DUPLICATE_COLUMN
    xor     ARG3, ARG3
    lea     ARG4, [err_dup_col]
    call    set_binder_error
    mov     eax, SQL_ERR_DUPLICATE_COLUMN
    jmp     .binder_exit

.tbl_not_found:
    mov     ARG1, [rbp - 40]
    mov     ARG2, SQL_ERR_TABLE_NOT_FOUND
    xor     ARG3, ARG3
    lea     ARG4, [err_tbl_not_found]
    call    set_binder_error
    mov     eax, SQL_ERR_TABLE_NOT_FOUND
    jmp     .binder_exit

.col_not_found:
    mov     ARG1, [rbp - 40]
    mov     ARG2, SQL_ERR_COLUMN_NOT_FOUND
    xor     ARG3, ARG3
    lea     ARG4, [err_col_not_found]
    call    set_binder_error
    mov     eax, SQL_ERR_COLUMN_NOT_FOUND
    jmp     .binder_exit

.index_unsupported:
    mov     ARG1, [rbp - 40]
    mov     ARG2, SQL_ERR_TYPE_MISMATCH
    xor     ARG3, ARG3
    lea     ARG4, [err_no_index]
    call    set_binder_error
    mov     eax, SQL_ERR_TYPE_MISMATCH
    jmp     .binder_exit

.index_bad_type:
    mov     ARG1, [rbp - 40]
    mov     ARG2, SQL_ERR_TYPE_MISMATCH
    xor     ARG3, ARG3
    lea     ARG4, [err_index_type]
    call    set_binder_error
    mov     eax, SQL_ERR_TYPE_MISMATCH
    jmp     .binder_exit

.index_not_found:
    mov     ARG1, [rbp - 40]
    mov     ARG2, SQL_ERR_TABLE_NOT_FOUND
    xor     ARG3, ARG3
    lea     ARG4, [err_index_missing]
    call    set_binder_error
    mov     eax, SQL_ERR_TABLE_NOT_FOUND
    jmp     .binder_exit

.queue_unsupported:
    mov     ARG1, [rbp - 40]
    mov     ARG2, SQL_ERR_TYPE_MISMATCH
    xor     ARG3, ARG3
    lea     ARG4, [err_no_queue]
    call    set_binder_error
    mov     eax, SQL_ERR_TYPE_MISMATCH
    jmp     .binder_exit

.queue_not_found:
    mov     ARG1, [rbp - 40]
    mov     ARG2, SQL_ERR_TABLE_NOT_FOUND
    xor     ARG3, ARG3
    lea     ARG4, [err_queue_missing]
    call    set_binder_error
    mov     eax, SQL_ERR_TABLE_NOT_FOUND
    jmp     .binder_exit
.stream_unsupported:
    mov     ARG1, [rbp - 40]
    mov     ARG2, SQL_ERR_TYPE_MISMATCH
    xor     ARG3, ARG3
    lea     ARG4, [err_no_stream]
    call    set_binder_error
    mov     eax, SQL_ERR_TYPE_MISMATCH
    jmp     .binder_exit
.stream_not_found:
    mov     ARG1, [rbp - 40]
    mov     ARG2, SQL_ERR_TABLE_NOT_FOUND
    xor     ARG3, ARG3
    lea     ARG4, [err_stream_missing]
    call    set_binder_error
    mov     eax, SQL_ERR_TABLE_NOT_FOUND
    jmp     .binder_exit
.cursor_name_len:
    mov     ARG1, [rbp - 40]
    mov     ARG2, SQL_ERR_SYNTAX
    xor     ARG3, ARG3
    lea     ARG4, [err_cursor_name]
    call    set_binder_error
    mov     eax, SQL_ERR_SYNTAX
    jmp     .binder_exit

.queue_bad_payload:
    mov     ARG1, [rbp - 40]
    mov     ARG2, SQL_ERR_TYPE_MISMATCH
    xor     ARG3, ARG3
    lea     ARG4, [err_queue_payload]
    call    set_binder_error
    mov     eax, SQL_ERR_TYPE_MISMATCH
    jmp     .binder_exit

.queue_too_long:
    mov     ARG1, [rbp - 40]
    mov     ARG2, SQL_ERR_TYPE_MISMATCH
    xor     ARG3, ARG3
    lea     ARG4, [err_queue_long]
    call    set_binder_error
    mov     eax, SQL_ERR_TYPE_MISMATCH
    jmp     .binder_exit

.bad_val_count:
    mov     ARG1, [rbp - 40]
    mov     ARG2, SQL_ERR_VALUE_COUNT
    xor     ARG3, ARG3
    lea     ARG4, [err_val_count]
    call    set_binder_error
    mov     eax, SQL_ERR_VALUE_COUNT
    jmp     .binder_exit

.type_mismatch:
    mov     ARG1, [rbp - 40]
    mov     ARG2, SQL_ERR_TYPE_MISMATCH
    xor     ARG3, ARG3
    lea     ARG4, [err_type_mismatch]
    call    set_binder_error
    mov     eax, SQL_ERR_TYPE_MISMATCH
    jmp     .binder_exit

.not_nullable:
    mov     ARG1, [rbp - 40]
    mov     ARG2, SQL_ERR_NOT_NULLABLE
    xor     ARG3, ARG3
    lea     ARG4, [err_not_nullable]
    call    set_binder_error
    mov     eax, SQL_ERR_NOT_NULLABLE
    jmp     .binder_exit

.oom:
    mov     ARG1, [rbp - 40]
    mov     ARG2, SQL_ERR_NO_STORAGE
    xor     ARG3, ARG3
    lea     ARG4, [err_oom]
    call    set_binder_error
    mov     eax, SQL_ERR_NO_STORAGE
    jmp     .binder_exit

.fail:
    mov     eax, SQL_ERR_SYNTAX
    jmp     .binder_exit

.binder_exit:
    mov     rbx, [rbp - 136]
    mov     r12, [rbp - 144]
    mov     r13, [rbp - 152]
    mov     r14, [rbp - 160]
    mov     r15, [rbp - 168]
    mov     rsi, [rbp - 176]
    mov     rdi, [rbp - 184]
    FRAME_END
    ret

; Return the union of physical column references in a successfully bound tree.
; --- CHOOSE AN INDEX ---------------------------------------------------------
; A SELECT whose whole predicate is one comparison against an indexed column
; can find its rows through the tree instead of by reading the whole table.
;
; Every shape it takes becomes the same thing: a pair of inclusive bounds. An
; equality is the pair where both are the key; a range leaves one side at the
; extreme of what a key can be, and a strict side moves in by one. That is why
; `> the largest key there is` and `< the smallest` are refused here rather
; than represented - they are empty, and an empty pair is not a pair.
;
; Nothing here changes what the query returns. The rows the tree names are read
; and the predicate is evaluated over them exactly as a scan would: an index is
; an access path, and a wrong one has to cost time rather than answers.
;
; Locals: [rbp-8]=ctx, [rbp-16]=plan, [rbp-24]=predicate, [rbp-32]=id walked
;         past, [rbp-40]=this index's id, [rbp-48]=lo, [rbp-56]=hi
plan_index_eq:
    FRAME_BEGIN 64, 0
    mov [rbp - 8], ARG1                 ; ctx
    mov [rbp - 16], ARG2                ; plan
    mov [rbp - 24], ARG3                ; bound predicate, or zero
    mov r10, ARG1
    test qword [r10 + DB_FEATURES], CybouDB_FEATURE_INDEX
    jz .no
    mov r11, ARG3
    test r11, r11
    jz .no
    cmp qword [r11 + BEXPR_KIND], BEXPR_COMPARE_COL_LIT
    jne .no
    mov rax, [r11 + BEXPR_COL_TYPE]
    cmp rax, CAT_INT32
    je .type_ok
    cmp rax, CAT_INT64
    jne .no
.type_ok:

    ; The key, sign-extended the way the tree orders it.
    mov rdx, [r11 + BEXPR_LIT_VAL]
    cmp qword [r11 + BEXPR_COL_TYPE], CAT_INT32
    jne .key_ready
    movsxd rdx, edx
.key_ready:
    mov rax, 0x8000000000000000
    mov [rbp - 48], rax                 ; nothing sorts below this
    not rax
    mov [rbp - 56], rax                 ; nor above this
    mov rcx, [r11 + BEXPR_OP]
    cmp rcx, OP_EQ
    je .bound_eq
    cmp rcx, OP_GTE
    je .bound_from
    cmp rcx, OP_GT
    je .bound_after
    cmp rcx, OP_LTE
    je .bound_to
    cmp rcx, OP_LT
    je .bound_below
    jmp .no                             ; <> names everything but one key
.bound_eq:
    mov [rbp - 48], rdx
    mov [rbp - 56], rdx
    jmp .bounds_ready
.bound_from:
    mov [rbp - 48], rdx
    jmp .bounds_ready
.bound_after:
    cmp rdx, [rbp - 56]
    je .no                              ; above the largest key there is
    inc rdx
    mov [rbp - 48], rdx
    jmp .bounds_ready
.bound_to:
    mov [rbp - 56], rdx
    jmp .bounds_ready
.bound_below:
    cmp rdx, [rbp - 48]
    je .no                              ; below the smallest key there is
    dec rdx
    mov [rbp - 56], rdx
.bounds_ready:

    ; An index of this table, over this column.
    mov r10, [rbp - 16]
    mov qword [rbp - 32], 0             ; the id walked past so far
.next_index:
    mov ARG1, [rbp - 8]
    mov r11, [rbp - 16]
    mov ARG2, [r11 + PLAN_TABLE_ID]
    mov ARG3, [rbp - 32]
    lea ARG4, [rbp - 40]
    call db_index_of_table
    test rax, rax
    jz .no
    mov r11, [rbp - 24]
    mov ecx, [rax + IDX_COLUMN]
    cmp rcx, [r11 + BEXPR_COL_IDX]
    jne .skip

    mov r10, [rbp - 16]
    mov rax, [rbp - 40]
    mov [r10 + PLAN_INDEX_ID], rax
    mov rax, [r11 + BEXPR_COL_IDX]
    mov [r10 + PLAN_INDEX_COL], rax
    mov rax, [rbp - 48]
    mov [r10 + PLAN_INDEX_LO], rax
    mov rax, [rbp - 56]
    mov [r10 + PLAN_INDEX_HI], rax
    or qword [r10 + PLAN_FLAGS], PLAN_FLAG_INDEX_SEEK
    mov eax, 1
    FRAME_END
    ret
.skip:
    mov rax, [rbp - 40]
    mov [rbp - 32], rax
    jmp .next_index
.no:
    xor eax, eax
    FRAME_END
    ret

; The binder has already checked indices (0..63) and node kinds.
required_expr_columns:
    FRAME_BEGIN 32, 0
    xor     eax, eax
    xor     edx, edx
    test    ARG1, ARG1
    jz      .done
    mov     r10, ARG1
    mov     rcx, [r10 + BEXPR_KIND]
    cmp     rcx, BEXPR_NOT
    je      .unary
    cmp     rcx, BEXPR_AND
    je      .binary
    cmp     rcx, BEXPR_OR
    je      .binary
    mov     rcx, [r10 + BEXPR_COL_IDX]
    bts     rax, rcx
    cmp     qword [r10 + BEXPR_KIND], BEXPR_COMPARE_COL_LIT
    jne     .done
    mov     rdx, rax
    jmp     .done
.unary:
    mov     ARG1, [r10 + BEXPR_LEFT]
    call    required_expr_columns
    jmp     .done
.binary:
    mov     rax, [r10 + BEXPR_RIGHT]
    mov     [rbp - 8], rax
    mov     ARG1, [r10 + BEXPR_LEFT]
    call    required_expr_columns
    mov     [rbp - 16], rax
    mov     [rbp - 24], rdx
    mov     ARG1, [rbp - 8]
    call    required_expr_columns
    or      rax, [rbp - 16]
    or      rdx, [rbp - 24]
.done:
    FRAME_END
    ret

%ifdef CybouDB_LINUX
section .note.GNU-stack noalloc noexec nowrite progbits
%endif
