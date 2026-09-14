; Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
; SPDX-License-Identifier: Apache-2.0
; =============================================================================
;  crypto/chacha20.asm - the stream cipher half of the page seal
; =============================================================================
;  RFC 8439, SSE2 only. Three blocks at a time where there is work for three,
;  one at a time for what is left.
;
;  Why SSE2 and not AVX2: SSE2 is part of the x86-64 baseline, so this needs no
;  CPUID question, no dispatch, and no fallback to test. The engine's other
;  vector paths - POPCNT, BMI2, the AVX2 kernels - all carry a scalar twin
;  because the instruction might be missing. There is no x86-64 machine this
;  engine runs on that lacks SSE2.
;
;  Why three blocks and not four. The fast way to do four is the transposed
;  layout, where a register holds word i of four different blocks and the
;  diagonal round costs nothing - but that needs all sixteen state words in
;  registers at once, and SSE2 has sixteen, leaving none for the rotation
;  temporary that shift-shift-or requires. Three independent copies of the
;  row-oriented block function fit exactly: twelve state registers and three
;  temporaries, with one to spare. The measured C versions bracket it - one
;  block 4.6 us per page, four blocks 2.6 - and three chains is where most of
;  that distance is, because the win is having independent work rather than
;  wider registers.
;
;  Win64 makes xmm6..xmm15 the caller's, so the three-block path saves the nine
;  it uses and gives them back. System V does not need that and does not pay
;  for it. The frame is laid out identically on both so the offsets below mean
;  one thing.
;
;  The output is byte-identical to the portable implementation, at every
;  length, and to the one-block path it replaces. That is not a quality bar, it
;  is the format's requirement: the file says XChaCha20-Poly1305 and never says
;  which instructions computed it. See docs/CRYPTO_BACKEND.md.
; =============================================================================

%include "cyboudb.inc"

BITS 64
default rel

global cyboudb_chacha20_xor
global cyboudb_hchacha20

section .rodata
align 16
chacha_sigma:   dd 0x61707865, 0x3320646e, 0x79622d32, 0x6b206574
chacha_one:     dd 1, 0, 0, 0

section .text

; --- frame offsets, all from rbp -------------------------------------------
%define ST_ROW0   16                    ; the three rows every block shares
%define ST_ROW1   32
%define ST_ROW2   48
%define ST_CTR    64                    ; row three for the next block
%define ST_D0     80                    ; row three as each block started with
%define ST_D1     96
%define ST_D2     112
%define ST_KS     320                   ; 192 bytes of keystream, blocks A B C
%define ST_BUF    328
%define ST_LEFT   336
%define ST_XMM    480                   ; xmm6..xmm14, Win64 only

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
;  QUARTER_ROUND <a>, <b>, <c>, <d>, <temp> - RFC 8439 section 2.1, on rows.
; -----------------------------------------------------------------------------
%macro QUARTER_ROUND 5
    paddd   %1, %2
    pxor    %4, %1
    ROTL_EPI32 %4, %5, 16
    paddd   %3, %4
    pxor    %2, %3
    ROTL_EPI32 %2, %5, 12
    paddd   %1, %2
    pxor    %4, %1
    ROTL_EPI32 %4, %5, 8
    paddd   %3, %4
    pxor    %2, %3
    ROTL_EPI32 %2, %5, 7
%endmacro

