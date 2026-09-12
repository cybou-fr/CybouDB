; Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
; SPDX-License-Identifier: Apache-2.0
; =============================================================================
;  src/sql/executor.asm - Batch SQL Plan Executor (CREATE, INSERT, SELECT; UPDATE gated)
; =============================================================================

%include "sql.inc"
%include "order_executor.inc"
%include "select_cursor.inc"
%include "vector.inc"

BITS 64
default rel

; Frame storage a predicated DELETE stages surviving rows in, below every
; other local. Seventeen bytes per cell - eight of value, eight of varlen
; length, one of NULL - so the whole region divides once and every array is a
; fixed address. A fixed-width table never reads the lengths, and pays for
; them in staged rows per append rather than in correctness. The borrowed
; batch views sit in the same region. Deliberately not arena storage: an
; embedder's statement arena is small, and how many rows a DELETE can stage at
; a time should not depend on how much of it the plan happened to use.
%define DELETE_SCRATCH_BASE  36864                  ; lowest frame offset used
%define DELETE_VIEW_OFF      DELETE_SCRATCH_BASE    ; borrowed batch views
%define DELETE_VALUES_OFF    35320                  ; DELETE_VIEW_OFF - 1544
%define DELETE_SCRATCH_CELLS 1957                   ; (35320 - 2052) / 17
%define DELETE_LENGTHS_OFF   19664                  ; VALUES_OFF - CELLS * 8
%define DELETE_NULLS_OFF     4008                   ; LENGTHS_OFF - CELLS * 8

extern db_catalog_put, db_catalog_drop, db_catalog_truncate_data, db_pax_insert, db_pax_update_one, db_pax_capacity, db_commit, db_rollback
extern db_catalog_get, db_pax_scan_open_bound, db_pax_scan_batch
extern db_var_write_chain, db_var_read_chain
extern sql_select_open, sql_select_next
extern sql_arena_alloc
extern sql_join_execute
extern sql_order_init, sql_order_collect, sql_order_emit
extern vector_topk_init
extern vector_topk_cosine_begin, vector_topk_cosine_feed, vector_topk_cosine_finish
extern vector_topk_l2sq_begin, vector_topk_l2sq_feed, vector_topk_l2sq_finish
extern cyboudb_vector_normalize_f32
extern for8_eq, for8_ne, for8_lt, for8_le, for8_gt, for8_ge
extern for16_eq, for16_ne, for16_lt, for16_le, for16_gt, for16_ge
global sql_execute_batch
global eval_predicate
global eval_predicate_encoded

section .text

; -----------------------------------------------------------------------------
;  eval_predicate(bexpr, rows, batch_view) -> RAX: true_mask, RDX: unknown_mask
;
;  Evaluates predicate using three-valued logic (3VL).
;  In columnar layout, column values are accessed directly from mapped PAX page
;  memory via batch_view->columns[col_idx].values_ptr, and nulls are tested
;  via batch_view->columns[col_idx].null_mask.
;
;  Local slots:
;    [rbp - 8]   = bexpr
;    [rbp - 16]  = rows (1..64)
;    [rbp - 24]  = batch_view
;    [rbp - 32]  = active_mask
;    [rbp - 40]  = L_true (for AND/OR)
;    [rbp - 48]  = L_unk
;    [rbp - 56]  = final_true
; -----------------------------------------------------------------------------
eval_predicate:
    xor     ARG4, ARG4
eval_predicate_encoded:
    FRAME_BEGIN 96, 0
    mov     [rbp - 64], ARG4            ; optional private encoding views
    mov     [rbp - 8], ARG1             ; bexpr
    mov     [rbp - 16], ARG2            ; rows (1..64)
    mov     [rbp - 24], ARG3            ; batch_view

    ; Compute active_mask for 1..64 rows
    mov     rcx, [rbp - 16]
    cmp     rcx, 64
    jae     .all_ones
    mov     rax, 1
    shl     rax, cl
    dec     rax
    jmp     .mask_ready
.all_ones:
    mov     rax, -1
.mask_ready:
    mov     [rbp - 32], rax             ; active_mask

    cmp     qword [rbp - 8], 0
    jnz     .have_expr

    ; No WHERE filter: all rows pass, no unknown rows
    mov     rax, [rbp - 32]
    xor     edx, edx
    jmp     .eval_exit

.have_expr:
    mov     r10, [rbp - 8]
    mov     rax, [r10 + BEXPR_KIND]

    cmp     rax, BEXPR_AND
    je      .eval_and
    cmp     rax, BEXPR_OR
    je      .eval_or
    cmp     rax, BEXPR_NOT
    je      .eval_not
    cmp     rax, BEXPR_IS_NULL
    je      .eval_is_null
    cmp     rax, BEXPR_IS_NOT_NULL
    je      .eval_is_not_null
    cmp     rax, BEXPR_COMPARE_NULL_LIT
    je      .eval_comp_null_lit
    cmp     rax, BEXPR_COMPARE_COL_LIT
    je      .eval_compare

    ; Unknown expression kind: all false
    xor     eax, eax
    xor     edx, edx
    jmp     .eval_exit

; --- BEXPR_AND ---------------------------------------------------------------
.eval_and:
    mov     r10, [rbp - 8]
    mov     ARG1, [r10 + BEXPR_LEFT]
    mov     ARG2, [rbp - 16]
    mov     ARG3, [rbp - 24]
    mov     ARG4, [rbp - 64]
    call    eval_predicate_encoded
    mov     [rbp - 40], rax             ; L_true
    mov     [rbp - 48], rdx             ; L_unk

    mov     r10, [rbp - 8]
    mov     ARG1, [r10 + BEXPR_RIGHT]
    mov     ARG2, [rbp - 16]
    mov     ARG3, [rbp - 24]
    mov     ARG4, [rbp - 64]
    call    eval_predicate_encoded
    mov     r8, rax                     ; R_true
    mov     r9, rdx                     ; R_unk

    ; true_mask = L_true & R_true
    mov     rax, [rbp - 40]
    and     rax, r8
    mov     [rbp - 56], rax

    ; 3VL: neither_false = (L_true | L_unk) & (R_true | R_unk)
    mov     r10, [rbp - 40]
    or      r10, [rbp - 48]
    mov     r11, r8
    or      r11, r9
    and     r10, r11

    ; unknown_mask = neither_false & ~true_mask
    mov     rdx, [rbp - 56]
    not     rdx
    and     rdx, r10

    mov     rax, [rbp - 56]
    jmp     .eval_exit

; --- BEXPR_OR ----------------------------------------------------------------
.eval_or:
    mov     r10, [rbp - 8]
    mov     ARG1, [r10 + BEXPR_LEFT]
    mov     ARG2, [rbp - 16]
    mov     ARG3, [rbp - 24]
    mov     ARG4, [rbp - 64]
    call    eval_predicate_encoded
    mov     [rbp - 40], rax             ; L_true
    mov     [rbp - 48], rdx             ; L_unk

    mov     r10, [rbp - 8]
    mov     ARG1, [r10 + BEXPR_RIGHT]
    mov     ARG2, [rbp - 16]
    mov     ARG3, [rbp - 24]
    mov     ARG4, [rbp - 64]
    call    eval_predicate_encoded
    mov     r8, rax                     ; R_true
    mov     r9, rdx                     ; R_unk

    ; true_mask = L_true | R_true
    mov     rax, [rbp - 40]
    or      rax, r8
    mov     [rbp - 56], rax

    ; 3VL: unknown_mask = (L_unk | R_unk) & ~true_mask
    mov     r10, [rbp - 48]
    or      r10, r9
    mov     rdx, [rbp - 56]
    not     rdx
    and     rdx, r10

    mov     rax, [rbp - 56]
    jmp     .eval_exit

; --- BEXPR_NOT ---------------------------------------------------------------
.eval_not:
    mov     r10, [rbp - 8]
    mov     ARG1, [r10 + BEXPR_LEFT]
    mov     ARG2, [rbp - 16]
    mov     ARG3, [rbp - 24]
    mov     ARG4, [rbp - 64]
    call    eval_predicate_encoded
    ; RAX = C_true, RDX = C_unk
    ; 3VL: new_unknown = C_unk
    ;      new_true = ~(C_true | C_unk) & active_mask
    mov     r8, rax
    or      r8, rdx
    not     r8
    and     r8, [rbp - 32]
    mov     rax, r8
    jmp     .eval_exit

; --- BEXPR_IS_NULL -----------------------------------------------------------
.eval_is_null:
    mov     r10, [rbp - 8]
    mov     rax, [r10 + BEXPR_COL_IDX]
    imul    rax, CybouDB_COLVIEW_SIZE
    add     rax, [rbp - 24]             ; + batch_view
    add     rax, BATCH_VIEW_COLUMNS
    mov     rax, [rax + COLVIEW_NULL_MASK]
    and     rax, [rbp - 32]             ; & active_mask
    xor     edx, edx                    ; IS NULL is never unknown
    jmp     .eval_exit

; --- BEXPR_IS_NOT_NULL -------------------------------------------------------
.eval_is_not_null:
    mov     r10, [rbp - 8]
    mov     rax, [r10 + BEXPR_COL_IDX]
    imul    rax, CybouDB_COLVIEW_SIZE
    add     rax, [rbp - 24]             ; + batch_view
    add     rax, BATCH_VIEW_COLUMNS
    mov     rax, [rax + COLVIEW_NULL_MASK]
    not     rax
    and     rax, [rbp - 32]             ; & active_mask
    xor     edx, edx                    ; IS NOT NULL is never unknown
    jmp     .eval_exit

