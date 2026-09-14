; Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
; SPDX-License-Identifier: Apache-2.0
; =============================================================================
;  crypto/keccak.asm - the permutation the key hierarchy and ML-KEM both need
; =============================================================================
;  FIPS 202. Keccak-f[1600] and SHAKE256.
;
;  Why this and not HKDF-SHA256, which would be the boring choice: SHAKE256
;  needs one new primitive where HKDF needs two - SHA-256 and the HMAC
;  construction - and ML-KEM and ML-DSA are built on this same permutation
;  (FIPS 203 and 204 use SHA3-256, SHA3-512, SHAKE128 and SHAKE256 throughout).
;  Steps 5 and 3.5 need Keccak whatever step 4 chooses. See
;  docs/KEY_HIERARCHY.md, Decision 1.
;
;  The state is twenty-five 64-bit lanes and x86-64 has sixteen registers, so
;  the state lives in the caller's 200 bytes and rho/pi write through a scratch
;  copy in this frame. Theta's five column parities are the only thing held in
;  registers across a step.
;
;  The twenty-five moves of rho and pi were generated from the definitions -
;  lane (x, y) rotates by r[x][y] and lands at (y, 2x + 3y mod 5), with
;  A[x][y] at index x + 5y - rather than transcribed by hand, because a single
;  wrong offset in that table produces code that still looks like Keccak. The
;  vectors are what confirm it: SHAKE256 of the empty message, and of one byte.
; =============================================================================

%include "cyboudb.inc"

BITS 64
default rel

global cyboudb_keccak_f1600
global cyboudb_shake256

section .rodata
align 16
keccak_rc:
    dq 0x0000000000000001, 0x0000000000008082
    dq 0x800000000000808A, 0x8000000080008000
    dq 0x000000000000808B, 0x0000000080000001
    dq 0x8000000080008081, 0x8000000000008009
    dq 0x000000000000008A, 0x0000000000000088
    dq 0x0000000080008009, 0x000000008000000A
    dq 0x000000008000808B, 0x800000000000008B
    dq 0x8000000000008089, 0x8000000000008003
    dq 0x8000000000008002, 0x8000000000000080
    dq 0x000000000000800A, 0x800000008000000A
    dq 0x8000000080008081, 0x8000000000008080
    dq 0x0000000080000001, 0x8000000080008008

; -----------------------------------------------------------------------------
;  THETA_COLUMN <x>, <C[x-1]>, <C[x+1]> - D[x] = C[x-1] ^ rol(C[x+1], 1), xored
;  into all five lanes of column x.
; -----------------------------------------------------------------------------
%macro THETA_COLUMN 3
    mov     rax, %3
    rol     rax, 1
    xor     rax, %2
    xor     [rbx + %1 * 8], rax
    xor     [rbx + %1 * 8 + 40], rax
    xor     [rbx + %1 * 8 + 80], rax
    xor     [rbx + %1 * 8 + 120], rax
    xor     [rbx + %1 * 8 + 160], rax
%endmacro

section .text

; --- frame ------------------------------------------------------------------
%define KC_B      200                   ; the scratch state rho and pi write
%define KC_RBX    208
%define KC_ROUND  216
%define KC_R12    224                   ; theta's fifth column parity
%define KC_FRAME  240

; =============================================================================
;  cyboudb_keccak_f1600(state)
;
;  ARG1  uint8_t state[200]   - twenty-five little-endian lanes, in place
; =============================================================================
cyboudb_keccak_f1600:
    FRAME_BEGIN KC_FRAME, 0
    mov     [rbp - KC_RBX], rbx
    mov     [rbp - KC_R12], r12         ; theta needs five registers, and the
    mov     rbx, ARG1                   ; fifth is the caller's
    mov     qword [rbp - KC_ROUND], 0

