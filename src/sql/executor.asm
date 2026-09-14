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

; What sql_index_patch is asked to do. The descriptor exists because six
; registers is what the ABI passes and this needs nine.
%define IXP_CTX        0
%define IXP_TABLE      8
%define IXP_SCHEMA     16               ; the address, current with the table
%define IXP_ARENA      24
%define IXP_SPANS      32               ; UPDATE_SPAN_SIZE entries
%define IXP_SPAN_COUNT 40
%define IXP_COLUMN     48               ; -1 for every index of the table
%define IXP_KEY        56               ; what an insert puts back
%define IXP_MODE       64
%define IXP_SIZE       72
%define IXP_MODE_REMOVE 0
%define IXP_MODE_INSERT 1

; Where sql_execute_batch keeps one of those, and the schema page id it reads
; on the way to filling it in. Below the DELETE scratch rather than inside it:
; a DELETE patches indexes too, and the two regions are live at once.
%define IXP_DESC_OFF    (DELETE_SCRATCH_BASE + 80)
%define IXP_PAGE_OFF    (DELETE_SCRATCH_BASE + 88)
; Where this execution found the schema. PLAN_SCHEMA_PAGE is an address the
; binder cached, and copy-on-write moves the page it names on every commit, so
; a prepared statement run a second time would read a page that has since been
; retired. The select cursor already guards its own use of that cache against
; the generation; the mutation paths re-resolve instead, which is what
; .exec_insert has always done.
%define UPD_SCHEMA_OFF  (DELETE_SCRATCH_BASE + 96)
%define EXEC_FRAME_SIZE (DELETE_SCRATCH_BASE + 128)

extern db_catalog_put, db_catalog_drop, db_catalog_truncate_data, db_pax_insert, db_pax_update_one, db_pax_capacity, db_commit, db_rollback
extern db_pax_mark_dead, db_pax_dead_total
extern db_catalog_put_index, db_catalog_set_index_root, db_index_of_table
extern db_catalog_put_queue, db_queue_push, db_queue_pop, db_queue_peek
extern db_queue_retire_all
extern sql_index_bounds
extern db_queue_claim, db_queue_ack, db_queue_nack, db_queue_renew
extern lease_find_slot, os_wall_ms, queue_slot_copy
extern db_catalog_put_stream, db_stream_retire_all, db_stream_append
extern db_stream_cursor_add, db_stream_cursor_drop
extern db_stream_peek, db_stream_read, db_stream_trim
extern db_catalog_page
extern db_index_retire_tree
extern db_index_insert, db_index_insert_unique, db_index_delete
extern db_index_search, db_index_node_addr
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
global sql_params_apply_predicates
global eval_predicate
global eval_predicate_encoded

section .data
; Times a SELECT found its row through a tree instead of by reading the
; table. A test can assert the answer and this together, which is the
; difference between a query that is right and a query that is right for
; the reason the plan claims.

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
;  sql_params_apply_predicates(plan) -> RAX: 0 applied, 1 something is unbound
;
;  A placeholder in a predicate fills the literal field of a bound expression
;  node. Doing it here rather than at bind time is what keeps the rule the
;  engine already holds: the plan is what prepare produced, and a bound value
;  is input to one execution. The node carries a zero until this runs, and
;  running it again writes the same field from the same slot - so applying it
;  twice is applying it once, and nothing has to be undone between executions.
;
;  Cells are not touched here. An INSERT restores its batch from the binder's
;  pristine copy at the top of its own execution, so its parameters have to go
;  on after that, and they do.
; -----------------------------------------------------------------------------
sql_params_apply_predicates:
    FRAME_BEGIN 32, 0
    mov     [rbp - 8], ARG1
    mov     r10, ARG1
    test    r10, r10
    jz      .ok
    mov     r11, [r10 + PLAN_PARAM_SLOTS]
    test    r11, r11
    jz      .ok
    mov     rcx, [r10 + PLAN_PARAM_COUNT]
    test    rcx, rcx
    jz      .ok
.next:
    dec     rcx
    mov     rdx, rcx
    shl     rdx, 6                      ; PARAM_SLOT_SIZE
    add     rdx, r11
    cmp     qword [rdx + PARAM_KIND], PARAM_TO_CELL
    je      .more                       ; an INSERT applies its own, later
    cmp     qword [rdx + PARAM_STATE], PARAM_UNBOUND
    je      .unbound
    mov     r8, [rdx + PARAM_TARGET]
    test    r8, r8
    jz      .more
    cmp     qword [rdx + PARAM_KIND], PARAM_TO_PLAN_UPDATE
    je      .to_assignment

    ; A predicate: the literal field of a bound comparison node.
    mov     rax, [rdx + PARAM_VAL]
    mov     [r8 + BEXPR_LIT_VAL], rax
    jmp     .more

.to_assignment:
    ; An UPDATE's SET value, which is a scalar or a pointer and a length.
    cmp     qword [rdx + PARAM_STATE], PARAM_NULL
    je      .assignment_null
    mov     rax, [rdx + PARAM_TYPE]
    cmp     rax, CAT_TEXT
    jae     .assignment_varlen
    mov     rax, [rdx + PARAM_VAL]
    mov     [r8 + PLAN_UPDATE_VALUE], rax
    mov     qword [r8 + PLAN_UPDATE_LENGTH], 0
    mov     qword [r8 + PLAN_UPDATE_IS_NULL], 0
    jmp     .more
.assignment_varlen:
    ; The engine's copy of the bytes, not the caller's pointer.
    mov     rax, [r8 + PLAN_PARAM_BUF]
    add     rax, PARAM_BUF_BYTES
    add     rax, [rdx + PARAM_VAL]
    mov     [r8 + PLAN_UPDATE_VALUE], rax
    mov     rax, [rdx + PARAM_LEN]
    mov     [r8 + PLAN_UPDATE_LENGTH], rax
    mov     qword [r8 + PLAN_UPDATE_IS_NULL], 0
    jmp     .more
.assignment_null:
    mov     qword [r8 + PLAN_UPDATE_VALUE], 0
    mov     qword [r8 + PLAN_UPDATE_LENGTH], 0
    mov     qword [r8 + PLAN_UPDATE_IS_NULL], 1
.more:
    test    rcx, rcx
    jnz     .next

    ; The index seek's key bounds, when they are arithmetic on a value that
    ; has just arrived. Which index the plan uses was decided at bind time and
    ; stays decided; only the range moves, and it is recomputed by the same
    ; routine the binder uses so the two cannot disagree.
    mov     r10, [rbp - 8]
    test    qword [r10 + PLAN_FLAGS], PLAN_FLAG_INDEX_SEEK_PARAM
    jz      .ok
    mov     ARG1, [r10 + PLAN_INDEX_PARAM_BEXPR]
    test    ARG1, ARG1
    jz      .ok
    lea     ARG2, [rbp - 16]
    lea     ARG3, [rbp - 24]
    call    sql_index_bounds
    test    eax, eax
    jz      .ok                         ; the binder would not have set the flag
    mov     r10, [rbp - 8]
    mov     rax, [rbp - 16]
    mov     [r10 + PLAN_INDEX_LO], rax
    mov     rax, [rbp - 24]
    mov     [r10 + PLAN_INDEX_HI], rax
.ok:
    xor     eax, eax
    FRAME_END
    ret
.unbound:
    mov     eax, 1
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
    FRAME_BEGIN EXEC_FRAME_SIZE, 2   ; a READ passes six
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

    ; Predicate parameters go on before anything reads the predicate. They are
    ; input to this execution, so they are applied per execution and the plan
    ; keeps the zero the binder left. After the arguments are in locals,
    ; because out_err has to be there for the refusal below to say anything.
    mov     ARG1, [rbp - 16]
    call    sql_params_apply_predicates
    test    eax, eax
    jz      .params_ok
    lea     r11, [exec_unbound_param_msg]
    jmp     .custom_exec_err
