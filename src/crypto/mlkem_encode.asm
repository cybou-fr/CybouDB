; Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
; SPDX-License-Identifier: Apache-2.0
; =============================================================================
;  crypto/mlkem_encode.asm - what a polynomial looks like on the wire
; =============================================================================
;  FIPS 203 sections 4.2.1 and 4.2.2: byte encoding at twelve bits per
;  coefficient, and the lossy compression that makes a ciphertext 1088 bytes
;  instead of 2304.
;
;  Compression is where a KEM meets a division by q on secret data, which
;  docs/PQ_KEM.md forbids in the only sense that matters - a real division has
;  a data-dependent latency on some machines, and the message polynomial is
;  secret. It is done here as a multiply and a shift:
;
;      n / 3329  ==  (n * 2580335) >> 33      for every n this file can produce
;
;  which is not an approximation that happens to work on the cases anyone
;  tried: tools/gen_mlkem_tables.py checks it against the real division for
;  every n from zero to the largest value compression can present, and the
;  generator fails if it ever stops being true.
;
;  Nothing here branches on a coefficient. The masks are arithmetic.
; =============================================================================

%include "cyboudb.inc"

BITS 64
default rel

global cyboudb_mlkem_poly_tobytes
global cyboudb_mlkem_poly_frombytes
global cyboudb_mlkem_poly_compress10
global cyboudb_mlkem_poly_decompress10
global cyboudb_mlkem_poly_compress4
global cyboudb_mlkem_poly_decompress4
global cyboudb_mlkem_poly_frommsg
global cyboudb_mlkem_poly_tomsg

section .rodata
%include "mlkem_zetas.inc"

section .text

; -----------------------------------------------------------------------------
;  CSUB_Q_TO_POSITIVE <reg32> - a centred coefficient becomes its
;  representative in [0, q), without a branch: the arithmetic shift of a
;  negative value is all ones, and of a non-negative one is all zeros.
; -----------------------------------------------------------------------------
%macro TO_POSITIVE 2                    ; %1 = value reg32, %2 = scratch reg32
    mov     %2, %1
    sar     %2, 31
    and     %2, MLKEM_Q
    add     %1, %2
%endmacro

; -----------------------------------------------------------------------------
;  DIV_Q <reg64> - divide by q, the way that has no data-dependent latency.
;  Clobbers the register it is given and rax.
; -----------------------------------------------------------------------------
%macro DIV_Q 1
    mov     rax, %1
    imul    rax, MLKEM_DIV_M
    shr     rax, MLKEM_DIV_S
    mov     %1, rax
%endmacro

; =============================================================================
;  cyboudb_mlkem_poly_tobytes(out, poly)   384 bytes, twelve bits each
;  cyboudb_mlkem_poly_frombytes(poly, in)
;
;  Lossless, and the encoding a public key and a secret key are written in.
; =============================================================================
cyboudb_mlkem_poly_tobytes:
    mov     r10, ARG1                   ; out
    mov     r11, ARG2                   ; poly
    xor     rcx, rcx                    ; i, over 128 pairs
.pair:
    movsx   r8d, word [r11 + rcx * 4]
    TO_POSITIVE r8d, r9d
    movsx   r9d, word [r11 + rcx * 4 + 2]
    mov     eax, r9d
    sar     eax, 31
    and     eax, MLKEM_Q
    add     r9d, eax

    mov     rax, rcx
    imul    rax, rax, 3
    mov     [r10 + rax], r8b            ; t0 low eight
    mov     edx, r8d
    shr     edx, 8                      ; t0 high four
    mov     r8d, r9d
    shl     r8d, 4
    or      edx, r8d
    mov     [r10 + rax + 1], dl
    shr     r9d, 4
    mov     [r10 + rax + 2], r9b

    inc     rcx
    cmp     rcx, 128
    jb      .pair
    ret

cyboudb_mlkem_poly_frombytes:
    mov     r10, ARG1                   ; poly
    mov     r11, ARG2                   ; in
    xor     rcx, rcx
.pair:
    mov     rax, rcx
    imul    rax, rax, 3
    movzx   r8d, byte [r11 + rax]
    movzx   edx, byte [r11 + rax + 1]
    movzx   r9d, byte [r11 + rax + 2]

    mov     eax, edx
    shl     eax, 8
    or      r8d, eax
    and     r8d, 0xFFF                  ; the first twelve bits
    mov     [r10 + rcx * 4], r8w

    shr     edx, 4
    shl     r9d, 4
    or      edx, r9d
    and     edx, 0xFFF
    mov     [r10 + rcx * 4 + 2], dx

    inc     rcx
    cmp     rcx, 128
    jb      .pair
    ret

