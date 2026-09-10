; Experiment-only AVX2 FOR8/FOR16 predicate kernels. Not linked into the engine.
;
; Legacy count interface (for_count8 / for_count16) is preserved for the old
; experiment harness (for_width_experiment.c).
;
; Production predicate interface (for8_* / for16_*):
;
;   kernel(encoded_delta_ptr, null_mask, active_mask, literal_delta)
;       -> RAX: true_mask
;          RDX: unknown_mask
;
;   Caller guarantees:
;     - encoded_delta_ptr points to the packed byte/word stream for this batch
;       (stream_header + 16 + first_row * element_size, already offset)
;     - null_mask:   bit i = 1 if row i is NULL
;     - active_mask: bit i = 1 if row i is in scope
;     - literal_delta: unsigned (literal - base), caller-vetted to fit width
;
;   Sign-flip trick: XOR values and literal with 0x80 (FOR8) or 0x8000 (FOR16)
;   so that vpcmpgtb/vpcmpgtw (signed) gives the right unsigned order.
;   NE/LE/GE are derived by inverting within active & ~null, not a bare NOT.
;
; Call only after cpu_has_avx2 and cpu_has_popcnt succeed.
%include "abi.inc"
BITS 64
default rel
section .text

; =============================================================================
;  Legacy count kernels  (for_width_experiment.c compatibility)
; =============================================================================
%macro WIDTH_COUNT 4
global %1
%1:
    FRAME_BEGIN 32, 0
    mov r10, ARG1
    mov r11, ARG2
    mov [rbp - 8], ARG3
    mov [rbp - 16], ARG4
    xor edx, edx
    vmovd xmm1, [rbp - 8]
    %2 ymm1, xmm1
    mov eax, %4
    vmovd xmm2, eax
    %2 ymm2, xmm2
    vpxor ymm1, ymm1, ymm2
.loop:
    cmp r11, 32 / %3
    jb .tail
    vmovdqu ymm0, [r10]
    vpxor ymm0, ymm0, ymm2
    cmp qword [rbp - 16], 1
    je .equal
%if %3 = 1
    vpcmpgtb ymm0, ymm0, ymm1
%else
    vpcmpgtw ymm0, ymm0, ymm1
%endif
    jmp .mask
.equal:
%if %3 = 1
    vpcmpeqb ymm0, ymm0, ymm1
%else
    vpcmpeqw ymm0, ymm0, ymm1
%endif
.mask:
    vpmovmskb eax, ymm0
    popcnt eax, eax
%if %3 = 2
    shr eax, 1
%endif
    add rdx, rax
    add r10, 32
    sub r11, 32 / %3
    jmp .loop
.tail:
    test r11, r11
    jz .done
%if %3 = 1
    movzx eax, byte [r10]
%else
    movzx eax, word [r10]
%endif
    cmp qword [rbp - 16], 1
    je .tail_equal
    cmp rax, [rbp - 8]
    jbe .tail_next
    inc rdx
    jmp .tail_next
.tail_equal:
    cmp rax, [rbp - 8]
    jne .tail_next
    inc rdx
.tail_next:
    add r10, %3
    dec r11
    jmp .tail
.done:
    vzeroupper
    mov rax, rdx
    FRAME_END
    ret
%endmacro
WIDTH_COUNT for_count8,  vpbroadcastb, 1, 0x80
WIDTH_COUNT for_count16, vpbroadcastw, 2, 0x8000

; =============================================================================
;  FOR8 production predicate kernels
;
;  32 lanes per YMM -> two YMM passes -> 64-bit result mask.
;
;  Local slots (all 6 kernels share this layout):
;   [rbp - 8]  = encoded_delta_ptr
;   [rbp - 16] = null_mask
;   [rbp - 24] = active_mask
;   [rbp - 32] = literal_delta
; =============================================================================

