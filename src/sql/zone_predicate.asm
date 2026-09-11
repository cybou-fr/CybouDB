; Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
; SPDX-License-Identifier: Apache-2.0
; SQL truth-set summaries over validated per-leaf storage statistics.
; NONE: no row is TRUE; ALL: every row is TRUE; UNKNOWN: evaluate the rows.
; NONE does not distinguish FALSE from SQL UNKNOWN, so NOT cannot invert it.
%include "sql.inc"
BITS 64
default rel
global sql_zone_eval, sql_zone_force_off, sql_zone_trace
global sql_zone_leaf_total, sql_zone_leaf_none, sql_zone_leaf_all, sql_zone_leaf_unknown
global sql_zone_batch_total, sql_zone_column_mask

section .bss
align 8
; Internal test/benchmark controls, disabled diagnostics by default. Callers
; that enable tracing own/reset these process-wide counters between queries.
sql_zone_force_off: resd 1
sql_zone_trace: resd 1
sql_zone_leaf_total: resq 1
sql_zone_leaf_none: resq 1
sql_zone_leaf_all: resq 1
sql_zone_leaf_unknown: resq 1
sql_zone_batch_total: resq 1
sql_zone_column_mask: resq 1

section .text
; Non-NaN binary32 -> signed 64-bit ordering key; raw stored bounds unchanged.
%macro ZONE_F32_KEY 2
    mov eax, %1
    and eax, 0x7fffffff
    jnz %%nonzero
    xor %1, %1
%%nonzero:
    test %1, %1
    jns %%positive
    xor %1, 0x7fffffff
%%positive:
    movsxd %2, %1
%endmacro

; sql_zone_eval(bound_expr, zone_stats_or_zero, validated_schema) -> ZONE_TEST_*.
sql_zone_eval:
    FRAME_BEGIN 48, 0
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
    mov [rbp - 24], ARG3
    test ARG1, ARG1
    jz .all
    mov r10, ARG1
    mov rax, [r10 + BEXPR_KIND]
    cmp rax, BEXPR_NOT
    je .unknown
    cmp rax, BEXPR_AND
    je .combine
    cmp rax, BEXPR_OR
    je .combine
    cmp rax, BEXPR_COMPARE_NULL_LIT
    je .none                        ; no TRUE rows, including under AND/OR
    cmp qword [rbp - 16], 0
    je .unknown
    mov r11, [rbp - 24]
    mov rcx, [r10 + BEXPR_COL_IDX]
    cmp ecx, [r11 + CAT_COUNT]
    jae .unknown
    cmp rcx, 64
    jae .unknown
    mov rax, rcx
    shl rax, 5
    mov eax, [r11 + CAT_COLUMNS + rax]
    cmp rax, [r10 + BEXPR_COL_TYPE]
    jne .unknown
    imul rcx, ZSTAT_SIZE
    add rcx, [rbp - 16]
    mov rdx, [rcx + ZSTAT_FLAGS]
    mov [rbp - 40], rdx
    cmp qword [r10 + BEXPR_KIND], BEXPR_IS_NULL
    je .is_null
    cmp qword [r10 + BEXPR_KIND], BEXPR_IS_NOT_NULL
    je .is_not_null
    cmp qword [r10 + BEXPR_KIND], BEXPR_COMPARE_COL_LIT
    jne .unknown
    mov rax, [r10 + BEXPR_OP]
    cmp rax, OP_EQ
    je .comparison
    cmp rax, OP_LT
    jb .unknown                     ; NEQ remains a per-row predicate
    cmp rax, OP_GTE
    ja .unknown