.params_ok:

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
    cmp     rax, STMT_CREATE_INDEX
    je      .exec_create_index
    cmp     rax, STMT_DROP_INDEX
    je      .exec_drop_index
    cmp     rax, STMT_CREATE_QUEUE
    je      .exec_create_queue
    cmp     rax, STMT_DROP_QUEUE
    je      .exec_drop_queue
    cmp     rax, STMT_CREATE_STREAM
    je      .exec_create_stream
    cmp     rax, STMT_DROP_STREAM
    je      .exec_drop_stream
    cmp     rax, STMT_APPEND
    je      .exec_append
    cmp     rax, STMT_READ
    je      .exec_read
    cmp     rax, STMT_TRIM
    je      .exec_trim
    cmp     rax, STMT_CREATE_CURSOR
    je      .exec_create_cursor
    cmp     rax, STMT_DROP_CURSOR
    je      .exec_drop_cursor
    cmp     rax, STMT_ENQUEUE
    je      .exec_enqueue
    cmp     rax, STMT_DEQUEUE
    je      .exec_dequeue
    cmp     rax, STMT_CLAIM
    je      .exec_claim
    cmp     rax, STMT_ACK
    je      .exec_ack
    cmp     rax, STMT_NACK
    je      .exec_nack
    cmp     rax, STMT_RENEW
    je      .exec_renew
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
    jnz     .commit_failed
    xor     eax, eax
    jmp     .exec_exit

.commit_failed:
    ; A refused commit leaves its pages staged, and the transaction is over.
    ; Discard them here: the next statement autocommits, and a staged graph
    ; that validates on the second attempt would otherwise be published along
    ; with whatever that statement wrote. db_rollback may itself refuse - a
    ; failed sync poisons the handle - and its code must not displace the one
    ; that explains why the commit did not happen.
    mov     [rbp - 48], rax
    mov     ARG1, [rbp - 8]
    call    db_rollback
    mov     rax, [rbp - 48]
    jmp     .storage_done

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
    test    eax, eax
    jnz     .storage_done
    mov     ARG1, [rbp - 8]
    mov     r10, [rbp - 16]
    mov     ARG2, [r10 + PLAN_TABLE_ID]
    call    sql_index_empty_all
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
    ; Room to remember which rows matched, so that marking them stays one
    ; scan rather than two. Only a file that reserved tombstone space can use
    ; it, and a refused allocation costs the mark path, not the statement:
    ; the rewrite below needs none of this.
    mov     qword [rbp - 64], 0         ; span array
    mov     qword [rbp - 72], 0         ; spans recorded
    mov     r11, [rbp - 8]
    test    qword [r11 + DB_FEATURES], CybouDB_FEATURE_TOMBSTONES
    jz      .delete_count_prep
    mov     rax, [rbp - 1752]
    add     rax, 63
    shr     rax, 6
    shl     rax, 4
    mov     ARG1, [rbp - 24]
    mov     ARG2, rax
    call    sql_arena_alloc
    mov     [rbp - 64], rax
.delete_count_prep:
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
    cmp     qword [rbp - 64], 0
    je      .delete_count_bits_ready
    mov     rax, [rbp - 72]
    shl     rax, 4
    add     rax, [rbp - 64]
    mov     r10, [rbp - 1760]
    mov     rcx, [rbp - 1728 + SEL_SCAN + SCAN_NEXT]
    sub     rcx, [r10 + BATCH_VIEW_ROWS]
    mov     [rax + UPDATE_SPAN_START], rcx
    mov     [rax + UPDATE_SPAN_MASK], rdx
    inc     qword [rbp - 72]
.delete_count_bits_ready:
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

    ; Three ways to remove rows, and the table decides which. Rows already
    ; dead count towards the decision: they are what a rewrite reclaims and
    ; what marking leaves behind.
    mov     ARG1, [rbp - 8]
    mov     ARG2, [rbp - 1744]
    call    db_pax_dead_total
    mov     [rbp - 80], rax
    add     rax, [rbp - 1776]
    cmp     rax, [rbp - 1752]
    jae     .exec_delete_truncate       ; nothing would survive
    cmp     qword [rbp - 64], 0
    je      .delete_rewrite             ; no tombstones, or no room to record
    shl     rax, 1
    cmp     rax, [rbp - 1752]
    ja      .delete_rewrite             ; past half dead: compact instead
    jmp     .delete_mark

    ; --- Marking: flip a bit per matched row, in place under COW ----------
    ; Spans are grouped by the leaf they land in, so one leaf is copied once
    ; however many batches selected rows inside it. This is the same grouping
    ; an UPDATE does, for the same reason.
.delete_mark:
    mov     ARG1, [rbp - 8]
    mov     ARG2, [rbp - 1744]
    call    db_pax_capacity
    test    rax, rax
    jz      .delete_rewrite             ; nothing to group by
    mov     [rbp - 88], rax             ; physical rows per leaf

    ; An index describes live rows, so the entries of the rows about to stop
    ; being live come out of it. Before the marking rather than after: the
    ; keys are read from the table, and a row that has been marked is one a
    ; scan is entitled to skip. Every index, because a DELETE removes whole
    ; rows rather than one column of them.
    mov     r10, [rbp - 8]
    mov     [rbp - IXP_DESC_OFF + IXP_CTX], r10
    mov     rax, [rbp - 1744]
    mov     [rbp - IXP_DESC_OFF + IXP_SCHEMA], rax
    mov     r11, [rbp - 16]
    mov     rax, [r11 + PLAN_TABLE_ID]
    mov     [rbp - IXP_DESC_OFF + IXP_TABLE], rax
    mov     rax, [rbp - 24]
    mov     [rbp - IXP_DESC_OFF + IXP_ARENA], rax
    mov     rax, [rbp - 64]
    mov     [rbp - IXP_DESC_OFF + IXP_SPANS], rax
    mov     rax, [rbp - 72]
    mov     [rbp - IXP_DESC_OFF + IXP_SPAN_COUNT], rax
    mov     qword [rbp - IXP_DESC_OFF + IXP_COLUMN], -1
    mov     qword [rbp - IXP_DESC_OFF + IXP_KEY], 0
    mov     qword [rbp - IXP_DESC_OFF + IXP_MODE], IXP_MODE_REMOVE
    lea     ARG1, [rbp - IXP_DESC_OFF]
    call    sql_index_patch
    test    eax, eax
    jnz     .storage_done

    mov     qword [rbp - 96], 0         ; spans applied
.delete_mark_apply:
    mov     rax, [rbp - 96]
    cmp     rax, [rbp - 72]
    jae     .delete_mark_done
    shl     rax, 4
    add     rax, [rbp - 64]
    mov     [rbp - 104], rax            ; first span of this group
    mov     rax, [rax + UPDATE_SPAN_START]
    xor     edx, edx
    div     qword [rbp - 88]
    mov     [rbp - 112], rax            ; the leaf they share
    mov     rcx, [rbp - 96]
.delete_mark_group:
    inc     rcx
    cmp     rcx, [rbp - 72]
    jae     .delete_mark_ready
    mov     rax, rcx
    shl     rax, 4
    add     rax, [rbp - 64]
    mov     rax, [rax + UPDATE_SPAN_START]
    xor     edx, edx
    div     qword [rbp - 88]
    cmp     rax, [rbp - 112]
    je      .delete_mark_group
.delete_mark_ready:
    sub     rcx, [rbp - 96]
    mov     [rbp - 240], rcx
    mov     rax, [rbp - 104]
    mov     [rbp - 296], rax            ; UPDATE_GROUP_SPANS
    mov     [rbp - 288], rcx            ; UPDATE_GROUP_COUNT
    mov     ARG1, [rbp - 8]
    mov     r10, [rbp - 16]
    mov     ARG2, [r10 + PLAN_TABLE_ID]
    lea     ARG3, [rbp - 296]
    call    db_pax_mark_dead
    test    eax, eax
    jnz     .storage_done
    mov     rax, [rbp - 240]
    add     [rbp - 96], rax
    jmp     .delete_mark_apply
.delete_mark_done:
    ; The entries came out before the marking, so there is nothing left to do
    ; here. Rebuilding the tree from the table was what stood here, and it
    ; cost the table: a DELETE of one row of fifty thousand took 101.9 ms
    ; where the same statement on the same table without an index took 7.2 ms.
    xor     eax, eax
    jmp     .exec_exit

    ; --- Pass 2: rewrite the survivors ------------------------------------
    ; The cursor is opened on the graph as it stands and keeps reading it
    ; after the truncation stages an empty root: append-only COW never
    ; overwrites a page the live generation still references, so the old
    ; leaves stay readable until this transaction commits.