; --- BEXPR_COMPARE_NULL_LIT --------------------------------------------------
.eval_comp_null_lit:
    ; Comparison with NULL literal (e.g. col = NULL) is always UNKNOWN in 3VL
    xor     eax, eax
    mov     rdx, [rbp - 32]             ; all active rows unknown
    jmp     .eval_exit


; --- BEXPR_COMPARE_COL_LIT ---------------------------------------------------
.eval_compare:
    mov     r10, [rbp - 8]
    mov     rax, [r10 + BEXPR_COL_IDX]
    imul    rax, CybouDB_COLVIEW_SIZE
    add     rax, [rbp - 24]             ; + batch_view
    add     rax, BATCH_VIEW_COLUMNS     ; pointer to CybouDB_COLVIEW

    mov     r11, rax                    ; mapped column view
    mov     r9, [rbp - 64]
    test    r9, r9
    jz      .compare_typed
    mov     rcx, [r10 + BEXPR_COL_IDX]
    shl     rcx, 4
    add     r9, rcx
    ; Extract low-byte kind from META (high bits hold first_row for FOR8/16)
    movzx   rax, byte [r9 + PAX_ENC_META]
    test    rax, rax
    je      .compare_typed
    mov     rcx, [r11 + COLVIEW_NULL_MASK]
    and     rcx, [rbp - 32]
    mov     [rbp - 80], rcx             ; original NULL lanes remain UNKNOWN
    cmp     rax, PAX_ENC_KIND_BOOL
    je      .compare_packed_bool
    cmp     rax, PAX_ENC_KIND_FOR8
    je      .compare_for8
    cmp     rax, PAX_ENC_KIND_FOR16
    je      .compare_for16
    ; kind == PAX_ENC_KIND_CONST: one active lane
    lea     ARG1, [r9 + PAX_ENC_DATA]
    xor     ARG2, ARG2
    mov     ARG3, 1
    mov     ARG4, [r10 + BEXPR_LIT_VAL]
    call    [r10 + BEXPR_KERNEL]
    neg     rax                        ; broadcast the one-bit answer
    jmp     .encoded_masks
.compare_packed_bool:
    ; Resolve the predicate for FALSE and TRUE once, not for 64 decoded bytes.
    mov     qword [rbp - 72], 0x100     ; two byte values: false, true
    lea     ARG1, [rbp - 72]
    xor     ARG2, ARG2
    mov     ARG3, 3
    mov     ARG4, [r10 + BEXPR_LIT_VAL]
    call    [r10 + BEXPR_KERNEL]
    mov     r10, [rbp - 8]
    mov     rcx, [r10 + BEXPR_COL_IDX]
    shl     rcx, 4
    add     rcx, [rbp - 64]
    mov     r11, [rcx + PAX_ENC_DATA]
    xor     r8d, r8d
    test    al, 1
    jz      .bool_true
    mov     r8, r11
    not     r8
.bool_true:
    test    al, 2
    jz      .bool_masks
    or      r8, r11
.bool_masks:
    mov     rax, r8
.encoded_masks:
    mov     rdx, [rbp - 80]
    mov     rcx, rdx
    not     rcx
    and     rax, rcx
    and     rax, [rbp - 32]
    jmp     .eval_exit

; ---- FOR8 direct predicate ---------------------------------------------------
; At entry: r9 = enc_view ptr, r10 = bexpr ptr, [rbp-80] = null_active_mask
; Uses scratch slots [rbp-88] and [rbp-96].
.compare_for8:
    ; stream = DATA, first_row = META >> 8
    mov     r8, [r9 + PAX_ENC_DATA]     ; r8 = FOR stream header ptr
    mov     rax, [r9 + PAX_ENC_META]
    shr     rax, 8                      ; first_row
    add     r8, 16                      ; skip header
    add     r8, rax                     ; + first_row (bytes for FOR8)
    mov     [rbp - 88], r8              ; save delta_ptr

    ; base = signed qword at stream header
    mov     r8, [r9 + PAX_ENC_DATA]
    mov     r8, [r8]                    ; base (sign-extended int64)
    mov     rax, [r10 + BEXPR_LIT_VAL]  ; literal

    ; signed compare: literal vs base
    cmp     rax, r8
    jl      .for8_lit_below_base        ; literal < base
    sub     rax, r8                     ; delta = unsigned(literal - base)
    cmp     rax, 255                    ; fits in uint8?
    ja      .for8_lit_above_max

    ; delta in [0..255]: call the right kernel
    mov     [rbp - 96], rax             ; save delta
    mov     ARG1, [rbp - 88]            ; delta_ptr
    mov     ARG2, [r11 + COLVIEW_NULL_MASK]   ; null_mask (r11 = colview)
    mov     ARG3, [rbp - 32]            ; active_mask
    mov     ARG4, [rbp - 96]            ; literal_delta

    mov     rax, [r10 + BEXPR_OP]
    cmp     rax, OP_EQ
    je      .for8_call_eq
    cmp     rax, OP_NEQ
    je      .for8_call_ne
    cmp     rax, OP_LT
    je      .for8_call_lt
    cmp     rax, OP_LTE
    je      .for8_call_le
    cmp     rax, OP_GT
    je      .for8_call_gt
    cmp     rax, OP_GTE
    je      .for8_call_ge
    jmp     .compare_typed              ; unknown op: fall back

.for8_call_eq:  call for8_eq
    jmp .for8_done
.for8_call_ne:  call for8_ne
    jmp .for8_done
.for8_call_lt:  call for8_lt
    jmp .for8_done
.for8_call_le:  call for8_le
    jmp .for8_done
.for8_call_gt:  call for8_gt
    jmp .for8_done
.for8_call_ge:  call for8_ge
.for8_done:
    ; RAX=true_mask, RDX=unknown_mask from kernel -- jump directly out
    jmp     .eval_exit

.for8_lit_below_base:
    ; literal < base: all values v >= base > literal
    ; EQ / LT / LTE: false
    ; GT / GTE / NEQ: true
    mov     rax, [r10 + BEXPR_OP]
    cmp     rax, OP_EQ
    je      .for_all_false
    cmp     rax, OP_LT
    je      .for_all_false
    cmp     rax, OP_LTE
    je      .for_all_false
    ; GT / GTE / NEQ: all active non-null rows satisfy the predicate
    jmp     .for_all_true_nonnull

.for8_lit_above_max:
    ; delta > 255: all values v <= base + 255 < literal
    ; EQ / GT / GTE: false
    ; LT / LTE / NEQ: true
    mov     rax, [r10 + BEXPR_OP]
    cmp     rax, OP_EQ
    je      .for_all_false
    cmp     rax, OP_GT
    je      .for_all_false
    cmp     rax, OP_GTE
    je      .for_all_false
    jmp     .for_all_true_nonnull

; ---- FOR16 direct predicate --------------------------------------------------
.compare_for16:
    mov     r8, [r9 + PAX_ENC_DATA]
    mov     rax, [r9 + PAX_ENC_META]
    shr     rax, 8                      ; first_row
    add     r8, 16
    shl     rax, 1                      ; first_row * 2 (bytes for FOR16)
    add     r8, rax
    mov     [rbp - 88], r8

    mov     r8, [r9 + PAX_ENC_DATA]
    mov     r8, [r8]
    mov     rax, [r10 + BEXPR_LIT_VAL]

    cmp     rax, r8
    jl      .for16_lit_below_base
    sub     rax, r8
    cmp     rax, 65535
    ja      .for16_lit_above_max

    mov     [rbp - 96], rax
    mov     ARG1, [rbp - 88]
    mov     ARG2, [r11 + COLVIEW_NULL_MASK]
    mov     ARG3, [rbp - 32]
    mov     ARG4, [rbp - 96]

    mov     rax, [r10 + BEXPR_OP]
    cmp     rax, OP_EQ
    je      .for16_call_eq
    cmp     rax, OP_NEQ
    je      .for16_call_ne
    cmp     rax, OP_LT
    je      .for16_call_lt
    cmp     rax, OP_LTE
    je      .for16_call_le
    cmp     rax, OP_GT
    je      .for16_call_gt
    cmp     rax, OP_GTE
    je      .for16_call_ge
    jmp     .compare_typed

.for16_call_eq:  call for16_eq
    jmp .for16_done
.for16_call_ne:  call for16_ne
    jmp .for16_done
.for16_call_lt:  call for16_lt
    jmp .for16_done
.for16_call_le:  call for16_le
    jmp .for16_done
.for16_call_gt:  call for16_gt
    jmp .for16_done
.for16_call_ge:  call for16_ge
.for16_done:
    jmp     .eval_exit

.for16_lit_below_base:
    ; literal < base: all values v >= base > literal
    ; EQ / LT / LTE: false
    ; GT / GTE / NEQ: true
    mov     rax, [r10 + BEXPR_OP]
    cmp     rax, OP_EQ
    je      .for_all_false
    cmp     rax, OP_LT
    je      .for_all_false
    cmp     rax, OP_LTE
    je      .for_all_false
    jmp     .for_all_true_nonnull

