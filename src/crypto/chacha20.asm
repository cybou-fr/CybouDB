; Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
; SPDX-License-Identifier: Apache-2.0
; =============================================================================
;  crypto/chacha20.asm - the stream cipher half of the page seal
; =============================================================================
;  RFC 8439. One block at a time in four SSE2 registers: the state's four rows,
;  with the diagonal round expressed as three PSHUFDs rather than as a
;  different set of registers.
;
;  Why SSE2 and not AVX2: SSE2 is part of the x86-64 baseline, so this needs no
;  CPUID question, no dispatch, and no fallback to test. The engine's other
;  vector paths - POPCNT, BMI2, the AVX2 kernels - all carry a scalar twin
;  because the instruction might be missing. There is no x86-64 machine this
;  engine runs on that lacks SSE2.
;
;  Why one block and not four: four blocks need the sixteen state words in
;  sixteen registers, leaving nothing for the rotation temporary, so a
;  four-block version spills or gives up a state word to memory. Measured in C,
;  four blocks is 1.8x this one - so the four-block assembly is worth writing
;  and is worth writing second, against a correct one-block implementation that
;  can check it.
;
;  Registers: xmm0..xmm5 only. Both calling conventions treat those as
;  volatile - Win64 makes xmm6..xmm15 the caller's, and a routine that used
;  them without saving would be the SIMD version of the bug
;  tests/abi_nonvolatile_lint.py exists to catch.
;
;  The output is byte-identical to the portable implementation, at every
;  length. That is not a quality bar, it is the format's requirement: the file
;  says XChaCha20-Poly1305 and never says which instructions computed it.
;  See docs/CRYPTO_BACKEND.md.
; =============================================================================

%include "cyboudb.inc"

BITS 64
default rel

global cyboudb_chacha20_xor

section .rodata
align 16
chacha_sigma:   dd 0x61707865, 0x3320646e, 0x79622d32, 0x6b206574
chacha_one:     dd 1, 0, 0, 0

section .text

; -----------------------------------------------------------------------------
;  ROTL_EPI32 <vector>, <temp>, <bits>
;
;  SSE2 has no rotate, so it is a left shift, a right shift and an or. PSHUFB
;  would do the 16 and 8 cases in one instruction and would drag SSSE3 and a
;  dispatch decision in with it.
; -----------------------------------------------------------------------------
%macro ROTL_EPI32 3
    movdqa  %2, %1
    pslld   %1, %3
    psrld   %2, 32 - %3
    por     %1, %2
%endmacro

; -----------------------------------------------------------------------------
;  QUARTER_ROUND - the four lines of RFC 8439 section 2.1, on whole rows.
;  xmm0 = a, xmm1 = b, xmm2 = c, xmm3 = d, xmm4 = scratch.
; -----------------------------------------------------------------------------
%macro QUARTER_ROUND 0
    paddd   xmm0, xmm1
    pxor    xmm3, xmm0
    ROTL_EPI32 xmm3, xmm4, 16

    paddd   xmm2, xmm3
    pxor    xmm1, xmm2
    ROTL_EPI32 xmm1, xmm4, 12

    paddd   xmm0, xmm1
    pxor    xmm3, xmm0
    ROTL_EPI32 xmm3, xmm4, 8

    paddd   xmm2, xmm3
    pxor    xmm1, xmm2
    ROTL_EPI32 xmm1, xmm4, 7
%endmacro

; =============================================================================
;  cyboudb_chacha20_xor(key, counter, nonce, buf, len)
;
;  ARG1  const uint8_t key[32]
;  ARG2  uint32_t      counter      (the block counter the first block uses)
;  ARG3  const uint8_t nonce[12]
;  ARG4  uint8_t      *buf          (xored in place)
;  ARG5  uint64_t      len
;
;  Frame:
;    [rbp - 16]  original row 0        [rbp - 80]  the d row being built
;    [rbp - 32]  original row 1        [rbp - 160] keystream block
;    [rbp - 48]  original row 2
;    [rbp - 64]  original row 3
; =============================================================================
cyboudb_chacha20_xor:
    FRAME_BEGIN 176, 0

    ; Arguments are read from the last to the first, into registers that
    ; neither convention uses for arguments. Reading them in the written order
    ; put the length in R8 - which is ARG5 itself under System V and ARG3 under
    ; Win64 - and tests/abi_arg_lint.py said so before the first test ran.
%ifdef CybouDB_WINDOWS
    mov     rax, IN_ARG5
%else
    mov     rax, ARG5
