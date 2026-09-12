; Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
; SPDX-License-Identifier: Apache-2.0
; Bounded, arena-owned materialization for one-key ORDER BY.
%include "sql.inc"
%include "order_executor.inc"

BITS 64
default rel

extern sql_arena_alloc
global sql_order_init, sql_order_collect, sql_order_emit

section .text

; sql_order_init(state, arena, plan) -> eax SQL status
sql_order_init:
    FRAME_BEGIN 16, 0
    mov [rbp - 8], ARG1
    mov r10, ARG1
    mov [r10 + ORDER_ARENA], ARG2
    mov [r10 + ORDER_PLAN], ARG3
    mov qword [r10 + ORDER_HEAD], 0
    mov qword [r10 + ORDER_TAIL], 0
    mov qword [r10 + ORDER_ERROR], 0
    mov qword [r10 + ORDER_BATCH], 0
    mov ARG1, ARG2
    mov ARG2, CybouDB_BATCH_VIEW_SIZE
    call sql_arena_alloc
    test rax, rax
    jz .init_oom
    mov r10, [rbp - 8]
    mov [r10 + ORDER_BATCH], rax
    xor eax, eax
    FRAME_END
    ret
.init_oom:
    mov eax, SQL_ERR_NO_STORAGE
    FRAME_END
    ret

; Result sink: materialize selected projected rows as arena-owned nodes.
sql_order_collect:
    FRAME_BEGIN 96, 0
    mov [rbp - 8], ARG1                ; state
    mov [rbp - 16], ARG2               ; batch
    mov [rbp - 24], ARG3               ; projection
    mov [rbp - 32], ARG4               ; selection
    mov [rbp - 56], rbx
    mov [rbp - 64], r12
    mov [rbp - 72], r13
    mov [rbp - 80], r14
    mov [rbp - 88], r15
.collect_row:
    mov rax, [rbp - 32]
    test rax, rax
    jz .collect_ok
    tzcnt r12, rax
    btr rax, r12
    mov [rbp - 32], rax
    mov r10, [rbp - 8]
    mov ARG1, [r10 + ORDER_ARENA]
    mov ARG2, ORDER_NODE_SIZE
    call sql_arena_alloc
    test rax, rax
    jz .collect_oom
    mov [rbp - 40], rax                ; node
    mov qword [rax + ORDER_NODE_NEXT], 0
    mov r10, [rbp - 24]
    mov r13, [r10 + RESULT_PROJ_COUNT]
    xor ebx, ebx
.collect_col:
    cmp rbx, r13
    jae .append_node
    mov r14, [r10 + RESULT_PROJ_INDICES]
    mov eax, [r14 + rbx * 4]
    imul rax, CybouDB_COLVIEW_SIZE
    mov r14, [rbp - 16]
    lea r14, [r14 + BATCH_VIEW_COLUMNS + rax]
    mov r15, [rbp - 40]
    bt qword [r14 + COLVIEW_NULL_MASK], r12
    setc al
    mov [r15 + ORDER_NODE_NULLS + rbx], al
    xor eax, eax
    test byte [r15 + ORDER_NODE_NULLS + rbx], 1
    jnz .store_col
    mov r11, [r14 + COLVIEW_VALUES_PTR]
    mov ecx, [r14 + COLVIEW_WIDTH]
    cmp ecx, 8
    je .load8
    cmp ecx, 1
    je .load1
    mov eax, [r11 + r12 * 4]
    jmp .store_col
.load8:
    mov rax, [r11 + r12 * 8]
    jmp .store_col
.load1:
    mov al, [r11 + r12]
.store_col:
    mov [r15 + ORDER_NODE_VALUES + rbx * 8], rax
    inc rbx
    mov r10, [rbp - 24]
    jmp .collect_col
.append_node:
    mov r10, [rbp - 8]
    mov rax, [rbp - 40]
    mov r11, [r10 + ORDER_TAIL]
    test r11, r11
    jz .append_first
    mov [r11 + ORDER_NODE_NEXT], rax
    jmp .append_tail
.append_first:
    mov [r10 + ORDER_HEAD], rax
.append_tail:
    mov [r10 + ORDER_TAIL], rax
    jmp .collect_row
