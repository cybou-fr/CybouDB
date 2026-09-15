; Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
; SPDX-License-Identifier: Apache-2.0
; =============================================================================
;  crypto/kmac.asm - KMAC256, the standard construction this project was
;                    quietly reinventing
; =============================================================================
;  NIST SP 800-185. Until now the seal tree authenticated itself with
;
;      SHAKE256(key | label | bytes)[0..16]
;
;  and the key hierarchy derived with a similar prefix construction. Both were
;  domain-separated and carefully argued, and both were mine. That is the
;  wrong side of a line this project had already drawn: implementing a
;  standard primitive is work that can be checked against another
;  implementation, while inventing a construction is work that cannot.
;
;      a primitive implemented here    checkable, and done - ML-KEM, ChaCha20
;      a construction invented here    avoid
;
;  KMAC is the standardised answer for exactly these two jobs: it is a MAC and
;  it is a PRF, and its encodings are the part that makes the domain
;  separation unambiguous rather than merely careful. bytepad, encode_string
;  and right_encode are not decoration - they are what stops two different
;  (key, customization, message) triples from producing the same absorbed
;  bytes.
;
;  KMAC256(K, X, L, S) = cSHAKE256(newX, L, "KMAC", S), where
;      newX = bytepad(encode_string(K), 136) || X || right_encode(L)
;
;  and cSHAKE differs from SHAKE in its padding byte - 0x04 rather than 0x1f -
;  which is the whole of what stops a cSHAKE output from ever colliding with a
;  SHAKE output of the same input.
;
;  The key and the customization string are capped at 64 bytes each, which
;  makes every bytepad block exactly one rate. Everything this database needs
;  to key or to label fits in that, and a cap that is checked is better than a
;  loop that is almost never exercised.
; =============================================================================

%include "cyboudb.inc"
%include "crypto.inc"

BITS 64
default rel

global cyboudb_kmac256_init
global cyboudb_kmac256_update
global cyboudb_kmac256_final
global cyboudb_kmac256

extern cyboudb_sponge_init
extern cyboudb_sponge_absorb
extern cyboudb_sponge_finish
extern cyboudb_sponge_squeeze
extern cyboudb_sponge_wipe

section .rodata
kmac_name: db "KMAC"
KMAC_NAME_LEN equ $ - kmac_name

section .text

; -----------------------------------------------------------------------------
;  LEFT_ENCODE - write left_encode(value in bits) at [rbx + rcx], advancing rcx.
;
;  left_encode puts the byte count first and then the value, big-endian. One
;  byte is enough below 256; two carry everything this file allows, since the
;  caps make the largest encoded value 64 * 8 = 512 bits.
;
;  r8 holds the value. Clobbers rax.
; -----------------------------------------------------------------------------
%macro LEFT_ENCODE 0
    cmp     r8, 256
    jae     %%two
    mov     byte [rbx + rcx], 1
    inc     rcx
    mov     rax, r8
    mov     [rbx + rcx], al
    inc     rcx
    jmp     %%done
%%two:
    mov     byte [rbx + rcx], 2
    inc     rcx
    mov     rax, r8
    shr     rax, 8
    mov     [rbx + rcx], al
    inc     rcx
    mov     rax, r8
    mov     [rbx + rcx], al
    inc     rcx
%%done:
%endmacro

; =============================================================================
;  cyboudb_kmac256_init(ctx, key, key_len, custom, custom_len) -> int
;
;  ARG1  uint8_t       *ctx         CybouDB_SHCTX_SIZE bytes
;  ARG2  const uint8_t *key
;  ARG3  uint64_t       key_len     at most 64
;  ARG4  const uint8_t *custom      may be NULL when custom_len is zero
;  ARG5  uint64_t       custom_len  at most 64
;
;  Frame:
;    [rbp - 8..32]  saved rbx, r12, r13
;    [rbp - 40] ctx  [rbp - 48] key  [rbp - 56] key_len
;    [rbp - 64] custom  [rbp - 72] custom_len
;    [rbp - 224] block, 136 bytes - one rate, which every bytepad here fills
;
;  The block stops sixteen bytes short of the argument slots, and the loops
;  below clear exactly 136 bytes. The first version cleared 144 and the block
;  ended where the slots began, so zeroing it erased custom_len: every case
;  with a customization string became a case without one, and only the case
;  with an empty string passed.
; =============================================================================
%define KM_BLOCK   224                  ; the block spans [rbp-224, rbp-88):
%define KM_FRAME   288                  ; sixteen bytes clear of the slots