.round:
    ; --- theta ---------------------------------------------------------------
    ; C[x] = A[x,0] ^ A[x,1] ^ A[x,2] ^ A[x,3] ^ A[x,4]
    mov     r8, [rbx + 0]
    xor     r8, [rbx + 40]
    xor     r8, [rbx + 80]
    xor     r8, [rbx + 120]
    xor     r8, [rbx + 160]
    mov     r9, [rbx + 8]
    xor     r9, [rbx + 48]
    xor     r9, [rbx + 88]
    xor     r9, [rbx + 128]
    xor     r9, [rbx + 168]
    mov     r10, [rbx + 16]
    xor     r10, [rbx + 56]
    xor     r10, [rbx + 96]
    xor     r10, [rbx + 136]
    xor     r10, [rbx + 176]
    mov     r11, [rbx + 24]
    xor     r11, [rbx + 64]
    xor     r11, [rbx + 104]
    xor     r11, [rbx + 144]
    xor     r11, [rbx + 184]
    mov     r12, [rbx + 32]
    xor     r12, [rbx + 72]
    xor     r12, [rbx + 112]
    xor     r12, [rbx + 152]
    xor     r12, [rbx + 192]

    ; D[x] = C[x-1] ^ rol(C[x+1], 1), xored into the whole column
    THETA_COLUMN 0, r12, r9
    THETA_COLUMN 1, r8, r10
    THETA_COLUMN 2, r9, r11
    THETA_COLUMN 3, r10, r12
    THETA_COLUMN 4, r11, r8

    ; --- rho and pi ----------------------------------------------------------
    mov     rax, [rbx + 0]
    mov     [rbp - KC_B + 0], rax      ; A[0,0] -> B[0,0], no rotation
    mov     rax, [rbx + 8]
    rol     rax, 1                  ; A[1,0] -> B[0,2]
    mov     [rbp - KC_B + 80], rax
    mov     rax, [rbx + 16]
    rol     rax, 62                 ; A[2,0] -> B[0,4]
    mov     [rbp - KC_B + 160], rax
    mov     rax, [rbx + 24]
    rol     rax, 28                 ; A[3,0] -> B[0,1]
    mov     [rbp - KC_B + 40], rax
    mov     rax, [rbx + 32]
    rol     rax, 27                 ; A[4,0] -> B[0,3]
    mov     [rbp - KC_B + 120], rax
    mov     rax, [rbx + 40]
    rol     rax, 36                 ; A[0,1] -> B[1,3]
    mov     [rbp - KC_B + 128], rax
    mov     rax, [rbx + 48]
    rol     rax, 44                 ; A[1,1] -> B[1,0]
    mov     [rbp - KC_B + 8], rax
    mov     rax, [rbx + 56]
    rol     rax, 6                  ; A[2,1] -> B[1,2]
    mov     [rbp - KC_B + 88], rax
    mov     rax, [rbx + 64]
    rol     rax, 55                 ; A[3,1] -> B[1,4]
    mov     [rbp - KC_B + 168], rax
    mov     rax, [rbx + 72]
    rol     rax, 20                 ; A[4,1] -> B[1,1]
    mov     [rbp - KC_B + 48], rax
    mov     rax, [rbx + 80]
    rol     rax, 3                  ; A[0,2] -> B[2,1]
    mov     [rbp - KC_B + 56], rax
    mov     rax, [rbx + 88]
    rol     rax, 10                 ; A[1,2] -> B[2,3]
    mov     [rbp - KC_B + 136], rax
    mov     rax, [rbx + 96]
    rol     rax, 43                 ; A[2,2] -> B[2,0]
    mov     [rbp - KC_B + 16], rax
    mov     rax, [rbx + 104]
    rol     rax, 25                 ; A[3,2] -> B[2,2]
    mov     [rbp - KC_B + 96], rax
    mov     rax, [rbx + 112]
    rol     rax, 39                 ; A[4,2] -> B[2,4]
    mov     [rbp - KC_B + 176], rax
    mov     rax, [rbx + 120]
    rol     rax, 41                 ; A[0,3] -> B[3,4]
    mov     [rbp - KC_B + 184], rax
    mov     rax, [rbx + 128]
    rol     rax, 45                 ; A[1,3] -> B[3,1]
    mov     [rbp - KC_B + 64], rax
    mov     rax, [rbx + 136]
    rol     rax, 15                 ; A[2,3] -> B[3,3]
    mov     [rbp - KC_B + 144], rax
    mov     rax, [rbx + 144]
    rol     rax, 21                 ; A[3,3] -> B[3,0]
    mov     [rbp - KC_B + 24], rax
    mov     rax, [rbx + 152]
    rol     rax, 8                  ; A[4,3] -> B[3,2]
    mov     [rbp - KC_B + 104], rax
    mov     rax, [rbx + 160]
    rol     rax, 18                 ; A[0,4] -> B[4,2]
    mov     [rbp - KC_B + 112], rax
    mov     rax, [rbx + 168]
    rol     rax, 2                  ; A[1,4] -> B[4,4]
    mov     [rbp - KC_B + 192], rax
    mov     rax, [rbx + 176]
    rol     rax, 61                 ; A[2,4] -> B[4,1]
    mov     [rbp - KC_B + 72], rax
    mov     rax, [rbx + 184]
    rol     rax, 56                 ; A[3,4] -> B[4,3]
    mov     [rbp - KC_B + 152], rax
    mov     rax, [rbx + 192]
    rol     rax, 14                 ; A[4,4] -> B[4,0]
    mov     [rbp - KC_B + 32], rax

    ; --- chi -----------------------------------------------------------------
