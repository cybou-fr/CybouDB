; =============================================================================
;  src/sql/executor.asm - Batch SQL Plan Executor (CREATE, INSERT, SELECT; UPDATE gated)
; =============================================================================

%include "sql.inc"
%include "order_executor.inc"
%include "select_cursor.inc"

BITS 64
default rel

extern db_catalog_put, db_catalog_drop, db_pax_insert, db_pax_update_one, db_pax_capacity, db_commit
extern db_var_write_chain
extern sql_select_open, sql_select_next
extern sql_arena_alloc
extern sql_join_execute
extern sql_order_init, sql_order_collect, sql_order_emit
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
    FRAME_BEGIN 1728, 1
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
    mov     eax, SQL_ERR_SYNTAX
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
    mov rax, [rbp - 208]
    mov [rbp - 248], rax            ; UPDATE_GROUP_SPANS
    mov rax, [rbp - 232]
    mov [rbp - 240], rax            ; UPDATE_GROUP_COUNT
    mov r10, [rbp - 16]
    mov ARG1, [rbp - 8]
    mov ARG2, [r10 + PLAN_TABLE_ID]
    mov ARG3, [r10 + PLAN_UPDATE_COL_IDX]
    mov ARG4, [r10 + PLAN_UPDATE_VALUE]
    mov rax, [r10 + PLAN_UPDATE_IS_NULL]
    PASS_ARG5 rax
    lea rax, [rbp - 248]
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
section .rodata
exec_error_message: db "invalid bound plan", 0
exec_oom_message: db "memory arena capacity exceeded", 0
exec_storage_message: db "storage execution failed", 0
exec_sink_message: db "SELECT requires a result callback", 0
exec_sink_failed_message: db "result callback reported a failure", 0
