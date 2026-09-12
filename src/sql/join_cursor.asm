; Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
; SPDX-License-Identifier: Apache-2.0
; Correctness-first INNER equi-join executor. It scans batch x batch, skips
; NULL keys, and materializes at most 64 joined rows into a compact sink batch.
%include "sql.inc"
%include "join_cursor.inc"

BITS 64
default rel

extern sql_arena_alloc
extern db_pax_scan_open_bound, db_pax_scan_batch
global sql_join_execute

section .text

; sql_join_execute(db, plan, arena, batch_cb, cb_ctx, out_err) -> eax
sql_join_execute:
    FRAME_BEGIN 256, 2
    mov     [rbp - 8], ARG1             ; db
    mov     [rbp - 16], ARG2            ; plan
    mov     [rbp - 24], ARG3            ; arena
    mov     [rbp - 32], ARG4            ; callback
    mov     rax, IN_ARG5
    mov     [rbp - 40], rax             ; callback context
    mov     rax, IN_ARG6
    mov     [rbp - 48], rax             ; out_error (owned by caller)
    mov     [rbp - 176], rbx
    mov     [rbp - 184], r12
    mov     [rbp - 192], r13
    mov     [rbp - 200], r14
    mov     [rbp - 208], r15
    mov     [rbp - 216], rsi
    mov     [rbp - 224], rdi

    ; Runtime objects are statement-arena owned.
    mov     ARG1, [rbp - 24]
    mov     ARG2, CybouDB_SCAN_SIZE
    call    sql_arena_alloc
    test    rax, rax
    jz      .oom
    mov     [rbp - 56], rax             ; left scan
    mov     ARG1, [rbp - 24]
    mov     ARG2, CybouDB_SCAN_SIZE
    call    sql_arena_alloc
    test    rax, rax
    jz      .oom
    mov     [rbp - 64], rax             ; right scan
    mov     ARG1, [rbp - 24]
    mov     ARG2, CybouDB_BATCH_VIEW_SIZE
    call    sql_arena_alloc
    test    rax, rax
    jz      .oom
    mov     [rbp - 72], rax             ; left batch
    mov     ARG1, [rbp - 24]
    mov     ARG2, CybouDB_BATCH_VIEW_SIZE
    call    sql_arena_alloc
    test    rax, rax
    jz      .oom
    mov     [rbp - 80], rax             ; right batch
    mov     ARG1, [rbp - 24]
    mov     ARG2, CybouDB_BATCH_VIEW_SIZE
    call    sql_arena_alloc
    test    rax, rax
    jz      .oom
    mov     [rbp - 88], rax             ; joined output batch
    mov     ARG1, [rbp - 24]
    mov     ARG2, PAX_DECODE_MAX_BYTES
    call    sql_arena_alloc
    test    rax, rax
    jz      .oom
    mov     [rbp - 96], rax             ; left decode
    mov     ARG1, [rbp - 24]
    mov     ARG2, PAX_DECODE_MAX_BYTES
    call    sql_arena_alloc
    test    rax, rax
    jz      .oom
    mov     [rbp - 104], rax            ; right decode
    mov     ARG1, [rbp - 24]
    mov     ARG2, JOIN_MAX_VALUE_BYTES
    call    sql_arena_alloc
    test    rax, rax
    jz      .oom
    mov     [rbp - 112], rax            ; output scalar backing

    ; Required masks: join key plus all projected input columns.
    mov     r10, [rbp - 16]
    xor     eax, eax
    mov     rcx, [r10 + PLAN_JOIN_LEFT_COL]
    bts     rax, rcx
    mov     [rbp - 120], rax
    xor     eax, eax
    mov     rcx, [r10 + PLAN_JOIN_RIGHT_COL]
    bts     rax, rcx
    mov     [rbp - 128], rax
    mov     r11, [r10 + PLAN_JOIN_PROJECTIONS]
    xor     ecx, ecx