cyboudb_kmac256_init:
    FRAME_BEGIN KM_FRAME, 1
    mov     [rbp - 8], rbx
    mov     [rbp - 16], r12
    mov     [rbp - 24], r13

    mov     [rbp - 40], ARG1
    mov     [rbp - 48], ARG2
    mov     [rbp - 56], ARG3
    mov     [rbp - 64], ARG4
    mov     rax, IN_ARG5
    mov     [rbp - 72], rax

    cmp     qword [rbp - 56], 64
    ja      .refuse
    cmp     rax, 64
    ja      .refuse

    mov     ARG1, [rbp - 40]
    mov     ARG2, SHAKE256_RATE
    mov     ARG3, CSHAKE_PAD
    call    cyboudb_sponge_init

    ; --- bytepad(encode_string("KMAC") || encode_string(S), 136) -------------
    lea     rbx, [rbp - KM_BLOCK]
    xor     rax, rax
    xor     rcx, rcx
.zero_a:
    mov     [rbx + rcx], rax
    add     rcx, 8
    cmp     rcx, SHAKE256_RATE          ; exactly one rate, and 136 is 17 qwords
    jb      .zero_a

    xor     rcx, rcx
    mov     r8, SHAKE256_RATE
    LEFT_ENCODE                         ; left_encode(w), the bytepad prefix

    mov     r8, KMAC_NAME_LEN * 8
    LEFT_ENCODE
    lea     r12, [kmac_name]
    xor     r13, r13
.copy_name:
    mov     al, [r12 + r13]
    mov     [rbx + rcx], al
    inc     rcx
    inc     r13
    cmp     r13, KMAC_NAME_LEN
    jb      .copy_name

    mov     r8, [rbp - 72]
    shl     r8, 3                       ; the length is in bits
    LEFT_ENCODE
    mov     r12, [rbp - 64]
    mov     r13, [rbp - 72]
    test    r13, r13
    jz      .name_done
.copy_custom:
    mov     al, [r12]
    mov     [rbx + rcx], al
    inc     rcx
    inc     r12
    dec     r13
    jnz     .copy_custom
.name_done:
    mov     ARG1, [rbp - 40]
    lea     ARG2, [rbp - KM_BLOCK]
    mov     ARG3, SHAKE256_RATE         ; zero-padded to the rate, as bytepad says
    call    cyboudb_sponge_absorb

    ; --- bytepad(encode_string(K), 136) --------------------------------------
    lea     rbx, [rbp - KM_BLOCK]
    xor     rax, rax
    xor     rcx, rcx
.zero_b:
    mov     [rbx + rcx], rax
    add     rcx, 8
    cmp     rcx, SHAKE256_RATE
    jb      .zero_b

    xor     rcx, rcx
    mov     r8, SHAKE256_RATE
    LEFT_ENCODE
    mov     r8, [rbp - 56]
    shl     r8, 3
    LEFT_ENCODE
    mov     r12, [rbp - 48]
    mov     r13, [rbp - 56]
    test    r13, r13
    jz      .key_done
.copy_key:
    mov     al, [r12]
    mov     [rbx + rcx], al
    inc     rcx
    inc     r12
    dec     r13
    jnz     .copy_key
.key_done:
    mov     ARG1, [rbp - 40]
    lea     ARG2, [rbp - KM_BLOCK]
    mov     ARG3, SHAKE256_RATE
    call    cyboudb_sponge_absorb

    xor     eax, eax
    jmp     .done
.refuse:
    mov     eax, CybouDB_E_STATE
