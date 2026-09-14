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
;  r, its powers and the pad live in the frame rather than in registers, and
;  MUL takes a memory operand, so keeping them there costs nothing and leaves
;  the registers for the accumulator and the three 128-bit partial products.
;
;  Poly1305 is a Horner evaluation - h = (((h + m1)r + m2)r + m3)r ... - so
;  every block waits for the one before it and the machine's multipliers idle.
;  Four accumulators, each advancing by r^4 and combined at the end with r^4,
;  r^3, r^2 and r, give four independent chains. Measured in C that is 1.6x,
;  and it is the same trick that made the cipher fast: independent work rather
;  than wider registers.
;
;  Under 64 bytes there is nothing to parallelise, so the tail is the ordinary
;  serial evaluation. Both paths are behind one entry point, which is what lets
;  tests/poly1305_test.c check every length from 0 to 600 and cross the
;  boundary between them thirty-seven times.
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
;  Each power of r is five qwords: r0, r1, r2, then r1*20 and r2*20, which is
;  the 2^130 = 5 reduction folded into the multiply.
%define PO_PAD0  48
%define PO_PAD1  56
%define PO_MAC   64
%define PO_TAIL  80                     ; 16 bytes: the padded final block
%define PO_SUM   120                    ; the combined accumulator, 3 limbs
%define PW_R     200                    ; r
%define PW_R2    240                    ; r^2
%define PW_R3    280                    ; r^3
%define PW_R4    320                    ; r^4
%define ACC      416                    ; four accumulators, three limbs each
%define PO_RBX   448
%define PO_RSI   456
%define PO_RDI   464
%define PO_R12   472
%define PO_R13   480
%define PO_R14   488
%define PO_R15   496
%define PO_FRAME 512

%define MASK44   0xfffffffffff
%define MASK42   0x3ffffffffff

; -----------------------------------------------------------------------------
;  POLY_MULMOD <power base> - h = h * <power> mod 2^130-5.
;  h0 = r8, h1 = r9, h2 = r10. Clobbers rax, rdx, rcx, r11..r15, rbx.
; -----------------------------------------------------------------------------
%macro POLY_MULMOD 1
    ; d0 = h0*r0 + h1*s2 + h2*s1
    mov     rax, r8
    mul     qword [rbp - %1]
    mov     r11, rax
    mov     r12, rdx
    mov     rax, r9
    mul     qword [rbp - %1 + 32]
    add     r11, rax
    adc     r12, rdx
    mov     rax, r10
    mul     qword [rbp - %1 + 24]
    add     r11, rax
    adc     r12, rdx

    ; d1 = h0*r1 + h1*r0 + h2*s2
    mov     rax, r8
    mul     qword [rbp - %1 + 8]
    mov     r13, rax
    mov     r14, rdx
    mov     rax, r9
    mul     qword [rbp - %1]
    add     r13, rax
    adc     r14, rdx
    mov     rax, r10
    mul     qword [rbp - %1 + 32]
    add     r13, rax
    adc     r14, rdx

    ; d2 = h0*r2 + h1*r1 + h2*r0
    mov     rax, r8
    mul     qword [rbp - %1 + 16]
    mov     r15, rax
    mov     rbx, rdx
    mov     rax, r9
    mul     qword [rbp - %1 + 8]
    add     r15, rax
    adc     rbx, rdx
    mov     rax, r10
    mul     qword [rbp - %1]
    add     r15, rax
    adc     rbx, rdx

    ; carry the three 128-bit products down into 44, 44 and 42 bits
    mov     rax, r11
    shrd    rax, r12, 44
    mov     rcx, MASK44
    and     r11, rcx
    mov     r8, r11
    add     r13, rax
    adc     r14, 0

    mov     rax, r13
    shrd    rax, r14, 44
    and     r13, rcx
    mov     r9, r13
    add     r15, rax
    adc     rbx, 0

    mov     rax, r15
    shrd    rax, rbx, 42
    mov     rcx, MASK42
    and     r15, rcx
    mov     r10, r15

    lea     rax, [rax + rax * 4]        ; the 2^130 = 5 reduction
    add     r8, rax
    mov     rax, r8
    shr     rax, 44
    mov     rcx, MASK44
    and     r8, rcx
    add     r9, rax