.collect_oom:
    mov r10, [rbp - 8]
    mov qword [r10 + ORDER_ERROR], SQL_ERR_NO_STORAGE
    mov eax, CybouDB_SINK_ERROR
    jmp .collect_done
.collect_ok:
    xor eax, eax
.collect_done:
    mov rbx, [rbp - 56]
    mov r12, [rbp - 64]
    mov r13, [rbp - 72]
    mov r14, [rbp - 80]
    mov r15, [rbp - 88]
    FRAME_END
    ret

; sql_order_emit(state, downstream_cb, downstream_ctx) -> eax SQL status
sql_order_emit:
    FRAME_BEGIN 112, 0
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
    mov [rbp - 24], ARG3
    mov [rbp - 72], rbx
    mov [rbp - 80], r12
    mov [rbp - 88], r13
    mov [rbp - 96], r14
    mov [rbp - 104], r15
    mov r10, ARG1
    mov rax, [r10 + ORDER_ERROR]
    test eax, eax
    jnz .emit_done

    ; Stable insertion sort of the linked nodes.
    mov r12, [r10 + ORDER_HEAD]
    xor r13d, r13d                    ; sorted head
.sort_node:
    test r12, r12
    jz .sort_done
    mov r14, [r12 + ORDER_NODE_NEXT]  ; remaining input
    xor r15d, r15d                    ; previous
    mov rbx, r13                     ; current
.find_slot:
    test rbx, rbx
    jz .insert_slot
    mov ARG1, r12
    mov ARG2, rbx
    mov r10, [rbp - 8]
    mov ARG3, [r10 + ORDER_PLAN]
    call .node_precedes
    test eax, eax
    jnz .insert_slot
    mov r15, rbx
    mov rbx, [rbx + ORDER_NODE_NEXT]
    jmp .find_slot
.insert_slot:
    mov [r12 + ORDER_NODE_NEXT], rbx
    test r15, r15
    jz .insert_head
    mov [r15 + ORDER_NODE_NEXT], r12
    jmp .inserted
.insert_head:
    mov r13, r12
.inserted:
    mov r12, r14
    jmp .sort_node
.sort_done:
    mov [rbp - 40], r13              ; delivery cursor
    mov qword [rbp - 48], 0          ; offset
    mov qword [rbp - 56], -1         ; remaining limit
    mov r10, [rbp - 8]
    mov r11, [r10 + ORDER_PLAN]
    test qword [r11 + PLAN_FLAGS], PLAN_FLAG_LIMIT
    jz .skip_rows
    mov rax, [r11 + PLAN_OFFSET_VALUE]
    mov [rbp - 48], rax
    mov rax, [r11 + PLAN_LIMIT_VALUE]
    mov [rbp - 56], rax
.skip_rows:
    cmp qword [rbp - 48], 0
    je .emit_rows
    mov rax, [rbp - 40]
    test rax, rax
    jz .emit_ok
    mov rax, [rax + ORDER_NODE_NEXT]
    mov [rbp - 40], rax
    dec qword [rbp - 48]
    jmp .skip_rows
.emit_rows:
    cmp qword [rbp - 56], 0
    je .emit_ok
    mov r12, [rbp - 40]
    test r12, r12
    jz .emit_ok
    mov r10, [rbp - 8]
    mov r14, [r10 + ORDER_BATCH]
    mov qword [r14 + BATCH_VIEW_ROWS], 1
    mov r11, [r10 + ORDER_PLAN]
    xor ebx, ebx
.emit_col:
    cmp rbx, [r11 + PLAN_DATA1]
    jae .emit_batch
    mov r13, [r11 + PLAN_DATA2]
    mov eax, [r13 + rbx * 4]
    imul rax, CybouDB_COLVIEW_SIZE
    lea r15, [r14 + BATCH_VIEW_COLUMNS + rax]
    lea rax, [r12 + ORDER_NODE_VALUES + rbx * 8]
    mov [r15 + COLVIEW_VALUES_PTR], rax
    movzx eax, byte [r12 + ORDER_NODE_NULLS + rbx]
    mov [r15 + COLVIEW_NULL_MASK], rax
    mov r13, [r11 + PLAN_DATA3]
    mov eax, [r13 + rbx * 4]
    mov [r15 + COLVIEW_TYPE], eax
    mov edx, 4
    cmp eax, CAT_INT64
    jne .emit_not_i64
    mov edx, 8