; FOR8_PREDICATE name, invert(0=direct/1=invert), cmp_op(0=eq/1=a>b/2=b>a)
%macro FOR8_PREDICATE 3
global %1
%1:
    FRAME_BEGIN 40, 0
    mov     [rbp - 8],  ARG1
    mov     [rbp - 16], ARG2
    mov     [rbp - 24], ARG3
    mov     [rbp - 32], ARG4

    ; sign-flip constant: broadcast 0x80 to all bytes
    mov     eax, 0x80808080
    vmovd   xmm3, eax
    vpbroadcastb ymm3, xmm3

    ; sign-flipped literal
    movzx   eax, byte [rbp - 32]
    xor     eax, 0x80
    vmovd   xmm4, eax
    vpbroadcastb ymm4, xmm4

    mov     r10, [rbp - 8]

    ; lanes 0..31
    vmovdqu ymm0, [r10]
    vpxor   ymm0, ymm0, ymm3
%if %3 = 0
    vpcmpeqb ymm1, ymm0, ymm4
%elif %3 = 1
    vpcmpgtb ymm1, ymm0, ymm4
%else
    vpcmpgtb ymm1, ymm4, ymm0
%endif
    vpmovmskb eax, ymm1

    ; lanes 32..63
    vmovdqu ymm0, [r10 + 32]
    vpxor   ymm0, ymm0, ymm3
%if %3 = 0
    vpcmpeqb ymm2, ymm0, ymm4
%elif %3 = 1
    vpcmpgtb ymm2, ymm0, ymm4
%else
    vpcmpgtb ymm2, ymm4, ymm0
%endif
    vpmovmskb edx, ymm2

    ; 64-bit raw mask
    shl     rdx, 32
    or      rdx, rax

%if %2 = 1
    ; invert within active & ~null
    mov     rax, [rbp - 16]
    not     rax
    and     rax, [rbp - 24]
    xor     rdx, rax
%endif

    ; true_mask = raw & ~null & active
    mov     rax, [rbp - 16]
    not     rax
    and     rdx, rax
    and     rdx, [rbp - 24]
    mov     rax, rdx

    ; unknown_mask = active & null
    mov     rdx, [rbp - 16]
    and     rdx, [rbp - 24]

    vzeroupper
    FRAME_END
    ret
%endmacro

; op: 0=eq, 1=a>b, 2=b>a
FOR8_PREDICATE for8_eq, 0, 0
FOR8_PREDICATE for8_ne, 1, 0
FOR8_PREDICATE for8_gt, 0, 1
FOR8_PREDICATE for8_le, 1, 1
FOR8_PREDICATE for8_lt, 0, 2
FOR8_PREDICATE for8_ge, 1, 2

; =============================================================================
;  FOR16 production predicate kernels
;
;  16 lanes per YMM (each lane is 2 bytes) -> four YMM passes -> 64-bit mask.
;
;  vpmovmskb on 16-bit comparisons gives two bits per lane (the high byte).
;  Compact to one bit per lane via bit-interleave:
;    x &= 0x55555555; x |= (x>>1); x &= 0x33333333; ...
;
;  Local slots identical to FOR8.
; =============================================================================

; compact_w16: eax -> 16-bit lane mask (uses ecx as scratch)
%macro COMPACT_W16 0
    and     eax, 0x55555555
    mov     ecx, eax
    shr     ecx, 1
    or      eax, ecx
    and     eax, 0x33333333
    mov     ecx, eax
    shr     ecx, 2
    or      eax, ecx
    and     eax, 0x0F0F0F0F
    mov     ecx, eax
    shr     ecx, 4
    or      eax, ecx
    and     eax, 0x00FF00FF
    mov     ecx, eax
    shr     ecx, 8
    or      eax, ecx
    and     eax, 0x0000FFFF
%endmacro