.comparison:
    test rdx, ZSTAT_HAS_COMPARABLE
    jz .none
    mov r8, [rcx + ZSTAT_MIN]
    mov r9, [rcx + ZSTAT_MAX]
    mov r11, [r10 + BEXPR_LIT_VAL]
    cmp qword [r10 + BEXPR_COL_TYPE], CAT_FLOAT32
    je .float
    cmp qword [r10 + BEXPR_COL_TYPE], CAT_BOOL
    jne .bounds
    ; BOOL kernels accept equality only; unusual coerced literals fall back.
    cmp qword [r10 + BEXPR_OP], OP_EQ
    jne .unknown
    cmp r11, 1
    ja .unknown
    xor r8d, r8d
    test rdx, ZSTAT_HAS_FALSE
    setz r8b
    xor r9d, r9d
    test rdx, ZSTAT_HAS_TRUE
    setnz r9b
    jmp .bounds
.float:
    mov eax, r11d
    and eax, 0x7fffffff
    cmp eax, 0x7f800000
    ja .none                        ; every comparison against NaN is non-TRUE
    ZONE_F32_KEY r8d, r8
    ZONE_F32_KEY r9d, r9
    ZONE_F32_KEY r11d, r11
.bounds:
    mov rax, [r10 + BEXPR_OP]
    cmp rax, OP_EQ
    je .eq
    cmp rax, OP_LT
    je .lt
    cmp rax, OP_LTE
    je .lte
    cmp rax, OP_GT
    je .gt
    ; >= literal
    cmp r9, r11
    jl .none
    cmp r8, r11
    jge .all_comparable
    jmp .unknown
.gt:
    cmp r9, r11
    jle .none
    cmp r8, r11
    jg .all_comparable
    jmp .unknown
.lt:
    cmp r8, r11
    jge .none
    cmp r9, r11
    jl .all_comparable
    jmp .unknown
.lte:
    cmp r8, r11
    jg .none
    cmp r9, r11
    jle .all_comparable
    jmp .unknown
.eq:
    cmp r11, r8
    jl .none
    cmp r11, r9
    jg .none
    cmp r8, r9
    jne .unknown
.all_comparable:
    test qword [rbp - 40], ZSTAT_HAS_NULLS | ZSTAT_HAS_NAN
    jnz .unknown
    jmp .all
.is_null:
    test rdx, ZSTAT_HAS_NULLS
    jz .none
    test rdx, ZSTAT_HAS_COMPARABLE | ZSTAT_HAS_NAN
    jz .all
    jmp .unknown
.is_not_null:
    test rdx, ZSTAT_HAS_NULLS
    jz .all
    test rdx, ZSTAT_HAS_COMPARABLE | ZSTAT_HAS_NAN
    jz .none
    jmp .unknown
.combine:
    mov ARG1, [r10 + BEXPR_LEFT]
    mov ARG2, [rbp - 16]
    mov ARG3, [rbp - 24]
    call sql_zone_eval
    mov [rbp - 32], rax
    mov r10, [rbp - 8]
    cmp qword [r10 + BEXPR_KIND], BEXPR_AND
    jne .or_short
    cmp eax, ZONE_TEST_NONE
    je .none
    jmp .right
.or_short:
    cmp eax, ZONE_TEST_ALL
    je .all
.right:
    mov ARG1, [r10 + BEXPR_RIGHT]
    mov ARG2, [rbp - 16]
    mov ARG3, [rbp - 24]
    call sql_zone_eval
    mov r10, [rbp - 8]
    cmp qword [r10 + BEXPR_KIND], BEXPR_OR
    je .or
    cmp eax, ZONE_TEST_NONE
    je .none
    cmp eax, ZONE_TEST_ALL
    jne .unknown
    cmp qword [rbp - 32], ZONE_TEST_ALL
    je .all
    jmp .unknown
.or:
    cmp eax, ZONE_TEST_ALL
    je .all
    cmp eax, ZONE_TEST_NONE
    jne .unknown
    cmp qword [rbp - 32], ZONE_TEST_NONE
    je .none
.unknown:
    mov eax, ZONE_TEST_UNKNOWN
    FRAME_END
    ret
.none:
    mov eax, ZONE_TEST_NONE
    FRAME_END
    ret
.all:
    mov eax, ZONE_TEST_ALL
    FRAME_END
    ret