.delete_rewrite:
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
    ; A row already marked dead is not a survivor either. The core scan
    ; reports the leaf's tombstones rather than applying them, so the rewrite
    ; that republishes this table has to, or a compaction would resurrect
    ; every row an earlier DELETE marked.
    mov     rcx, [rbp - 1984 + SCAN_DEAD]
    not     rcx
    and     rax, rcx
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
    ; A four-byte cell is INT32 or FLOAT32, and only one of them is a
    ; signed number. An INT32 that arrives zero-extended is out of range
    ; for the column it came from, so a table holding a negative one
    ; could not have a row deleted at all.
    mov     rdx, r8
    imul    rdx, CAT_COLUMN_SIZE
    add     rdx, [rbp - 1744]
    cmp     dword [rdx + CAT_COLUMNS], CAT_INT32
    jne     .delete_rewrite_store
    movsxd  rcx, ecx
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
    ; Every surviving row has moved, so every entry naming a row by position
    ; has stopped meaning what it said.
    mov     ARG1, [rbp - 8]
    mov     r10, [rbp - 16]
    mov     ARG2, [r10 + PLAN_TABLE_ID]
    lea     ARG3, [rbp - 64]
    call    db_catalog_get
    test    eax, eax
    jnz     .storage_done
    mov     r10, [rbp - 8]
    mov     rax, [rbp - 64]
    shl     rax, CybouDB_PAGE_SHIFT
    add     rax, [r10 + DB_BASE]
    mov     ARG3, rax
    mov     ARG1, r10
    mov     r11, [rbp - 16]
    mov     ARG2, [r11 + PLAN_TABLE_ID]
    mov     ARG4, [rbp - 24]
    mov     rax, -1
    PASS_ARG5 rax
    call    sql_index_rebuild_all
    test    eax, eax
    jnz     .storage_done
    xor     eax, eax
    jmp     .exec_exit

.exec_create_index:
    ; The catalog entry first, then the tree over the rows the table already
    ; has - which is the same work a compacting DELETE has to redo, so it is
    ; the same code.
    mov     ARG1, [rbp - 8]
    mov     r10, [rbp - 16]
    mov     ARG2, [r10 + PLAN_TABLE_ID]
    mov     ARG3, [r10 + PLAN_DATA1]
    call    db_catalog_put_index
    test    eax, eax
    jnz     .storage_done

    mov     ARG1, [rbp - 8]
    mov     r10, [rbp - 16]
    mov     ARG2, [r10 + PLAN_TABLE_ID]
    lea     ARG3, [rbp - 64]
    call    db_catalog_get
    test    eax, eax
    jnz     .storage_done
    mov     r10, [rbp - 8]
    mov     rax, [rbp - 64]
    shl     rax, CybouDB_PAGE_SHIFT
    add     rax, [r10 + DB_BASE]
    mov     ARG3, rax
    mov     ARG1, r10
    mov     r11, [rbp - 16]
    mov     ARG2, [r11 + PLAN_TABLE_ID]
    mov     ARG4, [r11 + PLAN_SCHEMA_PAGE]
    mov     rax, [rbp - 24]
    PASS_ARG5 rax
    call    sql_index_build_one
    jmp     .storage_done

.exec_drop_index:
    mov     ARG1, [rbp - 8]
    mov     r10, [rbp - 16]
    mov     ARG2, [r10 + PLAN_TABLE_ID]
    lea     ARG3, [rbp - 64]
    call    db_catalog_get
    test    eax, eax
    jnz     .storage_done
    mov     r10, [rbp - 8]
    mov     rax, [rbp - 64]
    shl     rax, CybouDB_PAGE_SHIFT
    add     rax, [r10 + DB_BASE]
    mov     ARG1, r10
    mov     ARG2, [rax + IDX_ROOT]
    call    db_index_retire_tree
    mov     ARG1, [rbp - 8]
    mov     r10, [rbp - 16]
    mov     ARG2, [r10 + PLAN_TABLE_ID]
    call    db_catalog_drop
    jmp     .storage_done

; A queue is one catalog page and nothing else until something enqueues, so
; creating one is the entry and dropping one is its removal. When segments
; exist the drop will have to retire them, the way dropping an index retires
; its tree - which is why that is a line in the roadmap and not a silence here.
.exec_create_queue:
    mov     ARG1, [rbp - 8]
    mov     r10, [rbp - 16]
    mov     ARG2, [r10 + PLAN_TABLE_ID]
    mov     ARG3, [r10 + PLAN_DATA1]
    call    db_catalog_put_queue
    jmp     .storage_done

; The same page image, and a different shape check over it: what makes the
; zeroed page with a name in it a stream rather than a queue is which entry
; point the catalog publishes it through.
.exec_create_stream:
    mov     ARG1, [rbp - 8]
    mov     r10, [rbp - 16]
    mov     ARG2, [r10 + PLAN_TABLE_ID]
    mov     ARG3, [r10 + PLAN_DATA1]
    call    db_catalog_put_stream
    jmp     .storage_done

; As with a queue, the pages it is holding go before the entry that names
; them. A stream has none until something appends, and this is written for
; when it does rather than left to be remembered then.
.exec_drop_stream:
    mov     ARG1, [rbp - 8]
    mov     r10, [rbp - 16]
    mov     ARG2, [r10 + PLAN_TABLE_ID]
    call    db_stream_retire_all
    test    eax, eax
    jnz     .storage_done
    mov     ARG1, [rbp - 8]
    mov     r10, [rbp - 16]
    mov     ARG2, [r10 + PLAN_TABLE_ID]
    call    db_catalog_drop
    jmp     .storage_done

.exec_enqueue:
    mov     ARG1, [rbp - 8]
    mov     r10, [rbp - 16]
    mov     ARG2, [r10 + PLAN_TABLE_ID]
    mov     ARG3, [r10 + PLAN_DATA1]
    mov     ARG4, [r10 + PLAN_DATA2]
    call    db_queue_push
    jmp     .storage_done

.exec_append:
    mov     ARG1, [rbp - 8]
    mov     r10, [rbp - 16]
    mov     ARG2, [r10 + PLAN_TABLE_ID]
    mov     ARG3, [r10 + PLAN_DATA1]
    mov     ARG4, [r10 + PLAN_DATA2]
    call    db_stream_append
    jmp     .storage_done

; A record comes back the way a message does: through the plan, because a READ
; answers with one value and a stream has no schema to present it as a row. The
; peek is what sizes the buffer, and it hands back the cursor so that the read
; does not resolve the reader's name a second time.
.exec_read:
    mov     r10, [rbp - 16]
    mov     qword [r10 + PLAN_DATA3], 0
    lea     r11, [rbp - 1848]
    PASS_ARG6 r11                   ; which cursor it turned out to be
    lea     r11, [rbp - 1840]
    PASS_ARG5 r11                   ; how much room the record needs
    mov     ARG4, [r10 + PLAN_READER_LEN]
    mov     ARG3, [r10 + PLAN_READER_PTR]
    mov     ARG2, [r10 + PLAN_TABLE_ID]
    mov     ARG1, [rbp - 8]
    call    db_stream_peek
    cmp     eax, CybouDB_E_NOTFOUND
    je      .read_caught_up
    test    eax, eax
    jnz     .storage_done
    mov     ARG2, [rbp - 1840]
    test    ARG2, ARG2
    jnz     .read_sized
    mov     ARG2, 1                 ; a record of no bytes still needs an address
.read_sized:
    mov     ARG1, [rbp - 24]
    call    sql_arena_alloc
    test    rax, rax
    jz      .read_oom
    mov     r10, [rbp - 16]
    mov     [r10 + PLAN_DATA1], rax
    mov     r11, [rbp - 1840]
    PASS_ARG6 r11                   ; capacity: exactly what the peek asked for
    lea     r11, [rbp - 1856]
    PASS_ARG5 r11
    mov     ARG4, rax
    mov     ARG3, [rbp - 1848]
    mov     ARG2, [r10 + PLAN_TABLE_ID]
    mov     ARG1, [rbp - 8]
    call    db_stream_read
    cmp     eax, CybouDB_E_NOTFOUND
    je      .read_caught_up
    test    eax, eax
    jnz     .storage_done
    mov     r10, [rbp - 16]
    mov     r11, [rbp - 1856]
    mov     [r10 + PLAN_DATA2], r11
    mov     qword [r10 + PLAN_DATA3], 1
    xor     eax, eax
    jmp     .exec_exit
.read_caught_up:
    xor     eax, eax
    jmp     .exec_exit
.read_oom:
    mov     eax, SQL_ERR_NO_STORAGE
    jmp     .exec_exit

.exec_trim:
    mov     ARG1, [rbp - 8]
    mov     r10, [rbp - 16]
    mov     ARG2, [r10 + PLAN_TABLE_ID]
    mov     ARG3, [r10 + PLAN_DATA1]
    call    db_stream_trim
    jmp     .storage_done