.for16_lit_above_max:
    ; delta > 65535: all values v <= base + 65535 < literal
    ; EQ / GT / GTE: false
    ; LT / LTE / NEQ: true
    mov     rax, [r10 + BEXPR_OP]
    cmp     rax, OP_EQ
    je      .for_all_false
    cmp     rax, OP_GT
    je      .for_all_false
    cmp     rax, OP_GTE
    je      .for_all_false
    jmp     .for_all_true_nonnull

; ---- FOR shortcircuit helpers ------------------------------------------------
.for_all_false:
    xor     eax, eax                    ; true_mask = 0
    mov     rdx, [rbp - 80]             ; unknown_mask = original null lanes
    jmp     .eval_exit

.for_all_true_nonnull:
    ; true_mask = active & ~null_mask
    mov     rax, [r11 + COLVIEW_NULL_MASK]
    not     rax
    and     rax, [rbp - 32]
    mov     rdx, [rbp - 80]             ; unknown_mask = null lanes
    jmp     .eval_exit

.compare_typed:
    mov     ARG1, [r11 + COLVIEW_VALUES_PTR]
    mov     ARG2, [r11 + COLVIEW_NULL_MASK]
    mov     ARG3, [rbp - 32]            ; active lanes
    mov     ARG4, [r10 + BEXPR_LIT_VAL]
    call    [r10 + BEXPR_KERNEL]        ; returns true_mask and unknown_mask

.eval_exit:
    FRAME_END
    ret



; -----------------------------------------------------------------------------
;  sql_execute_batch(db, plan, arena, batch_cb, cb_ctx, out_err)
;  batch_cb(ctx, batch_view, projection, selection_mask) returns one of
;  CybouDB_SINK_CONTINUE, CybouDB_SINK_STOP or CybouDB_SINK_ERROR. Only nonempty
;  selections are delivered. Stopping is successful completion; any other
;  nonzero answer means the sink itself failed and the statement fails with it.
; -----------------------------------------------------------------------------
sql_execute_batch:
    FRAME_BEGIN DELETE_SCRATCH_BASE, 1
    mov     [rbp - 8], ARG1
    mov     [rbp - 16], ARG2
    mov     [rbp - 24], ARG3
    mov     [rbp - 32], ARG4
    mov     rax, IN_ARG5
    mov     [rbp - 40], rax
    mov     rax, IN_ARG6
    mov     [rbp - 128], rax
    SQL_CLEAR_ERROR rax
    mov     qword [rbp - 136], SQL_DOMAIN_SQL
    mov     r10, [rbp - 16]
    mov     rax, [r10 + PLAN_TYPE]
    cmp     rax, STMT_CREATE_TABLE
    je      .exec_create
    cmp     rax, STMT_INSERT
    je      .exec_insert
    cmp     rax, STMT_SELECT
    je      .exec_select
    cmp     rax, STMT_UPDATE
    je      .exec_update
    cmp     rax, STMT_DROP_TABLE
    je      .exec_drop
    cmp     rax, STMT_DELETE
    je      .exec_delete
    cmp     rax, STMT_BEGIN
    je      .exec_begin
    cmp     rax, STMT_COMMIT
    je      .exec_commit
    cmp     rax, STMT_ROLLBACK
    je      .exec_rollback
    mov     eax, SQL_ERR_SYNTAX
    jmp     .exec_exit

.exec_begin:
    mov     r10, [rbp - 8]              ; db
    cmp     qword [r10 + DB_WRITABLE], 1
    jne     .begin_readonly
    cmp     qword [r10 + DB_TX_ACTIVE], 0
    jne     .begin_already_active
    mov     qword [r10 + DB_TX_ACTIVE], 1
    inc     qword [r10 + DB_TX_ID]
    xor     eax, eax
    jmp     .exec_exit

.begin_readonly:
    lea     r11, [exec_readonly_tx_msg]
    jmp     .custom_exec_err

.begin_already_active:
    lea     r11, [exec_active_tx_msg]
    jmp     .custom_exec_err

.exec_commit:
    mov     r10, [rbp - 8]              ; db
    cmp     qword [r10 + DB_TX_ACTIVE], 0
    je      .commit_no_active
    mov     ARG1, r10
    call    db_commit
    mov     r10, [rbp - 8]
    mov     qword [r10 + DB_TX_ACTIVE], 0
    test    rax, rax
    jnz     .storage_done
    xor     eax, eax
    jmp     .exec_exit

.commit_no_active:
    lea     r11, [exec_no_active_tx_commit_msg]
    jmp     .custom_exec_err

.exec_rollback:
    mov     r10, [rbp - 8]              ; db
    cmp     qword [r10 + DB_TX_ACTIVE], 0
    je      .rollback_no_active
    mov     ARG1, r10
    call    db_rollback
    mov     r10, [rbp - 8]
    mov     qword [r10 + DB_TX_ACTIVE], 0
    test    rax, rax
    jnz     .storage_done
    xor     eax, eax
    jmp     .exec_exit

.rollback_no_active:
    lea     r11, [exec_no_active_tx_rollback_msg]
    jmp     .custom_exec_err

.custom_exec_err:
    mov     r10, [rbp - 128]            ; out_err
    test    r10, r10
    jz      .custom_err_done
    mov     qword [r10 + SQL_ERR_CODE], SQL_ERR_EXEC
    mov     qword [r10 + SQL_ERR_DOMAIN], SQL_DOMAIN_SQL
    xor     ecx, ecx
.copy_custom_err:
    mov     dl, [r11 + rcx]
    mov     [r10 + SQL_ERR_MSG + rcx], dl
    inc     ecx
    test    dl, dl
    jnz     .copy_custom_err
.custom_err_done:
    mov     eax, SQL_ERR_EXEC
    FRAME_END
    ret

; DELETE. Without a predicate the table is truncated; with one, the rows the
; predicate does not select are rewritten into a fresh graph. Either way an
; empty result stages nothing, so the generation does not move on a DELETE
; that removed no rows.
;
; Extra locals, all below the SELECT cursor at [rbp-1728]:
;   [rbp-1736] schema page id    [rbp-1744] schema address
;   [rbp-1752] rows in the table [rbp-1760] batch view
;   [rbp-1768] decode storage    [rbp-1776] matching rows
;   [rbp-1784] columns           [rbp-1792] all-columns request mask
;   [rbp-1800] rows per leaf     [rbp-1808] rows per staged chunk
;   [rbp-1824] values scratch    [rbp-1832] NULL scratch
;   [rbp-1840] rows in the buffer
;   [rbp-1848] rows in the batch [rbp-1856] surviving lanes
;   [rbp-1864] lane being copied [rbp-1872] first cell of that row
;   [rbp-1880] varlen length scratch
;   [rbp-1984] scan cursor (80)  [rbp-2048] insert batch descriptor (40)
.exec_delete:
    ; The row count comes from the catalog rather than the plan: a prepared
    ; DELETE may be stepped again after other statements changed the table.
    mov     ARG1, [rbp - 8]
    mov     ARG2, [r10 + PLAN_TABLE_ID]
    lea     ARG3, [rbp - 1736]
    call    db_catalog_get
    test    eax, eax
    jnz     .storage_done
    mov     r10, [rbp - 8]
    mov     rax, [rbp - 1736]
    shl     rax, CybouDB_PAGE_SHIFT
    add     rax, [r10 + DB_BASE]
    mov     [rbp - 1744], rax
    mov     rcx, [rax + CAT_TABLE_ROWS]
    mov     [rbp - 1752], rcx
    mov     r10, [rbp - 16]
    mov     qword [r10 + PLAN_DELETE_ROWS], 0
    test    rcx, rcx
    jz      .exec_delete_none
    cmp     qword [r10 + PLAN_DATA4], 0
    jne     .exec_delete_where
    mov     [r10 + PLAN_DELETE_ROWS], rcx

.exec_delete_truncate:
    mov     ARG1, [rbp - 8]
    mov     r10, [rbp - 16]
    mov     ARG2, [r10 + PLAN_TABLE_ID]
    call    db_catalog_truncate_data
    jmp     .storage_done

.exec_delete_none:
    xor     eax, eax
    jmp     .exec_exit

    ; --- Pass 1: how many rows match --------------------------------------
    ; Counting first keeps the no-match case free of staged pages, and tells
    ; the rewrite whether truncation alone would do.
.exec_delete_where:
    lea     rax, [rbp - DELETE_VIEW_OFF]
    mov     [rbp - 1760], rax
    mov     qword [rbp - 1768], 0
    mov     r11, [rbp - 8]
    test    qword [r11 + DB_FEATURES], CybouDB_FEATURE_COMPRESSION
    jz      .delete_count_open
    mov     ARG1, [rbp - 24]
    mov     ARG2, PAX_DECODE_MAX_BYTES
    call    sql_arena_alloc
    test    rax, rax
    jz      .oom
    mov     [rbp - 1768], rax
.delete_count_open:
    mov     rax, [rbp - 1768]
    PASS_ARG5 rax
    lea     ARG1, [rbp - 1728]
    mov     ARG2, [rbp - 8]
    mov     ARG3, [rbp - 16]
    mov     ARG4, [rbp - 1760]
    call    sql_select_open
    test    eax, eax
    jnz     .storage_done
    mov     qword [rbp - 1776], 0
.delete_count_scan:
    lea     ARG1, [rbp - 1728]
    call    sql_select_next
    test    eax, eax
    jnz     .storage_done
    test    rdx, rdx
    jz      .delete_counted
    mov     rax, rdx
