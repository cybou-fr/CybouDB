; Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
; SPDX-License-Identifier: Apache-2.0
; =============================================================================
;  crypto/mlkem.asm - ML-KEM-768: K-PKE, and the transform that wraps it
; =============================================================================
;  FIPS 203 Algorithms 13 to 18, and docs/PQ_KEM.md for why any of it is here.
;
;  Three things about this file are worth saying before the code:
;
;  1. **Key generation is a function of its seed.** d and z come in as
;     arguments and nothing here reads a random number generator. That is what
;     makes the implementation checkable against another one - OpenSSL stores
;     the same 64-byte seed and will print it - and it is also what keeps the
;     randomness in one place the engine owns rather than in the primitive.
;
;  2. **Decapsulation never fails.** A ciphertext that does not re-encrypt to
;     itself yields a shared secret derived from z instead of an error. The
;     selection is arithmetic: no branch reads the comparison, because the
;     branch would say out loud what the design refuses to say.
;
;  3. **The transpose is not a detail.** KeyGen forms t = A s + e and Encrypt
;     forms u = A^T y + e1 from the same A. Sampling A the same way in both and
;     indexing it transposed in one is the whole of it; getting it wrong gives
;     a KEM that works perfectly with itself.
; =============================================================================

%include "cyboudb.inc"
%include "crypto.inc"

BITS 64
default rel

global cyboudb_mlkem_keygen
global cyboudb_mlkem_encaps
global cyboudb_mlkem_decaps

extern cyboudb_mlkem_ntt
extern cyboudb_mlkem_invntt
extern cyboudb_mlkem_basemul
extern cyboudb_mlkem_poly_add
extern cyboudb_mlkem_poly_sub
extern cyboudb_mlkem_poly_reduce
extern cyboudb_mlkem_poly_tomont
extern cyboudb_mlkem_poly_tobytes
extern cyboudb_mlkem_poly_frombytes
extern cyboudb_mlkem_poly_compress10
extern cyboudb_mlkem_poly_decompress10
extern cyboudb_mlkem_poly_compress4
extern cyboudb_mlkem_poly_decompress4
extern cyboudb_mlkem_poly_frommsg
extern cyboudb_mlkem_poly_tomsg
extern cyboudb_mlkem_sample_ntt
extern cyboudb_mlkem_cbd2
extern cyboudb_mlkem_prf
extern cyboudb_sha3_256
extern cyboudb_sha3_512
extern cyboudb_shake256

%define MLKEM_K          3
%define POLY_MEM         512            ; 256 coefficients as int16
%define POLY_ENC         384            ; twelve bits each, on the wire
%define POLY_C1          320            ; compressed at du = 10
%define POLY_C2          128            ; compressed at dv = 4
%define MLKEM_EK_BYTES   1184
%define MLKEM_DK_BYTES   2400
%define MLKEM_CT_BYTES   1088

section .text

; =============================================================================
;  The frame of every routine below is mapped in a comment before it, giving
;  each slot a name and a size. This file allocates five kilobytes of
;  polynomials on the stack, and a slot collision inside a frame that large is
;  the one bug that produces a plausible wrong answer instead of a crash - the
;  Poly1305 frame and the ML-KEM PRF buffer both taught that lesson already.
; =============================================================================

; -----------------------------------------------------------------------------
;  kpke_matvec(dst_vec, seed, vec, transpose)
;
;  ARG1  int16_t *dst      k polynomials
;  ARG2  uint8_t *rho
;  ARG3  int16_t *vec      k polynomials, in the NTT domain
;  ARG4  uint64_t transpose   0: dst = A vec, 1: dst = A^T vec
;
;  Frame:
;    [rbp - 8]   saved rbx        [rbp - 40]  saved r15
;    [rbp - 16]  saved r12        [rbp - 48]  dst
;    [rbp - 24]  saved r13        [rbp - 56]  rho
;    [rbp - 32]  saved r14        [rbp - 64]  vec
;                                 [rbp - 72]  transpose
;    [rbp - 592]  a, one sampled polynomial
;    [rbp - 1104] tmp, one product
;
;  The arrays stop sixteen bytes above the argument slots rather than exactly
;  at them: an array whose last byte is a slot's first byte is correct right
;  up until someone adds a slot, and this frame had that bug before it ran.
;
;  A is sampled a polynomial at a time and thrown away, which costs nine XOF
;  runs and saves four and a half kilobytes of stack. The XOF is the expensive
;  part either way and this is not the place to decide that differently.
; -----------------------------------------------------------------------------
%define MV_A     592                    ; a spans [rbp-592, rbp-80)
%define MV_TMP   1104
%define MV_FRAME 1168