.exec_create_cursor:
    mov     ARG1, [rbp - 8]
    mov     r10, [rbp - 16]
    mov     ARG2, [r10 + PLAN_TABLE_ID]
    mov     ARG3, [r10 + PLAN_READER_PTR]
    mov     ARG4, [r10 + PLAN_READER_LEN]
    call    db_stream_cursor_add
    jmp     .storage_done

.exec_drop_cursor:
    mov     ARG1, [rbp - 8]
    mov     r10, [rbp - 16]
    mov     ARG2, [r10 + PLAN_TABLE_ID]
    mov     ARG3, [r10 + PLAN_READER_PTR]
    mov     ARG4, [r10 + PLAN_READER_LEN]
    call    db_stream_cursor_drop
    jmp     .storage_done

; The message comes back through the plan, because a DEQUEUE answers with one
; value and not with rows: it has no columns to describe and no schema to
; describe them from. PLAN_DATA3 says whether there was one at all, which is
; how an empty queue differs from a message of no bytes.
.exec_dequeue:
    mov     r10, [rbp - 16]
    mov     qword [r10 + PLAN_DATA3], 0
    ; How much room the message needs, before taking it. A queue holds bytes
    ; and not a column, so there is no width to read off a schema - asking is
    ; the only way a caller can size a buffer that a longer message would not
    ; simply be unable to leave the queue through.
    mov     ARG1, [rbp - 8]
    mov     ARG2, [r10 + PLAN_TABLE_ID]
    lea     ARG3, [rbp - 1840]
    call    db_queue_peek
    cmp     eax, CybouDB_E_NOTFOUND
    je      .dequeue_empty
    test    eax, eax
    jnz     .storage_done
    mov     ARG2, [rbp - 1840]
    test    ARG2, ARG2
    jnz     .dequeue_sized
    mov     ARG2, 1                 ; a message of no bytes still needs an address
.dequeue_sized:
    mov     ARG1, [rbp - 24]
    call    sql_arena_alloc
    test    rax, rax
    jz      .dequeue_oom
    mov     r10, [rbp - 16]
    mov     [r10 + PLAN_DATA1], rax
    mov     ARG3, rax
    mov     rcx, [rbp - 1840]
    PASS_ARG5 rcx
    mov     ARG1, [rbp - 8]
    mov     ARG2, [r10 + PLAN_TABLE_ID]
    lea     ARG4, [r10 + PLAN_DATA2]
    call    db_queue_pop
    cmp     eax, CybouDB_E_NOTFOUND
    je      .dequeue_empty
    test    eax, eax
    jnz     .storage_done
    mov     r10, [rbp - 16]
    mov     qword [r10 + PLAN_DATA3], 1
    xor     eax, eax
    jmp     .exec_exit
.dequeue_empty:
    xor     eax, eax
    jmp     .exec_exit
.dequeue_oom:
    mov     eax, SQL_ERR_NO_STORAGE
    jmp     .exec_exit

; --- CLAIM -------------------------------------------------------------------
; A DEQUEUE's shape, because a caller reads the bytes the same way: PLAN_DATA1
; is where they are, PLAN_DATA2 how many, and PLAN_DATA3 says whether this step
; took anything at all. What a claim adds is the ticket.
.exec_claim:
    mov     r10, [rbp - 16]
    mov     qword [r10 + PLAN_DATA3], 0
    call    os_wall_ms
    mov     [rbp - 48], rax
    mov     r10, [rbp - 16]
    mov     ARG1, [rbp - 8]
    mov     ARG2, [r10 + PLAN_TABLE_ID]
    mov     ARG3, [rbp - 48]
    mov     ARG4, [r10 + PLAN_LEASE_DURATION]
    lea     rax, [r10 + PLAN_LEASE_POSITION]
    PASS_ARG5 rax
    lea     rax, [r10 + PLAN_LEASE_TOKEN]
    PASS_ARG6 rax
    call    db_queue_claim
    cmp     eax, CybouDB_E_NOTFOUND
    je      .claim_empty
    test    eax, eax
    jnz     .storage_done

    ; The bytes, copied out of the segment into the arena before anything else
    ; moves: the page they are in may be rewritten by the next operation.
    mov     r10, [rbp - 16]
    mov     ARG1, [rbp - 8]
    mov     ARG2, [r10 + PLAN_TABLE_ID]
    mov     ARG3, [r10 + PLAN_LEASE_POSITION]
    call    lease_find_slot
    test    rax, rax
    jz      .claim_empty
    mov     [rbp - 56], rax
    mov     ecx, [rax + QMSG_LENGTH]
    mov     [rbp - 64], rcx
    mov     ARG2, rcx
    test    ARG2, ARG2
    jnz     .claim_sized
    mov     ARG2, 1                 ; a message of no bytes still needs one
.claim_sized:
    mov     ARG1, [rbp - 24]
    call    sql_arena_alloc
    test    rax, rax
    jz      .claim_oom
    mov     r10, [rbp - 16]
    mov     [r10 + PLAN_DATA1], rax
    ; queue_slot_copy(ctx, id, slot, out, out length, capacity) - the same six
    ; db_queue_pop hands it, because it is the same copy.
    mov     rcx, [rbp - 64]
    PASS_ARG6 rcx
    lea     rcx, [rbp - 72]
    PASS_ARG5 rcx
    mov     ARG4, rax
    mov     ARG3, [rbp - 56]
    mov     ARG1, [rbp - 8]
    mov     ARG2, [r10 + PLAN_TABLE_ID]
    call    queue_slot_copy
    test    eax, eax
    jnz     .storage_done
    mov     r10, [rbp - 16]
    mov     rcx, [rbp - 72]
    mov     [r10 + PLAN_DATA2], rcx
    mov     qword [r10 + PLAN_DATA3], 1
    xor     eax, eax
    jmp     .exec_exit
.claim_empty:
    xor     eax, eax
    jmp     .exec_exit
.claim_oom:
    mov     eax, SQL_ERR_NO_STORAGE
    jmp     .exec_exit

; --- ACK / NACK / RENEW ------------------------------------------------------
.exec_ack:
    mov     r10, [rbp - 16]
    mov     ARG1, [rbp - 8]
    mov     ARG2, [r10 + PLAN_TABLE_ID]
    mov     ARG3, [r10 + PLAN_LEASE_POSITION]
    mov     ARG4, [r10 + PLAN_LEASE_TOKEN]
    call    db_queue_ack
    jmp     .storage_done

.exec_nack:
    mov     r10, [rbp - 16]
    mov     ARG1, [rbp - 8]
    mov     ARG2, [r10 + PLAN_TABLE_ID]
    mov     ARG3, [r10 + PLAN_LEASE_POSITION]
    mov     ARG4, [r10 + PLAN_LEASE_TOKEN]
    call    db_queue_nack
    jmp     .storage_done

.exec_renew:
    call    os_wall_ms
    mov     [rbp - 48], rax
    mov     r10, [rbp - 16]
    mov     ARG1, [rbp - 8]
    mov     ARG2, [r10 + PLAN_TABLE_ID]
    mov     ARG3, [r10 + PLAN_LEASE_POSITION]
    mov     ARG4, [r10 + PLAN_LEASE_TOKEN]
    mov     rax, [rbp - 48]
    PASS_ARG5 rax
    mov     rax, [r10 + PLAN_LEASE_DURATION]
    PASS_ARG6 rax
    call    db_queue_renew
    jmp     .storage_done

.exec_drop_queue:
    ; The pages it is holding go first. Removing the directory entry takes
    ; the last reference to them with it, and a payload page nothing
    ; references is one nothing will hand out again.
    mov     ARG1, [rbp - 8]
    mov     r10, [rbp - 16]
    mov     ARG2, [r10 + PLAN_TABLE_ID]
    call    db_queue_retire_all
    test    eax, eax
    jnz     .storage_done
    mov     ARG1, [rbp - 8]
    mov     r10, [rbp - 16]
    mov     ARG2, [r10 + PLAN_TABLE_ID]
    call    db_catalog_drop
    jmp     .storage_done