; -----------------------------------------------------------------------------
;  COMPRESS <dst32>, <src32 coefficient>, <bits>
;
;  round(2^d * x / q) mod 2^d, as FIPS 203 defines it: shift, add half of q,
;  divide, mask. Clobbers rax and rdx.
; -----------------------------------------------------------------------------
%macro COMPRESS 3
    TO_POSITIVE %2, eax
    mov     edx, %2                     ; zero-extends: it is in [0, q)
    shl     rdx, %3
    add     rdx, MLKEM_Q / 2
    DIV_Q   rdx
    and     edx, (1 << %3) - 1
    mov     %1, edx
%endmacro

; -----------------------------------------------------------------------------
;  DECOMPRESS <dst32>, <src32 value>, <bits> - round(q * y / 2^d).
;  An exact shift, so no division and no constant.
; -----------------------------------------------------------------------------
%macro DECOMPRESS 3
    imul    %1, %2, MLKEM_Q
    add     %1, 1 << (%3 - 1)
    shr     %1, %3
%endmacro

; =============================================================================
;  cyboudb_mlkem_poly_compress10(out, poly)    du = 10: 320 bytes
;  cyboudb_mlkem_poly_decompress10(poly, in)
;
;  Four coefficients into five bytes. The ciphertext's u vector is carried at
;  this width, which is where most of ML-KEM-768's 1088 bytes go.
; =============================================================================
cyboudb_mlkem_poly_compress10:
    FRAME_BEGIN 64, 0
    mov     [rbp - 8], rbx
    mov     [rbp - 16], r12
    mov     [rbp - 24], r13

    mov     rbx, ARG1                   ; out
    mov     r12, ARG2                   ; poly
    xor     r13, r13                    ; i, over 64 groups of four
.group:
    mov     rcx, r13
    shl     rcx, 2                      ; first coefficient of the group

    movsx   r8d, word [r12 + rcx * 2]
    COMPRESS r8d, r8d, 10
    movsx   r9d, word [r12 + rcx * 2 + 2]
    COMPRESS r9d, r9d, 10
    movsx   r10d, word [r12 + rcx * 2 + 4]
    COMPRESS r10d, r10d, 10
    movsx   r11d, word [r12 + rcx * 2 + 6]
    COMPRESS r11d, r11d, 10

    mov     rcx, r13
    imul    rcx, rcx, 5
    mov     [rbx + rcx], r8b

    mov     eax, r8d
    shr     eax, 8
    mov     edx, r9d
    shl     edx, 2
    or      eax, edx
    mov     [rbx + rcx + 1], al

    mov     eax, r9d
    shr     eax, 6
    mov     edx, r10d
    shl     edx, 4
    or      eax, edx
    mov     [rbx + rcx + 2], al

    mov     eax, r10d
    shr     eax, 4
    mov     edx, r11d
    shl     edx, 6
    or      eax, edx
    mov     [rbx + rcx + 3], al

    mov     eax, r11d
    shr     eax, 2
    mov     [rbx + rcx + 4], al

    inc     r13
    cmp     r13, 64
    jb      .group

    mov     rbx, [rbp - 8]
    mov     r12, [rbp - 16]
    mov     r13, [rbp - 24]
    FRAME_END
    ret

cyboudb_mlkem_poly_decompress10:
    FRAME_BEGIN 64, 0
    mov     [rbp - 8], rbx
    mov     [rbp - 16], r12
    mov     [rbp - 24], r13

    mov     rbx, ARG1                   ; poly
    mov     r12, ARG2                   ; in
    xor     r13, r13
.group:
    mov     rcx, r13
    imul    rcx, rcx, 5
    movzx   eax, byte [r12 + rcx]
    movzx   edx, byte [r12 + rcx + 1]
    movzx   r8d, byte [r12 + rcx + 2]
    movzx   r9d, byte [r12 + rcx + 3]
    movzx   r10d, byte [r12 + rcx + 4]

    ; The five bytes hold four ten-bit values, straddling byte boundaries.
    mov     r11d, edx
    shl     r11d, 8
    or      r11d, eax
    and     r11d, 0x3FF
    mov     [rbp - 32], r11d

    mov     r11d, r8d
    shl     r11d, 6
    shr     edx, 2
    or      r11d, edx
    and     r11d, 0x3FF
    mov     [rbp - 36], r11d

    mov     r11d, r9d
    shl     r11d, 4
    shr     r8d, 4
    or      r11d, r8d
    and     r11d, 0x3FF
    mov     [rbp - 40], r11d

    mov     r11d, r10d
    shl     r11d, 2
    shr     r9d, 6
    or      r11d, r9d
    and     r11d, 0x3FF
    mov     [rbp - 44], r11d

    mov     rcx, r13
    shl     rcx, 2
    mov     eax, [rbp - 32]
    DECOMPRESS edx, eax, 10
    mov     [rbx + rcx * 2], dx
    mov     eax, [rbp - 36]
    DECOMPRESS edx, eax, 10
    mov     [rbx + rcx * 2 + 2], dx
    mov     eax, [rbp - 40]
    DECOMPRESS edx, eax, 10
    mov     [rbx + rcx * 2 + 4], dx
    mov     eax, [rbp - 44]
    DECOMPRESS edx, eax, 10
    mov     [rbx + rcx * 2 + 6], dx

    inc     r13
    cmp     r13, 64
    jb      .group

    mov     rbx, [rbp - 8]
    mov     r12, [rbp - 16]
    mov     r13, [rbp - 24]
    FRAME_END
    ret