; -----------------------------------------------------------------------------
;  QR3 - the same quarter round for three blocks, interleaved line by line so
;  that the three dependency chains are visible to the machine rather than
;  sequential. This interleaving is the whole reason the three-block path is
;  faster than three calls to the one-block path.
; -----------------------------------------------------------------------------
%macro QR3 0
    paddd   xmm0, xmm1
    paddd   xmm4, xmm5
    paddd   xmm8, xmm9
    pxor    xmm3, xmm0
    pxor    xmm7, xmm4
    pxor    xmm11, xmm8
    ROTL_EPI32 xmm3, xmm12, 16
    ROTL_EPI32 xmm7, xmm13, 16
    ROTL_EPI32 xmm11, xmm14, 16

    paddd   xmm2, xmm3
    paddd   xmm6, xmm7
    paddd   xmm10, xmm11
    pxor    xmm1, xmm2
    pxor    xmm5, xmm6
    pxor    xmm9, xmm10
    ROTL_EPI32 xmm1, xmm12, 12
    ROTL_EPI32 xmm5, xmm13, 12
    ROTL_EPI32 xmm9, xmm14, 12

    paddd   xmm0, xmm1
    paddd   xmm4, xmm5
    paddd   xmm8, xmm9
    pxor    xmm3, xmm0
    pxor    xmm7, xmm4
    pxor    xmm11, xmm8
    ROTL_EPI32 xmm3, xmm12, 8
    ROTL_EPI32 xmm7, xmm13, 8
    ROTL_EPI32 xmm11, xmm14, 8

    paddd   xmm2, xmm3
    paddd   xmm6, xmm7
    paddd   xmm10, xmm11
    pxor    xmm1, xmm2
    pxor    xmm5, xmm6
    pxor    xmm9, xmm10
    ROTL_EPI32 xmm1, xmm12, 7
    ROTL_EPI32 xmm5, xmm13, 7
    ROTL_EPI32 xmm9, xmm14, 7
%endmacro

%macro SHUFFLE3 3                       ; b by %1, c by %2, d by %3 lanes
    pshufd  xmm1, xmm1, %1
    pshufd  xmm5, xmm5, %1
    pshufd  xmm9, xmm9, %1
    pshufd  xmm2, xmm2, %2
    pshufd  xmm6, xmm6, %2
    pshufd  xmm10, xmm10, %2
    pshufd  xmm3, xmm3, %3
    pshufd  xmm7, xmm7, %3
    pshufd  xmm11, xmm11, %3
%endmacro

; =============================================================================
;  cyboudb_chacha20_xor(key, counter, nonce, buf, len)
;
;  ARG1  const uint8_t key[32]
;  ARG2  uint32_t      counter      (the block counter the first block uses)
;  ARG3  const uint8_t nonce[12]
;  ARG4  uint8_t      *buf          (xored in place)
;  ARG5  uint64_t      len
; =============================================================================
cyboudb_chacha20_xor:
    FRAME_BEGIN ST_XMM, 0

    ; Arguments are read from the last to the first, into registers that
    ; neither convention uses for arguments. Reading them in the written order
    ; put the length in R8 - which is ARG5 itself under System V and ARG3 under
    ; Win64 - and tests/abi_arg_lint.py said so before the first test ran.
%ifdef CybouDB_WINDOWS
    mov     rax, IN_ARG5
%else
    mov     rax, ARG5
%endif
    mov     [rbp - ST_LEFT], rax
    mov     [rbp - ST_BUF], ARG4
    mov     r11, ARG3                   ; nonce
    mov     r10d, ARG2d                 ; counter
    mov     r9, ARG1                    ; key

    test    rax, rax
    jz      .done

%ifdef CybouDB_WINDOWS
    movdqa  [rbp - ST_XMM], xmm6        ; the caller's, under this convention
    movdqa  [rbp - ST_XMM + 16], xmm7
    movdqa  [rbp - ST_XMM + 32], xmm8
    movdqa  [rbp - ST_XMM + 48], xmm9
    movdqa  [rbp - ST_XMM + 64], xmm10
    movdqa  [rbp - ST_XMM + 80], xmm11
    movdqa  [rbp - ST_XMM + 96], xmm12
    movdqa  [rbp - ST_XMM + 112], xmm13
    movdqa  [rbp - ST_XMM + 128], xmm14
