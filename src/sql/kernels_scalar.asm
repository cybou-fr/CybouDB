; Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
; SPDX-License-Identifier: Apache-2.0
; Scalar predicate kernel ABI v1. No storage access, allocation or expression walk.
; kernel(values, null_mask, active_mask, literal_bits) -> RAX=true, RDX=unknown
; Only active, non-NULL lanes may be loaded; no padding or alignment requirement.
; Unknown = active & null. True is disjoint from unknown and a subset of active.
; All other registers follow the platform ABI. MXCSR is unchanged.
%include "sql.inc"
BITS 64
default rel
global sql_kernel_resolve
global sql_kernel_force_scalar

extern cpu_has_avx2
extern avx2_kernel_table

section .data
align 4
sql_kernel_force_scalar: dd 0

section .text
; Resolve once at bind time. Unsupported (type, op) pairs return NULL.
; Dispatches to AVX2 kernels when CPU & OS support AVX2, unless forced scalar.
sql_kernel_resolve:
    mov     r10, ARG1
    mov     r11, ARG2
    dec     r10
    cmp     r10, 3
    ja      .invalid
    dec     r11
    cmp     r11, 5
    ja      .invalid
    imul    r10, 6
    add     r10, r11

    cmp     dword [sql_kernel_force_scalar], 0
    jne     .use_scalar

    FRAME_BEGIN 16, 0
    mov     [rbp - 8], r10
    call    cpu_has_avx2
    mov     r10, [rbp - 8]
    FRAME_END

    test    eax, eax
    jz      .use_scalar

    lea     rax, [avx2_kernel_table]
    mov     rax, [rax + r10 * 8]
    test    rax, rax
    jnz     .done

.use_scalar:
    lea     rax, [scalar_kernel_table]
    mov     rax, [rax + r10 * 8]

.done:
    ret

.invalid:
    xor     eax, eax
    ret

; Macro specialization removes type and operator dispatch from the lane loop.
; Args: symbol, type (i32/i64/f32/bool), conditional branch for accepting a lane.
%macro SCALAR_KERNEL 3
global %1
%1:
    FRAME_BEGIN 16, 0
    mov     r10, ARG1                   ; values
    mov     r11, ARG4                   ; literal (capture before overwriting r9)
    mov     rax, ARG2                   ; nulls
    mov     r8, ARG3                    ; active
    and     rax, r8
    mov     [rbp - 8], rax              ; unknown
    not     rax
    and     r8, rax                     ; remaining active non-NULL lanes
    xor     r9d, r9d                    ; true
%ifidni %2, f32
    ; IEEE ordering by signed integer keys, with signed zero canonicalized.
    ; NaNs (including signaling NaNs) are FALSE for every comparison. Integer
    ; classification avoids exceptions and makes subnormals independent of DAZ.
    mov     eax, r11d
    and     eax, 0x7fffffff
    cmp     eax, 0x7f800000
    ja      %%done
    test    eax, eax
    jnz     %%literal_nonzero
    xor     r11d, r11d
%%literal_nonzero:
    test    r11d, r11d
    jns     %%loop
    xor     r11d, 0x7fffffff
%endif
%%loop:
    test    r8, r8
    jz      %%done
    bsf     rcx, r8
    btr     r8, rcx
%ifidni %2, i64
    mov     rax, [r10 + rcx * 8]
    cmp     rax, r11
%elifidni %2, i32
    mov     eax, [r10 + rcx * 4]
    cmp     eax, r11d
%elifidni %2, bool
    movzx   eax, byte [r10 + rcx]
    cmp     al, r11b
%else
    mov     eax, [r10 + rcx * 4]
    mov     edx, eax
    and     edx, 0x7fffffff
    cmp     edx, 0x7f800000
    ja      %%loop
    test    edx, edx
    jnz     %%value_nonzero
    xor     eax, eax
%%value_nonzero:
    test    eax, eax
    jns     %%value_key
    xor     eax, 0x7fffffff
%%value_key:
    cmp     eax, r11d
%endif
    %3      %%accept
    jmp     %%loop
%%accept:
    bts     r9, rcx
    jmp     %%loop
%%done:
    mov     rax, r9
    mov     rdx, [rbp - 8]
    FRAME_END
    ret
%endmacro

SCALAR_KERNEL scalar_i32_eq,  i32, je
SCALAR_KERNEL scalar_i32_neq, i32, jne
SCALAR_KERNEL scalar_i32_lt,  i32, jl
SCALAR_KERNEL scalar_i32_lte, i32, jle
SCALAR_KERNEL scalar_i32_gt,  i32, jg
SCALAR_KERNEL scalar_i32_gte, i32, jge
SCALAR_KERNEL scalar_i64_eq,  i64, je
SCALAR_KERNEL scalar_i64_neq, i64, jne
SCALAR_KERNEL scalar_i64_lt,  i64, jl
SCALAR_KERNEL scalar_i64_lte, i64, jle
SCALAR_KERNEL scalar_i64_gt,  i64, jg
SCALAR_KERNEL scalar_i64_gte, i64, jge
SCALAR_KERNEL scalar_f32_eq,  f32, je
SCALAR_KERNEL scalar_f32_neq, f32, jne
SCALAR_KERNEL scalar_f32_lt,  f32, jl
SCALAR_KERNEL scalar_f32_lte, f32, jle
SCALAR_KERNEL scalar_f32_gt,  f32, jg
SCALAR_KERNEL scalar_f32_gte, f32, jge
SCALAR_KERNEL scalar_bool_eq,  bool, je
SCALAR_KERNEL scalar_bool_neq, bool, jne

section .rodata
align 8
scalar_kernel_table:
    dq scalar_i32_eq, scalar_i32_neq, scalar_i32_lt, scalar_i32_lte, scalar_i32_gt, scalar_i32_gte
    dq scalar_i64_eq, scalar_i64_neq, scalar_i64_lt, scalar_i64_lte, scalar_i64_gt, scalar_i64_gte
    dq scalar_f32_eq, scalar_f32_neq, scalar_f32_lt, scalar_f32_lte, scalar_f32_gt, scalar_f32_gte
    dq scalar_bool_eq, scalar_bool_neq, 0, 0, 0, 0
