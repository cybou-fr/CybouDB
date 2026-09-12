; Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
; SPDX-License-Identifier: Apache-2.0
; =============================================================================
;  src/sql/for_kernels_avx2.asm - AVX2 FOR8/FOR16 direct predicate kernels
; =============================================================================
;  Zero-decode predicate evaluation directly over FOR-encoded byte/word streams.
;
;  kernel(delta_ptr, null_mask, active_mask, literal_delta)
;      -> RAX: true_mask
;         RDX: unknown_mask
;
;  delta_ptr:    &stream[16 + first_row * element_width]
;  null_mask:    bit i = 1 if row i is NULL
;  active_mask:  bit i = 1 if row i is in scope (1..64 lanes)
;  literal_delta: unsigned (literal - base), caller-vetted to fit the width
;
;  Sign-flip trick: XOR values and literal with 0x80 (FOR8) or 0x8000 (FOR16)
;  so signed vpcmpgtb/vpcmpgtw give the correct unsigned ordering.
;  NE/LE/GE are derived by inverting within active & ~null, not a bare NOT.
;
;  PAX-internal read contract: callers first verify cpu_has_avx2 and guarantee
;  a complete readable 64-lane encoded window (64 bytes for FOR8, 128 bytes
;  for FOR16). Inactive lanes may be read, but are always removed from masks.
; =============================================================================

%include "cyboudb.inc"

BITS 64
default rel

global for8_eq, for8_ne, for8_lt, for8_le, for8_gt, for8_ge
global for16_eq, for16_ne, for16_lt, for16_le, for16_gt, for16_ge

section .text

; =============================================================================
;  FOR8 kernels -- 32 lanes per YMM, two passes, 64-bit result mask
; =============================================================================
; Local layout for all 6 FOR8 kernels:
;   [rbp - 8]  = delta_ptr
;   [rbp - 16] = null_mask
;   [rbp - 24] = active_mask
;   [rbp - 32] = literal_delta

; FOR8_PREDICATE name, invert(0=direct,1=invert), cmp_op(0=eq,1=a>b,2=b>a)
%macro FOR8_PREDICATE 3
%1:
    FRAME_BEGIN 40, 0
    mov     [rbp - 8],  ARG1
    mov     [rbp - 16], ARG2
    mov     [rbp - 24], ARG3
    mov     [rbp - 32], ARG4

    mov     eax, 0x80808080
    vmovd   xmm3, eax
    vpbroadcastb ymm3, xmm3             ; sign-flip constant

    movzx   eax, byte [rbp - 32]
    xor     eax, 0x80
    vmovd   xmm4, eax
    vpbroadcastb ymm4, xmm4             ; sign-flipped literal

    mov     r10, [rbp - 8]

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

    shl     rdx, 32
    or      rdx, rax

%if %2 = 1
    mov     rax, [rbp - 16]
    not     rax
    and     rax, [rbp - 24]
    xor     rdx, rax
%endif

    mov     rax, [rbp - 16]
    not     rax
    and     rdx, rax
    and     rdx, [rbp - 24]
    mov     rax, rdx

    mov     rdx, [rbp - 16]
    and     rdx, [rbp - 24]

    vzeroupper
    FRAME_END
    ret
%endmacro

FOR8_PREDICATE for8_eq, 0, 0
FOR8_PREDICATE for8_ne, 1, 0
FOR8_PREDICATE for8_gt, 0, 1
FOR8_PREDICATE for8_le, 1, 1
FOR8_PREDICATE for8_lt, 0, 2
FOR8_PREDICATE for8_ge, 1, 2

; =============================================================================
;  FOR16 kernels -- 16 lanes per YMM, four passes, 64-bit result mask
; =============================================================================
; compact_w16: eax -> 16-bit lane mask from vpmovmskb output (uses ecx scratch)
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

; FOR16_PREDICATE name, invert, op(0=eq,1=a>b,2=b>a)
%macro FOR16_PREDICATE 3
%1:
    FRAME_BEGIN 56, 0
    mov     [rbp - 8],  ARG1
    mov     [rbp - 16], ARG2
    mov     [rbp - 24], ARG3
    mov     [rbp - 32], ARG4

    mov     eax, 0x80008000
    vmovd   xmm3, eax
    vpbroadcastd ymm3, xmm3             ; sign-flip constant per word

    movzx   eax, word [rbp - 32]
    xor     eax, 0x8000
    vmovd   xmm4, eax
    vpbroadcastw ymm4, xmm4

    mov     r10, [rbp - 8]

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

    shl     rax, 48
    shl     qword [rbp - 40], 32
    or      rax, [rbp - 40]
    shl     r8, 16
    or      rax, r8
    or      rax, r9
    mov     [rbp - 48], rax

%if %2 = 1
    mov     rcx, [rbp - 16]
    not     rcx
    and     rcx, [rbp - 24]
    xor     [rbp - 48], rcx
%endif

    mov     rax, [rbp - 48]
    mov     rcx, [rbp - 16]
    not     rcx
    and     rax, rcx
    and     rax, [rbp - 24]

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

%ifdef CybouDB_LINUX
section .note.GNU-stack noalloc noexec nowrite progbits
%endif
