; Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
; SPDX-License-Identifier: Apache-2.0
; =============================================================================
;  crypto/kdf.asm - deriving keys, and wrapping them
; =============================================================================
;  docs/KEY_HIERARCHY.md, Decisions 2 and 3.
;
;  Derivation is KMAC256 used as a PRF, which is one of the two jobs NIST
;  SP 800-185 defines it for:
;
;      key = KMAC256( K = root,
;                     S = "CybouDB/0.7/" | label,
;                     X = context,
;                     L = length )
;
;  It was a prefix construction over SHAKE256 with a 0x00 separator after the
;  label, and the separator was doing real work - it is what stopped
;  "page-seal" with context "1" and "page-seal1" with no context from deriving
;  the same key. That is precisely the class of question KMAC's encodings
;  answer once and for everybody, by encoding every length rather than hoping
;  a separator covers each case someone thought of.
;
;  The change is not a bug fix. The old construction had no attack against it
;  that anyone here can show. It is a scope decision: this project implements
;  standard primitives, which another implementation can check, and does not
;  invent constructions, which nobody can.
;
;  The purpose is still a number from a closed list and the label still comes
;  from a table in this file. A caller cannot pass a string: a KDF whose label
;  is supplied from outside is an oracle wearing a helpful interface, and every
;  separation this hierarchy rests on would be the caller's discipline rather
;  than arithmetic.
;
;  Wrapping is the AEAD that already exists - a wrapped key is a sealed key -
;  with the key's identity as associated data, so a key for one scope does not
;  unwrap in another. No new construction, and therefore no new mistakes.
; =============================================================================

%include "cyboudb.inc"
%include "crypto.inc"

BITS 64
default rel

global cyboudb_kdf
global cyboudb_key_wrap
global cyboudb_key_unwrap

extern cyboudb_kmac256_init
extern cyboudb_kmac256_update
extern cyboudb_kmac256_final
extern cyboudb_xchacha20poly1305_seal
extern cyboudb_xchacha20poly1305_open
extern os_random

section .rodata
align 16
kdf_prefix:     db "CybouDB/0.7/"
kdf_prefix_len  equ $ - kdf_prefix

; One sixteen-byte row per purpose: a length, then the label. Indexed by
; (purpose - 1) * 16, so an unknown purpose cannot reach a row at all.
align 16
kdf_labels:
    db 12, "metadata-kek", 0, 0, 0
    db  9, "page-seal", 0, 0, 0, 0, 0, 0
    db  9, "seal-tree", 0, 0, 0, 0, 0, 0
    db  9, "scope-kek", 0, 0, 0, 0, 0, 0
    db  8, "manifest", 0, 0, 0, 0, 0, 0, 0

section .text

; --- frame ------------------------------------------------------------------
; Frame:
;    [rbp - 8]   out            [rbp - 40]  context
;    [rbp - 16]  out_len        [rbp - 48]  context length
;    [rbp - 24]  root           [rbp - 56]  how long the customization is
;    [rbp - 32]  the KMAC context pointer
;    [rbp - 128] the customization string: prefix and label, 24 bytes at most
;    [rbp - 384] the KMAC context
%define KD_OUT     8
%define KD_OUTLEN  16
%define KD_ROOT    24
%define KD_CTXPTR  32
%define KD_CTX     40
%define KD_CTXLEN  48
%define KD_LEN     56
%define KD_INPUT   128                  ; the customization string
%define KD_CTXBUF  384                  ; the KMAC context
%define KD_FRAME   448

; =============================================================================
;  cyboudb_kdf(out, out_len, purpose, root, context, context_len) -> EAX
;
;  ARG1  uint8_t       *out
;  ARG2  uint64_t       out_len
;  ARG3  uint64_t       purpose        one of KDF_*
;  ARG4  const uint8_t  root[32]
;  ARG5  const uint8_t *context        may be null when the length is zero
;  ARG6  uint64_t       context_len
;
;  Returns 0, or 1 for a purpose outside the list or a context that is too
;  long. Both are misuse rather than failure: nothing a caller does with a
;  correct hierarchy reaches them.
; =============================================================================
cyboudb_kdf:
    FRAME_BEGIN KD_FRAME, 2
%ifdef CybouDB_WINDOWS
    mov     rax, IN_ARG6
    mov     [rbp - KD_CTXLEN], rax
    mov     rax, IN_ARG5
    mov     [rbp - KD_CTX], rax
%else
    mov     [rbp - KD_CTXLEN], ARG6
    mov     [rbp - KD_CTX], ARG5