.exec_drop:
    mov     ARG1, [rbp - 8]
    mov     ARG2, [r10 + PLAN_TABLE_ID]
    call    sql_index_drop_all
    test    eax, eax
    jnz     .storage_done
    mov     ARG1, [rbp - 8]
    mov     r10, [rbp - 16]
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
    ; The bound batch is restored from the copy the binder took before anything
    ; touches it. Materialising a TEXT, BLOB or VECTOR cell writes that cell's
    ; extent root over the pointer to its literal bytes, so a prepared INSERT
    ; stepped a second time would otherwise read a page id as an address. The
    ; plan is what prepare produced and has to stay that way; execution works
    ; on values it restored for itself.
    mov     r10, [rbp - 16]
    mov     r11, [r10 + PLAN_INSERT_PRISTINE]
    test    r11, r11
    jz      .insert_values_ready
    mov     rcx, [r10 + PLAN_INSERT_CELLS]
    test    rcx, rcx
    jz      .insert_values_ready
    mov     rax, [r10 + PLAN_DATA1]
    mov     rax, [rax + BATCH_VALUES]
    test    rax, rax
    jz      .insert_values_ready
.insert_restore:
    dec     rcx
    mov     rdx, [r11 + rcx * 8]
    mov     [rax + rcx * 8], rdx
    test    rcx, rcx
    jnz     .insert_restore
.insert_values_ready:

    ; Bound parameters go on here, over the values the restore just put back.
    ; They are input to this execution rather than part of the plan, which is
    ; why they are applied afterwards and not written into what prepare
    ; produced: the plan stays what it was, and the next execution starts from
    ; the same place with whatever is bound by then.
    ;
    ; All three arrays are written for every parameter, so applying them twice
    ; is applying them once - no state from the previous execution survives to
    ; be undone. Only volatile registers are used: this function does not save
    ; rsi, rdi or rbx, so it does not get to borrow them.
    mov     r10, [rbp - 16]
    mov     r11, [r10 + PLAN_PARAM_SLOTS]
    test    r11, r11
    jz      .insert_params_ready
    mov     rcx, [r10 + PLAN_PARAM_COUNT]
    test    rcx, rcx
    jz      .insert_params_ready
    mov     r10, [r10 + PLAN_DATA1]
    test    r10, r10
    jz      .insert_params_ready
    cmp     qword [r10 + BATCH_VALUES], 0
    je      .insert_params_ready

.insert_param_next:
    dec     rcx
    mov     rdx, rcx
    shl     rdx, 6                      ; PARAM_SLOT_SIZE
    add     rdx, r11                    ; the slot
    cmp     qword [rdx + PARAM_STATE], PARAM_UNBOUND
    je      .insert_unbound

    mov     r9, [rbp - 16]
    mov     r8, [r9 + PLAN_DATA1]
    mov     rax, [rdx + PARAM_CELL]
    mov     r10, [r8 + BATCH_NULLS]
    cmp     qword [rdx + PARAM_STATE], PARAM_NULL
    je      .insert_param_null

    mov     byte [r10 + rax], 0
    mov     r10, [r8 + BATCH_VALUES]
    mov     r9, [rdx + PARAM_TYPE]
    cmp     r9, CAT_TEXT
    jb      .insert_param_scalar

    ; TEXT, BLOB and VECTOR. The cell names where the engine put the bytes and
    ; not where the caller had them: the caller's buffer stopped mattering the
    ; moment the bind returned.
    mov     r9, [rbp - 16]
    mov     r9, [r9 + PLAN_PARAM_BUF]
    add     r9, PARAM_BUF_BYTES
    add     r9, [rdx + PARAM_VAL]
    mov     [r10 + rax * 8], r9
    mov     r9, [r8 + BATCH_VAR_LENGTHS]
    test    r9, r9
    jz      .insert_param_more
    mov     r8, [rdx + PARAM_LEN]
    mov     [r9 + rax * 8], r8
    jmp     .insert_param_more

.insert_param_scalar:
    mov     r9, [rdx + PARAM_VAL]
    mov     [r10 + rax * 8], r9
    mov     r9, [r8 + BATCH_VAR_LENGTHS]
    test    r9, r9
    jz      .insert_param_more
    mov     qword [r9 + rax * 8], 0
    jmp     .insert_param_more

.insert_param_null:
    mov     byte [r10 + rax], 1
    mov     r10, [r8 + BATCH_VALUES]
    mov     qword [r10 + rax * 8], 0
    mov     r9, [r8 + BATCH_VAR_LENGTHS]
    test    r9, r9
    jz      .insert_param_more
    mov     qword [r9 + rax * 8], 0

.insert_param_more:
    test    rcx, rcx
    jnz     .insert_param_next
    jmp     .insert_params_ready

.insert_unbound:
    ; A NULL would be the quiet answer and it is the wrong one: a statement
    ; whose value never arrived has not been told what to insert.
    lea     r11, [exec_unbound_param_msg]
    jmp     .custom_exec_err

.insert_params_ready:
    mov     r10, [rbp - 16]

    ; Where the appended rows will sit, read before the append moves it.
    ; Through db_catalog_page rather than db_catalog_get: the second validates
    ; the whole staged graph, which is a walk proportional to the table, and
    ; doing it per INSERT is exactly what this path used to avoid.
    mov     ARG1, [rbp - 8]
    mov     ARG2, [r10 + PLAN_TABLE_ID]
    call    db_catalog_page
    test    rax, rax
    jnz     .insert_schema_found
    mov     eax, CybouDB_E_NOTFOUND     ; a lookup that finds nothing is
    jmp     .storage_done               ; an error, not a quiet success
.insert_schema_found:
    mov     [rbp - 72], rax             ; schema
    mov     rcx, [rax + CAT_TABLE_ROWS]
    mov     [rbp - 80], rcx             ; the first row this INSERT adds

    mov     ARG1, [rbp - 8]
    mov     r10, [rbp - 16]
    mov     ARG2, [r10 + PLAN_TABLE_ID]
    mov     ARG3, [r10 + PLAN_DATA1]
    call    db_pax_insert
    test    eax, eax
    jnz     .storage_done
    mov     ARG1, [rbp - 8]
    mov     r10, [rbp - 16]
    mov     ARG2, [r10 + PLAN_TABLE_ID]
    mov     ARG3, [rbp - 72]
    mov     ARG4, [r10 + PLAN_DATA1]
    mov     rax, [rbp - 80]
    PASS_ARG5 rax
    call    sql_index_insert_batch
    jmp     .storage_done
.exec_update:
    ; An UPDATE reports how many rows it changed by leaving the count in
    ; PLAN_DATA1, which is where a SELECT plan keeps its projection count - so
    ; the scan this statement opens next time would read that count and follow
    ; PLAN_DATA2 as an array of projections that an UPDATE never had. The plan
    ; starts every execution the way the binder left it.
    mov     r10, [rbp - 16]
    mov     qword [r10 + PLAN_DATA1], 0
    mov     qword [r10 + PLAN_DATA2], 0
    mov     qword [r10 + PLAN_DATA3], 0

    ; The schema as it is now, not as it was when this plan was bound.
    mov     ARG1, [rbp - 8]
    mov     r10, [rbp - 16]
    mov     ARG2, [r10 + PLAN_TABLE_ID]
    call    db_catalog_page
    test    rax, rax
    jnz     .update_schema_found
    mov     eax, CybouDB_E_NOTFOUND
    jmp     .storage_done
.update_schema_found:
    mov [rbp - UPD_SCHEMA_OFF], rax
    mov r11, rax
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
    mov ARG2, [rbp - UPD_SCHEMA_OFF]
    call db_pax_capacity
    mov [rbp - 216], rax            ; physical rows per leaf

    ; Every index over the column this statement writes names the keys those
    ; rows carry now, and they are about to stop carrying them. The entries
    ; come out while the table can still say what they were; they go back in
    ; after the write, under the one key every row it touched now has.
    mov ARG1, [rbp - 8]
    mov r10, [rbp - 16]
    mov ARG2, [r10 + PLAN_TABLE_ID]
    lea ARG3, [rbp - IXP_PAGE_OFF]
    call db_catalog_get
    test eax, eax
    jnz .storage_done
    mov r10, [rbp - 8]
    mov [rbp - IXP_DESC_OFF + IXP_CTX], r10
    mov rax, [rbp - IXP_PAGE_OFF]
    shl rax, CybouDB_PAGE_SHIFT
    add rax, [r10 + DB_BASE]
    mov [rbp - IXP_DESC_OFF + IXP_SCHEMA], rax
    mov r11, [rbp - 16]
    mov rax, [r11 + PLAN_TABLE_ID]
    mov [rbp - IXP_DESC_OFF + IXP_TABLE], rax
    mov rax, [rbp - 24]
    mov [rbp - IXP_DESC_OFF + IXP_ARENA], rax
    mov rax, [rbp - 168]
    mov [rbp - IXP_DESC_OFF + IXP_SPANS], rax
    mov rax, [rbp - 176]
    mov [rbp - IXP_DESC_OFF + IXP_SPAN_COUNT], rax
    mov rax, [r11 + PLAN_UPDATE_COL_IDX]
    mov [rbp - IXP_DESC_OFF + IXP_COLUMN], rax
    mov rax, [r11 + PLAN_UPDATE_VALUE]
    mov [rbp - IXP_DESC_OFF + IXP_KEY], rax
    mov qword [rbp - IXP_DESC_OFF + IXP_MODE], IXP_MODE_REMOVE
    lea ARG1, [rbp - IXP_DESC_OFF]
    call sql_index_patch
    test eax, eax
    jnz .storage_done