.delete_count_bits:
    test    rax, rax
    jz      .delete_count_scan
    lea     rcx, [rax - 1]
    and     rax, rcx
    inc     qword [rbp - 1776]
    jmp     .delete_count_bits
.delete_counted:
    mov     rax, [rbp - 1776]
    mov     r10, [rbp - 16]
    mov     [r10 + PLAN_DELETE_ROWS], rax
    test    rax, rax
    jz      .exec_delete_none
    cmp     rax, [rbp - 1752]
    jae     .exec_delete_truncate       ; everything matched: truncation is it

    ; --- Pass 2: rewrite the survivors ------------------------------------
    ; The cursor is opened on the graph as it stands and keeps reading it
    ; after the truncation stages an empty root: append-only COW never
    ; overwrites a page the live generation still references, so the old
    ; leaves stay readable until this transaction commits.
    mov     r11, [rbp - 1744]
    mov     ecx, [r11 + CAT_COUNT]
    mov     [rbp - 1784], rcx
    mov     eax, 64
    sub     eax, ecx
    mov     ecx, eax
    mov     rax, -1
    shr     rax, cl
    mov     [rbp - 1792], rax           ; every column of the old row

    mov     ARG1, [rbp - 8]
    mov     ARG2, [rbp - 1744]
    call    db_pax_capacity
    test    rax, rax
    jz      .scan_state
    mov     [rbp - 1800], rax
    ; As many rows as the scratch region holds, and never more than one leaf.
    mov     rax, DELETE_SCRATCH_CELLS
    xor     edx, edx
    div     qword [rbp - 1784]
    cmp     rax, [rbp - 1800]
    jbe     .delete_chunk_ready
    mov     rax, [rbp - 1800]
.delete_chunk_ready:
    mov     [rbp - 1808], rax
    lea     rax, [rbp - DELETE_VALUES_OFF]
    mov     [rbp - 1824], rax
    lea     rax, [rbp - DELETE_NULLS_OFF]
    mov     [rbp - 1832], rax
    lea     rax, [rbp - DELETE_LENGTHS_OFF]
    mov     [rbp - 1880], rax

    mov     ARG1, [rbp - 8]
    mov     ARG2, [rbp - 1744]
    lea     ARG3, [rbp - 1984]
    call    db_pax_scan_open_bound
    test    eax, eax
    jnz     .storage_done

    mov     ARG1, [rbp - 8]
    mov     r10, [rbp - 16]
    mov     ARG2, [r10 + PLAN_TABLE_ID]
    call    db_catalog_truncate_data
    test    eax, eax
    jnz     .storage_done
    mov     qword [rbp - 1840], 0

.delete_rewrite_scan:
    lea     ARG1, [rbp - 1984]
    mov     ARG2, [rbp - 1760]
    mov     ARG3, [rbp - 1792]
    mov     ARG4, [rbp - 1768]
    call    db_pax_scan_batch
    test    eax, eax
    jnz     .storage_done
    test    rdx, rdx
    jz      .delete_rewrite_tail
    mov     [rbp - 1848], rdx
    mov     r10, [rbp - 16]
    mov     ARG1, [r10 + PLAN_DATA4]
    mov     ARG2, rdx
    mov     ARG3, [rbp - 1760]
    call    eval_predicate
    ; A row survives unless the predicate selected it. UNKNOWN is not TRUE,
    ; so a NULL comparison keeps its row, exactly as WHERE does in a SELECT.
    mov     ecx, 64
    sub     rcx, [rbp - 1848]
    mov     rdx, -1
    shr     rdx, cl
    not     rax
    and     rax, rdx
    mov     [rbp - 1856], rax

.delete_rewrite_row:
    mov     rax, [rbp - 1840]
    cmp     rax, [rbp - 1808]
    jb      .delete_rewrite_pick
    ; The buffer is full: append it and start the next chunk.
    mov     [rbp - 2048 + BATCH_ROWS], rax
    mov     rax, [rbp - 1824]
    mov     [rbp - 2048 + BATCH_VALUES], rax
    mov     rax, [rbp - 1832]
    mov     [rbp - 2048 + BATCH_NULLS], rax
    mov     rax, [rbp - 1880]
    mov     [rbp - 2048 + BATCH_VAR_LENGTHS], rax
    ; The varlen slots hold the roots the surviving cells already point at.
    mov     qword [rbp - 2048 + BATCH_FLAGS], BATCH_VARLEN_PERSISTED
    mov     ARG1, [rbp - 8]
    mov     r10, [rbp - 16]
    mov     ARG2, [r10 + PLAN_TABLE_ID]
    lea     ARG3, [rbp - 2048]
    call    db_pax_insert
    test    eax, eax
    jnz     .storage_done
    mov     qword [rbp - 1840], 0
    jmp     .delete_rewrite_row

.delete_rewrite_pick:
    mov     rax, [rbp - 1856]
    test    rax, rax
    jz      .delete_rewrite_scan
    bsf     rcx, rax
    mov     [rbp - 1864], rcx
    lea     rdx, [rax - 1]
    and     rax, rdx
    mov     [rbp - 1856], rax
    mov     rax, [rbp - 1840]
    imul    rax, [rbp - 1784]
    mov     [rbp - 1872], rax
    xor     r8d, r8d
.delete_rewrite_cell:
    cmp     r8, [rbp - 1784]
    jae     .delete_rewrite_row_done
    mov     r9, r8
    imul    r9, CybouDB_COLVIEW_SIZE
    add     r9, [rbp - 1760]
    add     r9, BATCH_VIEW_COLUMNS
    mov     r10, [rbp - 1872]
    add     r10, r8
    mov     r11, [rbp - 1832]
    mov     byte [r11 + r10], 0
    mov     rax, [rbp - 1824]
    mov     qword [rax + r10 * 8], 0
    mov     r11, [rbp - 1880]
    mov     qword [r11 + r10 * 8], 0
    mov     r11, [rbp - 1832]
    mov     rcx, [rbp - 1864]
    mov     rdx, [r9 + COLVIEW_NULL_MASK]
    bt      rdx, rcx
    jnc     .delete_rewrite_value
    mov     byte [r11 + r10], 1
    jmp     .delete_rewrite_cell_next
.delete_rewrite_value:
    mov     edx, [r9 + COLVIEW_WIDTH]
    mov     r11, [r9 + COLVIEW_VALUES_PTR]
    imul    rcx, rdx
    add     r11, rcx
    cmp     edx, VAR_CELL_SIZE
    je      .delete_rewrite_w16
    cmp     edx, 8
    je      .delete_rewrite_w8
    cmp     edx, 1
    je      .delete_rewrite_w1
    mov     ecx, [r11]
    jmp     .delete_rewrite_store
.delete_rewrite_w8:
    mov     rcx, [r11]
    jmp     .delete_rewrite_store
.delete_rewrite_w1:
    movzx   ecx, byte [r11]
    jmp     .delete_rewrite_store
.delete_rewrite_w16:
    ; TEXT, BLOB and VECTOR: carry the extent root and its length across
    ; rather than reading the payload out and writing it back. The chain is
    ; owned by this table and is not retired by the republication, which is
    ; the same reason an UPDATE may copy an untouched cell through the leaf
    ; it rewrites.
    mov     rdx, [r11 + VAR_CELL_LENGTH]
    mov     r11, [rbp - 1880]
    mov     [r11 + r10 * 8], rdx
    mov     r11, [r9 + COLVIEW_VALUES_PTR]
    mov     rcx, [rbp - 1864]
    imul    rcx, VAR_CELL_SIZE
    add     r11, rcx
    mov     rcx, [r11 + VAR_CELL_ROOT]
.delete_rewrite_store:
    mov     [rax + r10 * 8], rcx
.delete_rewrite_cell_next:
    inc     r8
    jmp     .delete_rewrite_cell
.delete_rewrite_row_done:
    inc     qword [rbp - 1840]
    jmp     .delete_rewrite_row

.delete_rewrite_tail:
    mov     rax, [rbp - 1840]
    test    rax, rax
    jz      .delete_rewrite_done
    mov     [rbp - 2048 + BATCH_ROWS], rax
    mov     rax, [rbp - 1824]
    mov     [rbp - 2048 + BATCH_VALUES], rax
    mov     rax, [rbp - 1832]
    mov     [rbp - 2048 + BATCH_NULLS], rax
    mov     rax, [rbp - 1880]
    mov     [rbp - 2048 + BATCH_VAR_LENGTHS], rax
    ; The varlen slots hold the roots the surviving cells already point at.
    mov     qword [rbp - 2048 + BATCH_FLAGS], BATCH_VARLEN_PERSISTED
    mov     ARG1, [rbp - 8]
    mov     r10, [rbp - 16]
    mov     ARG2, [r10 + PLAN_TABLE_ID]
    lea     ARG3, [rbp - 2048]
    call    db_pax_insert
    test    eax, eax
    jnz     .storage_done
.delete_rewrite_done:
    xor     eax, eax
    jmp     .exec_exit

.exec_drop:
    mov     ARG1, [rbp - 8]
    mov     ARG2, [r10 + PLAN_TABLE_ID]
    call    db_catalog_drop
    jmp     .storage_done
.exec_create:
    mov     ARG1, [rbp - 8]
    mov     ARG2, [r10 + PLAN_TABLE_ID]
    mov     ARG3, [r10 + PLAN_DATA1]
    call    db_catalog_put
    jmp     .storage_done
