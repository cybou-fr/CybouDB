; Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
; SPDX-License-Identifier: Apache-2.0
; =============================================================================
;  crypto/kdf.asm - deriving keys, and wrapping them
; =============================================================================
;  docs/KEY_HIERARCHY.md, Decisions 2 and 3.
;
;  Derivation is a one-step KDF over SHAKE256, in the shape NIST SP 800-56C
;  describes: the derived key is the sponge output of a fixed prefix, the
;  purpose, the root, and the context.
;
;      key = SHAKE256( "CybouDB/0.7/" | label | 0x00 | root | context , length )
;
;  The purpose is a number from a closed list and the label comes from a table
;  here. A caller cannot pass a string: a KDF whose label is supplied from
;  outside is an oracle wearing a helpful interface, and every separation this
;  hierarchy rests on would be the caller's discipline rather than arithmetic.
;
;  The 0x00 after the label is what stops "page-seal" with context "1" and
;  "page-seal1" with no context deriving the same key. It costs one byte and
;  removes a whole class of question.
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

extern cyboudb_shake256
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
%define KD_INPUT   192                  ; prefix, label, 0x00, root, context
%define KD_LEN     200                  ; how much of it is used
%define KD_OUT     208
%define KD_OUTLEN  216
%define KD_ROOT    224
%define KD_CTX     232
%define KD_CTXLEN  240
%define KD_FRAME   256

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
    FRAME_BEGIN KD_FRAME, 0

    ; Arguments last to first, into registers no argument aliases.
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

    ; --- the prefix ----------------------------------------------------------
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
    mov     [rbp - KD_LEN], rcx

    ; --- the label for this purpose ------------------------------------------
    dec     r10
    shl     r10, 4                      ; sixteen bytes a row
    lea     rdx, [kdf_labels]
    add     rdx, r10
    movzx   r9, byte [rdx]              ; the length in the first byte
    inc     rdx                         ; then the label itself

    mov     rcx, [rbp - KD_LEN]
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
    mov     byte [r11 + rcx], 0         ; the separator
    inc     rcx

    ; --- the root ------------------------------------------------------------
    mov     rdx, [rbp - KD_ROOT]
    xor     r8, r8
.copy_root:
    cmp     r8, CybouDB_KDF_ROOT_SIZE
    jae     .root_done
    mov     al, [rdx + r8]
    mov     [r11 + rcx], al
    inc     rcx
    inc     r8
    jmp     .copy_root
.root_done:

    ; --- and the context, if there is one -------------------------------------
    mov     r9, [rbp - KD_CTXLEN]
    test    r9, r9
    jz      .input_ready
    mov     rdx, [rbp - KD_CTX]
    xor     r8, r8
.copy_ctx:
    cmp     r8, r9
    jae     .input_ready
    mov     al, [rdx + r8]
    mov     [r11 + rcx], al
    inc     rcx
    inc     r8
    jmp     .copy_ctx

.input_ready:
    mov     [rbp - KD_LEN], rcx

    mov     ARG4, rcx
    lea     ARG3, [rbp - KD_INPUT]
    mov     ARG2, [rbp - KD_OUTLEN]
    mov     ARG1, [rbp - KD_OUT]
    call    cyboudb_shake256

    ; The input holds the root. Nothing of it stays in this frame.
    xor     rax, rax
    mov     rcx, KD_INPUT / 8
    lea     r11, [rbp - KD_INPUT]
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