; row 0
    mov     rax, [rbp - KC_B + 8]
    not     rax
    and     rax, [rbp - KC_B + 16]
    xor     rax, [rbp - KC_B + 0]
    mov     [rbx + 0], rax
    mov     rax, [rbp - KC_B + 16]
    not     rax
    and     rax, [rbp - KC_B + 24]
    xor     rax, [rbp - KC_B + 8]
    mov     [rbx + 8], rax
    mov     rax, [rbp - KC_B + 24]
    not     rax
    and     rax, [rbp - KC_B + 32]
    xor     rax, [rbp - KC_B + 16]
    mov     [rbx + 16], rax
    mov     rax, [rbp - KC_B + 32]
    not     rax
    and     rax, [rbp - KC_B + 0]
    xor     rax, [rbp - KC_B + 24]
    mov     [rbx + 24], rax
    mov     rax, [rbp - KC_B + 0]
    not     rax
    and     rax, [rbp - KC_B + 8]
    xor     rax, [rbp - KC_B + 32]
    mov     [rbx + 32], rax
    ; row 1
    mov     rax, [rbp - KC_B + 48]
    not     rax
    and     rax, [rbp - KC_B + 56]
    xor     rax, [rbp - KC_B + 40]
    mov     [rbx + 40], rax
    mov     rax, [rbp - KC_B + 56]
    not     rax
    and     rax, [rbp - KC_B + 64]
    xor     rax, [rbp - KC_B + 48]
    mov     [rbx + 48], rax
    mov     rax, [rbp - KC_B + 64]
    not     rax
    and     rax, [rbp - KC_B + 72]
    xor     rax, [rbp - KC_B + 56]
    mov     [rbx + 56], rax
    mov     rax, [rbp - KC_B + 72]
    not     rax
    and     rax, [rbp - KC_B + 40]
    xor     rax, [rbp - KC_B + 64]
    mov     [rbx + 64], rax
    mov     rax, [rbp - KC_B + 40]
    not     rax
    and     rax, [rbp - KC_B + 48]
    xor     rax, [rbp - KC_B + 72]
    mov     [rbx + 72], rax
    ; row 2
    mov     rax, [rbp - KC_B + 88]
    not     rax
    and     rax, [rbp - KC_B + 96]
    xor     rax, [rbp - KC_B + 80]
    mov     [rbx + 80], rax
    mov     rax, [rbp - KC_B + 96]
    not     rax
    and     rax, [rbp - KC_B + 104]
    xor     rax, [rbp - KC_B + 88]
    mov     [rbx + 88], rax
    mov     rax, [rbp - KC_B + 104]
    not     rax
    and     rax, [rbp - KC_B + 112]
    xor     rax, [rbp - KC_B + 96]
    mov     [rbx + 96], rax
    mov     rax, [rbp - KC_B + 112]
    not     rax
    and     rax, [rbp - KC_B + 80]
    xor     rax, [rbp - KC_B + 104]
    mov     [rbx + 104], rax
    mov     rax, [rbp - KC_B + 80]
    not     rax
    and     rax, [rbp - KC_B + 88]
    xor     rax, [rbp - KC_B + 112]
    mov     [rbx + 112], rax
    ; row 3
    mov     rax, [rbp - KC_B + 128]
    not     rax
    and     rax, [rbp - KC_B + 136]
    xor     rax, [rbp - KC_B + 120]
    mov     [rbx + 120], rax
    mov     rax, [rbp - KC_B + 136]
    not     rax
    and     rax, [rbp - KC_B + 144]
    xor     rax, [rbp - KC_B + 128]
    mov     [rbx + 128], rax
    mov     rax, [rbp - KC_B + 144]
    not     rax
    and     rax, [rbp - KC_B + 152]
    xor     rax, [rbp - KC_B + 136]
    mov     [rbx + 136], rax
    mov     rax, [rbp - KC_B + 152]
    not     rax
    and     rax, [rbp - KC_B + 120]
    xor     rax, [rbp - KC_B + 144]
    mov     [rbx + 144], rax
    mov     rax, [rbp - KC_B + 120]
    not     rax
    and     rax, [rbp - KC_B + 128]
    xor     rax, [rbp - KC_B + 152]
    mov     [rbx + 152], rax
    ; row 4
    mov     rax, [rbp - KC_B + 168]
    not     rax
    and     rax, [rbp - KC_B + 176]
    xor     rax, [rbp - KC_B + 160]
    mov     [rbx + 160], rax
    mov     rax, [rbp - KC_B + 176]
    not     rax
    and     rax, [rbp - KC_B + 184]
    xor     rax, [rbp - KC_B + 168]
    mov     [rbx + 168], rax
    mov     rax, [rbp - KC_B + 184]
    not     rax
    and     rax, [rbp - KC_B + 192]
    xor     rax, [rbp - KC_B + 176]
    mov     [rbx + 176], rax
    mov     rax, [rbp - KC_B + 192]
    not     rax
    and     rax, [rbp - KC_B + 160]
    xor     rax, [rbp - KC_B + 184]
    mov     [rbx + 184], rax
    mov     rax, [rbp - KC_B + 160]
    not     rax
    and     rax, [rbp - KC_B + 168]
    xor     rax, [rbp - KC_B + 192]
    mov     [rbx + 192], rax
    ; --- iota ----------------------------------------------------------------
    mov     rax, [rbp - KC_ROUND]
    lea     rcx, [keccak_rc]
    mov     rax, [rcx + rax * 8]
    xor     [rbx], rax

    inc     qword [rbp - KC_ROUND]
    cmp     qword [rbp - KC_ROUND], 24
    jb      .round

    ; The scratch copy holds the state one step short of the output, which is
    ; as much of a secret as the state itself.
    xor     rax, rax
    mov     rcx, 25
    lea     rdx, [rbp - KC_B]