.update_apply:
    mov rax, [rbp - 200]
    cmp rax, [rbp - 176]
    jae .update_indexes
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
.update_indexes:
    ; The rows did not move, and their entries came out before the write. The
    ; column now holds one value in every row this statement touched, so what
    ; goes back is that key and the rows it names - not a tree rebuilt from a
    ; table it never stopped describing.
    mov r10, [rbp - 16]
    cmp qword [r10 + PLAN_UPDATE_IS_NULL], 0
    jne .success                    ; a NULL has no entry to put back

    ; The schema this statement started from is a generation behind: the
    ; write republished the leaves.
    mov ARG1, [rbp - 8]
    mov ARG2, [r10 + PLAN_TABLE_ID]
    lea ARG3, [rbp - IXP_PAGE_OFF]
    call db_catalog_get
    test eax, eax
    jnz .storage_done
    mov r10, [rbp - 8]
    mov rax, [rbp - IXP_PAGE_OFF]
    shl rax, CybouDB_PAGE_SHIFT
    add rax, [r10 + DB_BASE]
    mov [rbp - IXP_DESC_OFF + IXP_SCHEMA], rax
    mov qword [rbp - IXP_DESC_OFF + IXP_MODE], IXP_MODE_INSERT
    lea ARG1, [rbp - IXP_DESC_OFF]
    call sql_index_patch
    test eax, eax
    jnz .storage_done
    jmp .success
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
;  sql_index_build_one(ctx, index id, index page, schema, arena)
;      -> RAX: result code
;
;  Builds one index over the rows a table has now, and publishes it. This is
;  what CREATE INDEX does, and what a compacting DELETE has to do again: the
;  rewrite moves every surviving row, so every entry naming a row by position
;  stops meaning what it said.
;
;  One insert per row rather than a sorted bulk load: the rows arrive in row
;  order, not key order, and sorting them would need somewhere to put them.
;  The tree is the place they get sorted.
;
;  Local slots: [rbp-8]=ctx, [rbp-16]=index id, [rbp-24]=index page,
;               [rbp-32]=schema, [rbp-40]=arena, [rbp-48]=column,
;               [rbp-56]=unique, [rbp-64]=root, [rbp-72]=entries,
;               [rbp-80]=batch view, [rbp-88]=decode storage, [rbp-96]=mask,
;               [rbp-104]=first row of this batch, [rbp-112]=rows in it,
;               [rbp-120]=live lanes, [rbp-128]=the column's view,
;               [rbp-136]=lane, [rbp-144]=is int32, [rbp-2176]=cursor
; -----------------------------------------------------------------------------
sql_index_build_one:
    FRAME_BEGIN 2240, 2
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
    mov [rbp - 24], ARG3
    mov [rbp - 32], ARG4
    mov rax, IN_ARG5
    mov [rbp - 40], rax
    mov r10, ARG3
    mov ecx, [r10 + IDX_COLUMN]
    mov [rbp - 48], rcx
    mov ecx, [r10 + IDX_FLAGS]
    mov [rbp - 56], rcx
    mov qword [rbp - 64], 0
    mov qword [rbp - 72], 0
    ; Whatever this index held is about to stop being named by anything.
    mov ARG1, [rbp - 8]
    mov ARG2, [r10 + IDX_ROOT]
    call db_index_retire_tree

    ; INT32 is stored sign-extended, and the tree orders signed keys.
    mov r11, [rbp - 32]
    mov rax, [rbp - 48]
    imul rax, CAT_COLUMN_SIZE
    mov ecx, [r11 + CAT_COLUMNS + rax]
    xor eax, eax
    cmp ecx, CAT_INT32
    sete al
    mov [rbp - 144], rax

    mov rax, [rbp - 48]
    mov rcx, rax
    mov rax, 1
    shl rax, cl
    mov [rbp - 96], rax             ; just the column being indexed

    mov r11, [rbp - 32]
    cmp qword [r11 + CAT_TABLE_ROWS], 0
    je .publish

    mov ARG1, [rbp - 40]
    mov ARG2, CybouDB_BATCH_VIEW_SIZE
    call sql_arena_alloc
    test rax, rax
    jz .oom
    mov [rbp - 80], rax
    mov qword [rbp - 88], 0
    mov r10, [rbp - 8]
    test qword [r10 + DB_FEATURES], CybouDB_FEATURE_COMPRESSION
    jz .scan_open
    mov ARG1, [rbp - 40]
    mov ARG2, PAX_DECODE_MAX_BYTES
    call sql_arena_alloc
    test rax, rax
    jz .oom
    mov [rbp - 88], rax
.scan_open:
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 32]
    lea ARG3, [rbp - 2176]
    call db_pax_scan_open_bound
    test eax, eax
    jnz .done
    mov qword [rbp - 104], 0

.batch:
    lea ARG1, [rbp - 2176]
    mov ARG2, [rbp - 80]
    mov ARG3, [rbp - 96]
    mov ARG4, [rbp - 88]
    call db_pax_scan_batch
    test eax, eax
    jnz .done
    test rdx, rdx
    jz .publish
    mov [rbp - 112], rdx

    ; A row the table has marked dead is not a row the index names.
    mov rax, [rbp - 2176 + SCAN_DEAD]
    not rax
    mov rcx, 64
    sub rcx, [rbp - 112]
    mov rdx, -1
    shr rdx, cl
    and rax, rdx
    mov [rbp - 120], rax

    mov rax, [rbp - 48]
    imul rax, CybouDB_COLVIEW_SIZE
    add rax, [rbp - 80]
    add rax, BATCH_VIEW_COLUMNS
    mov [rbp - 128], rax

.row:
    mov rax, [rbp - 120]
    test rax, rax
    jz .batch_done
    bsf rcx, rax
    mov [rbp - 136], rcx
    lea rdx, [rax - 1]
    and rax, rdx
    mov [rbp - 120], rax

    ; A NULL has no key, so the index stores nothing for it.
    mov r8, [rbp - 128]
    mov rcx, [rbp - 136]
    bt qword [r8 + COLVIEW_NULL_MASK], rcx
    jc .row

    mov r9, [r8 + COLVIEW_VALUES_PTR]
    cmp qword [rbp - 144], 0
    je .key_64
    movsxd rdx, dword [r9 + rcx * 4]
    jmp .key_ready
.key_64:
    mov rdx, [r9 + rcx * 8]
.key_ready:
    ; Into a slot before any argument register is loaded: ARG2 is RDX on one
    ; of the two ABIs, and the key would go with it.
    mov [rbp - 152], rdx
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    mov ARG3, [rbp - 64]
    mov ARG4, [rbp - 152]
    mov rax, [rbp - 104]
    add rax, [rbp - 136]
    PASS_ARG5 rax
    lea rax, [rbp - 64]
    PASS_ARG6 rax
    cmp qword [rbp - 56], 0
    jne .unique
    call db_index_insert
    jmp .inserted
.unique:
    call db_index_insert_unique
.inserted:
    test eax, eax
    jnz .done
    inc qword [rbp - 72]
    jmp .row

.batch_done:
    mov rax, [rbp - 112]
    add [rbp - 104], rax
    jmp .batch

.publish:
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    mov ARG3, [rbp - 64]
    mov ARG4, [rbp - 72]
    call db_catalog_set_index_root
.done:
    FRAME_END
    ret