%endif

    ; --- the three rows that never change -----------------------------------
    movdqa  xmm0, [chacha_sigma]
    movdqu  xmm1, [r9]                  ; key words 0..3
    movdqu  xmm2, [r9 + 16]             ; key words 4..7
    movdqa  [rbp - ST_ROW0], xmm0
    movdqa  [rbp - ST_ROW1], xmm1
    movdqa  [rbp - ST_ROW2], xmm2

    ; --- row three: counter, then the twelve nonce bytes --------------------
    mov     [rbp - ST_CTR], r10d
    mov     eax, [r11]
    mov     [rbp - ST_CTR + 4], eax
    mov     eax, [r11 + 4]
    mov     [rbp - ST_CTR + 8], eax
    mov     eax, [r11 + 8]
    mov     [rbp - ST_CTR + 12], eax

; -----------------------------------------------------------------------------
;  Three blocks at a time, while there are 192 bytes to seal.
; -----------------------------------------------------------------------------
.three_loop:
    cmp     qword [rbp - ST_LEFT], 192
    jb      .one_block

    movdqa  xmm3, [rbp - ST_CTR]        ; block A's row three
    movdqa  xmm7, xmm3
    paddd   xmm7, [chacha_one]          ; B
    movdqa  xmm11, xmm7
    paddd   xmm11, [chacha_one]         ; C
    movdqa  [rbp - ST_D0], xmm3
    movdqa  [rbp - ST_D1], xmm7
    movdqa  [rbp - ST_D2], xmm11

    movdqa  xmm0, [rbp - ST_ROW0]
    movdqa  xmm1, [rbp - ST_ROW1]
    movdqa  xmm2, [rbp - ST_ROW2]
    movdqa  xmm4, xmm0
    movdqa  xmm5, xmm1
    movdqa  xmm6, xmm2
    movdqa  xmm8, xmm0
    movdqa  xmm9, xmm1
    movdqa  xmm10, xmm2

    mov     ecx, 10
.three_rounds:
    QR3
    SHUFFLE3 0x39, 0x4E, 0x93
    QR3
    SHUFFLE3 0x93, 0x4E, 0x39
    dec     ecx
    jnz     .three_rounds

    paddd   xmm0, [rbp - ST_ROW0]
    paddd   xmm1, [rbp - ST_ROW1]
    paddd   xmm2, [rbp - ST_ROW2]
    paddd   xmm3, [rbp - ST_D0]
    paddd   xmm4, [rbp - ST_ROW0]
    paddd   xmm5, [rbp - ST_ROW1]
    paddd   xmm6, [rbp - ST_ROW2]
    paddd   xmm7, [rbp - ST_D1]
    paddd   xmm8, [rbp - ST_ROW0]
    paddd   xmm9, [rbp - ST_ROW1]
    paddd   xmm10, [rbp - ST_ROW2]
    paddd   xmm11, [rbp - ST_D2]

    mov     r10, [rbp - ST_BUF]

    movdqu  xmm12, [r10]
    pxor    xmm12, xmm0
    movdqu  [r10], xmm12
    movdqu  xmm12, [r10 + 16]
    pxor    xmm12, xmm1
    movdqu  [r10 + 16], xmm12
    movdqu  xmm12, [r10 + 32]
    pxor    xmm12, xmm2
    movdqu  [r10 + 32], xmm12
    movdqu  xmm12, [r10 + 48]
    pxor    xmm12, xmm3
    movdqu  [r10 + 48], xmm12

    movdqu  xmm12, [r10 + 64]
    pxor    xmm12, xmm4
    movdqu  [r10 + 64], xmm12
    movdqu  xmm12, [r10 + 80]
    pxor    xmm12, xmm5
    movdqu  [r10 + 80], xmm12
    movdqu  xmm12, [r10 + 96]
    pxor    xmm12, xmm6
    movdqu  [r10 + 96], xmm12
    movdqu  xmm12, [r10 + 112]
    pxor    xmm12, xmm7
    movdqu  [r10 + 112], xmm12

    movdqu  xmm12, [r10 + 128]
    pxor    xmm12, xmm8
    movdqu  [r10 + 128], xmm12
    movdqu  xmm12, [r10 + 144]
    pxor    xmm12, xmm9
    movdqu  [r10 + 144], xmm12
    movdqu  xmm12, [r10 + 160]
    pxor    xmm12, xmm10
    movdqu  [r10 + 160], xmm12
    movdqu  xmm12, [r10 + 176]
    pxor    xmm12, xmm11
    movdqu  [r10 + 176], xmm12

    add     qword [rbp - ST_BUF], 192
    sub     qword [rbp - ST_LEFT], 192

    movdqa  xmm3, [rbp - ST_CTR]        ; three blocks consumed
    paddd   xmm3, [chacha_one]
    paddd   xmm3, [chacha_one]
    paddd   xmm3, [chacha_one]
    movdqa  [rbp - ST_CTR], xmm3
    jmp     .three_loop

