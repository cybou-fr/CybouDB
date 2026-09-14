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
;  Poly1305 is a Horner evaluation - h = (((h + m1)r + m2)r + m3)r ... - so
;  every block waits for the one before it and the machine's multipliers idle.
;  Four accumulators, each advancing by r^4 and combined at the end with r^4,
;  r^3, r^2 and r, give four independent chains: 3.6 GB/s against 2.2.
;
;  init / update / finish rather than one shot, because the AEAD authenticates
;  three pieces that are not adjacent in memory - the associated data, the
;  ciphertext, and the two lengths. cyboudb_poly1305 is still here and is now a
;  wrapper over the three, so there is one implementation rather than two.
;
;  The powers and the accumulators live in the caller's context between calls
;  and are copied into this frame for the duration of one, because the macros
;  address them relative to rbp and the context pointer would otherwise need a
;  register that POLY_MULMOD wants. 256 bytes copied per call, against the
;  hundreds of multiplies a page costs.
; =============================================================================

%include "cyboudb.inc"
%include "crypto.inc"

BITS 64
default rel

global cyboudb_poly1305
global cyboudb_poly1305_init
global cyboudb_poly1305_update
global cyboudb_poly1305_finish

section .text

; --- frame, from rbp --------------------------------------------------------
;  Written as a map rather than a list, because the slots are dense and several
;  of them are longer than a qword. PO_KEY was first put at 168, which is
;  inside the forty bytes PW_R occupies - so storing r destroyed the saved key
;  pointer, and the whole thing faulted on the next instruction that used it.
;
;      -48   PO_PAD0   8      -200  PW_R     40   [-200, -161]
;      -56   PO_PAD1   8      -240  PW_R2    40   [-240, -201]
;      -64   PO_MAC    8      -280  PW_R3    40   [-280, -241]
;      -80   PO_TAIL  16      -320  PW_R4    40   [-320, -281]
;     -120   PO_SUM   24      -416  ACC      96   [-416, -321]
;     -136   PO_KEY    8      -448  PO_RBX    8
;     -144   PO_CTX    8       ...  the other six saves, to -496
;     -152   PO_MSG    8
;     -160   PO_LEN    8      free: [-96, -81] and [-128, -121]
%define PO_PAD0  48
%define PO_PAD1  56
%define PO_MAC   64
%define PO_TAIL  80                     ; 16 bytes: the padded final block
%define PO_SUM   120                    ; the combined accumulator, 3 limbs
%define PO_KEY   136                    ; the key, which ARG2 does not outlive
%define PO_CTX   144                    ; the caller's context
%define PO_MSG   152
%define PO_LEN   160
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

%macro ACC_LOAD 1
    mov     r8, [rbp - ACC + %1 * 24]
    mov     r9, [rbp - ACC + %1 * 24 + 8]
    mov     r10, [rbp - ACC + %1 * 24 + 16]
%endmacro

%macro ACC_STORE 1
    mov     [rbp - ACC + %1 * 24], r8
    mov     [rbp - ACC + %1 * 24 + 8], r9
    mov     [rbp - ACC + %1 * 24 + 16], r10
%endmacro

; -----------------------------------------------------------------------------
;  SAVE_REGS / LOAD_REGS - the seven this file uses that belong to the caller.
; -----------------------------------------------------------------------------
%macro SAVE_REGS 0
    mov     [rbp - PO_RBX], rbx
    mov     [rbp - PO_RSI], rsi
    mov     [rbp - PO_RDI], rdi
    mov     [rbp - PO_R12], r12
    mov     [rbp - PO_R13], r13
    mov     [rbp - PO_R14], r14
    mov     [rbp - PO_R15], r15
%endmacro

%macro LOAD_REGS 0
    mov     rbx, [rbp - PO_RBX]
    mov     rsi, [rbp - PO_RSI]
    mov     rdi, [rbp - PO_RDI]
    mov     r12, [rbp - PO_R12]
    mov     r13, [rbp - PO_R13]
    mov     r14, [rbp - PO_R14]
    mov     r15, [rbp - PO_R15]
%endmacro

; -----------------------------------------------------------------------------
;  CTX_TO_FRAME / ACC_TO_CTX - the powers and accumulators, copied both ways.
;  r11 is the context pointer; rcx and rax are scratch.
; -----------------------------------------------------------------------------
%macro CTX_TO_FRAME 0
    mov     r11, [rbp - PO_CTX]
    lea     rdx, [rbp - PW_R4]          ; the powers are one run of 160 bytes
    mov     rcx, 20
%%powers:
    mov     rax, [r11 + PCTX_R4 - PCTX_R4]
    mov     [rdx], rax
    add     r11, 8
    add     rdx, 8
    dec     rcx
    jnz     %%powers

    mov     r11, [rbp - PO_CTX]
    lea     rdx, [rbp - ACC]
    mov     rcx, 12