.required_loop:
    cmp     rcx, [r10 + PLAN_DATA1]
    jae     .required_done
    mov     eax, [r11 + rcx * 4]
    test    eax, PLAN_PROJ_RIGHT_BIT
    jnz     .required_right
    bts     [rbp - 120], rax
    jmp     .required_next
.required_right:
    and     eax, 0x7fffffff
    bts     [rbp - 128], rax
.required_next:
    inc     rcx
    jmp     .required_loop
.required_done:

    ; Initialize compact output column views once.
    mov     r10, [rbp - 16]
    mov     r11, [r10 + PLAN_DATA3]
    mov     r12, [rbp - 88]
    mov     r13, [rbp - 112]
    xor     ebx, ebx
.init_output:
    cmp     rbx, [r10 + PLAN_DATA1]
    jae     .output_ready
    mov     rax, rbx
    imul    rax, CybouDB_COLVIEW_SIZE
    lea     r14, [r12 + BATCH_VIEW_COLUMNS + rax]
    mov     rax, rbx
    imul    rax, JOIN_VALUE_STRIDE
    add     rax, r13
    mov     [r14 + COLVIEW_VALUES_PTR], rax
    mov     qword [r14 + COLVIEW_NULL_MASK], 0
    mov     eax, [r11 + rbx * 4]
    mov     [r14 + COLVIEW_TYPE], eax
    mov     edx, 4
    cmp     eax, CAT_INT64
    jne     .init_not_i64
    mov     edx, 8
.init_not_i64:
    cmp     eax, CAT_BOOL
    jne     .init_width
    mov     edx, 1
.init_width:
    mov     [r14 + COLVIEW_WIDTH], edx
    inc     rbx
    jmp     .init_output
.output_ready:
    mov     qword [r12 + BATCH_VIEW_ROWS], 0

    ; Open and scan the left input.
    mov     r10, [rbp - 16]
    mov     ARG1, [rbp - 8]
    mov     ARG2, [r10 + PLAN_SCHEMA_PAGE]
    mov     ARG3, [rbp - 56]
    call    db_pax_scan_open_bound
    test    eax, eax
    jnz     .done

.left_batch:
    mov     ARG1, [rbp - 56]
    mov     ARG2, [rbp - 72]
    mov     ARG3, [rbp - 120]
    mov     ARG4, [rbp - 96]
    call    db_pax_scan_batch
    test    eax, eax
    jnz     .done
    test    rdx, rdx
    jz      .finish
    mov     [rbp - 136], rdx            ; left rows
    mov     qword [rbp - 152], 0         ; matched LHS rows
    mov     qword [rbp - 160], 0         ; synthesize-null RHS flag
    mov     qword [rbp - 168], 0         ; 0=matched loop, 1=unmatched loop

    ; Rewind the right scan for every left batch.
    mov     r10, [rbp - 16]
    mov     ARG1, [rbp - 8]
    mov     ARG2, [r10 + PLAN_RIGHT_SCHEMA]
    mov     ARG3, [rbp - 64]
    call    db_pax_scan_open_bound
    test    eax, eax
    jnz     .done

.right_batch:
    mov     ARG1, [rbp - 64]
    mov     ARG2, [rbp - 80]
    mov     ARG3, [rbp - 128]
    mov     ARG4, [rbp - 104]
    call    db_pax_scan_batch
    test    eax, eax
    jnz     .done
    test    rdx, rdx
    jz      .right_finished
    mov     [rbp - 144], rdx            ; right rows

    xor     r12d, r12d                  ; left row
.left_row:
    cmp     r12, [rbp - 136]
    jae     .right_batch
    xor     r13d, r13d                  ; right row