kpke_matvec:
    FRAME_BEGIN MV_FRAME, 0
    mov     [rbp - 8], rbx
    mov     [rbp - 16], r12
    mov     [rbp - 24], r13
    mov     [rbp - 32], r14
    mov     [rbp - 40], r15

    mov     [rbp - 48], ARG1
    mov     [rbp - 56], ARG2
    mov     [rbp - 64], ARG3
    mov     [rbp - 72], ARG4

    xor     r12, r12                    ; i, the row of the result
.row:
    ; dst[i] = 0
    mov     rbx, [rbp - 48]
    mov     rax, r12
    imul    rax, rax, POLY_MEM
    add     rbx, rax                    ; &dst[i]
    xor     rax, rax
    xor     rcx, rcx
.clear:
    mov     [rbx + rcx], rax
    add     rcx, 8
    cmp     rcx, POLY_MEM
    jb      .clear

    xor     r13, r13                    ; j
.col:
    ; A[i][j] with the indices swapped when a transpose was asked for
    mov     ARG1, rbp
    sub     ARG1, MV_A
    mov     ARG2, [rbp - 56]
    cmp     qword [rbp - 72], 0
    jne     .transposed
    mov     ARG3, r12
    mov     ARG4, r13
    jmp     .sample
.transposed:
    mov     ARG3, r13
    mov     ARG4, r12
.sample:
    call    cyboudb_mlkem_sample_ntt

    ; tmp = A[..] * vec[j]
    mov     ARG1, rbp
    sub     ARG1, MV_TMP
    mov     ARG2, rbp
    sub     ARG2, MV_A
    mov     rax, r13
    imul    rax, rax, POLY_MEM
    add     rax, [rbp - 64]
    mov     ARG3, rax
    call    cyboudb_mlkem_basemul

    ; dst[i] += tmp
    mov     ARG1, rbx
    mov     ARG2, rbx
    mov     ARG3, rbp
    sub     ARG3, MV_TMP
    call    cyboudb_mlkem_poly_add

    inc     r13
    cmp     r13, MLKEM_K
    jb      .col

    inc     r12
    cmp     r12, MLKEM_K
    jb      .row

    mov     rbx, [rbp - 8]
    mov     r12, [rbp - 16]
    mov     r13, [rbp - 24]
    mov     r14, [rbp - 32]
    mov     r15, [rbp - 40]
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  kpke_innerprod(dst, a_vec, b_vec) - dst = sum_i a[i] * b[i]
;
;  Frame:
;    [rbp - 8..32] saved rbx, r12, r13, r14
;    [rbp - 40]  dst    [rbp - 48] a    [rbp - 56] b
;    [rbp - 576] tmp
; -----------------------------------------------------------------------------
%define IP_TMP   576
%define IP_FRAME 640

kpke_innerprod:
    FRAME_BEGIN IP_FRAME, 0
    mov     [rbp - 8], rbx
    mov     [rbp - 16], r12
    mov     [rbp - 24], r13
    mov     [rbp - 32], r14

    mov     rbx, ARG1
    mov     [rbp - 48], ARG2
    mov     [rbp - 56], ARG3

    xor     rax, rax
    xor     rcx, rcx
.clear:
    mov     [rbx + rcx], rax
    add     rcx, 8
    cmp     rcx, POLY_MEM
    jb      .clear

    xor     r12, r12
.term:
    mov     ARG1, rbp
    sub     ARG1, IP_TMP
    mov     rax, r12
    imul    rax, rax, POLY_MEM
    mov     ARG2, rax
    add     ARG2, [rbp - 48]
    mov     ARG3, rax
    add     ARG3, [rbp - 56]
    call    cyboudb_mlkem_basemul

    mov     ARG1, rbx
    mov     ARG2, rbx
    mov     ARG3, rbp
    sub     ARG3, IP_TMP
    call    cyboudb_mlkem_poly_add

    inc     r12
    cmp     r12, MLKEM_K
    jb      .term

    mov     rbx, [rbp - 8]
    mov     r12, [rbp - 16]
    mov     r13, [rbp - 24]
    mov     r14, [rbp - 32]
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  kpke_noise(vec, seed, first_nonce, count) - count polynomials of CBD noise
;
;  Frame:
;    [rbp - 8..32] saved registers
;    [rbp - 40] vec   [rbp - 48] seed   [rbp - 56] nonce   [rbp - 64] count
;    [rbp - 192] buf, 128 bytes of PRF output
; -----------------------------------------------------------------------------
%define NS_BUF   192
%define NS_FRAME 256

