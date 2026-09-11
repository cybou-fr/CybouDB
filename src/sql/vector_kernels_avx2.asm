; Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
; SPDX-License-Identifier: Apache-2.0
; AVX2 FLOAT32 dot product. Full 8-lane chunks are multiplied in parallel;
; products are accumulated in lane order so results remain bit-identical to
; vector_dot_f32_scalar. The tail is scalar and never reads past dimensions.
%include "cyboudb.inc"
%include "vector.inc"
BITS 64
default rel

global vector_dot_f32_avx2, vector_l2sq_f32_avx2, vector_normalize_f32_avx2

section .text
vector_dot_f32_avx2:
    FRAME_BEGIN 48, 0
    mov r10, ARG3
    xor r11d, r11d
    vxorps xmm0, xmm0, xmm0
.chunk:
    mov rax, r10
    sub rax, r11
    cmp rax, 8
    jb .tail
    vmovups ymm1, [ARG1 + r11 * 4]
    vmulps ymm1, ymm1, [ARG2 + r11 * 4]
    vmovups [rbp - 32], ymm1
    xor eax, eax
.reduce:
    addss xmm0, [rbp - 32 + rax * 4]
    inc eax
    cmp eax, 8
    jb .reduce
    add r11, 8
    jmp .chunk
.tail:
    cmp r11, r10
    jae .done
    vmovss xmm1, [ARG1 + r11 * 4]
    vmulss xmm1, xmm1, [ARG2 + r11 * 4]
    vaddss xmm0, xmm0, xmm1
    inc r11
    jmp .tail
.done:
    vzeroupper
    FRAME_END
    ret

; Squared L2 distance with the same per-lane FLOAT32 rounding and sequential
; accumulation order as vector_l2sq_f32_scalar.
vector_l2sq_f32_avx2:
    FRAME_BEGIN 48, 0
    mov r10, ARG3
    xor r11d, r11d
    vxorps xmm0, xmm0, xmm0
.l2_chunk:
    mov rax, r10
    sub rax, r11
    cmp rax, 8
    jb .l2_tail
    vmovups ymm1, [ARG1 + r11 * 4]
    vsubps ymm1, ymm1, [ARG2 + r11 * 4]
    vmulps ymm1, ymm1, ymm1
    vmovups [rbp - 32], ymm1
    xor eax, eax
.l2_reduce:
    addss xmm0, [rbp - 32 + rax * 4]
    inc eax
    cmp eax, 8
    jb .l2_reduce
    add r11, 8
    jmp .l2_chunk
.l2_tail:
    cmp r11, r10
    jae .l2_done
    vmovss xmm1, [ARG1 + r11 * 4]
    vsubss xmm1, xmm1, [ARG2 + r11 * 4]
    vmulss xmm1, xmm1, xmm1
    vaddss xmm0, xmm0, xmm1
    inc r11
    jmp .l2_tail
.l2_done:
    vzeroupper
    FRAME_END
    ret

; Validate before writing, accumulate in scalar lane order for oracle parity,
; then normalize eight output lanes at a time. Input and output may alias.
vector_normalize_f32_avx2:
    test ARG1, ARG1
    jz .norm_invalid
    test ARG2, ARG2
    jz .norm_invalid
    test ARG3, ARG3
    jz .norm_invalid
    xor eax, eax
.norm_validate:
    cmp rax, ARG3
    jae .norm_sum_begin
    vmovss xmm1, [ARG1 + rax * 4]
    vucomiss xmm1, xmm1
    jp .norm_nonfinite
    vmovd r10d, xmm1
    and r10d, 0x7f800000
    cmp r10d, 0x7f800000
    je .norm_nonfinite
    inc rax
    jmp .norm_validate
.norm_sum_begin:
    FRAME_BEGIN 48, 0
    xor r11d, r11d
    vxorps xmm0, xmm0, xmm0
.norm_chunk:
    mov rax, ARG3
    sub rax, r11
    cmp rax, 8
    jb .norm_tail
    vmovups ymm1, [ARG1 + r11 * 4]
    vmulps ymm1, ymm1, ymm1
    vmovups [rbp - 32], ymm1
    xor eax, eax
.norm_reduce:
    addss xmm0, [rbp - 32 + rax * 4]
    inc eax
    cmp eax, 8
    jb .norm_reduce
    add r11, 8
    jmp .norm_chunk
.norm_tail:
    cmp r11, ARG3
    jae .norm_ready
    vmovss xmm1, [ARG1 + r11 * 4]
    vmulss xmm1, xmm1, xmm1
    vaddss xmm0, xmm0, xmm1
    inc r11
    jmp .norm_tail
.norm_ready:
    vucomiss xmm0, xmm0
    jp .norm_framed_nonfinite
    vmovd r10d, xmm0
    and r10d, 0x7fffffff
    jz .norm_framed_invalid
    cmp r10d, 0x7f800000
    jae .norm_framed_nonfinite
    vsqrtss xmm0, xmm0, xmm0
    vbroadcastss ymm2, xmm0
    xor r11d, r11d
.norm_write_chunk:
    mov rax, ARG3
    sub rax, r11
    cmp rax, 8
    jb .norm_write_tail
    vmovups ymm1, [ARG1 + r11 * 4]
    vdivps ymm1, ymm1, ymm2
    vmovups [ARG2 + r11 * 4], ymm1
    add r11, 8
    jmp .norm_write_chunk
.norm_write_tail:
    cmp r11, ARG3
    jae .norm_ok
    vmovss xmm1, [ARG1 + r11 * 4]
    vdivss xmm1, xmm1, xmm0
    vmovss [ARG2 + r11 * 4], xmm1
    inc r11
    jmp .norm_write_tail
.norm_ok:
    vzeroupper
    xor eax, eax
    FRAME_END
    ret
.norm_framed_invalid:
    mov eax, VECTOR_INVALID
    vzeroupper
    FRAME_END
    ret
.norm_framed_nonfinite:
    mov eax, VECTOR_NONFINITE
    vzeroupper
    FRAME_END
    ret
.norm_invalid:
    mov eax, VECTOR_INVALID
    ret
.norm_nonfinite:
    mov eax, VECTOR_NONFINITE
    ret

%ifndef CybouDB_WINDOWS
section .note.GNU-stack noalloc noexec nowrite progbits
%endif