%endif
    mov     [rbp - 176], rax            ; bytes left
    mov     [rbp - 168], ARG4           ; buf
    mov     r11, ARG3                   ; nonce
    mov     r10d, ARG2d                 ; counter
    mov     r9, ARG1                    ; key

    test    rax, rax
    jz      .done

    ; --- the three rows that never change -----------------------------------
    movdqa  xmm0, [chacha_sigma]
    movdqu  xmm1, [r9]                  ; key words 0..3
    movdqu  xmm2, [r9 + 16]             ; key words 4..7
    movdqa  [rbp - 16], xmm0
    movdqa  [rbp - 32], xmm1
    movdqa  [rbp - 48], xmm2

    ; --- row three: counter, then the twelve nonce bytes --------------------
    mov     [rbp - 80], r10d            ; the block counter
    mov     eax, [r11]                  ; and the twelve nonce bytes
    mov     [rbp - 76], eax
    mov     eax, [r11 + 4]
    mov     [rbp - 72], eax
    mov     eax, [r11 + 8]
    mov     [rbp - 68], eax

.block_loop:
    movdqa  xmm3, [rbp - 80]
    movdqa  [rbp - 64], xmm3            ; this block's original row three

    movdqa  xmm0, [rbp - 16]
    movdqa  xmm1, [rbp - 32]
    movdqa  xmm2, [rbp - 48]

    mov     ecx, 10
.round_loop:
    QUARTER_ROUND                       ; the column round

    pshufd  xmm1, xmm1, 0x39            ; rows slide one, two and three lanes
    pshufd  xmm2, xmm2, 0x4E
    pshufd  xmm3, xmm3, 0x93

    QUARTER_ROUND                       ; the diagonal round, same code

    pshufd  xmm1, xmm1, 0x93            ; and slide back
    pshufd  xmm2, xmm2, 0x4E
    pshufd  xmm3, xmm3, 0x39

    dec     ecx
    jnz     .round_loop

    paddd   xmm0, [rbp - 16]
    paddd   xmm1, [rbp - 32]
    paddd   xmm2, [rbp - 48]
    paddd   xmm3, [rbp - 64]

    movdqa  [rbp - 160], xmm0
    movdqa  [rbp - 144], xmm1
    movdqa  [rbp - 128], xmm2
    movdqa  [rbp - 112], xmm3

    ; --- xor it into the caller's bytes -------------------------------------
    mov     r10, [rbp - 168]            ; buf
    mov     r11, [rbp - 176]            ; bytes left
    mov     rax, 64
    cmp     r11, rax
    cmovb   rax, r11                    ; n = min(64, left)
    lea     r9, [rbp - 160]             ; keystream

    cmp     rax, 64
    jne     .xor_tail

    movdqu  xmm0, [r10]
    pxor    xmm0, [r9]
    movdqu  [r10], xmm0
    movdqu  xmm0, [r10 + 16]
    pxor    xmm0, [r9 + 16]
    movdqu  [r10 + 16], xmm0
    movdqu  xmm0, [r10 + 32]
    pxor    xmm0, [r9 + 32]
    movdqu  [r10 + 32], xmm0
    movdqu  xmm0, [r10 + 48]
    pxor    xmm0, [r9 + 48]
    movdqu  [r10 + 48], xmm0
    jmp     .xor_done

.xor_tail:
    ; A final partial block, byte at a time. Whole blocks are the common case
    ; and a 4096-byte page has none of these, but a page is not the only thing
    ; this will ever seal.
    xor     r8, r8
.xor_byte:
    cmp     r8, rax
    jae     .xor_done
    mov     cl, [r9 + r8]
    xor     [r10 + r8], cl
    inc     r8
    jmp     .xor_byte

.xor_done:
    add     [rbp - 168], rax            ; buf += n
    sub     [rbp - 176], rax            ; left -= n

    ; The counter lives in the stored row rather than a register, so that an
    ; overflow past 2^32 wraps exactly where RFC 8439 says it does.
    movdqa  xmm3, [rbp - 80]
    paddd   xmm3, [chacha_one]
    movdqa  [rbp - 80], xmm3

    cmp     qword [rbp - 176], 0
    jne     .block_loop

.done:
    ; Nothing of the key or the keystream is left on the stack for the next
    ; function to find. This costs one pass over 176 bytes per call.
    pxor    xmm0, xmm0
    movdqa  [rbp - 16], xmm0
    movdqa  [rbp - 32], xmm0
    movdqa  [rbp - 48], xmm0
    movdqa  [rbp - 64], xmm0
    movdqa  [rbp - 80], xmm0
    movdqa  [rbp - 160], xmm0
    movdqa  [rbp - 144], xmm0
    movdqa  [rbp - 128], xmm0
    movdqa  [rbp - 112], xmm0

    FRAME_END
    ret

%ifdef CybouDB_LINUX
section .note.GNU-stack noalloc noexec nowrite progbits
%endif
