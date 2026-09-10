; AVX2 FLOAT32 dot product. Full 8-lane chunks are multiplied in parallel;
; products are accumulated in lane order so results remain bit-identical to
; vector_dot_f32_scalar. The tail is scalar and never reads past dimensions.
%include "cyboudb.inc"
BITS 64
default rel

global vector_dot_f32_avx2

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

%ifndef CybouDB_WINDOWS
section .note.GNU-stack noalloc noexec nowrite progbits
%endif