kpke_noise:
    FRAME_BEGIN NS_FRAME, 0
    mov     [rbp - 8], rbx
    mov     [rbp - 16], r12
    mov     [rbp - 24], r13

    mov     [rbp - 40], ARG1
    mov     [rbp - 48], ARG2
    mov     r12, ARG3                   ; nonce
    mov     r13, ARG4                   ; how many

    xor     rbx, rbx
.poly:
    mov     ARG1, rbp
    sub     ARG1, NS_BUF
    mov     ARG2, 128
    mov     ARG3, [rbp - 48]
    mov     ARG4, r12
    call    cyboudb_mlkem_prf

    mov     rax, rbx
    imul    rax, rax, POLY_MEM
    add     rax, [rbp - 40]
    mov     ARG1, rax
    mov     ARG2, rbp
    sub     ARG2, NS_BUF
    call    cyboudb_mlkem_cbd2

    inc     r12
    inc     rbx
    cmp     rbx, r13
    jb      .poly

    mov     rbx, [rbp - 8]
    mov     r12, [rbp - 16]
    mov     r13, [rbp - 24]
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  vec_ntt(vec, count) / vec_reduce(vec, count) - in place, k at a time
; -----------------------------------------------------------------------------
vec_ntt:
    FRAME_BEGIN 48, 0
    mov     [rbp - 8], rbx
    mov     [rbp - 16], r12
    mov     [rbp - 24], r13
    mov     r12, ARG1
    mov     r13, ARG2
    xor     rbx, rbx
.one:
    mov     rax, rbx
    imul    rax, rax, POLY_MEM
    add     rax, r12
    mov     ARG1, rax
    call    cyboudb_mlkem_ntt
    inc     rbx
    cmp     rbx, r13
    jb      .one
    mov     rbx, [rbp - 8]
    mov     r12, [rbp - 16]
    mov     r13, [rbp - 24]
    FRAME_END
    ret

vec_reduce:
    FRAME_BEGIN 48, 0
    mov     [rbp - 8], rbx
    mov     [rbp - 16], r12
    mov     [rbp - 24], r13
    mov     r12, ARG1
    mov     r13, ARG2
    xor     rbx, rbx
.one:
    mov     rax, rbx
    imul    rax, rax, POLY_MEM
    add     rax, r12
    mov     ARG1, rax
    call    cyboudb_mlkem_poly_reduce
    inc     rbx
    cmp     rbx, r13
    jb      .one
    mov     rbx, [rbp - 8]
    mov     r12, [rbp - 16]
    mov     r13, [rbp - 24]
    FRAME_END
    ret

; =============================================================================
;  cyboudb_mlkem_keygen(ek, dk, d, z)
;
;  ARG1  uint8_t *ek       1184 bytes out
;  ARG2  uint8_t *dk       2400 bytes out
;  ARG3  const uint8_t *d  32 bytes of seed
;  ARG4  const uint8_t *z  32 bytes of implicit-rejection secret
;
;  Frame:
;    [rbp - 8..40]  saved rbx, r12, r13, r14, r15
;    [rbp - 48] ek   [rbp - 56] dk   [rbp - 64] z
;    [rbp - 128] g, 64 bytes: rho then sigma
;    [rbp - 192] dk_seed, 33 bytes: d then the parameter byte
;    [rbp - 1728] s, three polynomials
;    [rbp - 3264] e, three polynomials
;    [rbp - 4800] t, three polynomials
; =============================================================================
%define KG_G      128
%define KG_SEED   192
%define KG_S      1728
%define KG_E      3264
%define KG_T      4800
%define KG_FRAME  4864