; -----------------------------------------------------------------------------
;  One block at a time for the rest: at most two whole blocks and a tail.
; -----------------------------------------------------------------------------
.one_block:
    cmp     qword [rbp - ST_LEFT], 0
    je      .wipe

    movdqa  xmm3, [rbp - ST_CTR]
    movdqa  [rbp - ST_D0], xmm3
    movdqa  xmm0, [rbp - ST_ROW0]
    movdqa  xmm1, [rbp - ST_ROW1]
    movdqa  xmm2, [rbp - ST_ROW2]

    mov     ecx, 10
.one_rounds:
    QUARTER_ROUND xmm0, xmm1, xmm2, xmm3, xmm12
    pshufd  xmm1, xmm1, 0x39
    pshufd  xmm2, xmm2, 0x4E
    pshufd  xmm3, xmm3, 0x93
    QUARTER_ROUND xmm0, xmm1, xmm2, xmm3, xmm12
    pshufd  xmm1, xmm1, 0x93
    pshufd  xmm2, xmm2, 0x4E
    pshufd  xmm3, xmm3, 0x39
    dec     ecx
    jnz     .one_rounds

    paddd   xmm0, [rbp - ST_ROW0]
    paddd   xmm1, [rbp - ST_ROW1]
    paddd   xmm2, [rbp - ST_ROW2]
    paddd   xmm3, [rbp - ST_D0]

    movdqa  [rbp - ST_KS], xmm0
    movdqa  [rbp - ST_KS + 16], xmm1
    movdqa  [rbp - ST_KS + 32], xmm2
    movdqa  [rbp - ST_KS + 48], xmm3

    mov     r10, [rbp - ST_BUF]
    mov     r11, [rbp - ST_LEFT]
    mov     rax, 64
    cmp     r11, rax
    cmovb   rax, r11                    ; n = min(64, left)
    lea     r9, [rbp - ST_KS]

    cmp     rax, 64
    jne     .one_tail

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
    jmp     .one_done

.one_tail:
    ; A final partial block, byte at a time. A 4096-byte page has none of
    ; these, but a page is not the only thing this will ever seal.
    xor     r8, r8
.one_byte:
    cmp     r8, rax
    jae     .one_done
    mov     cl, [r9 + r8]
    xor     [r10 + r8], cl
    inc     r8
    jmp     .one_byte

.one_done:
    add     [rbp - ST_BUF], rax
    sub     [rbp - ST_LEFT], rax

    ; The counter lives in the stored row rather than a register, so that an
    ; overflow past 2^32 wraps exactly where RFC 8439 says it does.
    movdqa  xmm3, [rbp - ST_CTR]
    paddd   xmm3, [chacha_one]
    movdqa  [rbp - ST_CTR], xmm3
    jmp     .one_block