.oom:
    mov eax, SQL_ERR_NO_STORAGE
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  The entries of a set of rows, taken out of every index that names them, and
;  put back under a new key.
;
;  Rows that do not move keep their entries valid, so a statement that marks
;  rows dead or writes one column of them has no reason to rebuild an index
;  over the whole table: it has to reach the rows it touched and no others. A
;  span is a 64-row group and a mask of the lanes in it, which is the shape the
;  predicate already produced, so what this costs is the groups those rows sit
;  in.
;
;  What it replaces cost the table. An UPDATE of one row of fifty thousand took
;  93.7 ms where the same statement against the same table without an index
;  took 1.1 ms, and a DELETE of one row took 101.9 ms against 7.2 ms.
;
;  Removing and inserting are separate calls because they happen on either side
;  of the write. The old key is in the table until the statement overwrites it,
;  and the new one is only there afterwards. Doing both in one pass would also
;  have a unique index refuse the first row to take a key that a later row in
;  the same statement is about to give up.
;
;  IXP_MODE_REMOVE reads each row's current key and deletes that entry.
;  IXP_MODE_INSERT puts IXP_KEY there instead, for every row in the spans.
;
;  Local slots: [rbp-8]=descriptor, [rbp-16]=index page, [rbp-24]=index id,
;               [rbp-32]=id walked past, [rbp-40]=root, [rbp-48]=rows,
;               [rbp-56]=column, [rbp-64]=INT32, [rbp-72]=batch view,
;               [rbp-80]=decode buffer, [rbp-88]=column mask, [rbp-96]=span,
;               [rbp-104]=span mask, [rbp-112]=row, [rbp-120]=rows in batch,
;               [rbp-128]=column view, [rbp-136]=key, [rbp-144]=flags,
;               [rbp-152]=the key an insert puts back,
;               [rbp-2176]=scan
; -----------------------------------------------------------------------------
sql_index_patch:
    FRAME_BEGIN 2240, 2
    mov [rbp - 8], ARG1
    mov r10, [ARG1 + IXP_CTX]
    test qword [r10 + DB_FEATURES], CybouDB_FEATURE_INDEX
    jz .ok
    mov r11, [rbp - 8]
    cmp qword [r11 + IXP_SPAN_COUNT], 0
    je .ok

    mov r11, [rbp - 8]
    mov ARG1, [r11 + IXP_ARENA]
    mov ARG2, CybouDB_BATCH_VIEW_SIZE
    call sql_arena_alloc
    test rax, rax
    jz .oom
    mov [rbp - 72], rax
    mov qword [rbp - 80], 0
    mov r11, [rbp - 8]
    mov r10, [r11 + IXP_CTX]
    test qword [r10 + DB_FEATURES], CybouDB_FEATURE_COMPRESSION
    jz .indexes
    mov ARG1, [r11 + IXP_ARENA]
    mov ARG2, PAX_DECODE_MAX_BYTES
    call sql_arena_alloc
    test rax, rax
    jz .oom
    mov [rbp - 80], rax

.indexes:
    mov qword [rbp - 32], 0
.next_index:
    mov r11, [rbp - 8]
    mov ARG1, [r11 + IXP_CTX]
    mov ARG2, [r11 + IXP_TABLE]
    mov ARG3, [rbp - 32]
    lea ARG4, [rbp - 24]
    call db_index_of_table
    test rax, rax
    jz .ok
    mov [rbp - 16], rax
    mov ecx, [rax + IDX_COLUMN]
    mov [rbp - 56], rcx
    mov ecx, [rax + IDX_FLAGS]
    mov [rbp - 144], rcx
    mov rcx, [rax + IDX_ROOT]
    mov [rbp - 40], rcx
    mov rcx, [rax + IDX_ROWS]
    mov [rbp - 48], rcx
    mov r11, [rbp - 8]
    mov rax, [r11 + IXP_COLUMN]
    cmp rax, -1
    je .column_wanted
    cmp rax, [rbp - 56]
    jne .skip
.column_wanted:

    ; INT32 is stored sign-extended, and the tree orders signed keys.
    mov r11, [rbp - 8]
    mov r10, [r11 + IXP_SCHEMA]
    mov rax, [rbp - 56]
    imul rax, CAT_COLUMN_SIZE
    mov ecx, [r10 + CAT_COLUMNS + rax]
    xor eax, eax
    cmp ecx, CAT_INT32
    sete al
    mov [rbp - 64], rax

    ; The key an insert puts back, ordered the way the tree orders it.
    mov r11, [rbp - 8]
    mov rdx, [r11 + IXP_KEY]
    cmp qword [rbp - 64], 0
    je .new_key_ready
    movsxd rdx, edx
.new_key_ready:
    mov [rbp - 152], rdx

    mov rax, [rbp - 56]
    mov rcx, rax
    mov rax, 1
    shl rax, cl
    mov [rbp - 88], rax             ; just the column this index is over

    mov r11, [rbp - 8]
    cmp qword [r11 + IXP_MODE], IXP_MODE_INSERT
    je .spans                       ; the key is given, not read
    mov ARG1, [r11 + IXP_CTX]
    mov ARG2, [r11 + IXP_SCHEMA]
    lea ARG3, [rbp - 2176]
    call db_pax_scan_open_bound
    test eax, eax
    jnz .done
.spans:
    mov qword [rbp - 96], 0
.span:
    mov r11, [rbp - 8]
    mov rax, [rbp - 96]
    cmp rax, [r11 + IXP_SPAN_COUNT]
    jae .index_done
    imul rax, UPDATE_SPAN_SIZE
    add rax, [r11 + IXP_SPANS]
    mov rdx, [rax + UPDATE_SPAN_MASK]
    mov [rbp - 104], rdx
    mov rdx, [rax + UPDATE_SPAN_START]
    mov [rbp - 112], rdx            ; the group these lanes sit in

    ; An insert needs no cell: the key is the same for every row.
    mov r11, [rbp - 8]
    cmp qword [r11 + IXP_MODE], IXP_MODE_INSERT
    je .lane

    mov [rbp - 2176 + SCAN_NEXT], rdx
    lea ARG1, [rbp - 2176]
    mov ARG2, [rbp - 72]
    mov ARG3, [rbp - 88]
    mov ARG4, [rbp - 80]
    call db_pax_scan_batch
    test eax, eax
    jnz .done
    mov [rbp - 120], rdx
    mov rax, [rbp - 56]
    imul rax, CybouDB_COLVIEW_SIZE
    add rax, [rbp - 72]
    add rax, BATCH_VIEW_COLUMNS
    mov [rbp - 128], rax

.lane:
    mov rax, [rbp - 104]
    test rax, rax
    jz .next_span
    bsf rcx, rax
    lea rdx, [rax - 1]
    and rax, rdx
    mov [rbp - 104], rax
    mov rax, [rbp - 112]
    add rax, rcx                    ; the row itself
    mov r11, [rbp - 8]
    cmp qword [r11 + IXP_MODE], IXP_MODE_INSERT
    je .lane_insert

    cmp rcx, [rbp - 120]
    jae .lane                       ; past what the group still holds
    mov r8, [rbp - 128]
    bt qword [r8 + COLVIEW_NULL_MASK], rcx
    jc .lane                        ; a NULL has no entry to remove
    mov r9, [r8 + COLVIEW_VALUES_PTR]
    cmp qword [rbp - 64], 0
    je .key_64
    movsxd rdx, dword [r9 + rcx * 4]
    jmp .key_ready
.key_64:
    mov rdx, [r9 + rcx * 8]
.key_ready:
    mov [rbp - 136], rdx
    mov r11, [rbp - 8]
    mov ARG1, [r11 + IXP_CTX]
    mov ARG2, [rbp - 24]
    mov ARG3, [rbp - 40]
    mov ARG4, [rbp - 136]
    PASS_ARG5 rax
    lea rax, [rbp - 40]
    PASS_ARG6 rax
    call db_index_delete
    test eax, eax
    jnz .done
    dec qword [rbp - 48]
    jmp .lane

.lane_insert:
    mov r11, [rbp - 8]
    mov ARG1, [r11 + IXP_CTX]
    mov ARG2, [rbp - 24]
    mov ARG3, [rbp - 40]
    mov ARG4, [rbp - 152]
    PASS_ARG5 rax
    lea rax, [rbp - 40]
    PASS_ARG6 rax
    test dword [rbp - 144], IDX_UNIQUE
    jnz .lane_unique
    call db_index_insert
    jmp .lane_inserted
.lane_unique:
    call db_index_insert_unique
.lane_inserted:
    test eax, eax
    jnz .done
    inc qword [rbp - 48]
    jmp .lane

.next_span:
    inc qword [rbp - 96]
    jmp .span

.index_done:
    mov r11, [rbp - 8]
    mov ARG1, [r11 + IXP_CTX]
    mov ARG2, [rbp - 24]
    mov ARG3, [rbp - 40]
    mov ARG4, [rbp - 48]
    call db_catalog_set_index_root
    test eax, eax
    jnz .done