.right_row:
    cmp     r13, [rbp - 144]
    jae     .next_left_row

    ; Locate and compare the two key views. NULL never joins to NULL.
    mov     r10, [rbp - 16]
    mov     rax, [r10 + PLAN_JOIN_LEFT_COL]
    imul    rax, CybouDB_COLVIEW_SIZE
    mov     r14, [rbp - 72]
    lea     r14, [r14 + BATCH_VIEW_COLUMNS + rax]
    bt      qword [r14 + COLVIEW_NULL_MASK], r12
    jc      .next_left_row
    mov     rax, [r10 + PLAN_JOIN_RIGHT_COL]
    imul    rax, CybouDB_COLVIEW_SIZE
    mov     r15, [rbp - 80]
    lea     r15, [r15 + BATCH_VIEW_COLUMNS + rax]
    bt      qword [r15 + COLVIEW_NULL_MASK], r13
    jc      .next_right_row
    mov     rsi, [r14 + COLVIEW_VALUES_PTR]
    mov     rdi, [r15 + COLVIEW_VALUES_PTR]
    cmp     qword [r10 + PLAN_JOIN_KEY_TYPE], CAT_INT64
    je      .compare_i64
    mov     eax, [rsi + r12 * 4]
    cmp     eax, [rdi + r13 * 4]
    jne     .next_right_row
    jmp     .matched
.compare_i64:
    mov     rax, [rsi + r12 * 8]
    cmp     rax, [rdi + r13 * 8]
    jne     .next_right_row

.matched:
    bts     qword [rbp - 152], r12
    mov     qword [rbp - 160], 0
.emit_join_row:
    xor     ebx, ebx                    ; projection ordinal
.copy_projection:
    mov     r10, [rbp - 16]
    cmp     rbx, [r10 + PLAN_DATA1]
    jae     .row_copied
    mov     r11, [r10 + PLAN_JOIN_PROJECTIONS]
    mov     eax, [r11 + rbx * 4]
    mov     r15, [rbp - 88]
    mov     rdx, rbx
    imul    rdx, CybouDB_COLVIEW_SIZE
    lea     r15, [r15 + BATCH_VIEW_COLUMNS + rdx]
    mov     rdx, [rbp - 88]
    mov     rdx, [rdx + BATCH_VIEW_ROWS]
    mov     r14, [rbp - 72]
    mov     rcx, r12
    test    eax, PLAN_PROJ_RIGHT_BIT
    jz      .copy_source_ready
    and     eax, 0x7fffffff
    cmp     qword [rbp - 160], 0
    jne     .copy_synth_null
    mov     r14, [rbp - 80]
    mov     rcx, r13
.copy_source_ready:
    mov     edx, eax
    imul    rdx, CybouDB_COLVIEW_SIZE
    lea     r14, [r14 + BATCH_VIEW_COLUMNS + rdx]
    mov     rdx, [rbp - 88]
    mov     rdx, [rdx + BATCH_VIEW_ROWS]
    bt      qword [r14 + COLVIEW_NULL_MASK], rcx
    jnc     .copy_value
.copy_synth_null:
    bts     qword [r15 + COLVIEW_NULL_MASK], rdx
    jmp     .copy_next
.copy_value:
    mov     rsi, [r14 + COLVIEW_VALUES_PTR]
    mov     rdi, [r15 + COLVIEW_VALUES_PTR]
    mov     eax, [r15 + COLVIEW_WIDTH]
    cmp     eax, 8
    je      .copy8
    cmp     eax, 1
    je      .copy1
    mov     eax, [rsi + rcx * 4]
    mov     [rdi + rdx * 4], eax
    jmp     .copy_next
.copy8:
    mov     rax, [rsi + rcx * 8]
    mov     [rdi + rdx * 8], rax
    jmp     .copy_next
.copy1:
    mov     al, [rsi + rcx]
    mov     [rdi + rdx], al
.copy_next:
    inc     rbx
    jmp     .copy_projection

.row_copied:
    mov     r10, [rbp - 88]
    inc     qword [r10 + BATCH_VIEW_ROWS]
    cmp     qword [r10 + BATCH_VIEW_ROWS], 64
    jb      .advance_join_row
    call    .flush_output
    cmp     eax, CybouDB_SINK_CONTINUE
    je      .validate_after_flush
    cmp     eax, CybouDB_SINK_STOP
    je      .success
    mov     eax, SQL_ERR_SINK
    jmp     .done