cyboudb_mlkem_keygen:
    FRAME_BEGIN KG_FRAME, 0
    mov     [rbp - 8], rbx
    mov     [rbp - 16], r12
    mov     [rbp - 24], r13
    mov     [rbp - 32], r14
    mov     [rbp - 40], r15

    mov     [rbp - 48], ARG1
    mov     [rbp - 56], ARG2
    mov     [rbp - 64], ARG4            ; z
    mov     r14, ARG3                   ; d

    ; (rho, sigma) = G(d | k). The parameter byte is what keeps a seed from
    ; meaning two different keys at two different parameter sets.
    mov     rax, [r14]
    mov     [rbp - KG_SEED], rax
    mov     rax, [r14 + 8]
    mov     [rbp - KG_SEED + 8], rax
    mov     rax, [r14 + 16]
    mov     [rbp - KG_SEED + 16], rax
    mov     rax, [r14 + 24]
    mov     [rbp - KG_SEED + 24], rax
    mov     byte [rbp - KG_SEED + 32], MLKEM_K

    mov     ARG1, rbp
    sub     ARG1, KG_G
    mov     ARG2, rbp
    sub     ARG2, KG_SEED
    mov     ARG3, 33
    call    cyboudb_sha3_512

    ; s and e, from sigma, with nonces 0..2 and 3..5
    mov     ARG1, rbp
    sub     ARG1, KG_S
    mov     ARG2, rbp
    sub     ARG2, KG_G - 32             ; sigma
    mov     ARG3, 0
    mov     ARG4, MLKEM_K
    call    kpke_noise

    mov     ARG1, rbp
    sub     ARG1, KG_E
    mov     ARG2, rbp
    sub     ARG2, KG_G - 32
    mov     ARG3, MLKEM_K
    mov     ARG4, MLKEM_K
    call    kpke_noise

    mov     ARG1, rbp
    sub     ARG1, KG_S
    mov     ARG2, MLKEM_K
    call    vec_ntt
    mov     ARG1, rbp
    sub     ARG1, KG_E
    mov     ARG2, MLKEM_K
    call    vec_ntt

    ; t = A s + e
    mov     ARG1, rbp
    sub     ARG1, KG_T
    mov     ARG2, rbp
    sub     ARG2, KG_G                  ; rho
    mov     ARG3, rbp
    sub     ARG3, KG_S
    mov     ARG4, 0                     ; not transposed
    call    kpke_matvec

    xor     rbx, rbx
.finish_t:
    mov     rax, rbx
    imul    rax, rax, POLY_MEM
    mov     r12, rbp
    sub     r12, KG_T
    add     r12, rax                    ; &t[i]

    mov     ARG1, r12
    call    cyboudb_mlkem_poly_tomont   ; the matrix product owes a factor

    mov     ARG1, r12
    mov     ARG2, r12
    mov     rax, rbx
    imul    rax, rax, POLY_MEM
    mov     ARG3, rbp
    sub     ARG3, KG_E
    add     ARG3, rax
    call    cyboudb_mlkem_poly_add

    mov     ARG1, r12
    call    cyboudb_mlkem_poly_reduce

    ; ek holds t, encoded, and then rho
    mov     ARG1, rbx
    imul    ARG1, ARG1, POLY_ENC
    add     ARG1, [rbp - 48]
    mov     ARG2, r12
    call    cyboudb_mlkem_poly_tobytes

    ; dk_pke holds s
    mov     ARG1, rbx
    imul    ARG1, ARG1, POLY_ENC
    add     ARG1, [rbp - 56]
    mov     rax, rbx
    imul    rax, rax, POLY_MEM
    mov     ARG2, rbp
    sub     ARG2, KG_S
    add     ARG2, rax
    call    cyboudb_mlkem_poly_tobytes

    inc     rbx
    cmp     rbx, MLKEM_K
    jb      .finish_t

    ; rho, at the end of ek
    mov     r10, [rbp - 48]
    add     r10, MLKEM_K * POLY_ENC
    mov     rax, [rbp - KG_G]
    mov     [r10], rax
    mov     rax, [rbp - KG_G + 8]
    mov     [r10 + 8], rax
    mov     rax, [rbp - KG_G + 16]
    mov     [r10 + 16], rax
    mov     rax, [rbp - KG_G + 24]
    mov     [r10 + 24], rax

    ; dk = dk_pke | ek | H(ek) | z
    mov     r10, [rbp - 56]
    add     r10, MLKEM_K * POLY_ENC     ; where ek goes
    mov     r11, [rbp - 48]
    xor     rcx, rcx