%endmacro

; -----------------------------------------------------------------------------
;  POLY_ABSORB <base>, <displacement>, <hibit>
;  Adds the sixteen bytes at [base + displacement] to the accumulator.
; -----------------------------------------------------------------------------
%macro POLY_ABSORB 3
    mov     rax, [%1 + %2]
    mov     rdx, [%1 + %2 + 8]
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
%if %3
    mov     rcx, 1
    shl     rcx, 40                     ; the 2^128 bit, in limb two
    or      r11, rcx
%endif
    add     r10, r11
%endmacro

; -----------------------------------------------------------------------------
;  POWER_STORE <base> - write h0..h2 as a power block, with its two multiples.
; -----------------------------------------------------------------------------
%macro POWER_STORE 1
    mov     [rbp - %1], r8
    mov     [rbp - %1 + 8], r9
    mov     [rbp - %1 + 16], r10
    mov     rax, r9
    lea     rax, [rax + rax * 4]
    shl     rax, 2                      ; r1 * 20
    mov     [rbp - %1 + 24], rax
    mov     rax, r10
    lea     rax, [rax + rax * 4]
    shl     rax, 2                      ; r2 * 20
    mov     [rbp - %1 + 32], rax
%endmacro

%macro POWER_LOAD 1
    mov     r8, [rbp - %1]
    mov     r9, [rbp - %1 + 8]
    mov     r10, [rbp - %1 + 16]
%endmacro

%macro ACC_LOAD 1                       ; lane index
    mov     r8, [rbp - ACC + %1 * 24]
    mov     r9, [rbp - ACC + %1 * 24 + 8]
    mov     r10, [rbp - ACC + %1 * 24 + 16]
%endmacro

%macro ACC_STORE 1
    mov     [rbp - ACC + %1 * 24], r8
    mov     [rbp - ACC + %1 * 24 + 8], r9
    mov     [rbp - ACC + %1 * 24 + 16], r10
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
    ; the two registers neither POLY_ABSORB nor POLY_MULMOD touches. Arguments
    ; are read last to first into registers that alias no argument under either
    ; convention, then moved into place.
    mov     [rbp - PO_MAC], ARG4
    mov     r10, ARG3                   ; len
    mov     r11, ARG2                   ; msg
    mov     rbx, ARG1                   ; key
    mov     rdi, r10
    mov     rsi, r11

    ; --- r, clamped, in three limbs -----------------------------------------
    ; r11 and not rbx for the clamping: rbx still holds the key pointer, and
    ; the pad is read from it below.
    mov     rax, [rbx]
    mov     rdx, [rbx + 8]

    mov     r11, rax
    mov     rcx, 0x0ffc0fffffff
    and     r11, rcx
    mov     r8, r11

    mov     r11, rax
    shrd    r11, rdx, 44
    mov     rcx, 0x0fffffc0ffff
    and     r11, rcx
    mov     r9, r11

    mov     r11, rdx
    shr     r11, 24
    mov     rcx, 0x00ffffffc0f
    and     r11, rcx
    mov     r10, r11

    POWER_STORE PW_R

    mov     rax, [rbx + 16]
    mov     [rbp - PO_PAD0], rax
    mov     rax, [rbx + 24]
    mov     [rbp - PO_PAD1], rax

    ; --- the powers the four chains need ------------------------------------
    ; Three multiplies, computed whatever the length. Branching around them for
    ; short messages would save twenty-seven instructions and add a second path
    ; to get wrong.
    POLY_MULMOD PW_R                    ; r * r
    POWER_STORE PW_R2
    POLY_MULMOD PW_R                    ; r^2 * r
    POWER_STORE PW_R3
    POWER_LOAD PW_R2
    POLY_MULMOD PW_R2                   ; r^2 * r^2
    POWER_STORE PW_R4

    xor     rax, rax
    mov     rcx, 12
    lea     r11, [rbp - ACC]
