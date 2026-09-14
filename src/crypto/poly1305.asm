; Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
; SPDX-License-Identifier: Apache-2.0
; =============================================================================
;  crypto/poly1305.asm - the authenticator half of the page seal
; =============================================================================
;  RFC 8439 section 2.5. The accumulator is three limbs of 44, 44 and 42 bits,
;  so a block costs nine 64x64->128 multiplies instead of the twenty-five
;  32x32 ones a five-limb representation needs. MUL is baseline; MULX would be
;  one instruction shorter per product and would need BMI2 and a dispatch.
;
;  r, its multiples and the pad live in the frame rather than in registers, and
;  MUL takes a memory operand, so keeping them there costs nothing and leaves
;  the registers for the accumulator and the three 128-bit partial products.
;
;  This is the serial Horner evaluation: h = (((h + m1)r + m2)r + m3)r ... Each
;  block waits for the one before it, and the C measurements say a four-chain
;  version with precomputed powers of r is 1.6x faster
;  (benchmarks/results/2026-09-15-crypto-primitives.md). That version is worth
;  writing and is worth writing second, against this one - the same order the
;  cipher was built in, and for the same reason: a fast implementation with
;  nothing to check it against is a guess.
;
;  One-shot rather than init/update/finish: the engine seals a whole page at a
;  time. A streaming interface can be added when something needs it.
; =============================================================================

%include "cyboudb.inc"

BITS 64
default rel

global cyboudb_poly1305

section .text

; --- frame, from rbp --------------------------------------------------------
%define PO_R0    8
%define PO_R1    16
%define PO_R2    24
%define PO_S1    32                     ; r1 * 20
%define PO_S2    40                     ; r2 * 20
%define PO_PAD0  48
%define PO_PAD1  56
%define PO_MAC   64                     ; where the tag goes
%define PO_TAIL  80                     ; 16 bytes: the padded final block
%define PO_RBX   88
%define PO_RSI   96
%define PO_RDI   104
%define PO_R12   112
%define PO_R13   120
%define PO_R14   128
%define PO_R15   136
%define PO_FRAME 144

%define MASK44   0xfffffffffff
%define MASK42   0x3ffffffffff

; -----------------------------------------------------------------------------
;  POLY_MULMOD - h = h * r mod 2^130-5, with h already holding (h + message).
;
;  h0 = r8, h1 = r9, h2 = r10. Clobbers rax, rdx, rcx and r11..r15, rbx.
; -----------------------------------------------------------------------------
%macro POLY_MULMOD 0
    ; d0 = h0*r0 + h1*s2 + h2*s1
    mov     rax, r8
    mul     qword [rbp - PO_R0]
    mov     r11, rax
    mov     r12, rdx
    mov     rax, r9
    mul     qword [rbp - PO_S2]
    add     r11, rax
    adc     r12, rdx
    mov     rax, r10
    mul     qword [rbp - PO_S1]
    add     r11, rax
    adc     r12, rdx

    ; d1 = h0*r1 + h1*r0 + h2*s2
    mov     rax, r8
    mul     qword [rbp - PO_R1]
    mov     r13, rax
    mov     r14, rdx
    mov     rax, r9
    mul     qword [rbp - PO_R0]
    add     r13, rax
    adc     r14, rdx
    mov     rax, r10
    mul     qword [rbp - PO_S2]
    add     r13, rax
    adc     r14, rdx

    ; d2 = h0*r2 + h1*r1 + h2*r0
    mov     rax, r8
    mul     qword [rbp - PO_R2]
    mov     r15, rax
    mov     rbx, rdx
    mov     rax, r9
    mul     qword [rbp - PO_R1]
    add     r15, rax
    adc     rbx, rdx
    mov     rax, r10
    mul     qword [rbp - PO_R0]
    add     r15, rax
    adc     rbx, rdx

    ; carry the three 128-bit products down into 44, 44 and 42 bits
    mov     rax, r11
    shrd    rax, r12, 44                ; c = d0 >> 44
    mov     rcx, MASK44
    and     r11, rcx
    mov     r8, r11                     ; h0
    add     r13, rax
    adc     r14, 0

    mov     rax, r13
    shrd    rax, r14, 44                ; c = d1 >> 44
    and     r13, rcx
    mov     r9, r13                     ; h1
    add     r15, rax
    adc     rbx, 0

    mov     rax, r15
    shrd    rax, rbx, 42                ; c = d2 >> 42
    mov     rcx, MASK42
    and     r15, rcx
    mov     r10, r15                    ; h2

    lea     rax, [rax + rax * 4]        ; the 2^130 = 5 reduction
    add     r8, rax
    mov     rax, r8
    shr     rax, 44
    mov     rcx, MASK44
    and     r8, rcx
    add     r9, rax
