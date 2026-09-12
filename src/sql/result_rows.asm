; Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
; SPDX-License-Identifier: Apache-2.0
; Row compatibility adapter over the primary batch executor.
%include "sql.inc"
BITS 64
default rel
extern sql_execute_batch
global sql_execute
section .text
; Keep the six-argument sql_execute signature and callback stop semantics.
; The row callback answers with the same CybouDB_SINK_* values as a batch sink;
; the adapter passes its answer straight back so that a row consumer can end
; the scan early or report its own failure.
sql_execute:
    test    ARG4, ARG4
    jz      sql_execute_batch          ; mutations need no sink; SELECT reports missing sink
    FRAME_BEGIN 1152, 2
    mov     [rbp - 8], ARG1
    mov     [rbp - 16], ARG2
    mov     [rbp - 24], ARG3
    lea     r10, [rbp - 1152]           ; cb, ctx, values, NULL bytes, varlen lengths
    mov     [r10], ARG4
    mov     rax, IN_ARG5
    mov     [r10 + 8], rax
    mov     rax, IN_ARG6
    mov     [rbp - 32], rax
    mov     ARG1, [rbp - 8]
    mov     ARG2, [rbp - 16]
    mov     ARG3, [rbp - 24]
    lea     ARG4, [result_rows]
    PASS_ARG5 r10
    mov     rax, [rbp - 32]
    PASS_ARG6 rax
    call    sql_execute_batch
    FRAME_END
    ret

; result_rows(adapter_ctx, batch_view, projection, selected_mask)
result_rows:
    FRAME_BEGIN 144, 1
    mov     [rbp - 88], r12
    mov     [rbp - 96], r13
    mov     [rbp - 104], r14
    mov     [rbp - 112], r15
    mov     [rbp - 120], rsi
    mov     [rbp - 128], rdi
    mov     [rbp - 24], ARG1
    mov     [rbp - 8], ARG2
    mov     [rbp - 16], ARG3
    mov     r12, ARG4
    mov     r10, [rbp - 24]
    mov     rax, [r10]
    mov     [rbp - 80], rax             ; row callback
    mov     rax, [r10 + 8]
    mov     [rbp - 40], rax             ; original callback context
    lea     rax, [r10 + 16]
    mov     [rbp - 64], rax             ; row values (512 bytes)
    lea     rax, [r10 + 528]
    mov     [rbp - 72], rax             ; row nulls (64 bytes)
    lea     rax, [r10 + 592]
    mov     [rbp - 136], rax            ; row varlen lengths (512 bytes)
    mov     r10, [rbp - 16]
    mov     rax, [r10 + RESULT_PROJ_COUNT]
    mov     [rbp - 32], rax
    test    r12, r12
    jnz     .row_dispatch
    xor     eax, eax
    jmp     .adapter_done

.row_dispatch:
    tzcnt   r13, r12
    btr     r12, r13

    ; Project columns for row r13 directly from mapped PAX columns
    mov     r10, [rbp - 16]
    mov     r14, [r10 + RESULT_PROJ_INDICES]     ; proj_indices
    xor     r15, r15                    ; p = 0

.proj_cell_loop:
    mov     eax, [r14 + r15 * 4]        ; c (col index in schema)
    mov     rdx, [rbp - 8]            ; batch_view
    add     rdx, BATCH_VIEW_COLUMNS
    imul    rax, CybouDB_COLVIEW_SIZE
    add     rdx, rax                    ; rdx points to CybouDB_COLVIEW

    ; Check NULL bit in colview.null_mask
    mov     rsi, [rdx + COLVIEW_NULL_MASK]
    bt      rsi, r13
    setc    al
    mov     rdi, [rbp - 72]            ; row_nulls
    mov     [rdi + r15], al
    test    al, al
    jnz     .cell_is_null

    mov     rdi, [rbp - 136]
    mov     qword [rdi + r15 * 8], 0

    ; Read value directly from mapped PAX memory
    mov     rsi, [rdx + COLVIEW_VALUES_PTR]
    mov     ecx, [rdx + COLVIEW_WIDTH]
    cmp     ecx, VAR_CELL_SIZE
    je      .read_varlen
    cmp     ecx, 8
    je      .read_width_8
    cmp     ecx, 4
    je      .read_width_4
    ; width 1 (bool)
    movzx   rax, byte [rsi + r13]
    jmp     .store_row_val

.read_width_8:
    mov     rax, [rsi + r13 * 8]
    jmp     .store_row_val

.read_width_4:
    mov     ecx, [rdx + COLVIEW_TYPE]
    cmp     ecx, CAT_INT32
    jne     .read_float_4
    movsxd  rax, dword [rsi + r13 * 4]
    jmp     .store_row_val

.read_float_4:
    mov     eax, [rsi + r13 * 4]
    jmp     .store_row_val

.read_varlen:
    mov     rax, r13
    shl     rax, 4
    add     rsi, rax
    mov     rax, [rsi + VAR_CELL_ROOT]
    mov     rdi, [rbp - 136]
    mov     rcx, [rsi + VAR_CELL_LENGTH]
    mov     [rdi + r15 * 8], rcx
    jmp     .store_row_val

.cell_is_null:
    xor     eax, eax
    mov     rdi, [rbp - 136]
    mov     qword [rdi + r15 * 8], 0

.store_row_val:
    mov     rdi, [rbp - 64]            ; row_values
    mov     [rdi + r15 * 8], rax

    inc     r15
    cmp     r15, [rbp - 32]            ; proj_count
    jb      .proj_cell_loop

    ; Call row_cb(cb_ctx, proj_count, row_values, row_nulls)
    mov     ARG1, [rbp - 40]            ; cb_ctx
    mov     ARG2, [rbp - 32]           ; proj_count
    mov     ARG3, [rbp - 64]           ; row_values
    mov     ARG4, [rbp - 72]           ; row_nulls
    mov     rax, [rbp - 136]
    PASS_ARG5 rax                      ; optional varlen lengths
    call    [rbp - 80]
    test    eax, eax
    jnz     .adapter_done

.next_dispatch_row:
    test    r12, r12
    jnz     .row_dispatch
    xor     eax, eax
.adapter_done:
    mov     r12, [rbp - 88]
    mov     r13, [rbp - 96]
    mov     r14, [rbp - 104]
    mov     r15, [rbp - 112]
    mov     rsi, [rbp - 120]
    mov     rdi, [rbp - 128]
    FRAME_END
    ret

%ifdef CybouDB_LINUX
section .note.GNU-stack noalloc noexec nowrite progbits
%endif
