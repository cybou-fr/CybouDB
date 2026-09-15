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
%include "crypto.inc"

BITS 64
default rel

global cyboudb_keccak_f1600
global cyboudb_shake256
global cyboudb_shake256_init
global cyboudb_shake256_update
global cyboudb_shake256_final
global cyboudb_shake128
global cyboudb_shake128_init
global cyboudb_sha3_256
global cyboudb_sha3_512
global cyboudb_sponge_init
global cyboudb_sponge_absorb
global cyboudb_sponge_finish
global cyboudb_sponge_squeeze
global cyboudb_sponge_wipe
global cyboudb_sponge_ctx_size

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
; =============================================================================
;  The sponge, in four parts
; =============================================================================
;  One permutation, four functions over it, and the rate and the padding byte
;  held in the context rather than compiled in. FIPS 202 is a family and
;  ML-KEM uses four members of it at once - SHA3-256 as H, SHA3-512 as G,
;  SHAKE256 as J and the PRF, SHAKE128 as the XOF that samples the matrix -
;  so a sponge that knew only one rate would be copied four times, and the
;  fourth copy would be the one with the wrong padding byte.
;
;  Squeezing is incremental and separate from finishing, because the XOF is
;  read in pieces: sampling a polynomial pulls three bytes at a time and stops
;  when it has enough, which is not a length anyone knows in advance.
;
;  The absorb is byte at a time. Deliberate: 24 rounds of permutation per
;  rate dominates by a wide margin, so a qword fast path is an optimisation to
;  make after measuring rather than before.
; =============================================================================

; --- init ---------------------------------------------------------------------
;  cyboudb_sponge_init(ctx, rate, pad)
;
;  ARG1  uint8_t *ctx      CybouDB_SHCTX_SIZE bytes
;  ARG2  uint64_t rate     136 for SHA3-256 and SHAKE256, 72 for SHA3-512,
;                          168 for SHAKE128
;  ARG3  uint64_t pad      0x06 for SHA-3, 0x1f for SHAKE
; -----------------------------------------------------------------------------
cyboudb_sponge_init:
    mov     r10, ARG1
    mov     r11, ARG2
    mov     rdx, ARG3
    xor     rax, rax
    xor     rcx, rcx
.zero:
    mov     [r10 + rcx], rax
    add     rcx, 8
    cmp     rcx, CybouDB_SHCTX_SIZE
    jb      .zero
    mov     [r10 + SHCTX_RATE], r11
    mov     [r10 + SHCTX_PAD], rdx
    ret

; --- absorb -------------------------------------------------------------------
;  cyboudb_sponge_absorb(ctx, in, in_len)
;
;  Absorbing in any number of pieces must give what absorbing the whole thing
;  at once gives; the test splits a message at every boundary and demands one
;  digest.
; -----------------------------------------------------------------------------
cyboudb_sponge_absorb:
    FRAME_BEGIN 48, 0
    mov     [rbp - 8], rbx
    mov     [rbp - 16], r12
    mov     [rbp - 24], r13

    mov     rbx, ARG1                   ; ctx
    mov     r12, ARG2                   ; in
    mov     r13, ARG3                   ; remaining
    mov     rdx, [rbx + SHCTX_BUFLEN]

.byte:
    test    r13, r13
    jz      .done
    mov     al, [r12]
    xor     [rbx + SHCTX_STATE + rdx], al
    inc     r12
    dec     r13
    inc     rdx
    cmp     rdx, [rbx + SHCTX_RATE]
    jb      .byte

    mov     qword [rbx + SHCTX_BUFLEN], 0
    lea     ARG1, [rbx + SHCTX_STATE]
    call    cyboudb_keccak_f1600
    xor     rdx, rdx
    jmp     .byte

.done:
    mov     [rbx + SHCTX_BUFLEN], rdx
    mov     rbx, [rbp - 8]
    mov     r12, [rbp - 16]
    mov     r13, [rbp - 24]
    FRAME_END
    ret

; --- finish -------------------------------------------------------------------
;  cyboudb_sponge_finish(ctx)
;
;  Pads and permutes once. After this the context is a source of output and
;  not a sink for input; absorbing again would be a caller's bug and is not
;  defended against, because there is no correct thing to do about it.
; -----------------------------------------------------------------------------
cyboudb_sponge_finish:
    FRAME_BEGIN 32, 0
    mov     [rbp - 8], rbx
    mov     rbx, ARG1

    mov     rdx, [rbx + SHCTX_BUFLEN]
    mov     rax, [rbx + SHCTX_PAD]
    xor     [rbx + SHCTX_STATE + rdx], al
    mov     rcx, [rbx + SHCTX_RATE]
    mov     al, 0x80                    ; the other end of pad10*1
    xor     [rbx + SHCTX_STATE + rcx - 1], al

    lea     ARG1, [rbx + SHCTX_STATE]
    call    cyboudb_keccak_f1600

    mov     qword [rbx + SHCTX_SQPOS], 0
    mov     rbx, [rbp - 8]
    FRAME_END
    ret