.done:
    ; the block held the key
    lea     rbx, [rbp - KM_BLOCK]
    push    rax
    xor     rax, rax
    xor     rcx, rcx
.wipe:
    mov     [rbx + rcx], rax
    add     rcx, 8
    cmp     rcx, SHAKE256_RATE
    jb      .wipe
    pop     rax

    mov     rbx, [rbp - 8]
    mov     r12, [rbp - 16]
    mov     r13, [rbp - 24]
    FRAME_END
    ret

; =============================================================================
;  cyboudb_kmac256_update(ctx, in, in_len)
; =============================================================================
cyboudb_kmac256_update:
    jmp     cyboudb_sponge_absorb

; =============================================================================
;  cyboudb_kmac256_final(ctx, out, out_len)
;
;  right_encode(L) goes in last, which is what makes a KMAC of a given length
;  a different function from a KMAC of another length rather than a prefix of
;  it. A caller who wants 128 bits gets 128 bits of KMAC-128-bits, not the
;  first half of the 256-bit one.
; =============================================================================
cyboudb_kmac256_final:
    FRAME_BEGIN 96, 0
    mov     [rbp - 8], rbx
    mov     [rbp - 16], r12
    mov     [rbp - 24], r13

    mov     rbx, ARG1
    mov     r12, ARG2
    mov     r13, ARG3

    ; right_encode(out_len * 8): the value, then the number of bytes it took.
    ;
    ; The length is held in r10 and not in rdx. rdx is ARG2 under Win64, so
    ; "lea ARG2, [...]" then "mov ARG3, rdx" passes the buffer address as the
    ; length on Windows and works perfectly on Linux, where ARG2 is rsi. That
    ; is what the first version of this did, and it crashed on one platform
    ; only.
    mov     rax, r13
    shl     rax, 3
    lea     rcx, [rbp - 48]
    cmp     rax, 256
    jae     .two
    mov     [rcx], al
    mov     byte [rcx + 1], 1
    mov     r10, 2
    jmp     .absorb
.two:
    mov     r11, rax
    shr     r11, 8
    mov     [rcx], r11b
    mov     [rcx + 1], al
    mov     byte [rcx + 2], 2
    mov     r10, 3
.absorb:
    mov     ARG1, rbx
    lea     ARG2, [rbp - 48]
    mov     ARG3, r10
    call    cyboudb_sponge_absorb

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

; =============================================================================
;  cyboudb_kmac256(args) -> int
;
;  ARG1  const uint8_t *args   CybouDB_KMAC_ARGS_SIZE, laid out in crypto.inc
;
;  Seven values do not fit in registers, and a struct is how this file's
;  neighbours already pass that many.
; =============================================================================
cyboudb_kmac256:
    FRAME_BEGIN (CybouDB_SHCTX_SIZE + 64), 1
    mov     [rbp - 8], rbx
    mov     rbx, ARG1

    lea     ARG1, [rbp - (CybouDB_SHCTX_SIZE + 64)]
    mov     [rbp - 16], ARG1            ; the context, in this frame
    mov     ARG2, [rbx + KMAC_KEY]
    mov     ARG3, [rbx + KMAC_KEY_LEN]
    mov     ARG4, [rbx + KMAC_CUSTOM]
    mov     rax, [rbx + KMAC_CUSTOM_LEN]
    PASS_ARG5 rax
    call    cyboudb_kmac256_init
    test    eax, eax
    jnz     .done

    mov     ARG1, [rbp - 16]
    mov     ARG2, [rbx + KMAC_MSG]
    mov     ARG3, [rbx + KMAC_MSG_LEN]
    call    cyboudb_kmac256_update

    mov     ARG1, [rbp - 16]
    mov     ARG2, [rbx + KMAC_OUT]
    mov     ARG3, [rbx + KMAC_OUT_LEN]
    call    cyboudb_kmac256_final
    xor     eax, eax
.done:
    mov     rbx, [rbp - 8]
    FRAME_END
    ret

%ifdef CybouDB_LINUX
section .note.GNU-stack noalloc noexec nowrite progbits
%endif