.copy_ek:
    mov     al, [r11 + rcx]
    mov     [r10 + rcx], al
    inc     rcx
    cmp     rcx, MLKEM_EK_BYTES
    jb      .copy_ek

    mov     ARG1, [rbp - 56]
    add     ARG1, MLKEM_K * POLY_ENC + MLKEM_EK_BYTES
    mov     ARG2, [rbp - 48]
    mov     ARG3, MLKEM_EK_BYTES
    call    cyboudb_sha3_256

    mov     r10, [rbp - 56]
    add     r10, MLKEM_K * POLY_ENC + MLKEM_EK_BYTES + 32
    mov     r11, [rbp - 64]             ; z
    mov     rax, [r11]
    mov     [r10], rax
    mov     rax, [r11 + 8]
    mov     [r10 + 8], rax
    mov     rax, [r11 + 16]
    mov     [r10 + 16], rax
    mov     rax, [r11 + 24]
    mov     [r10 + 24], rax

    mov     rbx, [rbp - 8]
    mov     r12, [rbp - 16]
    mov     r13, [rbp - 24]
    mov     r14, [rbp - 32]
    mov     r15, [rbp - 40]
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  kpke_encrypt(ct, ek, m, r)
;
;  Frame:
;    [rbp - 8..40]  saved registers
;    [rbp - 48] ct  [rbp - 56] ek  [rbp - 64] m  [rbp - 72] r
;    [rbp - 1616] t      three polynomials, decoded from ek
;    [rbp - 3152] y      three
;    [rbp - 4688] e1     three
;    [rbp - 6224] u      three
;    [rbp - 6736] e2
;    [rbp - 7248] v
;    [rbp - 7760] mu
; -----------------------------------------------------------------------------
%define EN_T     1616                   ; t spans [rbp-1616, rbp-80)
%define EN_Y     3152
%define EN_E1    4688
%define EN_U     6224
%define EN_E2    6736
%define EN_V     7248
%define EN_MU    7760
%define EN_FRAME 7824

kpke_encrypt:
    FRAME_BEGIN EN_FRAME, 0
    mov     [rbp - 8], rbx
    mov     [rbp - 16], r12
    mov     [rbp - 24], r13
    mov     [rbp - 32], r14
    mov     [rbp - 40], r15

    mov     [rbp - 48], ARG1
    mov     [rbp - 56], ARG2
    mov     [rbp - 64], ARG3
    mov     [rbp - 72], ARG4

    ; t, from the first 1152 bytes of ek
    xor     rbx, rbx
.decode_t:
    mov     rax, rbx
    imul    rax, rax, POLY_MEM
    mov     ARG1, rbp
    sub     ARG1, EN_T
    add     ARG1, rax
    mov     rax, rbx
    imul    rax, rax, POLY_ENC
    mov     ARG2, [rbp - 56]
    add     ARG2, rax
    call    cyboudb_mlkem_poly_frombytes
    inc     rbx
    cmp     rbx, MLKEM_K
    jb      .decode_t

    ; y (nonces 0..2), e1 (3..5), e2 (6)
    mov     ARG1, rbp
    sub     ARG1, EN_Y
    mov     ARG2, [rbp - 72]
    mov     ARG3, 0
    mov     ARG4, MLKEM_K
    call    kpke_noise

    mov     ARG1, rbp
    sub     ARG1, EN_E1
    mov     ARG2, [rbp - 72]
    mov     ARG3, MLKEM_K
    mov     ARG4, MLKEM_K
    call    kpke_noise

    mov     ARG1, rbp
    sub     ARG1, EN_E2
    mov     ARG2, [rbp - 72]
    mov     ARG3, 2 * MLKEM_K
    mov     ARG4, 1
    call    kpke_noise

    mov     ARG1, rbp
    sub     ARG1, EN_Y
    mov     ARG2, MLKEM_K
    call    vec_ntt

    ; u = invNTT(A^T y) + e1
    mov     ARG1, rbp
    sub     ARG1, EN_U
    mov     ARG2, [rbp - 56]
    add     ARG2, MLKEM_K * POLY_ENC    ; rho
    mov     ARG3, rbp
    sub     ARG3, EN_Y
    mov     ARG4, 1                     ; transposed
    call    kpke_matvec

    xor     rbx, rbx