; --- squeeze ------------------------------------------------------------------
;  cyboudb_sponge_squeeze(ctx, out, out_len)
;
;  Callable any number of times: the stream continues where the last call left
;  it, which is what the matrix sampler needs and what a caller asking for one
;  digest never notices.
; -----------------------------------------------------------------------------
cyboudb_sponge_squeeze:
    FRAME_BEGIN 48, 0
    mov     [rbp - 8], rbx
    mov     [rbp - 16], r12
    mov     [rbp - 24], r13

    mov     rbx, ARG1                   ; ctx
    mov     r12, ARG2                   ; out
    mov     r13, ARG3                   ; remaining

.block:
    test    r13, r13
    jz      .done
    mov     rdx, [rbx + SHCTX_SQPOS]
    cmp     rdx, [rbx + SHCTX_RATE]
    jb      .have
    lea     ARG1, [rbx + SHCTX_STATE]
    call    cyboudb_keccak_f1600
    mov     qword [rbx + SHCTX_SQPOS], 0
    xor     rdx, rdx
.have:
    mov     al, [rbx + SHCTX_STATE + rdx]
    mov     [r12], al
    inc     r12
    dec     r13
    inc     rdx
    mov     [rbx + SHCTX_SQPOS], rdx
    jmp     .block

.done:
    mov     rbx, [rbp - 8]
    mov     r12, [rbp - 16]
    mov     r13, [rbp - 24]
    FRAME_END
    ret

; --- how big the context is ---------------------------------------------------
;  cyboudb_sponge_ctx_size() -> size in bytes
;
;  A caller that allocates the context has to know this, and a caller that
;  knows it as a number of its own eventually knows the wrong number: growing
;  the context by three fields turned a correct test into a stack smash. So
;  the size is askable, and the tests assert their constant against it.
; -----------------------------------------------------------------------------
cyboudb_sponge_ctx_size:
    mov     eax, CybouDB_SHCTX_SIZE
    ret

; --- wipe ---------------------------------------------------------------------
;  cyboudb_sponge_wipe(ctx)
;
;  The state is the secret: what it still holds would give the rest of the
;  stream to anyone who read the context afterwards. Separate from squeezing
;  because an XOF is read in pieces and cannot wipe after the first one.
; -----------------------------------------------------------------------------
cyboudb_sponge_wipe:
    mov     r10, ARG1
    xor     rax, rax
    xor     rcx, rcx
.word:
    mov     [r10 + rcx], rax
    add     rcx, 8
    cmp     rcx, CybouDB_SHCTX_SIZE
    jb      .word
    ret

; =============================================================================
;  The named members of the family
; =============================================================================
;  cyboudb_shake256_init / _update / _final keep the names the key hierarchy
;  and the seal tree already use; the rest are what ML-KEM asks for by letter.
; =============================================================================
cyboudb_shake256_init:
    mov     ARG3, SHAKE_PAD
    mov     ARG2, SHAKE256_RATE
    jmp     cyboudb_sponge_init

cyboudb_shake128_init:
    mov     ARG3, SHAKE_PAD
    mov     ARG2, SHAKE128_RATE
    jmp     cyboudb_sponge_init

cyboudb_shake256_update:
    jmp     cyboudb_sponge_absorb

; cyboudb_shake256_final(ctx, out, out_len) - one digest, and done with it.
cyboudb_shake256_final:
    FRAME_BEGIN 48, 0
    mov     [rbp - 8], rbx
    mov     [rbp - 16], r12
    mov     [rbp - 24], r13

    mov     rbx, ARG1
    mov     r12, ARG2
    mov     r13, ARG3

    mov     ARG1, rbx
    call    cyboudb_sponge_finish
    mov     ARG1, rbx
    mov     ARG2, r12
    mov     ARG3, r13
    call    cyboudb_sponge_squeeze
    mov     ARG1, rbx
    call    cyboudb_sponge_wipe

    mov     rbx, [rbp - 8]
    mov     r12, [rbp - 16]
    mov     r13, [rbp - 24]
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  sponge_oneshot(rbx = out, r12 = out_len, r13 = in, r14 = in_len,
;                 r15 = rate, r10 = pad)
;  Internal: the whole of a one-shot hash, over a context in this frame.
; -----------------------------------------------------------------------------
sponge_oneshot:
    push    rbp
    mov     rbp, rsp
    sub     rsp, CybouDB_SHCTX_SIZE + 32 + SHADOW_SPACE
    lea     r11, [rsp + SHADOW_SPACE]
    mov     [rsp + SHADOW_SPACE + CybouDB_SHCTX_SIZE], r11

    mov     ARG1, r11
    mov     ARG2, r15
    mov     ARG3, r10
    call    cyboudb_sponge_init

    mov     ARG1, [rsp + SHADOW_SPACE + CybouDB_SHCTX_SIZE]
    mov     ARG2, r13
    mov     ARG3, r14
    call    cyboudb_sponge_absorb

    mov     ARG1, [rsp + SHADOW_SPACE + CybouDB_SHCTX_SIZE]
    call    cyboudb_sponge_finish

    mov     ARG1, [rsp + SHADOW_SPACE + CybouDB_SHCTX_SIZE]
    mov     ARG2, rbx
    mov     ARG3, r12
    call    cyboudb_sponge_squeeze

    mov     ARG1, [rsp + SHADOW_SPACE + CybouDB_SHCTX_SIZE]
    call    cyboudb_sponge_wipe

    mov     rsp, rbp
    pop     rbp
    ret