.exec_insert:
    mov     ARG1, [rbp - 8]
    mov     ARG2, [r10 + PLAN_TABLE_ID]
    mov     ARG3, [r10 + PLAN_DATA1]
    call    db_pax_insert
    jmp     .storage_done
.exec_update:
    mov r10, [rbp - 16]
    mov r11, [r10 + PLAN_SCHEMA_PAGE]
    mov eax, [r11 + CAT_TABLE_ROWS]
    add rax, 63
    shr rax, 6
    shl rax, 4
    mov ARG1, [rbp - 24]
    mov ARG2, rax
    call sql_arena_alloc
    test rax, rax
    jz .oom
    mov [rbp - 168], rax            ; UPDATE_SPAN array
    mov qword [rbp - 176], 0        ; recorded nonempty spans
    mov qword [rbp - 184], 0        ; affected rows
    mov ARG1, [rbp - 24]
    mov ARG2, CybouDB_BATCH_VIEW_SIZE
    call sql_arena_alloc
    test rax, rax
    jz .oom
    mov [rbp - 120], rax
    mov qword [rbp - 56], 0
    mov r11, [rbp - 8]
    test qword [r11 + DB_FEATURES], CybouDB_FEATURE_COMPRESSION
    jz .update_open
    mov ARG1, [rbp - 24]
    mov ARG2, PAX_DECODE_MAX_BYTES
    call sql_arena_alloc
    test rax, rax
    jz .oom
    mov [rbp - 56], rax
.update_open:
    mov rax, [rbp - 56]
    PASS_ARG5 rax
    lea ARG1, [rbp - 1728]
    mov ARG2, [rbp - 8]
    mov ARG3, [rbp - 16]
    mov ARG4, [rbp - 120]
    call sql_select_open
    test eax, eax
    jnz .storage_done
.update_scan:
    lea ARG1, [rbp - 1728]
    call sql_select_next
    test eax, eax
    jnz .storage_done
    test rdx, rdx
    jz .update_scanned
    mov [rbp - 192], rdx
    mov rax, [rbp - 176]
    shl rax, 4
    add rax, [rbp - 168]
    mov r10, [rbp - 120]
    mov rcx, [rbp - 1728 + SEL_SCAN + SCAN_NEXT]
    sub rcx, [r10 + BATCH_VIEW_ROWS]
    mov [rax + UPDATE_SPAN_START], rcx
    mov [rax + UPDATE_SPAN_MASK], rdx
    xor ecx, ecx
    mov rax, rdx
.update_count:
    test rax, rax
    jz .update_counted
    lea rdx, [rax - 1]
    and rax, rdx
    inc rcx
    jmp .update_count
.update_counted:
    add [rbp - 184], rcx
    inc qword [rbp - 176]
    jmp .update_scan
.update_scanned:
    mov r10, [rbp - 16]
    mov rax, [rbp - 184]
    mov [r10 + PLAN_DATA1], rax
    mov qword [rbp - 200], 0
    test rax, rax
    jz .success

    ; If varlen (TEXT or BLOB), allocate extent chain once before leaf rewrites
    mov rax, [r10 + PLAN_UPDATE_COL_TYPE]
    cmp rax, CAT_TEXT
    je .update_prep_varlen
    cmp rax, CAT_BLOB
    je .update_prep_varlen
    jmp .update_prep_done

.update_prep_varlen:
    cmp qword [r10 + PLAN_UPDATE_IS_NULL], 0
    jne .update_varlen_empty
    cmp qword [r10 + PLAN_UPDATE_LENGTH], 0
    je .update_varlen_empty

    mov ARG1, [rbp - 8]             ; ctx
    mov ARG2, [r10 + PLAN_UPDATE_VALUE] ; bytes
    mov ARG3, [r10 + PLAN_UPDATE_LENGTH] ; length
    mov ARG4, [r10 + PLAN_TABLE_ID] ; owner table id
    lea rax, [rbp - 264]
    PASS_ARG5 rax
    call db_var_write_chain
    test eax, eax
    jnz .storage_done
    lea rax, [rbp - 264]
    mov r10, [rbp - 16]
    mov [r10 + PLAN_UPDATE_VALUE], rax
    jmp .update_prep_done

.update_varlen_empty:
    mov qword [rbp - 264], 0
    mov qword [rbp - 256], 0
    lea rax, [rbp - 264]
    mov r10, [rbp - 16]
    mov [r10 + PLAN_UPDATE_VALUE], rax

.update_prep_done:
    mov ARG1, [rbp - 8]
    mov r10, [rbp - 16]
    mov ARG2, [r10 + PLAN_SCHEMA_PAGE]
    call db_pax_capacity
    mov [rbp - 216], rax            ; physical rows per leaf
.update_apply:
    mov rax, [rbp - 200]
    cmp rax, [rbp - 176]
    jae .success
    shl rax, 4
    add rax, [rbp - 168]
    mov [rbp - 208], rax
    mov rdx, [rax + UPDATE_SPAN_START]
    mov rax, rdx
    xor edx, edx
    div qword [rbp - 216]
    mov [rbp - 224], rax            ; leaf shared by this group
    mov rcx, [rbp - 200]
.update_group:
    inc rcx
    cmp rcx, [rbp - 176]
    jae .update_group_ready
    mov rax, rcx
    shl rax, 4
    add rax, [rbp - 168]
    mov rax, [rax + UPDATE_SPAN_START]
    xor edx, edx
    div qword [rbp - 216]
    cmp rax, [rbp - 224]
    je .update_group
.update_group_ready:
    mov rax, rcx
    sub rax, [rbp - 200]
    mov [rbp - 232], rax
    ; The group is three fields at [rbp-296]; [rbp-232] and its neighbours are
    ; live locals of this loop, so it does not sit on top of them.
    mov rax, [rbp - 208]
    mov [rbp - 296], rax            ; UPDATE_GROUP_SPANS
    mov rax, [rbp - 232]
    mov [rbp - 288], rax            ; UPDATE_GROUP_COUNT
    mov qword [rbp - 280], UPDATE_MODE_VALUE
    mov r10, [rbp - 16]
    mov ARG1, [rbp - 8]
    mov ARG2, [r10 + PLAN_TABLE_ID]
    mov ARG3, [r10 + PLAN_UPDATE_COL_IDX]
    mov ARG4, [r10 + PLAN_UPDATE_VALUE]
    mov rax, [r10 + PLAN_UPDATE_IS_NULL]
    PASS_ARG5 rax
    lea rax, [rbp - 296]
    PASS_ARG6 rax
    call db_pax_update_one
    test eax, eax
    jnz .storage_done
    mov rax, [rbp - 232]
    add [rbp - 200], rax
    mov r10, [rbp - 16]
    jmp .update_apply
.exec_select:
    cmp qword [rbp - 32], 0
    je .missing_sink
    mov r10, [rbp - 16]
    test qword [r10 + PLAN_FLAGS], PLAN_FLAG_VECTOR_TOPK
    jnz .exec_vector_topk
    mov rax, [r10 + PLAN_OFFSET_VALUE]
    mov [rbp - 144], rax              ; rows still to skip
    mov rax, [r10 + PLAN_LIMIT_VALUE]
    mov [rbp - 152], rax              ; rows still to deliver
    test qword [r10 + PLAN_FLAGS], PLAN_FLAG_ORDER
    jz .order_state_ready
    lea ARG1, [rbp - 256]
    mov ARG2, [rbp - 24]
    mov ARG3, r10
    call sql_order_init
    test eax, eax
    jnz .oom
.order_state_ready:
    mov r10, [rbp - 16]
    cmp qword [r10 + PLAN_JOIN_TYPE], 0
    jne .exec_join
    mov ARG1, [rbp - 24]
    mov ARG2, CybouDB_BATCH_VIEW_SIZE
    call sql_arena_alloc
    test rax, rax
    jz .oom
    mov [rbp - 120], rax
    mov qword [rbp - 56], 0
    mov r11, [rbp - 8]
    test qword [r11 + DB_FEATURES], CybouDB_FEATURE_COMPRESSION
    jz .open_select
    mov ARG1, [rbp - 24]
    mov ARG2, PAX_DECODE_MAX_BYTES
    call sql_arena_alloc
    test rax, rax
    jz .oom
    mov [rbp - 56], rax
.open_select:
    mov rax, [rbp - 56]
    PASS_ARG5 rax
    lea ARG1, [rbp - 1728]
    mov ARG2, [rbp - 8]
    mov ARG3, [rbp - 16]
    mov ARG4, [rbp - 120]
    call sql_select_open
    test eax, eax
    jnz .storage_done
.next_select:
    lea ARG1, [rbp - 1728]
    call sql_select_next
    test eax, eax
    jnz .storage_done
    test rdx, rdx
    jz .select_complete
    mov ARG4, rdx
    mov ARG2, [rbp - 120]
    mov r10, [rbp - 16]
    lea ARG3, [r10 + PLAN_DATA1]
    test qword [r10 + PLAN_FLAGS], PLAN_FLAG_ORDER
    jz .select_direct_sink
    lea ARG1, [rbp - 256]
    call sql_order_collect
    jmp .select_sink_result
.select_direct_sink:
    mov ARG1, [rbp - 40]
    call [rbp - 32]
.select_sink_result:
    test eax, eax
    jz .next_select
    cmp eax, CybouDB_SINK_STOP
    jne .sink_failed
    jmp .success