.finish_u:
    mov     rax, rbx
    imul    rax, rax, POLY_MEM
    mov     r12, rbp
    sub     r12, EN_U
    add     r12, rax

    mov     ARG1, r12
    call    cyboudb_mlkem_invntt

    mov     ARG1, r12
    mov     ARG2, r12
    mov     rax, rbx
    imul    rax, rax, POLY_MEM
    mov     ARG3, rbp
    sub     ARG3, EN_E1
    add     ARG3, rax
    call    cyboudb_mlkem_poly_add

    mov     ARG1, r12
    call    cyboudb_mlkem_poly_reduce

    mov     ARG1, rbx
    imul    ARG1, ARG1, POLY_C1
    add     ARG1, [rbp - 48]
    mov     ARG2, r12
    call    cyboudb_mlkem_poly_compress10

    inc     rbx
    cmp     rbx, MLKEM_K
    jb      .finish_u

    ; v = invNTT(t . y) + e2 + mu
    mov     ARG1, rbp
    sub     ARG1, EN_V
    mov     ARG2, rbp
    sub     ARG2, EN_T
    mov     ARG3, rbp
    sub     ARG3, EN_Y
    call    kpke_innerprod

    mov     ARG1, rbp
    sub     ARG1, EN_V
    call    cyboudb_mlkem_invntt

    mov     ARG1, rbp
    sub     ARG1, EN_MU
    mov     ARG2, [rbp - 64]
    call    cyboudb_mlkem_poly_frommsg

    mov     ARG1, rbp
    sub     ARG1, EN_V
    mov     ARG2, rbp
    sub     ARG2, EN_V
    mov     ARG3, rbp
    sub     ARG3, EN_E2
    call    cyboudb_mlkem_poly_add

    mov     ARG1, rbp
    sub     ARG1, EN_V
    mov     ARG2, rbp
    sub     ARG2, EN_V
    mov     ARG3, rbp
    sub     ARG3, EN_MU
    call    cyboudb_mlkem_poly_add

    mov     ARG1, rbp
    sub     ARG1, EN_V
    call    cyboudb_mlkem_poly_reduce

    mov     ARG1, [rbp - 48]
    add     ARG1, MLKEM_K * POLY_C1
    mov     ARG2, rbp
    sub     ARG2, EN_V
    call    cyboudb_mlkem_poly_compress4

    mov     rbx, [rbp - 8]
    mov     r12, [rbp - 16]
    mov     r13, [rbp - 24]
    mov     r14, [rbp - 32]
    mov     r15, [rbp - 40]
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  kpke_decrypt(m, dk_pke, ct)
;
;  Frame:
;    [rbp - 8..40]  saved registers
;    [rbp - 48] m   [rbp - 56] dk   [rbp - 64] ct
;    [rbp - 1600] u   three polynomials
;    [rbp - 3136] s   three
;    [rbp - 3648] v
;    [rbp - 4160] w
; -----------------------------------------------------------------------------
%define DE_U     1600
%define DE_S     3136
%define DE_V     3648
%define DE_W     4160
%define DE_FRAME 4224

kpke_decrypt:
    FRAME_BEGIN DE_FRAME, 0
    mov     [rbp - 8], rbx
    mov     [rbp - 16], r12
    mov     [rbp - 24], r13

    mov     [rbp - 48], ARG1
    mov     [rbp - 56], ARG2
    mov     [rbp - 64], ARG3

    xor     rbx, rbx
.decode:
    mov     rax, rbx
    imul    rax, rax, POLY_MEM
    mov     ARG1, rbp
    sub     ARG1, DE_U
    add     ARG1, rax
    mov     rax, rbx
    imul    rax, rax, POLY_C1
    mov     ARG2, [rbp - 64]
    add     ARG2, rax
    call    cyboudb_mlkem_poly_decompress10

    mov     rax, rbx
    imul    rax, rax, POLY_MEM
    mov     ARG1, rbp
    sub     ARG1, DE_S
    add     ARG1, rax
    mov     rax, rbx
    imul    rax, rax, POLY_ENC
    mov     ARG2, [rbp - 56]
    add     ARG2, rax
    call    cyboudb_mlkem_poly_frombytes

    inc     rbx
    cmp     rbx, MLKEM_K
    jb      .decode

    mov     ARG1, rbp
    sub     ARG1, DE_V
    mov     ARG2, [rbp - 64]
    add     ARG2, MLKEM_K * POLY_C1
    call    cyboudb_mlkem_poly_decompress4

    mov     ARG1, rbp
    sub     ARG1, DE_U
    mov     ARG2, MLKEM_K
    call    vec_ntt

    mov     ARG1, rbp
    sub     ARG1, DE_W
    mov     ARG2, rbp
    sub     ARG2, DE_S
    mov     ARG3, rbp
    sub     ARG3, DE_U
    call    kpke_innerprod

    mov     ARG1, rbp
    sub     ARG1, DE_W
    call    cyboudb_mlkem_invntt

    ; w = v - s . u
    mov     ARG1, rbp
    sub     ARG1, DE_W
    mov     ARG2, rbp
    sub     ARG2, DE_V
    mov     ARG3, rbp
    sub     ARG3, DE_W
    call    cyboudb_mlkem_poly_sub

    mov     ARG1, rbp
    sub     ARG1, DE_W
    call    cyboudb_mlkem_poly_reduce

    mov     ARG1, [rbp - 48]
    mov     ARG2, rbp
    sub     ARG2, DE_W
    call    cyboudb_mlkem_poly_tomsg

    mov     rbx, [rbp - 8]
    mov     r12, [rbp - 16]
    mov     r13, [rbp - 24]
    FRAME_END
    ret