; -----------------------------------------------------------------------------
;  The one-shot entry points. SHAKE256 keeps the signature it has had since
;  the KDF was written; the SHA-3 pair have fixed output lengths, so saying
;  the length at the call site would only be a chance to say it wrong.
; -----------------------------------------------------------------------------
; cyboudb_shake256(out, out_len, in, in_len)
cyboudb_shake256:
    FRAME_BEGIN 64, 0
    mov     [rbp - 8], rbx
    mov     [rbp - 16], r12
    mov     [rbp - 24], r13
    mov     [rbp - 32], r14
    mov     [rbp - 40], r15

    mov     rbx, ARG1
    mov     r12, ARG2
    mov     r13, ARG3
    mov     r14, ARG4
    mov     r15, SHAKE256_RATE
    mov     r10, SHAKE_PAD
    call    sponge_oneshot

    mov     rbx, [rbp - 8]
    mov     r12, [rbp - 16]
    mov     r13, [rbp - 24]
    mov     r14, [rbp - 32]
    mov     r15, [rbp - 40]
    FRAME_END
    ret

; cyboudb_shake128(out, out_len, in, in_len)
cyboudb_shake128:
    FRAME_BEGIN 64, 0
    mov     [rbp - 8], rbx
    mov     [rbp - 16], r12
    mov     [rbp - 24], r13
    mov     [rbp - 32], r14
    mov     [rbp - 40], r15

    mov     rbx, ARG1
    mov     r12, ARG2
    mov     r13, ARG3
    mov     r14, ARG4
    mov     r15, SHAKE128_RATE
    mov     r10, SHAKE_PAD
    call    sponge_oneshot

    mov     rbx, [rbp - 8]
    mov     r12, [rbp - 16]
    mov     r13, [rbp - 24]
    mov     r14, [rbp - 32]
    mov     r15, [rbp - 40]
    FRAME_END
    ret

; cyboudb_sha3_256(out32, in, in_len)
cyboudb_sha3_256:
    FRAME_BEGIN 64, 0
    mov     [rbp - 8], rbx
    mov     [rbp - 16], r12
    mov     [rbp - 24], r13
    mov     [rbp - 32], r14
    mov     [rbp - 40], r15

    mov     rbx, ARG1
    mov     r13, ARG2
    mov     r14, ARG3
    mov     r12, 32
    mov     r15, SHA3_256_RATE
    mov     r10, SHA3_PAD
    call    sponge_oneshot

    mov     rbx, [rbp - 8]
    mov     r12, [rbp - 16]
    mov     r13, [rbp - 24]
    mov     r14, [rbp - 32]
    mov     r15, [rbp - 40]
    FRAME_END
    ret

; cyboudb_sha3_512(out64, in, in_len)
cyboudb_sha3_512:
    FRAME_BEGIN 64, 0
    mov     [rbp - 8], rbx
    mov     [rbp - 16], r12
    mov     [rbp - 24], r13
    mov     [rbp - 32], r14
    mov     [rbp - 40], r15

    mov     rbx, ARG1
    mov     r13, ARG2
    mov     r14, ARG3
    mov     r12, 64
    mov     r15, SHA3_512_RATE
    mov     r10, SHA3_PAD
    call    sponge_oneshot

    mov     rbx, [rbp - 8]
    mov     r12, [rbp - 16]
    mov     r13, [rbp - 24]
    mov     r14, [rbp - 32]
    mov     r15, [rbp - 40]
    FRAME_END
    ret

%ifdef CybouDB_LINUX
section .note.GNU-stack noalloc noexec nowrite progbits
%endif