.zero_acc:
    mov     [r11], rax
    add     r11, 8
    dec     rcx
    jnz     .zero_acc

; --- four blocks at a time ---------------------------------------------------
;  acc = acc * r^4 + m, and not (acc + m) * r^4: the second gives every block
;  one factor of r^4 too many. The RFC's own vector cannot see the difference,
;  because a 34-byte message never reaches this loop - the C version made
;  exactly that mistake and the differential test at every length caught it.
.four_loop:
    cmp     rdi, 64
    jb      .combine

    ACC_LOAD 0
    POLY_MULMOD PW_R4
    POLY_ABSORB rsi, 0, 1
    ACC_STORE 0

    ACC_LOAD 1
    POLY_MULMOD PW_R4
    POLY_ABSORB rsi, 16, 1
    ACC_STORE 1

    ACC_LOAD 2
    POLY_MULMOD PW_R4
    POLY_ABSORB rsi, 32, 1
    ACC_STORE 2

    ACC_LOAD 3
    POLY_MULMOD PW_R4
    POLY_ABSORB rsi, 48, 1
    ACC_STORE 3

    add     rsi, 64
    sub     rdi, 64
    jmp     .four_loop

; --- combine: H = a0.r^4 + a1.r^3 + a2.r^2 + a3.r ---------------------------
.combine:
    ACC_LOAD 0
    POLY_MULMOD PW_R4
    mov     [rbp - PO_SUM], r8
    mov     [rbp - PO_SUM + 8], r9
    mov     [rbp - PO_SUM + 16], r10

    ACC_LOAD 1
    POLY_MULMOD PW_R3
    add     [rbp - PO_SUM], r8
    add     [rbp - PO_SUM + 8], r9
    add     [rbp - PO_SUM + 16], r10

    ACC_LOAD 2
    POLY_MULMOD PW_R2
    add     [rbp - PO_SUM], r8
    add     [rbp - PO_SUM + 8], r9
    add     [rbp - PO_SUM + 16], r10

    ACC_LOAD 3
    POLY_MULMOD PW_R
    add     r8, [rbp - PO_SUM]
    add     r9, [rbp - PO_SUM + 8]
    add     r10, [rbp - PO_SUM + 16]

    ; Four reduced values summed: carry once, so the serial tail starts from
    ; limbs the multiply can take.
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

; --- what is left: whole blocks, then a partial one -------------------------
.block_loop:
    cmp     rdi, 16
    jb      .tail
    POLY_ABSORB rsi, 0, 1
    POLY_MULMOD PW_R
    add     rsi, 16
    sub     rdi, 16
    jmp     .block_loop

.tail:
    test    rdi, rdi
    jz      .finish

    xor     rax, rax
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
    POLY_ABSORB rsi, 0, 0
    POLY_MULMOD PW_R

; --- h mod 2^130-5, then + pad ----------------------------------------------
.finish:
    mov     rcx, MASK44
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

    ; g = h + 5, kept only if it carried out of 2^130. Chosen without a branch
    ; on the data.
    mov     r12, r8
    add     r12, 5
    mov     rax, r12
    shr     rax, 44
    and     r12, rcx
    mov     r13, r9
    add     r13, rax
    mov     rax, r13
    shr     rax, 44
    and     r13, rcx
    mov     r14, r10
    add     r14, rax
    mov     rax, 1
    shl     rax, 42
    sub     r14, rax

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

    ; Nothing of r, its powers, the pad or the accumulators is left behind:
    ; from PW_R4 up through the accumulators is one contiguous run.
    xor     rax, rax
    mov     rcx, 32                     ; 320 - 64 bytes, in qwords
    lea     r11, [rbp - ACC]
.wipe:
    mov     [r11], rax
    add     r11, 8
    dec     rcx
    jnz     .wipe

    mov     [rbp - PO_PAD0], rax
    mov     [rbp - PO_PAD1], rax
    mov     [rbp - PO_TAIL], rax
    mov     [rbp - PO_TAIL + 8], rax
    mov     [rbp - PO_SUM], rax
    mov     [rbp - PO_SUM + 8], rax
    mov     [rbp - PO_SUM + 16], rax

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