.wipe:
%ifdef CybouDB_WINDOWS
    movdqa  xmm6, [rbp - ST_XMM]
    movdqa  xmm7, [rbp - ST_XMM + 16]
    movdqa  xmm8, [rbp - ST_XMM + 32]
    movdqa  xmm9, [rbp - ST_XMM + 48]
    movdqa  xmm10, [rbp - ST_XMM + 64]
    movdqa  xmm11, [rbp - ST_XMM + 80]
    movdqa  xmm12, [rbp - ST_XMM + 96]
    movdqa  xmm13, [rbp - ST_XMM + 112]
    movdqa  xmm14, [rbp - ST_XMM + 128]
%endif

    ; Nothing of the key or the keystream is left on the stack for the next
    ; function to find.
    pxor    xmm0, xmm0
    movdqa  [rbp - ST_ROW0], xmm0
    movdqa  [rbp - ST_ROW1], xmm0
    movdqa  [rbp - ST_ROW2], xmm0
    movdqa  [rbp - ST_CTR], xmm0
    movdqa  [rbp - ST_D0], xmm0
    movdqa  [rbp - ST_D1], xmm0
    movdqa  [rbp - ST_D2], xmm0
    movdqa  [rbp - ST_KS], xmm0
    movdqa  [rbp - ST_KS + 16], xmm0
    movdqa  [rbp - ST_KS + 32], xmm0
    movdqa  [rbp - ST_KS + 48], xmm0

.done:
    FRAME_END
    ret

; =============================================================================
;  cyboudb_hchacha20(key, nonce, out)
;
;  ARG1  const uint8_t key[32]
;  ARG2  const uint8_t nonce[16]
;  ARG3  uint8_t       out[32]
;
;  draft-irtf-cfrg-xchacha section 2.2. The same permutation as ChaCha20 with
;  the sixteen nonce bytes where the counter and the twelve-byte nonce usually
;  sit, and **no final addition of the original state** - the output is rows
;  zero and three as the rounds left them.
;
;  That last difference is the whole of it, and it is why this cannot be a flag
;  on the cipher above: adding the original state back would make the result
;  invertible, and HChaCha20's job is to derive a subkey that does not give the
;  key away.
;
;  It is what turns a 24-byte nonce into something ChaCha20 can use: the first
;  sixteen bytes pick a subkey, the last eight become the nonce, and a random
;  192-bit nonce per page becomes safe to draw - docs/CRYPTO_BACKEND.md,
;  Decision 2.
; =============================================================================
cyboudb_hchacha20:
    FRAME_BEGIN 64, 0

    mov     r10, ARG3                   ; out
    mov     r11, ARG2                   ; nonce
    mov     r9, ARG1                    ; key

    movdqa  xmm0, [chacha_sigma]
    movdqu  xmm1, [r9]
    movdqu  xmm2, [r9 + 16]
    movdqu  xmm3, [r11]                 ; all sixteen nonce bytes

    mov     ecx, 10
.hround:
    QUARTER_ROUND xmm0, xmm1, xmm2, xmm3, xmm4
    pshufd  xmm1, xmm1, 0x39
    pshufd  xmm2, xmm2, 0x4E
    pshufd  xmm3, xmm3, 0x93
    QUARTER_ROUND xmm0, xmm1, xmm2, xmm3, xmm4
    pshufd  xmm1, xmm1, 0x93
    pshufd  xmm2, xmm2, 0x4E
    pshufd  xmm3, xmm3, 0x39
    dec     ecx
    jnz     .hround

    movdqu  [r10], xmm0                 ; rows zero and three, unadded
    movdqu  [r10 + 16], xmm3

    pxor    xmm0, xmm0
    pxor    xmm1, xmm1
    pxor    xmm2, xmm2
    pxor    xmm3, xmm3
    pxor    xmm4, xmm4

    FRAME_END
    ret

%ifdef CybouDB_LINUX
section .note.GNU-stack noalloc noexec nowrite progbits
%endif