.wipe:
    mov     [rdx], rax
    add     rdx, 8
    dec     rcx
    jnz     .wipe

    mov     rbx, [rbp - KC_RBX]
    mov     r12, [rbp - KC_R12]
    FRAME_END
    ret

; =============================================================================
;  cyboudb_shake256(out, out_len, in, in_len)
;
;  ARG1  uint8_t       *out
;  ARG2  uint64_t       out_len
;  ARG3  const uint8_t *in
;  ARG4  uint64_t       in_len
;
;  The sponge at rate 136 bytes, padded with 0x1F and a final 0x80 - the
;  domain separation that makes SHAKE256 a different function from SHA3-256
;  over the same permutation.
; =============================================================================
%define SH_STATE   200
%define SH_OUT     208
%define SH_OUTLEN  216
%define SH_IN      224
%define SH_INLEN   232
%define SH_RBX     240
%define SH_FRAME   256
%define SHAKE256_RATE 136

cyboudb_shake256:
    FRAME_BEGIN SH_FRAME, 0
    mov     [rbp - SH_RBX], rbx

    mov     r10, ARG4
    mov     r11, ARG3
    mov     rax, ARG2
    mov     rcx, ARG1
    mov     [rbp - SH_INLEN], r10
    mov     [rbp - SH_IN], r11
    mov     [rbp - SH_OUTLEN], rax
    mov     [rbp - SH_OUT], rcx

    ; an empty state
    xor     rax, rax
    mov     rcx, 25
    lea     rdx, [rbp - SH_STATE]