.validate_after_flush:
    ; Unlike a one-input cursor, a join continues consuming both borrowed
    ; batches after a sink call. Revalidate the snapshot before touching them.
    mov     r10, [rbp - 8]
    cmp     qword [r10 + DB_MODE], -1
    je      .state_error
    mov     r11, [rbp - 16]
    mov     rax, [r10 + DB_GENERATION]
    cmp     rax, [r11 + PLAN_GENERATION]
    jne     .state_error
    mov     rax, [r10 + DB_BASE]
    cmp     rax, [r11 + PLAN_DB_BASE]
    jne     .state_error
    mov     rax, [r10 + DB_ROOT]
    cmp     rax, [r11 + PLAN_DB_ROOT]
    jne     .state_error
    jmp     .advance_join_row

.advance_join_row:
    cmp     qword [rbp - 168], 0
    jne     .next_unmatched_row
    jmp     .next_right_row

.next_right_row:
    inc     r13
    jmp     .right_row
.next_left_row:
    inc     r12
    jmp     .left_row

.right_finished:
    mov     r10, [rbp - 16]
    cmp     qword [r10 + PLAN_JOIN_TYPE], JOIN_LEFT
    jne     .left_batch
    mov     qword [rbp - 168], 1
    mov     qword [rbp - 160], 1
    xor     r12d, r12d
.unmatched_row:
    cmp     r12, [rbp - 136]
    jae     .unmatched_done
    bt      qword [rbp - 152], r12
    jnc     .emit_join_row
.next_unmatched_row:
    inc     r12
    jmp     .unmatched_row
.unmatched_done:
    mov     qword [rbp - 168], 0
    mov     qword [rbp - 160], 0
    jmp     .left_batch

.finish:
    mov     r10, [rbp - 88]
    cmp     qword [r10 + BATCH_VIEW_ROWS], 0
    je      .success
    call    .flush_output
    test    eax, eax
    jz      .success
    cmp     eax, CybouDB_SINK_STOP
    je      .success
    mov     eax, SQL_ERR_SINK
    jmp     .done

; Returns the sink result and clears output row/null state for reuse.
.flush_output:
    FRAME_BEGIN 32, 0
    mov     r10, [rbp]                  ; parent RBP
    mov     r11, [r10 - 88]             ; output batch
    mov     rcx, [r11 + BATCH_VIEW_ROWS]
    mov     rax, -1
    cmp     rcx, 64
    je      .mask_ready
    mov     rax, 1
    shl     rax, cl
    dec     rax
.mask_ready:
    mov     ARG4, rax
    mov     ARG1, [r10 - 40]
    mov     ARG2, r11
    mov     rax, [r10 - 16]
    lea     ARG3, [rax + PLAN_DATA1]
    call    [r10 - 32]
    mov     [rbp - 8], rax
    mov     r10, [rbp]
    mov     r11, [r10 - 88]
    mov     qword [r11 + BATCH_VIEW_ROWS], 0
    mov     rax, [r10 - 16]
    mov     rcx, [rax + PLAN_DATA1]
    xor     edx, edx
.clear_nulls:
    cmp     rdx, rcx
    jae     .flushed
    mov     rax, rdx
    imul    rax, CybouDB_COLVIEW_SIZE
    mov     qword [r11 + BATCH_VIEW_COLUMNS + rax + COLVIEW_NULL_MASK], 0
    inc     rdx
    jmp     .clear_nulls
.flushed:
    mov     rax, [rbp - 8]
    FRAME_END
    ret

.oom:
    mov     eax, SQL_ERR_NO_STORAGE
    jmp     .done
.state_error:
    mov     eax, CybouDB_E_STATE
    jmp     .done
.success:
    xor     eax, eax
.done:
    mov     rbx, [rbp - 176]
    mov     r12, [rbp - 184]
    mov     r13, [rbp - 192]
    mov     r14, [rbp - 200]
    mov     r15, [rbp - 208]
    mov     rsi, [rbp - 216]
    mov     rdi, [rbp - 224]
    FRAME_END
    ret

%ifdef CybouDB_LINUX
section .note.GNU-stack noalloc noexec nowrite progbits
%endif