%endmacro

; -----------------------------------------------------------------------------
;  POLY_ABSORB <source register>, <hibit: 1 for a whole block, 0 for the tail>
;  Adds sixteen bytes to the accumulator.
; -----------------------------------------------------------------------------
%macro POLY_ABSORB 2
    mov     rax, [%1]
    mov     rdx, [%1 + 8]
    mov     rcx, MASK44

    mov     r11, rax
    and     r11, rcx
    add     r8, r11

    mov     r11, rax
    shrd    r11, rdx, 44
    and     r11, rcx
    add     r9, r11

    mov     r11, rdx
    shr     r11, 24
    mov     rcx, MASK42
    and     r11, rcx
%if %2
    mov     rcx, 1
    shl     rcx, 40                     ; the 2^128 bit, in limb two
    or      r11, rcx
%endif
    add     r10, r11
%endmacro

; =============================================================================
;  cyboudb_poly1305(key, msg, len, mac)
;
;  ARG1  const uint8_t key[32]      r, then the pad
;  ARG2  const uint8_t *msg
;  ARG3  uint64_t       len
;  ARG4  uint8_t        mac[16]
; =============================================================================
cyboudb_poly1305:
    FRAME_BEGIN PO_FRAME, 0

    mov     [rbp - PO_RBX], rbx
    mov     [rbp - PO_RSI], rsi
    mov     [rbp - PO_RDI], rdi
    mov     [rbp - PO_R12], r12
    mov     [rbp - PO_R13], r13
    mov     [rbp - PO_R14], r14
    mov     [rbp - PO_R15], r15

    ; The message pointer lives in rsi and the length in rdi, because those are
    ; the two registers neither POLY_ABSORB nor POLY_MULMOD touches. The first
    ; version kept the pointer in r11, which POLY_MULMOD uses for the low half
    ; of its first product - so the first multiply destroyed the pointer and
    ; the second block read from nowhere.
    ;
    ; Arguments are read last to first into registers that alias no argument
    ; under either convention, then moved into place.
    mov     [rbp - PO_MAC], ARG4
    mov     r10, ARG3                   ; len
    mov     r11, ARG2                   ; msg
    mov     rbx, ARG1                   ; key
    mov     rdi, r10
    mov     rsi, r11

    ; --- r, clamped, in three limbs -----------------------------------------
    mov     rax, [rbx]
    mov     rdx, [rbx + 8]

    ; r11 and not rbx for the clamping: rbx still holds the key pointer, and
    ; the pad is read from it four instructions below. Overwriting it here read
    ; the pad from a clamped limb and faulted.
    mov     r11, rax
    mov     rcx, 0x0ffc0fffffff
    and     r11, rcx
    mov     [rbp - PO_R0], r11

    mov     r11, rax
    shrd    r11, rdx, 44
    mov     rcx, 0x0fffffc0ffff
    and     r11, rcx
    mov     [rbp - PO_R1], r11

    mov     r11, rdx
    shr     r11, 24
    mov     rcx, 0x00ffffffc0f
    and     r11, rcx
    mov     [rbp - PO_R2], r11

    ; s1 = r1 * 20, s2 = r2 * 20: the reduction folded into the multiply
    mov     rax, [rbp - PO_R1]
    lea     rax, [rax + rax * 4]
    shl     rax, 2
    mov     [rbp - PO_S1], rax
    mov     rax, [rbp - PO_R2]
    lea     rax, [rax + rax * 4]
    shl     rax, 2
    mov     [rbp - PO_S2], rax

    mov     rax, [rbx + 16]
    mov     [rbp - PO_PAD0], rax
    mov     rax, [rbx + 24]
    mov     [rbp - PO_PAD1], rax

    xor     r8, r8                      ; h0
    xor     r9, r9                      ; h1
    xor     r10, r10                    ; h2

; --- whole blocks ------------------------------------------------------------
.block_loop:
    cmp     rdi, 16
    jb      .tail
    POLY_ABSORB rsi, 1
    POLY_MULMOD
    add     rsi, 16
    sub     rdi, 16
    jmp     .block_loop

; --- the last, partial block -------------------------------------------------
.tail:
    test    rdi, rdi
    jz      .finish

    xor     rax, rax                    ; zero the sixteen bytes first
    mov     [rbp - PO_TAIL], rax
    mov     [rbp - PO_TAIL + 8], rax

    xor     rcx, rcx
