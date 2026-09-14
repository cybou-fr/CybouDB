; Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
; SPDX-License-Identifier: Apache-2.0
; =============================================================================
;  tests/chacha20_abi.asm - does the cipher give the caller's registers back?
; =============================================================================
;  Win64 makes xmm6..xmm15 callee-saved. src/crypto/chacha20.asm uses nine of
;  them on its three-block path and saves them by hand, and a C test cannot
;  check that: the compiler is free not to keep anything live in those
;  registers across the call, so the test would pass whether or not they came
;  back.
;
;  So this fills all ten with values nothing else would produce, calls the
;  cipher with enough bytes to take the three-block path, and reports which
;  ones changed. It is the SIMD half of what tests/abi_nonvolatile_lint.py does
;  for general-purpose registers - that lint reads the source, this runs it.
;
;  Returns a bitmask: bit 0 is xmm6, bit 9 is xmm15. Zero is the answer Win64
;  requires. Under System V those registers are scratch and a non-zero result
;  is not a defect, which is why the C side only asserts on Windows.
;
;  The call has to be 192 bytes or more or it takes the one-block path, which
;  touches none of these registers and would make this probe agree with
;  anything.
; =============================================================================

%include "cyboudb.inc"

BITS 64
default rel

global cyboudb_chacha20_abi_probe
extern cyboudb_chacha20_xor

section .rodata
align 16
abi_pattern:    dd 0xA5A50000, 0xA5A50001, 0xA5A50002, 0xA5A50003

section .text

; The frame, from rbp, each region distinct - the first version of this file
; parked the caller's registers and the expected pattern at the same address.
%define ABI_PAT   160                   ; [rbp-160 .. rbp-1]   ten copies
%define ABI_SAVE  320                   ; [rbp-320 .. rbp-161] ten saves
%define ABI_BUF   576                   ; [rbp-576 .. rbp-321] 256 bytes
%define ABI_KEY   608                   ; [rbp-608 .. rbp-577] key, then nonce

%macro CHECK_XMM 3                      ; pattern slot, register, mask bit
    movdqa  xmm0, [rbp - %1]
    pcmpeqd xmm0, %2
    pmovmskb ecx, xmm0
    cmp     ecx, 0xffff
    je      %%same
    or      eax, %3
%%same:
%endmacro

cyboudb_chacha20_abi_probe:
    FRAME_BEGIN ABI_KEY, 1

    ; Park the caller's copies first: this routine is as bound by the
    ; convention as the one it is testing.
    movdqa  [rbp - ABI_SAVE], xmm6
    movdqa  [rbp - ABI_SAVE + 16], xmm7
    movdqa  [rbp - ABI_SAVE + 32], xmm8
    movdqa  [rbp - ABI_SAVE + 48], xmm9
    movdqa  [rbp - ABI_SAVE + 64], xmm10
    movdqa  [rbp - ABI_SAVE + 80], xmm11
    movdqa  [rbp - ABI_SAVE + 96], xmm12
    movdqa  [rbp - ABI_SAVE + 112], xmm13
    movdqa  [rbp - ABI_SAVE + 128], xmm14
    movdqa  [rbp - ABI_SAVE + 144], xmm15

    ; A key, a nonce and a buffer, all zero: what the cipher computes does not
    ; matter here, only what it leaves behind.
    pxor    xmm0, xmm0
    movdqa  [rbp - ABI_KEY], xmm0
    movdqa  [rbp - ABI_KEY + 16], xmm0
    mov     ecx, 16
    lea     r10, [rbp - ABI_BUF]
.zero_buf:
    movdqa  [r10], xmm0
    add     r10, 16
    dec     ecx
    jnz     .zero_buf

    ; Fill the ten with a pattern, each different from the next.
    movdqa  xmm6, [abi_pattern]
    movdqa  xmm7, xmm6
    paddd   xmm7, [abi_pattern]
    movdqa  xmm8, xmm7
    paddd   xmm8, [abi_pattern]
    movdqa  xmm9, xmm8
    paddd   xmm9, [abi_pattern]
    movdqa  xmm10, xmm9
    paddd   xmm10, [abi_pattern]
    movdqa  xmm11, xmm10
    paddd   xmm11, [abi_pattern]
    movdqa  xmm12, xmm11
    paddd   xmm12, [abi_pattern]
    movdqa  xmm13, xmm12
    paddd   xmm13, [abi_pattern]
    movdqa  xmm14, xmm13
    paddd   xmm14, [abi_pattern]
    movdqa  xmm15, xmm14
    paddd   xmm15, [abi_pattern]

    ; And keep a copy where the call cannot reach it.
    movdqa  [rbp - ABI_PAT], xmm6
    movdqa  [rbp - ABI_PAT + 16], xmm7
    movdqa  [rbp - ABI_PAT + 32], xmm8
    movdqa  [rbp - ABI_PAT + 48], xmm9
    movdqa  [rbp - ABI_PAT + 64], xmm10
    movdqa  [rbp - ABI_PAT + 80], xmm11
    movdqa  [rbp - ABI_PAT + 96], xmm12
    movdqa  [rbp - ABI_PAT + 112], xmm13
    movdqa  [rbp - ABI_PAT + 128], xmm14
    movdqa  [rbp - ABI_PAT + 144], xmm15

    lea     ARG1, [rbp - ABI_KEY]       ; key
    mov     ARG2d, 1                    ; counter
    lea     ARG3, [rbp - ABI_KEY + 16]  ; nonce: twelve zero bytes
    lea     ARG4, [rbp - ABI_BUF]       ; buffer
%ifdef CybouDB_WINDOWS
    mov     rax, 256
    PASS_ARG5 rax
%else
    mov     ARG5, 256                   ; four blocks: the three-block path runs
%endif
    call    cyboudb_chacha20_xor

    xor     eax, eax
    CHECK_XMM ABI_PAT,       xmm6,  1
    CHECK_XMM ABI_PAT + 16,  xmm7,  2
    CHECK_XMM ABI_PAT + 32,  xmm8,  4
    CHECK_XMM ABI_PAT + 48,  xmm9,  8
    CHECK_XMM ABI_PAT + 64,  xmm10, 16
    CHECK_XMM ABI_PAT + 80,  xmm11, 32
    CHECK_XMM ABI_PAT + 96,  xmm12, 64
    CHECK_XMM ABI_PAT + 112, xmm13, 128
    CHECK_XMM ABI_PAT + 128, xmm14, 256
    CHECK_XMM ABI_PAT + 144, xmm15, 512

    movdqa  xmm6, [rbp - ABI_SAVE]
    movdqa  xmm7, [rbp - ABI_SAVE + 16]
    movdqa  xmm8, [rbp - ABI_SAVE + 32]
    movdqa  xmm9, [rbp - ABI_SAVE + 48]
    movdqa  xmm10, [rbp - ABI_SAVE + 64]
    movdqa  xmm11, [rbp - ABI_SAVE + 80]
    movdqa  xmm12, [rbp - ABI_SAVE + 96]
    movdqa  xmm13, [rbp - ABI_SAVE + 112]
    movdqa  xmm14, [rbp - ABI_SAVE + 128]
    movdqa  xmm15, [rbp - ABI_SAVE + 144]

    FRAME_END
    ret

%ifdef CybouDB_LINUX
section .note.GNU-stack noalloc noexec nowrite progbits
%endif