; =============================================================================
;  cyboudb_mlkem_poly_compress4(out, poly)     dv = 4: 128 bytes
;  cyboudb_mlkem_poly_decompress4(poly, in)
;
;  Two coefficients to a byte. This is the v part of a ciphertext, and four
;  bits is enough because what has to survive is one bit of message per
;  coefficient - the rest is noise the decoder is expected to throw away.
; =============================================================================
cyboudb_mlkem_poly_compress4:
    FRAME_BEGIN 48, 0
    mov     [rbp - 8], rbx
    mov     [rbp - 16], r12

    mov     rbx, ARG1
    mov     r12, ARG2
    xor     rcx, rcx
.pair:
    movsx   r8d, word [r12 + rcx * 4]
    COMPRESS r8d, r8d, 4
    movsx   r9d, word [r12 + rcx * 4 + 2]
    COMPRESS r9d, r9d, 4

    shl     r9d, 4
    or      r8d, r9d
    mov     [rbx + rcx], r8b

    inc     rcx
    cmp     rcx, 128
    jb      .pair

    mov     rbx, [rbp - 8]
    mov     r12, [rbp - 16]
    FRAME_END
    ret

cyboudb_mlkem_poly_decompress4:
    mov     r10, ARG1                   ; poly
    mov     r11, ARG2                   ; in
    xor     rcx, rcx
.pair:
    movzx   r8d, byte [r11 + rcx]
    mov     r9d, r8d
    and     r8d, 0x0F
    shr     r9d, 4

    DECOMPRESS eax, r8d, 4
    mov     [r10 + rcx * 4], ax
    DECOMPRESS eax, r9d, 4
    mov     [r10 + rcx * 4 + 2], ax

    inc     rcx
    cmp     rcx, 128
    jb      .pair
    ret

; =============================================================================
;  cyboudb_mlkem_poly_frommsg(poly, msg32)
;  cyboudb_mlkem_poly_tomsg(msg32, poly)
;
;  A message bit becomes a coefficient at the far end of the ring - (q+1)/2 -
;  and comes back by asking which end it is nearer. The whole security of the
;  FO transform runs through these two, so neither may branch on a bit: the
;  mask below is arithmetic, and the decode is the same divide-by-constant as
;  compression with d = 1.
; =============================================================================
cyboudb_mlkem_poly_frommsg:
    mov     r10, ARG1                   ; poly
    mov     r11, ARG2                   ; msg
    xor     rcx, rcx                    ; byte index
.byte:
    movzx   r8d, byte [r11 + rcx]
    xor     r9, r9                      ; bit index
.bit:
    mov     eax, r8d
    and     eax, 1
    neg     eax                         ; 0 or 0xFFFFFFFF, without a branch
    and     eax, (MLKEM_Q + 1) / 2
    shr     r8d, 1

    mov     rdx, rcx
    shl     rdx, 3
    add     rdx, r9
    mov     [r10 + rdx * 2], ax

    inc     r9
    cmp     r9, 8
    jb      .bit

    inc     rcx
    cmp     rcx, 32
    jb      .byte
    ret

cyboudb_mlkem_poly_tomsg:
    FRAME_BEGIN 48, 0
    mov     [rbp - 8], rbx
    mov     [rbp - 16], r12

    mov     [rbp - 32], ARG1            ; msg
    mov     r12, ARG2                   ; poly
    xor     rcx, rcx
.byte:
    xor     r9, r9                      ; bit index
    mov     r11d, 1                     ; that bit's weight
    xor     ebx, ebx                    ; the byte being assembled
.bit:
    mov     rdx, rcx
    shl     rdx, 3
    add     rdx, r9
    movsx   r8d, word [r12 + rdx * 2]
    TO_POSITIVE r8d, r10d

    ; bit = round(2 * x / q) & 1: is it nearer (q+1)/2 or nearer zero
    mov     rdx, r8
    shl     rdx, 1
    add     rdx, MLKEM_Q / 2
    DIV_Q   rdx
    and     edx, 1

    neg     edx                         ; 0 or all ones
    and     edx, r11d
    or      ebx, edx
    shl     r11d, 1

    inc     r9
    cmp     r9, 8
    jb      .bit

    mov     r10, [rbp - 32]             ; msg
    mov     [r10 + rcx], bl

    inc     rcx
    cmp     rcx, 32
    jb      .byte

    mov     rbx, [rbp - 8]
    mov     r12, [rbp - 16]
    FRAME_END
    ret

%ifdef CybouDB_LINUX
section .note.GNU-stack noalloc noexec nowrite progbits
%endif