.select_complete:
    mov r10, [rbp - 16]
    test qword [r10 + PLAN_FLAGS], PLAN_FLAG_ORDER
    jz .success
    lea ARG1, [rbp - 256]
    mov ARG2, [rbp - 32]
    mov ARG3, [rbp - 40]
    call sql_order_emit
    test eax, eax
    jz .success
    cmp eax, SQL_ERR_NO_STORAGE
    je .oom
    cmp eax, SQL_ERR_SINK
    je .sink_failed
    jmp .storage_done

.exec_join:
    mov r10, [rbp - 16]
    mov rax, [rbp - 32]
    mov [rbp - 160], rax              ; selected sink
    mov rax, [rbp - 40]
    mov [rbp - 168], rax              ; selected sink context
    test qword [r10 + PLAN_FLAGS], PLAN_FLAG_LIMIT
    jz .join_sink_ready
    lea rax, [.limited_sink]
    mov [rbp - 160], rax
    mov [rbp - 168], rbp
.join_sink_ready:
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    mov ARG3, [rbp - 24]
    mov ARG4, [rbp - 160]
    mov rax, [rbp - 168]
    PASS_ARG5 rax
    mov rax, [rbp - 128]
    PASS_ARG6 rax
    call sql_join_execute
    test eax, eax
    jz .success
    cmp eax, SQL_ERR_SINK
    je .sink_failed
    cmp eax, SQL_ERR_NO_STORAGE
    je .oom
    jmp .storage_done

.exec_vector_topk:
    mov ARG1, [rbp - 8]                 ; db
    mov ARG2, [rbp - 16]                ; plan
    mov ARG3, [rbp - 24]                ; arena
    mov ARG4, [rbp - 32]                ; batch_cb
    mov rax, [rbp - 40]                 ; cb_ctx
    PASS_ARG5 rax
    mov rax, [rbp - 128]                ; out_err
    PASS_ARG6 rax
    call sql_vector_topk_execute
    test eax, eax
    jz .success
    cmp eax, SQL_ERR_NO_STORAGE
    je .oom
    cmp eax, SQL_ERR_SINK
    je .sink_failed
    cmp eax, SQL_ERR_EXEC
    je .vector_exec_fail
    jmp .storage_done
.vector_exec_fail:
    mov qword [rbp - 136], SQL_DOMAIN_SQL
    mov eax, SQL_ERR_EXEC
    jmp .exec_exit

; Adapter for LIMIT/OFFSET. ARG1 is the parent executor frame; other arguments
; match the result-sink ABI. It preserves the lowest selected lanes in row order.
.limited_sink:
    FRAME_BEGIN 64, 0
    mov [rbp - 8], ARG1               ; parent frame
    mov [rbp - 16], ARG2              ; batch
    mov [rbp - 24], ARG3              ; projection
    mov [rbp - 32], rbx
    mov [rbp - 40], r12
    mov rbx, ARG4                     ; input selection
    xor r12d, r12d                    ; limited selection
.limit_lane:
    test rbx, rbx
    jz .limit_selected
    bsf rcx, rbx
    lea rax, [rbx - 1]
    and rbx, rax                      ; remove lowest selected lane
    mov r10, [rbp - 8]
    cmp qword [r10 - 144], 0
    je .limit_take
    dec qword [r10 - 144]
    jmp .limit_lane
.limit_take:
    cmp qword [r10 - 152], 0
    je .limit_selected
    bts r12, rcx
    dec qword [r10 - 152]
    jmp .limit_lane
.limit_selected:
    test r12, r12
    jnz .limit_call
    mov r10, [rbp - 8]
    cmp qword [r10 - 152], 0
    je .limit_stop
    jmp .limit_continue
.limit_call:
    mov ARG4, r12
    mov ARG1, [r10 - 40]
    mov ARG2, [rbp - 16]
    mov ARG3, [rbp - 24]
    call [r10 - 32]
    test eax, eax
    jnz .limit_done
    mov r10, [rbp - 8]
    cmp qword [r10 - 152], 0
    je .limit_stop
.limit_continue:
    xor eax, eax
    jmp .limit_done
.limit_stop:
    mov eax, CybouDB_SINK_STOP
.limit_done:
    mov rbx, [rbp - 32]
    mov r12, [rbp - 40]
    FRAME_END
    ret

.success:
    xor     eax, eax
    jmp     .exec_exit
.missing_sink:
    mov     eax, SQL_ERR_EXEC
    jmp     .exec_exit
.sink_failed:
    mov r10, [rbp - 16]
    test qword [r10 + PLAN_FLAGS], PLAN_FLAG_ORDER
    jz .sink_failed_plain
    cmp qword [rbp - 256 + ORDER_ERROR], SQL_ERR_NO_STORAGE
    je .oom
.sink_failed_plain:
    mov     eax, SQL_ERR_SINK
    jmp     .exec_exit
.oom:
    mov     eax, SQL_ERR_NO_STORAGE
    jmp     .exec_exit
.scan_state:
    mov     eax, CybouDB_E_STATE
.storage_done:
    mov     qword [rbp - 136], SQL_DOMAIN_STORAGE
.exec_exit:
    mov     r10, [rbp - 128]
    test    r10, r10
    jz      .return
    test    eax, eax
    jz      .return
    mov     [r10 + SQL_ERR_CODE], rax
    mov     r11, [rbp - 136]
    mov     [r10 + SQL_ERR_DOMAIN], r11
    lea     r11, [exec_storage_message]
    cmp     qword [r10 + SQL_ERR_DOMAIN], SQL_DOMAIN_STORAGE
    je      .message_ready
    lea     r11, [exec_error_message]
    cmp     eax, SQL_ERR_NO_STORAGE
    jne     .check_sink_error
    lea     r11, [exec_oom_message]
    jmp     .message_ready
.check_sink_error:
    cmp     eax, SQL_ERR_SINK
    jne     .check_missing_sink
    lea     r11, [exec_sink_failed_message]
    jmp     .message_ready
.check_missing_sink:
    cmp     eax, SQL_ERR_EXEC
    jne     .message_ready
    lea     r11, [exec_sink_message]
.message_ready:
    xor     ecx, ecx
.copy_error:
    mov     dl, [r11 + rcx]
    mov     [r10 + SQL_ERR_MSG + rcx], dl
    inc     ecx
    test    dl, dl
    jnz     .copy_error
.return:
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  sql_vector_topk_execute(db, plan, arena, batch_cb, cb_ctx, out_err)
;  Executes streaming Top-K vector search with O(K) memory overhead.
; -----------------------------------------------------------------------------
sql_vector_topk_execute:
    FRAME_BEGIN 2048, 2
    mov     [rbp - 8], ARG1             ; db
    mov     [rbp - 16], ARG2            ; plan
    mov     [rbp - 24], ARG3            ; arena
    mov     [rbp - 32], ARG4            ; batch_cb
    mov     rax, IN_ARG5
    mov     [rbp - 40], rax             ; cb_ctx
    mov     rax, IN_ARG6
    mov     [rbp - 48], rax             ; out_err

    mov     [rbp - 224], rbx
    mov     [rbp - 232], r12
    mov     [rbp - 240], r13
    mov     [rbp - 248], r14
    mov     [rbp - 256], r15
    mov     [rbp - 264], rsi
    mov     [rbp - 272], rdi

    mov     r10, [rbp - 16]             ; plan
    mov     rax, [r10 + PLAN_VECTOR_TOPK_EXPR]
    mov     [rbp - 64], rax             ; bexpr
    mov     rdx, [rax + BEXPR_COL_IDX]
    mov     [rbp - 72], rdx             ; col_idx
    mov     rdx, [rax + BEXPR_RIGHT]    ; dimension in floats
    mov     [rbp - 280], rdx            ; dim
    shl     rdx, 2
    mov     [rbp - 80], rdx             ; dim_bytes = dim * 4
    xor     edx, edx
    cmp     qword [rax + BEXPR_OP], OP_COSINE_DISTANCE
    sete    dl
    mov     [rbp - 104], rdx            ; is_cosine

    mov     r10, [rbp - 16]             ; plan
    mov     rax, [r10 + PLAN_LIMIT_VALUE]
    add     rax, [r10 + PLAN_OFFSET_VALUE]
    mov     [rbp - 128], rax            ; K = limit + offset

    ; Optional compression scratch storage
    mov     qword [rbp - 56], 0
    mov     r11, [rbp - 8]              ; db
    test    qword [r11 + DB_FEATURES], CybouDB_FEATURE_COMPRESSION
    jz      .vtopk_alloc_search
    mov     ARG1, [rbp - 24]            ; arena
    mov     ARG2, PAX_DECODE_MAX_BYTES
    call    sql_arena_alloc
    test    rax, rax
    jz      .vtopk_oom
    mov     [rbp - 56], rax             ; decode_storage