.zero:
    mov     [rdx], rax
    add     rdx, 8
    dec     rcx
    jnz     .zero

    ; --- absorb --------------------------------------------------------------
.absorb:
    cmp     qword [rbp - SH_INLEN], SHAKE256_RATE
    jb      .absorb_tail

    mov     r11, [rbp - SH_IN]
    lea     rdx, [rbp - SH_STATE]
    mov     rcx, SHAKE256_RATE / 8
.absorb_block:
    mov     rax, [r11]
    xor     [rdx], rax
    add     r11, 8
    add     rdx, 8
    dec     rcx
    jnz     .absorb_block

    add     qword [rbp - SH_IN], SHAKE256_RATE
    sub     qword [rbp - SH_INLEN], SHAKE256_RATE

    lea     ARG1, [rbp - SH_STATE]
    call    cyboudb_keccak_f1600
    jmp     .absorb

.absorb_tail:
    ; what is left, byte at a time, then the padding
    mov     r11, [rbp - SH_IN]
    mov     r10, [rbp - SH_INLEN]
    xor     rcx, rcx
.tail_byte:
    cmp     rcx, r10
    jae     .pad
    mov     al, [r11 + rcx]
    lea     rdx, [rbp - SH_STATE]
    xor     [rdx + rcx], al
    inc     rcx
    jmp     .tail_byte

.pad:
    lea     rdx, [rbp - SH_STATE]
    mov     al, 0x1f                    ; SHAKE's domain separation, then pad10*1
    xor     [rdx + rcx], al
    mov     al, 0x80
    xor     [rdx + SHAKE256_RATE - 1], al

    lea     ARG1, [rbp - SH_STATE]
    call    cyboudb_keccak_f1600

    ; --- squeeze -------------------------------------------------------------
.squeeze:
    cmp     qword [rbp - SH_OUTLEN], 0
    je      .done

    mov     rax, [rbp - SH_OUTLEN]
    mov     rcx, SHAKE256_RATE
    cmp     rax, rcx
    cmovae  rax, rcx                    ; this pass gives at most a rate
    mov     r10, rax

    mov     r11, [rbp - SH_OUT]
    lea     rdx, [rbp - SH_STATE]
    xor     rcx, rcx
.squeeze_byte:
    cmp     rcx, r10
    jae     .squeezed
    mov     al, [rdx + rcx]
    mov     [r11 + rcx], al
    inc     rcx
    jmp     .squeeze_byte

.squeezed:
    add     [rbp - SH_OUT], r10
    sub     [rbp - SH_OUTLEN], r10
    cmp     qword [rbp - SH_OUTLEN], 0
    je      .done
    lea     ARG1, [rbp - SH_STATE]
    call    cyboudb_keccak_f1600
    jmp     .squeeze

.done:
    ; the state is the secret here: whatever it still holds would give the
    ; rest of the stream to anyone who read this frame afterwards
    xor     rax, rax
    mov     rcx, 25
    lea     rdx, [rbp - SH_STATE]
.wipe_state:
    mov     [rdx], rax
    add     rdx, 8
    dec     rcx
    jnz     .wipe_state

    mov     rbx, [rbp - SH_RBX]
    FRAME_END
    ret

%ifdef CybouDB_LINUX
section .note.GNU-stack noalloc noexec nowrite progbits
%endif