.emit_not_i64:
    cmp eax, CAT_BOOL
    jne .emit_width
    mov edx, 1
.emit_width:
    mov [r15 + COLVIEW_WIDTH], edx
    inc rbx
    jmp .emit_col
.emit_batch:
    mov ARG1, [rbp - 24]
    mov ARG2, r14
    lea ARG3, [r11 + PLAN_DATA1]
    mov ARG4, 1
    call [rbp - 16]
    cmp eax, CybouDB_SINK_ERROR
    je .emit_sink_error
    cmp eax, CybouDB_SINK_STOP
    je .emit_ok
    mov r12, [rbp - 40]
    mov rax, [r12 + ORDER_NODE_NEXT]
    mov [rbp - 40], rax
    cmp qword [rbp - 56], -1
    je .emit_rows
    dec qword [rbp - 56]
    jmp .emit_rows

.emit_ok:
    xor eax, eax
    jmp .emit_done
.emit_sink_error:
    mov eax, SQL_ERR_SINK
.emit_done:
    mov rbx, [rbp - 72]
    mov r12, [rbp - 80]
    mov r13, [rbp - 88]
    mov r14, [rbp - 96]
    mov r15, [rbp - 104]
    FRAME_END
    ret

; node_precedes(new, current, plan) -> eax bool
.node_precedes:
    mov r10, ARG3
    mov r11, ARG1
    mov r9, ARG2
    mov rcx, [r10 + PLAN_ORDER_ORDINAL]
    movzx eax, byte [r11 + ORDER_NODE_NULLS + rcx]
    movzx edx, byte [r9 + ORDER_NODE_NULLS + rcx]
    cmp eax, edx
    jne .null_order
    test eax, eax
    jnz .not_before
    mov r8, [r11 + ORDER_NODE_VALUES + rcx * 8]
    mov r9, [r9 + ORDER_NODE_VALUES + rcx * 8]
    cmp qword [r10 + PLAN_ORDER_TYPE], CAT_INT32
    je .cmp_i32
    cmp qword [r10 + PLAN_ORDER_TYPE], CAT_INT64
    je .cmp_i64
    cmp qword [r10 + PLAN_ORDER_TYPE], CAT_BOOL
    je .cmp_bool
    movd xmm0, r8d
    movd xmm1, r9d
    cmp qword [r10 + PLAN_ORDER_DESC], 0
    jne .cmp_float_desc
    ucomiss xmm0, xmm1
    je .not_before
    setb al
    movzx eax, al
    ret
.cmp_float_desc:
    ucomiss xmm0, xmm1
    je .not_before
    seta al
    movzx eax, al
    ret
.cmp_i32:
    cmp qword [r10 + PLAN_ORDER_DESC], 0
    jne .cmp_i32_desc
    cmp r8d, r9d
    setl al
    movzx eax, al
    ret
.cmp_i32_desc:
    cmp r8d, r9d
    setg al
    movzx eax, al
    ret
.cmp_i64:
    cmp qword [r10 + PLAN_ORDER_DESC], 0
    jne .cmp_i64_desc
    cmp r8, r9
    setl al
    movzx eax, al
    ret
.cmp_i64_desc:
    cmp r8, r9
    setg al
    movzx eax, al
    ret
.cmp_bool:
    cmp qword [r10 + PLAN_ORDER_DESC], 0
    jne .cmp_bool_desc
    cmp r8b, r9b
    setb al
    movzx eax, al
    ret
.cmp_bool_desc:
    cmp r8b, r9b
    seta al
    movzx eax, al
    ret
.null_order:
    ; ASC: NULL last. DESC: NULL first.
    cmp qword [r10 + PLAN_ORDER_DESC], 0
    jne .desc_null
    test eax, eax
    setz al
    movzx eax, al
    ret
.desc_null:
    test eax, eax
    setnz al
    movzx eax, al
    ret
.not_before:
    xor eax, eax
    ret

%ifdef CybouDB_LINUX
section .note.GNU-stack noalloc noexec nowrite progbits
%endif