; FOR16_PREDICATE name, invert, op(0=eq/1=a>b/2=b>a)
%macro FOR16_PREDICATE 3
global %1
%1:
    FRAME_BEGIN 56, 0
    mov     [rbp - 8],  ARG1
    mov     [rbp - 16], ARG2
    mov     [rbp - 24], ARG3
    mov     [rbp - 32], ARG4

    ; sign-flip constant: 0x8000 per word
    mov     eax, 0x80008000
    vmovd   xmm3, eax
    vpbroadcastd ymm3, xmm3

    ; sign-flipped literal
    movzx   eax, word [rbp - 32]
    xor     eax, 0x8000
    vmovd   xmm4, eax
    vpbroadcastw ymm4, xmm4

    mov     r10, [rbp - 8]

    ; chunk 0: lanes 0..15
    vmovdqu ymm0, [r10]
    vpxor   ymm0, ymm0, ymm3
%if %3 = 0
    vpcmpeqw ymm1, ymm0, ymm4
%elif %3 = 1
    vpcmpgtw ymm1, ymm0, ymm4
%else
    vpcmpgtw ymm1, ymm4, ymm0
%endif
    vpmovmskb eax, ymm1
    COMPACT_W16
    mov     r9d, eax                    ; lanes 0..15

    ; chunk 1: lanes 16..31
    vmovdqu ymm0, [r10 + 32]
    vpxor   ymm0, ymm0, ymm3
%if %3 = 0
    vpcmpeqw ymm1, ymm0, ymm4
%elif %3 = 1
    vpcmpgtw ymm1, ymm0, ymm4
%else
    vpcmpgtw ymm1, ymm4, ymm0
%endif
    vpmovmskb eax, ymm1
    COMPACT_W16
    mov     r8d, eax                    ; lanes 16..31

    ; chunk 2: lanes 32..47
    vmovdqu ymm0, [r10 + 64]
    vpxor   ymm0, ymm0, ymm3
%if %3 = 0
    vpcmpeqw ymm1, ymm0, ymm4
%elif %3 = 1
    vpcmpgtw ymm1, ymm0, ymm4
%else
    vpcmpgtw ymm1, ymm4, ymm0
%endif
    vpmovmskb eax, ymm1
    COMPACT_W16
    mov     [rbp - 40], rax             ; lanes 32..47

    ; chunk 3: lanes 48..63
    vmovdqu ymm0, [r10 + 96]
    vpxor   ymm0, ymm0, ymm3
%if %3 = 0
    vpcmpeqw ymm1, ymm0, ymm4
%elif %3 = 1
    vpcmpgtw ymm1, ymm0, ymm4
%else
    vpcmpgtw ymm1, ymm4, ymm0
%endif
    vpmovmskb eax, ymm1
    COMPACT_W16                         ; eax = lanes 48..63

    ; assemble 64-bit raw mask
    shl     rax, 48
    shl     qword [rbp - 40], 32
    or      rax, [rbp - 40]
    shl     r8, 16
    or      rax, r8
    or      rax, r9
    mov     [rbp - 48], rax

%if %2 = 1
    ; invert within active & ~null
    mov     rcx, [rbp - 16]
    not     rcx
    and     rcx, [rbp - 24]
    xor     [rbp - 48], rcx
%endif

    ; true_mask = raw & ~null & active
    mov     rax, [rbp - 48]
    mov     rcx, [rbp - 16]
    not     rcx
    and     rax, rcx
    and     rax, [rbp - 24]

    ; unknown_mask = active & null
    mov     rdx, [rbp - 16]
    and     rdx, [rbp - 24]

    vzeroupper
    FRAME_END
    ret
%endmacro

FOR16_PREDICATE for16_eq, 0, 0
FOR16_PREDICATE for16_ne, 1, 0
FOR16_PREDICATE for16_gt, 0, 1
FOR16_PREDICATE for16_le, 1, 1
FOR16_PREDICATE for16_lt, 0, 2
FOR16_PREDICATE for16_ge, 1, 2