.tail_copy:
    cmp     rcx, rdi
    jae     .tail_pad
    mov     al, [rsi + rcx]
    mov     [rbp - PO_TAIL + rcx], al
    inc     rcx
    jmp     .tail_copy

.tail_pad:
    mov     byte [rbp - PO_TAIL + rcx], 1   ; the 1 that replaces 2^128
    lea     rsi, [rbp - PO_TAIL]
    POLY_ABSORB rsi, 0
    POLY_MULMOD

; --- h mod 2^130-5, then + pad ----------------------------------------------
.finish:
    mov     rcx, MASK44
    mov     rax, r9                     ; carry h1 into h2
    shr     rax, 44
    and     r9, rcx
    add     r10, rax

    mov     rcx, MASK42
    mov     rax, r10
    shr     rax, 42
    and     r10, rcx
    lea     rax, [rax + rax * 4]
    add     r8, rax

    mov     rcx, MASK44
    mov     rax, r8
    shr     rax, 44
    and     r8, rcx
    add     r9, rax

    mov     rax, r9
    shr     rax, 44
    and     r9, rcx
    add     r10, rax

    mov     rcx, MASK42
    mov     rax, r10
    shr     rax, 42
    and     r10, rcx
    lea     rax, [rax + rax * 4]
    add     r8, rax

    mov     rcx, MASK44
    mov     rax, r8
    shr     rax, 44
    and     r8, rcx
    add     r9, rax

    ; g = h + 5, and if it did not carry out of 2^130 then h was already below
    ; the prime and g is the wrong answer. Chosen without a branch on the data.
    mov     r12, r8
    add     r12, 5
    mov     rax, r12
    shr     rax, 44
    and     r12, rcx                    ; g0
    mov     r13, r9
    add     r13, rax
    mov     rax, r13
    shr     rax, 44
    and     r13, rcx                    ; g1
    mov     r14, r10
    add     r14, rax
    mov     rax, 1
    shl     rax, 42
    sub     r14, rax                    ; g2, borrowing if h < 2^130-5

    mov     rax, r14
    shr     rax, 63
    sub     rax, 1                      ; all ones when g did not borrow
    and     r12, rax
    and     r13, rax
    and     r14, rax
    not     rax
    and     r8, rax
    and     r9, rax
    and     r10, rax
    or      r8, r12
    or      r9, r13
    or      r10, r14

    ; + pad, and back into two 64-bit words. r11 is scratch again here: the
    ; message pointer is finished with.
    mov     rcx, MASK44
    mov     rax, [rbp - PO_PAD0]
    mov     rdx, [rbp - PO_PAD1]

    mov     r11, rax
    and     r11, rcx
    add     r8, r11

    mov     r11, rax
    shrd    r11, rdx, 44
    and     r11, rcx
    mov     rbx, r8
    shr     rbx, 44
    and     r8, rcx
    add     r9, r11
    add     r9, rbx

    mov     r11, rdx
    shr     r11, 24
    mov     rbx, MASK42
    and     r11, rbx
    mov     rax, r9
    shr     rax, 44
    and     r9, rcx
    add     r10, r11
    add     r10, rax
    and     r10, rbx

    mov     rax, r8
    mov     rdx, r9
    shl     rdx, 44
    or      rax, rdx                    ; the low eight bytes

    mov     rdx, r9
    shr     rdx, 20
    mov     rbx, r10
    shl     rbx, 24
    or      rdx, rbx                    ; and the high eight

    mov     rcx, [rbp - PO_MAC]
    mov     [rcx], rax
    mov     [rcx + 8], rdx

    ; Nothing of r, the pad or the accumulator is left for the next function.
    xor     rax, rax
    mov     [rbp - PO_R0], rax
    mov     [rbp - PO_R1], rax
    mov     [rbp - PO_R2], rax
    mov     [rbp - PO_S1], rax
    mov     [rbp - PO_S2], rax
    mov     [rbp - PO_PAD0], rax
    mov     [rbp - PO_PAD1], rax
    mov     [rbp - PO_TAIL], rax
    mov     [rbp - PO_TAIL + 8], rax

    mov     rbx, [rbp - PO_RBX]
    mov     rsi, [rbp - PO_RSI]
    mov     rdi, [rbp - PO_RDI]
    mov     r12, [rbp - PO_R12]
    mov     r13, [rbp - PO_R13]
    mov     r14, [rbp - PO_R14]
    mov     r15, [rbp - PO_R15]

    FRAME_END
    ret

%ifdef CybouDB_LINUX
section .note.GNU-stack noalloc noexec nowrite progbits
%endif