%endif
    mov     [rbp - KD_ROOT], ARG4
    mov     r10, ARG3                   ; purpose
    mov     [rbp - KD_OUTLEN], ARG2
    mov     [rbp - KD_OUT], ARG1

    ; --- what the list allows ------------------------------------------------
    test    r10, r10
    jz      .misuse
    cmp     r10, KDF_PURPOSE_MAX
    ja      .misuse
    cmp     qword [rbp - KD_CTXLEN], CybouDB_KDF_CONTEXT_MAX
    ja      .misuse

    ; --- the customization string: the prefix, then this purpose's label -----
    ;  Twelve bytes of prefix and at most twelve of label, so it is always
    ;  inside KMAC's 64-byte cap. The label still comes from the table and
    ;  never from a caller: a KDF whose label comes from outside is an oracle
    ;  with a helpful interface.
    lea     r11, [rbp - KD_INPUT]
    lea     rdx, [kdf_prefix]
    xor     rcx, rcx
.copy_prefix:
    cmp     rcx, kdf_prefix_len
    jae     .prefix_done
    mov     al, [rdx + rcx]
    mov     [r11 + rcx], al
    inc     rcx
    jmp     .copy_prefix
.prefix_done:

    dec     r10
    shl     r10, 4                      ; sixteen bytes a row
    lea     rdx, [kdf_labels]
    add     rdx, r10
    movzx   r9, byte [rdx]              ; the length in the first byte
    inc     rdx                         ; then the label itself

    xor     r8, r8
.copy_label:
    cmp     r8, r9
    jae     .label_done
    mov     al, [rdx + r8]
    mov     [r11 + rcx], al
    inc     rcx
    inc     r8
    jmp     .copy_label
.label_done:
    mov     [rbp - KD_LEN], rcx

    ; --- KMAC256(key = root, S = the label, X = the context) ------------------
    lea     rax, [rbp - KD_CTXBUF]
    mov     [rbp - KD_CTXPTR], rax
    mov     ARG1, rax
    mov     ARG2, [rbp - KD_ROOT]
    mov     ARG3, CybouDB_KDF_ROOT_SIZE
    lea     ARG4, [rbp - KD_INPUT]
    mov     rax, [rbp - KD_LEN]
    PASS_ARG5 rax
    call    cyboudb_kmac256_init
    test    eax, eax
    jnz     .misuse

    mov     ARG1, [rbp - KD_CTXPTR]
    mov     ARG2, [rbp - KD_CTX]
    mov     ARG3, [rbp - KD_CTXLEN]
    call    cyboudb_kmac256_update

    mov     ARG1, [rbp - KD_CTXPTR]
    mov     ARG2, [rbp - KD_OUT]
    mov     ARG3, [rbp - KD_OUTLEN]
    call    cyboudb_kmac256_final

    ; The KMAC context wipes itself at the end, and the customization is not a
    ; secret - but the frame is about to be somebody else's stack, so it goes
    ; out clean anyway.
    xor     rax, rax
    mov     rcx, KD_CTXBUF / 8
    lea     r11, [rbp - KD_CTXBUF]
.wipe:
    mov     [r11], rax
    add     r11, 8
    dec     rcx
    jnz     .wipe

    xor     eax, eax
    FRAME_END
    ret

.misuse:
    mov     eax, 1
    FRAME_END
    ret

; =============================================================================
;  cyboudb_key_wrap(out, kek, key, aad, aad_len) -> EAX
;
;  ARG1  uint8_t       *out[72]     nonce, then the sealed key, then the tag
;  ARG2  const uint8_t  kek[32]
;  ARG3  const uint8_t  key[32]     the key being wrapped, unchanged
;  ARG4  const uint8_t *aad         key id, scope, purpose, epoch
;  ARG5  uint64_t       aad_len
;
;  Returns 0, or 1 if the system's random source would not answer - which is a
;  refusal to wrap rather than a wrap with a nonce this code invented.
; =============================================================================
%define WR_ARGS    56                   ; the AEAD's argument struct
%define WR_OUT     64
%define WR_KEK     72
%define WR_KEY     80
%define WR_AAD     88
%define WR_AADLEN  96
%define WR_FRAME   128

cyboudb_key_wrap:
    FRAME_BEGIN WR_FRAME, 1

%ifdef CybouDB_WINDOWS
    mov     rax, IN_ARG5
%else
    mov     rax, ARG5