.vtopk_alloc_search:
    mov     ARG1, [rbp - 24]            ; arena
    mov     ARG2, VTOPK_STATE_SIZE
    call    sql_arena_alloc
    test    rax, rax
    jz      .vtopk_oom
    mov     [rbp - 96], rax             ; search state

    ; Initialize vector_topk state
    mov     ARG1, rax
    call    vector_topk_init
    test    eax, eax
    jnz     .vtopk_exec_error

    ; Allocate out_ids: K * 8 bytes
    mov     rax, [rbp - 128]
    shl     rax, 3
    mov     ARG1, [rbp - 24]
    mov     ARG2, rax
    call    sql_arena_alloc
    test    rax, rax
    jz      .vtopk_oom
    mov     r10, [rbp - 96]
    mov     [r10 + VTOPK_OUT_IDS], rax

    ; Allocate out_scores: K * 4 bytes
    mov     rax, [rbp - 128]
    shl     rax, 2
    mov     ARG1, [rbp - 24]
    mov     ARG2, rax
    call    sql_arena_alloc
    test    rax, rax
    jz      .vtopk_oom
    mov     r10, [rbp - 96]
    mov     [r10 + VTOPK_OUT_SCORES], rax

    ; Allocate batch_vec_buf: 64 * dim_bytes
    mov     rax, [rbp - 80]             ; dim_bytes
    shl     rax, 6                      ; * 64
    mov     ARG1, [rbp - 24]
    mov     ARG2, rax
    call    sql_arena_alloc
    test    rax, rax
    jz      .vtopk_oom
    mov     [rbp - 88], rax             ; batch_vec_buf

    ; Allocate batch_view: CybouDB_BATCH_VIEW_SIZE
    mov     ARG1, [rbp - 24]
    mov     ARG2, CybouDB_BATCH_VIEW_SIZE
    call    sql_arena_alloc
    test    rax, rax
    jz      .vtopk_oom
    mov     [rbp - 120], rax            ; batch_view

    ; Allocate emit_batch_view: CybouDB_BATCH_VIEW_SIZE
    mov     ARG1, [rbp - 24]
    mov     ARG2, CybouDB_BATCH_VIEW_SIZE
    call    sql_arena_alloc
    test    rax, rax
    jz      .vtopk_oom
    mov     [rbp - 152], rax            ; emit_batch_view

    ; Allocate order_nodes: K * 1088 bytes
    mov     rax, [rbp - 128]
    imul    rax, 1088
    mov     ARG1, [rbp - 24]
    mov     ARG2, rax
    call    sql_arena_alloc
    test    rax, rax
    jz      .vtopk_oom
    mov     [rbp - 144], rax            ; order_nodes

    mov     r10, [rbp - 96]             ; search
    mov     r11, [rbp - 64]             ; bexpr
    ; The query pointer lives in a stack slot, not in RSI: RSI and RDI are
    ; volatile under the System V ABI, so the arena call below would return
    ; into a register the callee was free to destroy.
    mov     rax, [r11 + BEXPR_LIT_VAL]  ; query vector ptr
    mov     [rbp - 160], rax
    cmp     qword [rbp - 104], 1        ; is_cosine?
    jne     .vtopk_query_ready
    mov     ARG1, [rbp - 24]            ; arena
    mov     ARG2, [rbp - 80]            ; dim_bytes
    call    sql_arena_alloc
    test    rax, rax
    jz      .vtopk_oom
    mov     [rbp - 168], rax            ; normalized query buffer
    mov     ARG1, [rbp - 160]           ; input
    mov     ARG2, [rbp - 168]           ; output
    mov     ARG3, [rbp - 280]           ; dim
    call    cyboudb_vector_normalize_f32
    test    eax, eax
    jnz     .vtopk_exec_error
    mov     rax, [rbp - 168]
    mov     [rbp - 160], rax            ; search the normalized copy
.vtopk_query_ready:
    mov     r10, [rbp - 96]             ; restore search
    mov     rax, [rbp - 160]            ; query vector (normalized for cosine)
    mov     [r10 + VTOPK_QUERY], rax
    mov     r11, [rbp - 64]             ; restore bexpr
    mov     rax, [r11 + BEXPR_RIGHT]    ; dimension
    mov     [r10 + VTOPK_DIM], rax
    mov     rax, [rbp - 80]             ; dim_bytes
    mov     [r10 + VTOPK_STRIDE], rax
    mov     rax, [rbp - 128]            ; K
    mov     [r10 + VTOPK_K], rax
    ; DESC is the k farthest rows, not the k nearest read backwards.
    mov     r11, [rbp - 16]             ; plan
    xor     eax, eax
    cmp     qword [r11 + PLAN_ORDER_DESC], 0
    setne   al
    mov     [r10 + VTOPK_REVERSE], rax

    mov     ARG1, r10
    cmp     qword [rbp - 104], 1        ; is_cosine
    je      .vtopk_init_cosine
    call    vector_topk_l2sq_begin
    jmp     .vtopk_begin_done
.vtopk_init_cosine:
    call    vector_topk_cosine_begin
.vtopk_begin_done:
    test    eax, eax
    jnz     .vtopk_exec_error

    ; Pass 1: Streaming candidate feed
    mov     rax, [rbp - 56]             ; decode_storage
    PASS_ARG5 rax
    lea     ARG1, [rbp - 1728]          ; cursor
    mov     ARG2, [rbp - 8]             ; db
    mov     ARG3, [rbp - 16]            ; plan
    mov     ARG4, [rbp - 120]           ; batch_view
    call    sql_select_open
    test    eax, eax
    jnz     .vtopk_storage_error

.vtopk_pass1_loop:
    lea     ARG1, [rbp - 1728]
    call    sql_select_next
    test    eax, eax
    jnz     .vtopk_storage_error
    test    rdx, rdx
    jz      .vtopk_pass1_done
    mov     r15, rdx                    ; selection mask

    ; Filter out NULL vectors
    mov     r10, [rbp - 120]            ; batch_view
    mov     rax, [rbp - 72]             ; col_idx
    imul    rax, CybouDB_COLVIEW_SIZE
    lea     r14, [r10 + BATCH_VIEW_COLUMNS + rax]
    mov     rax, [r14 + COLVIEW_NULL_MASK]
    not     rax
    and     r15, rax
    test    r15, r15
    jz      .vtopk_pass1_loop

    ; base_row = cursor->SCAN_NEXT - batch_view->rows
    mov     rcx, [rbp - 1728 + SEL_SCAN + SCAN_NEXT]
    sub     rcx, [r10 + BATCH_VIEW_ROWS]
    mov     [rbp - 184], rcx            ; base_row

    ; Read vector extents for active lanes
    mov     r12, r15
.vtopk_read_lane:
    test    r12, r12
    jz      .vtopk_feed_batch
    tzcnt   rbx, r12
    btr     r12, rbx

    mov     rax, [r14 + COLVIEW_VALUES_PTR]
    mov     rcx, rbx
    shl     rcx, 4
    add     rax, rcx
    mov     [rbp - 192], rax            ; desc_ptr

    mov     rax, rbx
    imul    rax, [rbp - 80]             ; dim_bytes
    add     rax, [rbp - 88]             ; batch_vec_buf
    mov     [rbp - 200], rax            ; dst_ptr

    mov     r10, [rbp - 8]              ; db
    mov     ARG1, r10
    mov     ARG2, [r10 + DB_SB_PTR]
    mov     ARG3, [rbp - 192]
    mov     r11, [rbp - 16]             ; plan
    mov     ARG4, [r11 + PLAN_TABLE_ID]
    mov     rax, [rbp - 200]
    PASS_ARG5 rax
    mov     rax, [rbp - 80]
    PASS_ARG6 rax
    call    db_var_read_chain
    test    eax, eax
    jnz     .vtopk_storage_error

    cmp     qword [rbp - 104], 1        ; is_cosine?
    jne     .vtopk_read_lane
    mov     ARG1, [rbp - 200]           ; dst_ptr
    mov     ARG2, [rbp - 200]           ; dst_ptr (in-place)
    mov     ARG3, [rbp - 280]           ; dim
    call    cyboudb_vector_normalize_f32
    test    eax, eax
    jz      .vtopk_read_lane
    btr     r15, rbx                    ; clear invalid candidate lane from mask
    jmp     .vtopk_read_lane

.vtopk_feed_batch:
    mov     ARG1, [rbp - 96]            ; search
    mov     ARG2, [rbp - 184]           ; base_row
    mov     ARG3, [rbp - 88]            ; batch_vec_buf
    mov     r10, [rbp - 120]            ; batch_view
    mov     ARG4, [r10 + BATCH_VIEW_ROWS]
    mov     rax, r15                    ; candidate_mask
    PASS_ARG5 rax
    cmp     qword [rbp - 104], 1
    je      .vtopk_feed_cosine
    call    vector_topk_l2sq_feed
    jmp     .vtopk_feed_done
.vtopk_feed_cosine:
    call    vector_topk_cosine_feed
.vtopk_feed_done:
    test    eax, eax
    jnz     .vtopk_exec_error
    jmp     .vtopk_pass1_loop

.vtopk_pass1_done:
    mov     ARG1, [rbp - 96]            ; search
    cmp     qword [rbp - 104], 1
    je      .vtopk_finish_cosine
    call    vector_topk_l2sq_finish
    jmp     .vtopk_finish_done
.vtopk_finish_cosine:
    call    vector_topk_cosine_finish
.vtopk_finish_done:
    test    eax, eax
    jnz     .vtopk_exec_error

    mov     r10, [rbp - 96]
    mov     rax, [r10 + VTOPK_OUT_COUNT]
    mov     [rbp - 112], rax            ; out_count
    test    rax, rax
    jz      .vtopk_success



    ; Pass 2: Re-open scan to materialize winning rows
    mov     qword [rbp - 208], 0        ; found_count = 0
    mov     rax, [rbp - 56]
    PASS_ARG5 rax
    lea     ARG1, [rbp - 1728]
    mov     ARG2, [rbp - 8]
    mov     ARG3, [rbp - 16]
    mov     ARG4, [rbp - 120]
    call    sql_select_open
    test    eax, eax
    jnz     .vtopk_storage_error

