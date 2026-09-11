; Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
; SPDX-License-Identifier: Apache-2.0
; Scalar FLOAT32 vector references used as the oracle for SIMD implementations.
; vector_dot_f32_scalar(a, b, dimensions) -> XMM0 float32
; vector_l2sq_f32_scalar(a, b, dimensions) -> XMM0 float32
; Each lane operation rounds as FLOAT32; dimension zero returns +0.0.
%include "cyboudb.inc"
%include "vector.inc"
BITS 64
default rel

extern cpu_has_avx2
extern sql_kernel_force_scalar
global vector_dot_f32_scalar, vector_l2sq_f32_scalar, vector_dot_f32_resolve
global vector_l2sq_f32_resolve
global vector_cosine_normalized_f32_scalar, vector_cosine_normalized_f32_resolve
global vector_normalize_f32_scalar, vector_normalize_f32_resolve
global cyboudb_vector_normalize_f32
global cyboudb_vector_dot_f32, cyboudb_vector_l2sq_f32
extern vector_dot_f32_avx2, vector_l2sq_f32_avx2, vector_normalize_f32_avx2

section .text
vector_dot_f32_resolve:
    cmp dword [sql_kernel_force_scalar], 0
    jne .scalar
    FRAME_BEGIN 0, 0
    call cpu_has_avx2
    test eax, eax
    jz .scalar_framed
    lea rax, [rel vector_dot_f32_avx2]
    FRAME_END
    ret
.scalar_framed:
    lea rax, [rel vector_dot_f32_scalar]
    FRAME_END
    ret
.scalar:
    lea rax, [rel vector_dot_f32_scalar]
    ret

vector_l2sq_f32_resolve:
    cmp dword [sql_kernel_force_scalar], 0
    jne .l2_scalar
    FRAME_BEGIN 0, 0
    call cpu_has_avx2
    test eax, eax
    jz .l2_scalar_framed
    lea rax, [rel vector_l2sq_f32_avx2]
    FRAME_END
    ret
.l2_scalar_framed:
    lea rax, [rel vector_l2sq_f32_scalar]
    FRAME_END
    ret
.l2_scalar:
    lea rax, [rel vector_l2sq_f32_scalar]
    ret

vector_normalize_f32_resolve:
    cmp dword [sql_kernel_force_scalar], 0
    jne .normalize_scalar
    FRAME_BEGIN 0, 0
    call cpu_has_avx2
    test eax, eax
    jz .normalize_scalar_framed
    lea rax, [rel vector_normalize_f32_avx2]
    FRAME_END
    ret

.normalize_scalar_framed:
    lea rax, [rel vector_normalize_f32_scalar]
    FRAME_END
    ret
.normalize_scalar:
    lea rax, [rel vector_normalize_f32_scalar]
    ret

; Public normalization resolves once per call while preserving its three
; volatile ABI arguments across CPUID on the first invocation.
cyboudb_vector_normalize_f32:
    FRAME_BEGIN 32, 0
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
    mov [rbp - 24], ARG3
    call vector_normalize_f32_resolve
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    mov ARG3, [rbp - 24]
    FRAME_END
    jmp rax

cyboudb_vector_dot_f32:
    FRAME_BEGIN 32, 0
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
    mov [rbp - 24], ARG3
    call vector_dot_f32_resolve
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    mov ARG3, [rbp - 24]
    FRAME_END
    jmp rax

cyboudb_vector_l2sq_f32:
    FRAME_BEGIN 32, 0
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
    mov [rbp - 24], ARG3
    call vector_l2sq_f32_resolve
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    mov ARG3, [rbp - 24]
    FRAME_END
    jmp rax

; Normalized cosine is definitionally the dot product. Keep named entry points
; so SQL/search code can state intent without introducing a second kernel.
vector_cosine_normalized_f32_resolve:
    jmp vector_dot_f32_resolve

vector_cosine_normalized_f32_scalar:
    jmp vector_dot_f32_scalar

vector_dot_f32_scalar:
    pxor xmm0, xmm0
    xor eax, eax
.dot_loop:
    cmp rax, ARG3
    jae .dot_done
    movss xmm1, [ARG1 + rax * 4]
    mulss xmm1, [ARG2 + rax * 4]
    addss xmm0, xmm1
    inc rax
    jmp .dot_loop
.dot_done:
    ret

vector_l2sq_f32_scalar:
    pxor xmm0, xmm0
    xor eax, eax
.l2_loop:
    cmp rax, ARG3
    jae .l2_done
    movss xmm1, [ARG1 + rax * 4]
    subss xmm1, [ARG2 + rax * 4]
    mulss xmm1, xmm1
    addss xmm0, xmm1
    inc rax
    jmp .l2_loop
.l2_done:
    ret

; vector_normalize_f32_scalar(input, output, dimensions) -> status
; Validation completes before output is touched, so failure is atomic even
; when input and output alias.
vector_normalize_f32_scalar:
    test ARG1, ARG1
    jz .normalize_invalid
    test ARG2, ARG2
    jz .normalize_invalid
    test ARG3, ARG3
    jz .normalize_invalid
    pxor xmm0, xmm0
    xor eax, eax
.norm_sum:
    cmp rax, ARG3
    jae .norm_ready
    movss xmm1, [ARG1 + rax * 4]
    ucomiss xmm1, xmm1
    jp .normalize_nonfinite
    movd r10d, xmm1
    and r10d, 0x7f800000
    cmp r10d, 0x7f800000
    je .normalize_nonfinite
    mulss xmm1, xmm1
    addss xmm0, xmm1
    inc rax
    jmp .norm_sum
.norm_ready:
    ucomiss xmm0, xmm0
    jp .normalize_nonfinite
    movd r10d, xmm0
    and r10d, 0x7fffffff
    jz .normalize_invalid
    cmp r10d, 0x7f800000
    jae .normalize_nonfinite
    sqrtss xmm0, xmm0
    xor eax, eax
.normalize_loop:
    cmp rax, ARG3
    jae .normalize_ok
    movss xmm1, [ARG1 + rax * 4]
    divss xmm1, xmm0
    movss [ARG2 + rax * 4], xmm1
    inc rax
    jmp .normalize_loop
.normalize_ok:
    xor eax, eax
    ret
.normalize_invalid:
    mov eax, VECTOR_INVALID
    ret
.normalize_nonfinite:
    mov eax, VECTOR_NONFINITE
    ret

%ifndef CybouDB_WINDOWS
section .note.GNU-stack noalloc noexec nowrite progbits
%endif