%%accs:
    mov     rax, [r11 + PCTX_ACC]
    mov     [rdx], rax
    add     r11, 8
    add     rdx, 8
    dec     rcx
    jnz     %%accs
%endmacro

%macro ACC_TO_CTX 0
    mov     r11, [rbp - PO_CTX]
    lea     rdx, [rbp - ACC]
    mov     rcx, 12
%%accs:
    mov     rax, [rdx]
    mov     [r11 + PCTX_ACC], rax
    add     r11, 8
    add     rdx, 8
    dec     rcx
    jnz     %%accs
%endmacro

; =============================================================================
;  cyboudb_poly1305_init(ctx, key)
; =============================================================================
cyboudb_poly1305_init:
    FRAME_BEGIN PO_FRAME, 0
    SAVE_REGS

    mov     r11, ARG2                   ; key
    mov     rbx, ARG1                   ; ctx
    mov     [rbp - PO_CTX], rbx
    mov     [rbp - PO_KEY], r11         ; kept, because ARG2 does not survive

    mov     rax, [r11]
    mov     rdx, [r11 + 8]

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
    POLY_MULMOD PW_R                    ; r * r
    POWER_STORE PW_R2
    POLY_MULMOD PW_R                    ; r^2 * r
    POWER_STORE PW_R3
    POWER_LOAD PW_R2
    POLY_MULMOD PW_R2                   ; r^2 * r^2
    POWER_STORE PW_R4

    ; the powers, in the order the context keeps them
    mov     rbx, [rbp - PO_CTX]
    lea     rdx, [rbp - PW_R4]
    mov     rcx, 20
    xor     r11, r11
.copy_powers:
    mov     rax, [rdx]
    mov     [rbx + r11], rax
    add     rdx, 8
    add     r11, 8
    dec     rcx
    jnz     .copy_powers

    ; The pad, from the saved pointer rather than from ARG2: ARG2 is RDX under
    ; Win64, and RDX has held the key's second half since the clamping above.
    ; On System V, where ARG2 is RSI, reading it again would have worked - which
    ; is exactly the kind of bug that passes on one platform, and exactly what
    ; tests/abi_arg_lint.py is for. It found this before the Windows build ran.
    mov     r11, [rbp - PO_KEY]
    mov     rax, [r11 + 16]
    mov     [rbx + PCTX_PAD0], rax
    mov     rax, [r11 + 24]
    mov     [rbx + PCTX_PAD1], rax

    xor     rax, rax
    mov     rcx, 12
    lea     rdx, [rbx + PCTX_ACC]
.zero_acc:
    mov     [rdx], rax
    add     rdx, 8
    dec     rcx
    jnz     .zero_acc
    mov     [rbx + PCTX_LEFT], rax

    LOAD_REGS
    FRAME_END
    ret

; =============================================================================
;  cyboudb_poly1305_update(ctx, msg, len)
; =============================================================================
cyboudb_poly1305_update:
    FRAME_BEGIN PO_FRAME, 0
    SAVE_REGS

    mov     r10, ARG3                   ; len
    mov     r11, ARG2                   ; msg
    mov     rbx, ARG1                   ; ctx
    mov     [rbp - PO_CTX], rbx
    mov     rsi, r11
    mov     rdi, r10

    test    rdi, rdi
    jz      .update_done

    CTX_TO_FRAME

    ; --- anything left over from last time, filled up to a group ------------
    mov     rbx, [rbp - PO_CTX]
    mov     r11, [rbx + PCTX_LEFT]
    test    r11, r11
    jz      .groups

.fill:
    cmp     r11, 64
    jae     .buffer_full
    test    rdi, rdi
    jz      .store_left
    mov     al, [rsi]
    mov     [rbx + PCTX_BUF + r11], al
    inc     r11
    inc     rsi
    dec     rdi
    jmp     .fill

.buffer_full:
    lea     r11, [rbx + PCTX_BUF]
    mov     [rbp - PO_MSG], r11
    call    .absorb_group
    mov     rbx, [rbp - PO_CTX]
    xor     r11, r11
    mov     [rbx + PCTX_LEFT], r11

.groups:
    cmp     rdi, 64
    jb      .keep_rest
    mov     [rbp - PO_MSG], rsi
    call    .absorb_group
    add     rsi, 64
    sub     rdi, 64
    jmp     .groups

.keep_rest:
    mov     rbx, [rbp - PO_CTX]
    xor     r11, r11
.rest_copy:
    cmp     r11, rdi
    jae     .store_left
    mov     al, [rsi + r11]
    mov     [rbx + PCTX_BUF + r11], al
    inc     r11
    jmp     .rest_copy

.store_left:
    mov     rbx, [rbp - PO_CTX]
    mov     [rbx + PCTX_LEFT], r11
    ACC_TO_CTX

.update_done:
    LOAD_REGS
    FRAME_END
    ret