; =============================================================================
;  cyboudb_mlkem_encaps(ct, ss, ek, m)
;
;  ARG1  uint8_t *ct       1088 bytes out
;  ARG2  uint8_t *ss       32 bytes out
;  ARG3  const uint8_t *ek 1184
;  ARG4  const uint8_t *m  32 bytes of message randomness
;
;  m is an argument and not something drawn here, for the reason at the top of
;  this file: the caller owns the randomness, and a test can therefore run
;  encapsulation against a value another implementation also used.
;
;  Frame:
;    [rbp - 8..32] saved registers
;    [rbp - 40] ct  [rbp - 48] ss  [rbp - 56] ek
;    [rbp - 128] g_in, 64 bytes: m then H(ek)
;    [rbp - 192] kr,   64 bytes: K then r
; =============================================================================
%define EC_GIN   128
%define EC_KR    192
%define EC_FRAME 256

cyboudb_mlkem_encaps:
    FRAME_BEGIN EC_FRAME, 0
    mov     [rbp - 8], rbx
    mov     [rbp - 16], r12

    mov     [rbp - 40], ARG1
    mov     [rbp - 48], ARG2
    mov     [rbp - 56], ARG3
    mov     r12, ARG4                   ; m

    mov     rax, [r12]
    mov     [rbp - EC_GIN], rax
    mov     rax, [r12 + 8]
    mov     [rbp - EC_GIN + 8], rax
    mov     rax, [r12 + 16]
    mov     [rbp - EC_GIN + 16], rax
    mov     rax, [r12 + 24]
    mov     [rbp - EC_GIN + 24], rax

    mov     ARG1, rbp
    sub     ARG1, EC_GIN - 32
    mov     ARG2, [rbp - 56]
    mov     ARG3, MLKEM_EK_BYTES
    call    cyboudb_sha3_256            ; H(ek), right after m

    mov     ARG1, rbp
    sub     ARG1, EC_KR
    mov     ARG2, rbp
    sub     ARG2, EC_GIN
    mov     ARG3, 64
    call    cyboudb_sha3_512            ; (K, r) = G(m | H(ek))

    mov     r10, [rbp - 48]
    mov     rax, [rbp - EC_KR]
    mov     [r10], rax
    mov     rax, [rbp - EC_KR + 8]
    mov     [r10 + 8], rax
    mov     rax, [rbp - EC_KR + 16]
    mov     [r10 + 16], rax
    mov     rax, [rbp - EC_KR + 24]
    mov     [r10 + 24], rax

    mov     ARG1, [rbp - 40]
    mov     ARG2, [rbp - 56]
    mov     ARG3, r12
    mov     ARG4, rbp
    sub     ARG4, EC_KR - 32            ; r
    call    kpke_encrypt

    mov     rbx, [rbp - 8]
    mov     r12, [rbp - 16]
    FRAME_END
    ret

; =============================================================================
;  cyboudb_mlkem_decaps(ss, ct, dk)
;
;  ARG1  uint8_t *ss        32 bytes out
;  ARG2  const uint8_t *ct  1088
;  ARG3  const uint8_t *dk  2400
;
;  Always succeeds, and says nothing about why. A ciphertext that does not
;  re-encrypt to itself gives the shared secret derived from z, selected
;  without a branch.
;
;  Frame:
;    [rbp - 8..40] saved registers
;    [rbp - 48] ss  [rbp - 56] ct  [rbp - 64] dk
;    [rbp - 128] m2, 32 (and its 32-byte neighbour holds h)
;    [rbp - 192] kr, 64
;    [rbp - 256] kbar, 32
;    [rbp - 1376] jin, 1120 bytes: z then the ciphertext
;    [rbp - 2496] ct2, the re-encryption
; =============================================================================
%define DC_M2    128
%define DC_KR    192
%define DC_KBAR  256
%define DC_JIN   1376
%define DC_CT2   2496
%define DC_FRAME 2560