.skip:
    mov rax, [rbp - 24]
    mov [rbp - 32], rax
    jmp .next_index
.ok:
    xor eax, eax
.done:
    FRAME_END
    ret
.oom:
    mov eax, SQL_ERR_NO_STORAGE
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  sql_index_rebuild_all(ctx, table id, schema, arena, column) -> RAX: result
;
;  Every index of a table that has stopped describing it. A column of -1 means
;  all of them, which is what a compacting DELETE needs: it moved every
;  surviving row, so every entry naming a row by position stopped meaning what
;  it said. A column instead means the indexes over that column, which is what
;  an UPDATE to it leaves behind.
;
;  Rebuilding rather than patching, in both cases, because the old keys are not
;  what the statement has: a rewrite has already visited every surviving row,
;  and an UPDATE knows the value it wrote and not the one it replaced.
; -----------------------------------------------------------------------------
sql_index_rebuild_all:
    FRAME_BEGIN 64, 1
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
    mov [rbp - 24], ARG3
    mov [rbp - 32], ARG4
    mov rax, IN_ARG5
    mov [rbp - 56], rax
    mov qword [rbp - 40], 0
    mov r10, ARG1
    test qword [r10 + DB_FEATURES], CybouDB_FEATURE_INDEX
    jz .ok
.index:
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    mov ARG3, [rbp - 40]
    lea ARG4, [rbp - 48]
    call db_index_of_table
    test rax, rax
    jz .ok
    cmp qword [rbp - 56], -1
    je .rebuild
    mov ecx, [rax + IDX_COLUMN]
    cmp rcx, [rbp - 56]
    jne .skip
.rebuild:
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 48]
    mov ARG3, rax
    mov ARG4, [rbp - 24]
    mov rax, [rbp - 32]
    PASS_ARG5 rax
    call sql_index_build_one
    test eax, eax
    jnz .done
.skip:
    mov rax, [rbp - 48]
    mov [rbp - 40], rax
    jmp .index
.ok:
    xor eax, eax
.done:
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  sql_index_insert_batch(ctx, table id, schema, batch, first row)
;      -> RAX: result code
;
;  Every index of the table learns about the rows an INSERT just appended. The
;  rows do not move, so each is one entry; a NULL has no key and is skipped;
;  and a unique index refusing a duplicate fails the statement, which is what
;  makes the constraint a constraint.
;
;  Local slots: [rbp-8]=ctx, [rbp-16]=table id, [rbp-24]=schema, [rbp-32]=batch,
;               [rbp-40]=first row, [rbp-48]=after id, [rbp-56]=this index id,
;               [rbp-64]=index page, [rbp-72]=root, [rbp-80]=entries,
;               [rbp-88]=column, [rbp-96]=column count, [rbp-104]=row,
;               [rbp-112]=is int32, [rbp-120]=unique
; -----------------------------------------------------------------------------
sql_index_insert_batch:
    FRAME_BEGIN 128, 2
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
    mov [rbp - 24], ARG3
    mov [rbp - 32], ARG4
    mov rax, IN_ARG5
    mov [rbp - 40], rax
    mov qword [rbp - 48], 0
    mov r10, ARG1
    test qword [r10 + DB_FEATURES], CybouDB_FEATURE_INDEX
    jz .ok
    mov r11, ARG3
    mov eax, [r11 + CAT_COUNT]
    mov [rbp - 96], rax
    mov r11, ARG4
    cmp qword [r11 + BATCH_ROWS], 0
    je .ok

.index:
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    mov ARG3, [rbp - 48]
    lea ARG4, [rbp - 56]
    call db_index_of_table
    test rax, rax
    jz .ok
    mov [rbp - 64], rax
    mov ecx, [rax + IDX_COLUMN]
    mov [rbp - 88], rcx
    mov ecx, [rax + IDX_FLAGS]
    mov [rbp - 120], rcx
    mov rcx, [rax + IDX_ROOT]
    mov [rbp - 72], rcx
    mov rcx, [rax + IDX_ROWS]
    mov [rbp - 80], rcx

    ; INT32 is stored sign-extended, and the tree orders signed keys.
    mov r11, [rbp - 24]
    mov rax, [rbp - 88]
    imul rax, CAT_COLUMN_SIZE
    mov ecx, [r11 + CAT_COLUMNS + rax]
    xor eax, eax
    cmp ecx, CAT_INT32
    sete al
    mov [rbp - 112], rax

    mov qword [rbp - 104], 0
.row:
    mov r11, [rbp - 32]
    mov rax, [rbp - 104]
    cmp rax, [r11 + BATCH_ROWS]
    jae .index_done
    imul rax, [rbp - 96]
    add rax, [rbp - 88]             ; the cell this row keeps its key in
    mov rcx, [r11 + BATCH_NULLS]
    test rcx, rcx
    jz .not_null
    cmp byte [rcx + rax], 0
    jne .next_row
.not_null:
    mov rcx, [r11 + BATCH_VALUES]
    mov rdx, [rcx + rax * 8]
    cmp qword [rbp - 112], 0
    je .key_ready
    movsxd rdx, edx
.key_ready:
    ; Into a slot before any argument register is loaded: ARG2 is RDX on one
    ; of the two ABIs, and the key would go with it.
    mov [rbp - 128], rdx
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 56]
    mov ARG3, [rbp - 72]
    mov ARG4, [rbp - 128]
    mov rax, [rbp - 40]
    add rax, [rbp - 104]
    PASS_ARG5 rax
    lea rax, [rbp - 72]
    PASS_ARG6 rax
    cmp qword [rbp - 120], 0
    jne .unique
    call db_index_insert
    jmp .inserted
.unique:
    call db_index_insert_unique
.inserted:
    test eax, eax
    jnz .done
    inc qword [rbp - 80]
.next_row:
    inc qword [rbp - 104]
    jmp .row

.index_done:
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 56]
    mov ARG3, [rbp - 72]
    mov ARG4, [rbp - 80]
    call db_catalog_set_index_root
    test eax, eax
    jnz .done
    mov rax, [rbp - 56]
    mov [rbp - 48], rax
    jmp .index
.ok:
    xor eax, eax
.done:
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  sql_index_empty_all(ctx, table id) -> RAX: result code
;
;  Every index of the table loses its tree. What a truncation leaves behind is
;  a table with no rows, and an index over no rows is an empty one.
; -----------------------------------------------------------------------------
sql_index_empty_all:
    FRAME_BEGIN 48, 0
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
    mov qword [rbp - 24], 0
    mov r10, ARG1
    test qword [r10 + DB_FEATURES], CybouDB_FEATURE_INDEX
    jz .ok
.index:
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    mov ARG3, [rbp - 24]
    lea ARG4, [rbp - 32]
    call db_index_of_table
    test rax, rax
    jz .ok
    cmp qword [rax + IDX_ROOT], 0
    je .already_empty
    mov ARG1, [rbp - 8]
    mov ARG2, [rax + IDX_ROOT]
    call db_index_retire_tree
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 32]
    xor ARG3, ARG3
    xor ARG4, ARG4
    call db_catalog_set_index_root
    test eax, eax
    jnz .done
.already_empty:
    mov rax, [rbp - 32]
    mov [rbp - 24], rax
    jmp .index
.ok:
    xor eax, eax
.done:
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  sql_index_drop_all(ctx, table id) -> RAX: result code
;
;  A table's indexes go with it. Dropping one changes the directory, so the
;  walk restarts from zero rather than continuing past an id that has moved.
; -----------------------------------------------------------------------------
sql_index_drop_all:
    FRAME_BEGIN 48, 0
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
    mov r10, ARG1
    test qword [r10 + DB_FEATURES], CybouDB_FEATURE_INDEX
    jz .ok
.index:
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    xor ARG3, ARG3
    lea ARG4, [rbp - 24]
    call db_index_of_table
    test rax, rax
    jz .ok
    mov ARG1, [rbp - 8]
    mov ARG2, [rax + IDX_ROOT]
    call db_index_retire_tree
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 24]
    call db_catalog_drop
    test eax, eax
    jnz .done
    jmp .index
.ok:
    xor eax, eax
.done:
    FRAME_END
    ret

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
exec_unbound_param_msg: db "a parameter was never bound", 0
exec_no_active_tx_rollback_msg: db "no active transaction to ROLLBACK", 0
exec_readonly_tx_msg: db "database is read-only", 0

%ifdef CybouDB_LINUX
section .note.GNU-stack noalloc noexec nowrite progbits
%endif