.vtopk_pass2_loop:
    lea     ARG1, [rbp - 1728]
    call    sql_select_next
    test    eax, eax
    jnz     .vtopk_storage_error
    test    rdx, rdx
    jz      .vtopk_pass2_done

    mov     r10, [rbp - 120]            ; batch_view
    mov     rcx, [rbp - 1728 + SEL_SCAN + SCAN_NEXT]
    sub     rcx, [r10 + BATCH_VIEW_ROWS]
    mov     [rbp - 184], rcx            ; base_row

    xor     ebx, ebx                    ; lane = 0
.vtopk_lane_check:
    mov     r10, [rbp - 120]            ; batch_view
    cmp     rbx, [r10 + BATCH_VIEW_ROWS]
    jae     .vtopk_pass2_loop

    mov     rax, [rbp - 184]
    add     rax, rbx                    ; row_id = base_row + lane

    ; Search if row_id is in out_ids[0..out_count-1]
    mov     r11, [rbp - 96]             ; search
    mov     r8, [r11 + VTOPK_OUT_IDS]
    xor     ecx, ecx                    ; rank = 0
.vtopk_find_rank:
    cmp     rcx, [rbp - 112]            ; out_count
    jae     .vtopk_lane_next
    cmp     rax, [r8 + rcx * 8]
    je      .vtopk_row_match
    inc     rcx
    jmp     .vtopk_find_rank

.vtopk_row_match:
    mov     rax, rcx
    imul    rax, 1088
    add     rax, [rbp - 144]
    mov     [rbp - 216], rax            ; node_ptr

    mov     r10, [rbp - 16]             ; plan
    mov     r14, [r10 + PLAN_DATA1]     ; proj_count
    xor     edi, edi                    ; p = 0
.vtopk_mat_col:
    cmp     rdi, r14
    jae     .vtopk_mat_done
    mov     r10, [rbp - 16]             ; plan
    mov     rax, [r10 + PLAN_DATA2]
    mov     eax, [rax + rdi * 4]        ; col_idx
    imul    rax, CybouDB_COLVIEW_SIZE
    mov     r11, [rbp - 120]
    lea     rsi, [r11 + BATCH_VIEW_COLUMNS + rax]

    mov     r12, [rbp - 216]            ; node_ptr
    bt      qword [rsi + COLVIEW_NULL_MASK], rbx
    setc    al
    mov     [r12 + 1024 + rdi], al
    test    al, al
    jnz     .vtopk_mat_null

    mov     rax, rdi
    shl     rax, 4
    lea     rcx, [r12 + rax]

    mov     r13, [rsi + COLVIEW_VALUES_PTR]
    mov     edx, [rsi + COLVIEW_WIDTH]
    cmp     edx, 16
    je      .vtopk_mat_varlen
    cmp     edx, 8
    je      .vtopk_mat_8
    cmp     edx, 1
    je      .vtopk_mat_1
    mov     eax, [r13 + rbx * 4]
    mov     [rcx], rax
    mov     qword [rcx + 8], 0
    jmp     .vtopk_mat_col_next
.vtopk_mat_8:
    mov     rax, [r13 + rbx * 8]
    mov     [rcx], rax
    mov     qword [rcx + 8], 0
    jmp     .vtopk_mat_col_next
.vtopk_mat_1:
    movzx   eax, byte [r13 + rbx]
    mov     [rcx], rax
    mov     qword [rcx + 8], 0
    jmp     .vtopk_mat_col_next
.vtopk_mat_varlen:
    mov     rax, rbx
    shl     rax, 4
    add     rax, r13
    mov     rdx, [rax]
    mov     [rcx], rdx
    mov     rdx, [rax + 8]
    mov     [rcx + 8], rdx
    jmp     .vtopk_mat_col_next
.vtopk_mat_null:
    mov     rax, rdi
    shl     rax, 4
    lea     rcx, [r12 + rax]
    mov     qword [rcx], 0
    mov     qword [rcx + 8], 0
.vtopk_mat_col_next:
    inc     rdi
    jmp     .vtopk_mat_col

.vtopk_mat_done:
    inc     qword [rbp - 208]
    mov     rax, [rbp - 208]
    cmp     rax, [rbp - 112]            ; found_count == out_count?
    je      .vtopk_pass2_done

.vtopk_lane_next:
    inc     rbx
    jmp     .vtopk_lane_check

.vtopk_pass2_done:
    ; Emit rows
    mov     r10, [rbp - 16]             ; plan
    mov     r12, [r10 + PLAN_OFFSET_VALUE] ; rank = offset
.vtopk_emit_loop:
    cmp     r12, [rbp - 112]            ; rank >= out_count?
    jae     .vtopk_success
    mov     r10, [rbp - 16]
    mov     rax, [r10 + PLAN_OFFSET_VALUE]
    add     rax, [r10 + PLAN_LIMIT_VALUE]
    cmp     r12, rax                    ; rank >= offset + limit?
    jae     .vtopk_success

    mov     rax, r12
    imul    rax, 1088
    add     rax, [rbp - 144]
    mov     [rbp - 216], rax            ; node_ptr

    mov     r14, [rbp - 152]            ; emit_batch_view
    mov     qword [r14 + BATCH_VIEW_ROWS], 1
    mov     r10, [rbp - 16]             ; plan
    mov     r15, [r10 + PLAN_DATA1]     ; proj_count
    xor     ebx, ebx                    ; p = 0
.vtopk_emit_col:
    cmp     rbx, r15
    jae     .vtopk_emit_call
    mov     r10, [rbp - 16]
    mov     rax, [r10 + PLAN_DATA2]
    mov     eax, [rax + rbx * 4]        ; col_idx
    imul    rax, CybouDB_COLVIEW_SIZE
    lea     rdx, [r14 + BATCH_VIEW_COLUMNS + rax]

    mov     rcx, [rbp - 216]            ; node_ptr
    mov     rax, rbx
    shl     rax, 4
    add     rax, rcx
    mov     [rdx + COLVIEW_VALUES_PTR], rax
    movzx   eax, byte [rcx + 1024 + rbx]
    mov     [rdx + COLVIEW_NULL_MASK], rax
    mov     r10, [rbp - 16]
    mov     rax, [r10 + PLAN_DATA3]
    mov     eax, [rax + rbx * 4]
    mov     [rdx + COLVIEW_TYPE], eax

    mov     ecx, 4
    cmp     eax, CAT_INT64
    jne     .vtopk_not_i64
    mov     ecx, 8
.vtopk_not_i64:
    cmp     eax, CAT_BOOL
    jne     .vtopk_not_bool
    mov     ecx, 1
.vtopk_not_bool:
    cmp     eax, CAT_TEXT
    je      .vtopk_is_varlen
    cmp     eax, CAT_BLOB
    je      .vtopk_is_varlen
    cmp     eax, CAT_VECTOR
    je      .vtopk_is_varlen
    jmp     .vtopk_store_width
.vtopk_is_varlen:
    mov     ecx, 16
.vtopk_store_width:
    mov     [rdx + COLVIEW_WIDTH], ecx
    inc     rbx
    jmp     .vtopk_emit_col

.vtopk_emit_call:
    mov     ARG1, [rbp - 40]            ; cb_ctx
    mov     ARG2, r14                   ; emit_batch_view
    mov     r10, [rbp - 16]             ; plan
    lea     ARG3, [r10 + PLAN_DATA1]    ; projection descriptor
    mov     ARG4, 1                     ; selection_mask = 1
    call    [rbp - 32]                  ; batch_cb
    cmp     eax, CybouDB_SINK_STOP
    je      .vtopk_success
    cmp     eax, CybouDB_SINK_ERROR
    je      .vtopk_sink_failed
    inc     r12
    jmp     .vtopk_emit_loop

.vtopk_success:
    xor     eax, eax
    jmp     .vtopk_done
.vtopk_oom:
    mov     eax, SQL_ERR_NO_STORAGE
    jmp     .vtopk_done
.vtopk_storage_error:
    jmp     .vtopk_done
.vtopk_exec_error:
    mov     eax, SQL_ERR_EXEC
    jmp     .vtopk_done
.vtopk_sink_failed:
    mov     eax, SQL_ERR_SINK
.vtopk_done:
    mov     rbx, [rbp - 224]
    mov     r12, [rbp - 232]
    mov     r13, [rbp - 240]
    mov     r14, [rbp - 248]
    mov     r15, [rbp - 256]
    mov     rsi, [rbp - 264]
    mov     rdi, [rbp - 272]
    FRAME_END
    ret

section .rodata
exec_error_message: db "invalid bound plan", 0
exec_oom_message: db "memory arena capacity exceeded", 0
exec_storage_message: db "storage execution failed", 0
exec_sink_message: db "SELECT requires a result callback", 0
exec_sink_failed_message: db "result callback reported a failure", 0
exec_active_tx_msg: db "cannot BEGIN inside active transaction", 0
exec_no_active_tx_commit_msg: db "no active transaction to COMMIT", 0
exec_no_active_tx_rollback_msg: db "no active transaction to ROLLBACK", 0
exec_readonly_tx_msg: db "database is read-only", 0

%ifdef CybouDB_LINUX
section .note.GNU-stack noalloc noexec nowrite progbits
%endif
