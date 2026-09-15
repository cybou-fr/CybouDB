; Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
; SPDX-License-Identifier: Apache-2.0
; =============================================================================
;  crypto/mlkem_sample.asm - where ML-KEM's polynomials come from
; =============================================================================
;  FIPS 203 Algorithms 7 and 8: uniform sampling of the public matrix from an
;  extendable output function, and centred binomial sampling of the secrets
;  and the noise.
;
;  These two have opposite timing rules, and docs/PQ_KEM.md settles which is
;  which once rather than per function:
;
;    SampleNTT rejects values that are not below q, so it runs for a number of
;    rounds that depends on its input. Its input is rho, which is published in
;    the encapsulation key. A variable-time loop over public data leaks
;    nothing, and pretending otherwise would cost a branch-free rejection
;    sampler for no gain at all.
;
;    SamplePolyCBD is fed PRF output derived from a secret seed, so it has no
;    branch and no memory index that depends on a byte it reads. The
;    two-bits-at-a-time walk below is the definition with its shifts fixed:
;    d >>= 2 twice per coefficient rather than a shift by a computed amount.
;
;  eta is 2 for both the secret and the noise at ML-KEM-768, so there is one
;  binomial sampler here and not two.
; =============================================================================

%include "cyboudb.inc"
%include "crypto.inc"

BITS 64
default rel

global cyboudb_mlkem_sample_ntt
global cyboudb_mlkem_cbd2
global cyboudb_mlkem_prf

extern cyboudb_sponge_init
extern cyboudb_sponge_absorb
extern cyboudb_sponge_finish
extern cyboudb_sponge_squeeze
extern cyboudb_sponge_wipe
extern cyboudb_shake256

%define MLKEM_Q 3329

; The sponge context and the little buffers live in the frame, at these
; offsets below rbp. Written down because a slot collision inside a frame is
; the one bug that produces plausible wrong answers rather than a crash.
%define SN_CTX      (CybouDB_SHCTX_SIZE + 64)    ; ctx occupies [-SN_CTX, -64)
%define SN_BUF      56                           ; three squeezed bytes
%define SN_EXTRA    48                           ; the two index bytes
; And the PRF's own frame, which is not the sampler's:
%define PRF_RBX     8
%define PRF_R12     16
%define PRF_BUF     96                  ; 33 bytes at [rbp-96, rbp-63)

%define SN_RBX      8
%define SN_R12      16
%define SN_R13      24
%define SN_R14      32
%define SN_R15      40
%define SN_FRAME    (SN_CTX + 16)

section .text

; =============================================================================
;  cyboudb_mlkem_sample_ntt(poly, seed, i, j)
;
;  ARG1  int16_t       *poly     256 coefficients, already in the NTT domain
;  ARG2  const uint8_t *seed     rho, 32 bytes, public
;  ARG3  uint64_t       i        the row
;  ARG4  uint64_t       j        the column
;
;  XOF(rho, j, i) - the two index bytes in that order, which is FIPS 203's
;  order and not the one that reads naturally. Getting it backwards produces a
;  matrix that is the transpose of the right one: self-consistent, and unable
;  to talk to anything else.
; =============================================================================
cyboudb_mlkem_sample_ntt:
    FRAME_BEGIN SN_FRAME, 0
    mov     [rbp - SN_RBX], rbx
    mov     [rbp - SN_R12], r12
    mov     [rbp - SN_R13], r13
    mov     [rbp - SN_R14], r14

    mov     rbx, ARG1                   ; poly
    mov     r14, ARG2                   ; seed
    mov     rax, ARG4
    mov     [rbp - SN_EXTRA], al        ; j first
    mov     rax, ARG3
    mov     [rbp - SN_EXTRA + 1], al    ; then i

    lea     r12, [rbp - SN_CTX]         ; the sponge

    mov     ARG1, r12
    mov     ARG2, SHAKE128_RATE
    mov     ARG3, SHAKE_PAD
    call    cyboudb_sponge_init

    mov     ARG1, r12
    mov     ARG2, r14
    mov     ARG3, 32
    call    cyboudb_sponge_absorb

    mov     ARG1, r12
    lea     ARG2, [rbp - SN_EXTRA]
    mov     ARG3, 2
    call    cyboudb_sponge_absorb

    mov     ARG1, r12
    call    cyboudb_sponge_finish

    xor     r13, r13                    ; how many coefficients are accepted