; --- one group of four blocks, from [rbp - PO_MSG] ---------------------------
;  acc = acc * r^4 + m, and not (acc + m) * r^4: the second gives every block
;  one factor of r^4 too many, and the RFC's own vector cannot see it because a
;  34-byte message never reaches this loop.
.absorb_group:
    mov     r11, [rbp - PO_MSG]
    mov     [rbp - PO_LEN], r11         ; keep it: the macros clobber r11

    ACC_LOAD 0
    POLY_MULMOD PW_R4
    mov     r11, [rbp - PO_LEN]
    POLY_ABSORB r11, 0, 1
    ACC_STORE 0

    ACC_LOAD 1
    POLY_MULMOD PW_R4
    mov     r11, [rbp - PO_LEN]
    POLY_ABSORB r11, 16, 1
    ACC_STORE 1

    ACC_LOAD 2
    POLY_MULMOD PW_R4
    mov     r11, [rbp - PO_LEN]
    POLY_ABSORB r11, 32, 1
    ACC_STORE 2

    ACC_LOAD 3
    POLY_MULMOD PW_R4
    mov     r11, [rbp - PO_LEN]
    POLY_ABSORB r11, 48, 1
    ACC_STORE 3
    ret

; =============================================================================
;  cyboudb_poly1305_finish(ctx, mac)
; =============================================================================
cyboudb_poly1305_finish:
    FRAME_BEGIN PO_FRAME, 0
    SAVE_REGS

    mov     r11, ARG2                   ; mac
    mov     rbx, ARG1                   ; ctx
    mov     [rbp - PO_MAC], r11
    mov     [rbp - PO_CTX], rbx

    CTX_TO_FRAME

    ; --- H = a0.r^4 + a1.r^3 + a2.r^2 + a3.r --------------------------------
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

    ; four reduced values summed: carry once before the tail uses them
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

    ; --- whatever never filled a group, serially ----------------------------
    mov     rbx, [rbp - PO_CTX]
    mov     rdi, [rbx + PCTX_LEFT]
    lea     rsi, [rbx + PCTX_BUF]

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
    jz      .reduce

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

.reduce:
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

    ; g = h + 5, kept only if it carried out of 2^130. No branch on the data.
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

    ; + pad, and back into two 64-bit words
    mov     rbx, [rbp - PO_CTX]
    mov     rcx, MASK44
    mov     rax, [rbx + PCTX_PAD0]
    mov     rdx, [rbx + PCTX_PAD1]

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

    ; Nothing of r, its powers, the pad or the accumulators is left behind,
    ; in the frame or in the caller's context.
    xor     rax, rax
    mov     rcx, 32
    lea     r11, [rbp - ACC]
.wipe_frame:
    mov     [r11], rax
    add     r11, 8
    dec     rcx
    jnz     .wipe_frame

    mov     [rbp - PO_SUM], rax
    mov     [rbp - PO_SUM + 8], rax
    mov     [rbp - PO_SUM + 16], rax
    mov     [rbp - PO_TAIL], rax
    mov     [rbp - PO_TAIL + 8], rax

    mov     r11, [rbp - PO_CTX]
    mov     rcx, CybouDB_POLY1305_CTX_SIZE / 8
.wipe_ctx:
    mov     [r11], rax
    add     r11, 8
    dec     rcx
    jnz     .wipe_ctx

    LOAD_REGS
    FRAME_END
    ret

; =============================================================================
;  cyboudb_poly1305(key, msg, len, mac) - the one-shot, over the three above
; =============================================================================
%define OS_CTX  (CybouDB_POLY1305_CTX_SIZE + 64)
%define OS_KEY  (OS_CTX + 8)
%define OS_MSG  (OS_CTX + 16)
%define OS_LEN  (OS_CTX + 24)
%define OS_MAC  (OS_CTX + 32)
%define OS_FRAME (OS_CTX + 48)

cyboudb_poly1305:
    FRAME_BEGIN OS_FRAME, 0

    mov     [rbp - OS_MAC], ARG4
    mov     r10, ARG3
    mov     r11, ARG2
    mov     rax, ARG1
    mov     [rbp - OS_LEN], r10
    mov     [rbp - OS_MSG], r11
    mov     [rbp - OS_KEY], rax

    lea     ARG1, [rbp - OS_CTX]
    mov     ARG2, rax
    call    cyboudb_poly1305_init

    lea     ARG1, [rbp - OS_CTX]
    mov     ARG2, [rbp - OS_MSG]
    mov     ARG3, [rbp - OS_LEN]
    call    cyboudb_poly1305_update

    lea     ARG1, [rbp - OS_CTX]
    mov     ARG2, [rbp - OS_MAC]
    call    cyboudb_poly1305_finish

    FRAME_END
    ret

%ifdef CybouDB_LINUX
section .note.GNU-stack noalloc noexec nowrite progbits
%endif