%endif
    mov     [rbp - WR_AADLEN], rax
    mov     [rbp - WR_AAD], ARG4
    mov     [rbp - WR_KEY], ARG3
    mov     [rbp - WR_KEK], ARG2
    mov     [rbp - WR_OUT], ARG1

    ; A nonce per wrap, from the system and not from here.
    mov     r10, [rbp - WR_OUT]
    lea     ARG1, [r10 + WRAP_NONCE]
    mov     ARG2, CybouDB_XAEAD_NONCE_SIZE
    call    os_random
    test    eax, eax
    jnz     .wrap_failed

    ; The key is sealed in place, so it is copied where the tag can cover it
    ; rather than encrypted in the caller's buffer.
    mov     r10, [rbp - WR_OUT]
    mov     r11, [rbp - WR_KEY]
    mov     rax, [r11]
    mov     [r10 + WRAP_CT], rax
    mov     rax, [r11 + 8]
    mov     [r10 + WRAP_CT + 8], rax
    mov     rax, [r11 + 16]
    mov     [r10 + WRAP_CT + 16], rax
    mov     rax, [r11 + 24]
    mov     [r10 + WRAP_CT + 24], rax

    mov     rax, [rbp - WR_KEK]
    mov     [rbp - WR_ARGS + AEAD_KEY], rax
    lea     rax, [r10 + WRAP_NONCE]
    mov     [rbp - WR_ARGS + AEAD_NONCE], rax
    mov     rax, [rbp - WR_AAD]
    mov     [rbp - WR_ARGS + AEAD_AAD], rax
    mov     rax, [rbp - WR_AADLEN]
    mov     [rbp - WR_ARGS + AEAD_AAD_LEN], rax
    lea     rax, [r10 + WRAP_CT]
    mov     [rbp - WR_ARGS + AEAD_BUF], rax
    mov     qword [rbp - WR_ARGS + AEAD_BUF_LEN], 32
    lea     rax, [r10 + WRAP_TAG]
    mov     [rbp - WR_ARGS + AEAD_TAG], rax

    lea     ARG1, [rbp - WR_ARGS]
    call    cyboudb_xchacha20poly1305_seal

    xor     eax, eax
    FRAME_END
    ret

.wrap_failed:
    mov     eax, 1
    FRAME_END
    ret

; =============================================================================
;  cyboudb_key_unwrap(key_out, kek, wrapped, aad, aad_len) -> EAX
;
;  Returns 0 when the key came back, and 1 when it did not - a wrong key, a
;  wrong scope, or bytes that were altered. The caller's buffer is left zero in
;  that case rather than holding a guess.
; =============================================================================
cyboudb_key_unwrap:
    FRAME_BEGIN WR_FRAME, 1

%ifdef CybouDB_WINDOWS
    mov     rax, IN_ARG5
%else
    mov     rax, ARG5
%endif
    mov     [rbp - WR_AADLEN], rax
    mov     [rbp - WR_AAD], ARG4
    mov     [rbp - WR_KEY], ARG3        ; the wrapped key
    mov     [rbp - WR_KEK], ARG2
    mov     [rbp - WR_OUT], ARG1        ; where the key goes

    ; The ciphertext is opened in the caller's buffer, so a refusal must leave
    ; it zero rather than half a key.
    mov     r10, [rbp - WR_OUT]
    mov     r11, [rbp - WR_KEY]
    mov     rax, [r11 + WRAP_CT]
    mov     [r10], rax
    mov     rax, [r11 + WRAP_CT + 8]
    mov     [r10 + 8], rax
    mov     rax, [r11 + WRAP_CT + 16]
    mov     [r10 + 16], rax
    mov     rax, [r11 + WRAP_CT + 24]
    mov     [r10 + 24], rax

    mov     rax, [rbp - WR_KEK]
    mov     [rbp - WR_ARGS + AEAD_KEY], rax
    lea     rax, [r11 + WRAP_NONCE]
    mov     [rbp - WR_ARGS + AEAD_NONCE], rax
    mov     rax, [rbp - WR_AAD]
    mov     [rbp - WR_ARGS + AEAD_AAD], rax
    mov     rax, [rbp - WR_AADLEN]
    mov     [rbp - WR_ARGS + AEAD_AAD_LEN], rax
    mov     [rbp - WR_ARGS + AEAD_BUF], r10
    mov     qword [rbp - WR_ARGS + AEAD_BUF_LEN], 32
    lea     rax, [r11 + WRAP_TAG]
    mov     [rbp - WR_ARGS + AEAD_TAG], rax

    lea     ARG1, [rbp - WR_ARGS]
    call    cyboudb_xchacha20poly1305_open
    test    eax, eax
    jnz     .unwrap_refused

    xor     eax, eax
    FRAME_END
    ret

.unwrap_refused:
    ; Not a key, and not the ciphertext either: a caller that ignores the
    ; return value gets zeroes rather than something that looks like a key.
    mov     r10, [rbp - WR_OUT]
    xor     rax, rax
    mov     [r10], rax
    mov     [r10 + 8], rax
    mov     [r10 + 16], rax
    mov     [r10 + 24], rax
    mov     eax, 1
    FRAME_END
    ret

%ifdef CybouDB_LINUX
section .note.GNU-stack noalloc noexec nowrite progbits
%endif