.pull:
    mov     ARG1, r12
    lea     ARG2, [rbp - SN_BUF]
    mov     ARG3, 3
    call    cyboudb_sponge_squeeze

    movzx   r8d, byte [rbp - SN_BUF]
    movzx   r9d, byte [rbp - SN_BUF + 1]
    movzx   r10d, byte [rbp - SN_BUF + 2]

    ; Three bytes hold two twelve-bit candidates.
    mov     eax, r9d
    and     eax, 0x0F
    shl     eax, 8
    or      eax, r8d                    ; d1
    mov     r11d, r9d
    shr     r11d, 4
    shl     r10d, 4
    or      r11d, r10d                  ; d2

    cmp     eax, MLKEM_Q
    jae     .second
    cmp     r13, 256
    jae     .done
    mov     [rbx + r13 * 2], ax
    inc     r13

.second:
    cmp     r11d, MLKEM_Q
    jae     .more
    cmp     r13, 256
    jae     .done
    mov     [rbx + r13 * 2], r11w
    inc     r13

.more:
    cmp     r13, 256
    jb      .pull

.done:
    mov     ARG1, r12
    call    cyboudb_sponge_wipe

    mov     rbx, [rbp - SN_RBX]
    mov     r12, [rbp - SN_R12]
    mov     r13, [rbp - SN_R13]
    mov     r14, [rbp - SN_R14]
    FRAME_END
    ret

; =============================================================================
;  cyboudb_mlkem_cbd2(poly, buf)
;
;  ARG1  int16_t       *poly
;  ARG2  const uint8_t *buf      128 bytes of PRF output
;
;  Each coefficient is the number of ones in two bits minus the number of ones
;  in the next two: the centred binomial distribution with eta = 2, which is
;  what gives ML-KEM its noise. Four bytes make eight coefficients.
;
;  No branch, and no shift by an amount taken from the data - the accumulator
;  walks down two bits at a time.
; =============================================================================
cyboudb_mlkem_cbd2:
    FRAME_BEGIN 48, 0
    mov     [rbp - 8], rbx
    mov     [rbp - 16], r12

    mov     rbx, ARG1                   ; poly
    mov     r12, ARG2                   ; buf
    xor     r10, r10                    ; group index, 0..31

.group:
    mov     eax, [r12 + r10 * 4]        ; four bytes, little-endian

    ; d = (t & 0x55555555) + ((t >> 1) & 0x55555555): every pair of bits
    ; becomes the count of ones in it.
    mov     r8d, eax
    and     r8d, 0x55555555
    shr     eax, 1
    and     eax, 0x55555555
    add     r8d, eax

    mov     r9, r10
    shl     r9, 3                       ; eight coefficients per group
    xor     r11, r11
.coeff:
    mov     eax, r8d
    and     eax, 3                      ; ones in the first pair
    shr     r8d, 2
    mov     ecx, r8d
    and     ecx, 3                      ; ones in the second
    shr     r8d, 2
    sub     eax, ecx

    mov     rdx, r9
    add     rdx, r11
    mov     [rbx + rdx * 2], ax

    inc     r11
    cmp     r11, 8
    jb      .coeff

    inc     r10
    cmp     r10, 32
    jb      .group

    mov     rbx, [rbp - 8]
    mov     r12, [rbp - 16]
    FRAME_END
    ret

; =============================================================================
;  cyboudb_mlkem_prf(out, out_len, key, nonce)
;
;  FIPS 203's PRF: SHAKE256 of the thirty-two byte key followed by one byte of
;  nonce. The nonce is what keeps the noise polynomials of one key generation
;  from being each other.
; =============================================================================
cyboudb_mlkem_prf:
    FRAME_BEGIN 128, 0
    mov     [rbp - PRF_RBX], rbx
    mov     [rbp - PRF_R12], r12

    mov     rbx, ARG1                   ; out
    mov     r12, ARG2                   ; out_len
    mov     r10, ARG3                   ; key
    mov     r11, ARG4                   ; nonce

    ; key | nonce, contiguous, because the sponge takes one buffer per call
    ; and this one is small enough that a second absorb would cost more than
    ; the copy.
    mov     rax, [r10]
    mov     [rbp - PRF_BUF], rax
    mov     rax, [r10 + 8]
    mov     [rbp - PRF_BUF + 8], rax
    mov     rax, [r10 + 16]
    mov     [rbp - PRF_BUF + 16], rax
    mov     rax, [r10 + 24]
    mov     [rbp - PRF_BUF + 24], rax
    mov     rax, r11
    mov     [rbp - PRF_BUF + 32], al

    mov     ARG1, rbx
    mov     ARG2, r12
    lea     ARG3, [rbp - PRF_BUF]
    mov     ARG4, 33
    call    cyboudb_shake256

    mov     rbx, [rbp - PRF_RBX]
    mov     r12, [rbp - PRF_R12]
    FRAME_END
    ret

%ifdef CybouDB_LINUX
section .note.GNU-stack noalloc noexec nowrite progbits
%endif