cyboudb_mlkem_decaps:
    FRAME_BEGIN DC_FRAME, 0
    mov     [rbp - 8], rbx
    mov     [rbp - 16], r12
    mov     [rbp - 24], r13
    mov     [rbp - 32], r14

    mov     [rbp - 48], ARG1
    mov     [rbp - 56], ARG2
    mov     [rbp - 64], ARG3

    ; m' = K-PKE.Decrypt(dk_pke, c)
    mov     ARG1, rbp
    sub     ARG1, DC_M2
    mov     ARG2, [rbp - 64]
    mov     ARG3, [rbp - 56]
    call    kpke_decrypt

    ; the hash of ek is stored in dk, so it is not recomputed here
    mov     r10, [rbp - 64]
    add     r10, MLKEM_K * POLY_ENC + MLKEM_EK_BYTES
    mov     rax, [r10]
    mov     [rbp - DC_M2 + 32], rax
    mov     rax, [r10 + 8]
    mov     [rbp - DC_M2 + 40], rax
    mov     rax, [r10 + 16]
    mov     [rbp - DC_M2 + 48], rax
    mov     rax, [r10 + 24]
    mov     [rbp - DC_M2 + 56], rax

    mov     ARG1, rbp
    sub     ARG1, DC_KR
    mov     ARG2, rbp
    sub     ARG2, DC_M2
    mov     ARG3, 64
    call    cyboudb_sha3_512            ; (K', r') = G(m' | h)

    ; K_bar = J(z | c)
    mov     r10, [rbp - 64]
    add     r10, MLKEM_K * POLY_ENC + MLKEM_EK_BYTES + 32
    mov     rax, [r10]
    mov     [rbp - DC_JIN], rax
    mov     rax, [r10 + 8]
    mov     [rbp - DC_JIN + 8], rax
    mov     rax, [r10 + 16]
    mov     [rbp - DC_JIN + 16], rax
    mov     rax, [r10 + 24]
    mov     [rbp - DC_JIN + 24], rax

    mov     r10, rbp
    sub     r10, DC_JIN - 32
    mov     r11, [rbp - 56]
    xor     rcx, rcx
.copy_ct:
    mov     al, [r11 + rcx]
    mov     [r10 + rcx], al
    inc     rcx
    cmp     rcx, MLKEM_CT_BYTES
    jb      .copy_ct

    mov     ARG1, rbp
    sub     ARG1, DC_KBAR
    mov     ARG2, 32
    mov     ARG3, rbp
    sub     ARG3, DC_JIN
    mov     ARG4, 32 + MLKEM_CT_BYTES
    call    cyboudb_shake256

    ; c' = K-PKE.Encrypt(ek, m', r')
    mov     ARG1, rbp
    sub     ARG1, DC_CT2
    mov     ARG2, [rbp - 64]
    add     ARG2, MLKEM_K * POLY_ENC    ; ek, inside dk
    mov     ARG3, rbp
    sub     ARG3, DC_M2
    mov     ARG4, rbp
    sub     ARG4, DC_KR - 32
    call    kpke_encrypt

    ; Constant-time comparison: every byte is looked at whatever the first one
    ; said, and the result selects between two secrets arithmetically.
    mov     r10, [rbp - 56]
    mov     r11, rbp
    sub     r11, DC_CT2
    xor     r8, r8                      ; the accumulated difference
    xor     rcx, rcx
.compare:
    movzx   eax, byte [r10 + rcx]
    movzx   edx, byte [r11 + rcx]
    xor     eax, edx
    or      r8d, eax
    inc     rcx
    cmp     rcx, MLKEM_CT_BYTES
    jb      .compare

    ; mask = all ones when the ciphertexts matched, zero otherwise
    mov     rax, r8
    neg     rax
    or      rax, r8
    sar     rax, 63                     ; -1 when different, 0 when equal
    not     rax                         ; -1 when equal, 0 when different
    mov     r9, rax

    mov     r10, [rbp - 48]             ; ss
    xor     rcx, rcx
.select:
    movzx   eax, byte [rbp - DC_KR + rcx]
    movzx   edx, byte [rbp - DC_KBAR + rcx]
    xor     eax, edx
    and     eax, r9d
    xor     eax, edx                    ; K' if equal, K_bar if not
    mov     [r10 + rcx], al
    inc     rcx
    cmp     rcx, 32
    jb      .select

    mov     rbx, [rbp - 8]
    mov     r12, [rbp - 16]
    mov     r13, [rbp - 24]
    mov     r14, [rbp - 32]
    FRAME_END
    ret

%ifdef CybouDB_LINUX
section .note.GNU-stack noalloc noexec nowrite progbits
%endif
