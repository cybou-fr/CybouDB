; Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
; SPDX-License-Identifier: Apache-2.0
; =============================================================================
;  crypto/aead.asm - sealing a page, and refusing one that was altered
; =============================================================================
;  RFC 8439 section 2.8 for the construction, draft-irtf-cfrg-xchacha for the
;  extended nonce. The cipher and the authenticator already exist; this is the
;  wiring that makes them an AEAD, and the wiring is where the mistakes live:
;
;    * the MAC key is the first 32 bytes of the keystream at counter 0, and the
;      data is encrypted from counter 1. Using the same counter for both would
;      hand the authentication key to anyone who can guess a plaintext byte;
;    * the associated data and the ciphertext are each padded to a multiple of
;      sixteen before the next piece starts, so that a byte moved from one into
;      the other changes the tag. Without the padding, an attacker chooses
;      where the boundary is;
;    * the two lengths go in at the end, for the same reason.
;
;  The nonce is 24 bytes: HChaCha20 turns the first sixteen into a subkey and
;  the last eight become the ChaCha20 nonce. That is what makes a random nonce
;  per page safe to draw rather than a counter that has to survive every crash
;  path - docs/ENCRYPTED_FORMAT.md, Decision 4.
;
;  Arguments arrive in a struct because there are seven of them and the second
;  calling convention puts everything past the fourth on the stack. One
;  pointer is cheaper to get right than four stack slots.
; =============================================================================

%include "cyboudb.inc"
%include "crypto.inc"

BITS 64
default rel

global cyboudb_chacha20poly1305_seal
global cyboudb_chacha20poly1305_open
global cyboudb_xchacha20poly1305_seal
global cyboudb_xchacha20poly1305_open

extern cyboudb_chacha20_xor
extern cyboudb_hchacha20
extern cyboudb_poly1305_init
extern cyboudb_poly1305_update
extern cyboudb_poly1305_finish

section .text

; --- frame, from rbp --------------------------------------------------------
%define AE_ARGS    8                    ; the caller's argument struct
%define AE_OTK     80                   ; 64 bytes: the keystream block at 0
%define AE_LENS    96                   ; 16 bytes: the two lengths
%define AE_ZERO    112                  ; 16 zero bytes, for padding
%define AE_TAG     144                  ; 16 bytes: the tag this computed
%define AE_SUBKEY  184                  ; 32 bytes, XChaCha20 only
%define AE_NONCE   200                  ; 12 bytes, XChaCha20 only
%define AE_INNER   264                  ; a nested argument struct
%define AE_CTX     (264 + CybouDB_POLY1305_CTX_SIZE)
%define AE_FRAME   (AE_CTX + 64)

; =============================================================================
;  seal / open, twelve-byte nonce. ARG1 = const cyboudb_aead_args *
;
;  seal: encrypts in place and writes the tag.
;  open: checks the tag first and decrypts only if it matched. Returns 0 when
;        the tag was right and 1 when it was not, and touches nothing on the
;        way out of the second case - a caller that ignores the result still
;        does not get plaintext.
; =============================================================================
cyboudb_chacha20poly1305_seal:
    FRAME_BEGIN AE_FRAME, 1
    mov     [rbp - AE_ARGS], ARG1

    call    aead_mac_key

    ; encrypt in place, from counter one
    mov     r11, [rbp - AE_ARGS]
    mov     ARG1, [r11 + AEAD_KEY]
    mov     ARG2d, 1
    mov     ARG3, [r11 + AEAD_NONCE]
    mov     ARG4, [r11 + AEAD_BUF]
    mov     rax, [r11 + AEAD_BUF_LEN]
%ifdef CybouDB_WINDOWS
    PASS_ARG5 rax
%else
    mov     ARG5, rax
%endif
    call    cyboudb_chacha20_xor

    call    aead_authenticate

    ; hand back the tag
    mov     r11, [rbp - AE_ARGS]
    mov     r10, [r11 + AEAD_TAG]
    mov     rax, [rbp - AE_TAG]
    mov     rdx, [rbp - AE_TAG + 8]
    mov     [r10], rax
    mov     [r10 + 8], rdx

    call    aead_wipe
    xor     eax, eax
    FRAME_END
    ret

cyboudb_chacha20poly1305_open:
    FRAME_BEGIN AE_FRAME, 1
    mov     [rbp - AE_ARGS], ARG1

    call    aead_mac_key
    call    aead_authenticate               ; over the ciphertext, before touching it

    ; Constant time: every byte is compared whatever the first one said.
    mov     r11, [rbp - AE_ARGS]
    mov     r10, [r11 + AEAD_TAG]
    mov     rax, [rbp - AE_TAG]
    xor     rax, [r10]
    mov     rdx, [rbp - AE_TAG + 8]
    xor     rdx, [r10 + 8]
    or      rax, rdx
    jnz     .open_refused

    mov     r11, [rbp - AE_ARGS]
    mov     ARG1, [r11 + AEAD_KEY]
    mov     ARG2d, 1
    mov     ARG3, [r11 + AEAD_NONCE]
    mov     ARG4, [r11 + AEAD_BUF]
    mov     rax, [r11 + AEAD_BUF_LEN]
%ifdef CybouDB_WINDOWS
    PASS_ARG5 rax
%else
    mov     ARG5, rax
%endif
    call    cyboudb_chacha20_xor

    call    aead_wipe
    xor     eax, eax
    FRAME_END
    ret

.open_refused:
    call    aead_wipe
    mov     eax, 1
    FRAME_END
    ret

; --- the one-time authentication key: keystream block zero -------------------
; -----------------------------------------------------------------------------
;  The three below are shared by seal and open and are therefore top-level
;  labels rather than .local ones: NASM binds a local label to whichever
;  top-level label came last, so seal calling `.mac_key` would have called a
;  symbol belonging to open.
;
;  They keep the caller's rbp - that is how they reach its locals - but they
;  must still fix the stack before calling anything themselves. The caller's
;  rsp was 16-byte aligned; the CALL that reached one of these pushed eight
;  bytes, so a further call from here would arrive misaligned and the first
;  MOVDQA against a frame slot in the cipher would fault. HELPER_ENTER takes
;  another 40: eight to realign and thirty-two of shadow space, which the
;  Win64 convention makes the caller's job.
; -----------------------------------------------------------------------------
%macro HELPER_ENTER 0
    sub     rsp, 40
%endmacro

%macro HELPER_LEAVE 0
    add     rsp, 40
%endmacro

aead_mac_key:
    HELPER_ENTER
    lea     r11, [rbp - AE_OTK]         ; 64 zero bytes to xor into
    xor     rax, rax
    mov     rcx, 8
aead_zero_otk:
    mov     [r11], rax
    add     r11, 8
    dec     rcx
    jnz     aead_zero_otk

    mov     r11, [rbp - AE_ARGS]
    mov     ARG1, [r11 + AEAD_KEY]
    xor     ARG2d, ARG2d                ; counter zero, and only for this
    mov     ARG3, [r11 + AEAD_NONCE]
    lea     ARG4, [rbp - AE_OTK]
    mov     rax, 64
%ifdef CybouDB_WINDOWS
    PASS_ARG5 rax
%else
    mov     ARG5, rax
%endif
    call    cyboudb_chacha20_xor
    HELPER_LEAVE
    ret

; --- aad || pad16 || ciphertext || pad16 || le64(aad) || le64(ciphertext) ----
aead_authenticate:
    HELPER_ENTER
    xor     rax, rax
    mov     [rbp - AE_ZERO], rax
    mov     [rbp - AE_ZERO + 8], rax

    lea     ARG1, [rbp - AE_CTX]
    lea     ARG2, [rbp - AE_OTK]        ; the first 32 bytes of the block
    call    cyboudb_poly1305_init

    mov     r11, [rbp - AE_ARGS]
    lea     ARG1, [rbp - AE_CTX]
    mov     ARG2, [r11 + AEAD_AAD]
    mov     ARG3, [r11 + AEAD_AAD_LEN]
    call    cyboudb_poly1305_update

    mov     r11, [rbp - AE_ARGS]
    mov     rax, [r11 + AEAD_AAD_LEN]
    and     rax, 15
    jz      aead_aad_aligned
    ; r10, not rcx: rcx is ARG1 under Win64, so `lea ARG1, ...` below would
    ; take the pad length with it and ARG3 would be handed a context pointer as
    ; a length. It did, and tests/abi_arg_lint.py could not see it until it
    ; learned that LEA sets an argument too.
    mov     r10, 16
    sub     r10, rax
    lea     ARG1, [rbp - AE_CTX]
    lea     ARG2, [rbp - AE_ZERO]
    mov     ARG3, r10
    call    cyboudb_poly1305_update
aead_aad_aligned:

    mov     r11, [rbp - AE_ARGS]
    lea     ARG1, [rbp - AE_CTX]
    mov     ARG2, [r11 + AEAD_BUF]
    mov     ARG3, [r11 + AEAD_BUF_LEN]
    call    cyboudb_poly1305_update

    mov     r11, [rbp - AE_ARGS]
    mov     rax, [r11 + AEAD_BUF_LEN]
    and     rax, 15
    jz      aead_buf_aligned
    ; r10, not rcx: rcx is ARG1 under Win64, so `lea ARG1, ...` below would
    ; take the pad length with it and ARG3 would be handed a context pointer as
    ; a length. It did, and tests/abi_arg_lint.py could not see it until it
    ; learned that LEA sets an argument too.
    mov     r10, 16
    sub     r10, rax
    lea     ARG1, [rbp - AE_CTX]
    lea     ARG2, [rbp - AE_ZERO]
    mov     ARG3, r10
    call    cyboudb_poly1305_update
aead_buf_aligned:

    mov     r11, [rbp - AE_ARGS]
    mov     rax, [r11 + AEAD_AAD_LEN]
    mov     [rbp - AE_LENS], rax
    mov     rax, [r11 + AEAD_BUF_LEN]
    mov     [rbp - AE_LENS + 8], rax

    lea     ARG1, [rbp - AE_CTX]
    lea     ARG2, [rbp - AE_LENS]
    mov     ARG3, 16
    call    cyboudb_poly1305_update

    lea     ARG1, [rbp - AE_CTX]
    lea     ARG2, [rbp - AE_TAG]
    call    cyboudb_poly1305_finish
    HELPER_LEAVE
    ret

; --- the one-time key is the secret worth the most here ----------------------
aead_wipe:
    xor     rax, rax
    lea     r11, [rbp - AE_OTK]
    mov     rcx, 8
aead_wipe_otk:
    mov     [r11], rax
    add     r11, 8
    dec     rcx
    jnz     aead_wipe_otk
    mov     [rbp - AE_TAG], rax
    mov     [rbp - AE_TAG + 8], rax
    ret

; =============================================================================
;  The twenty-four byte nonce: a subkey from the first sixteen, the last eight
;  as the nonce, and then exactly the construction above.
; =============================================================================
%macro XAEAD_PREPARE 0
    mov     [rbp - AE_ARGS], ARG1

    mov     r11, ARG1
    mov     ARG1, [r11 + AEAD_KEY]
    mov     ARG2, [r11 + AEAD_NONCE]    ; the first sixteen bytes
    lea     ARG3, [rbp - AE_SUBKEY]
    call    cyboudb_hchacha20

    ; the ChaCha20 nonce: four zero bytes, then the nonce's last eight
    xor     rax, rax
    mov     [rbp - AE_NONCE], rax
    mov     [rbp - AE_NONCE + 4], rax
    mov     r11, [rbp - AE_ARGS]
    mov     r10, [r11 + AEAD_NONCE]
    mov     rax, [r10 + 16]
    mov     [rbp - AE_NONCE + 4], rax

    ; an argument struct for the inner construction
    lea     rax, [rbp - AE_SUBKEY]
    mov     [rbp - AE_INNER + AEAD_KEY], rax
    lea     rax, [rbp - AE_NONCE]
    mov     [rbp - AE_INNER + AEAD_NONCE], rax
    mov     rax, [r11 + AEAD_AAD]
    mov     [rbp - AE_INNER + AEAD_AAD], rax
    mov     rax, [r11 + AEAD_AAD_LEN]
    mov     [rbp - AE_INNER + AEAD_AAD_LEN], rax
    mov     rax, [r11 + AEAD_BUF]
    mov     [rbp - AE_INNER + AEAD_BUF], rax
    mov     rax, [r11 + AEAD_BUF_LEN]
    mov     [rbp - AE_INNER + AEAD_BUF_LEN], rax
    mov     rax, [r11 + AEAD_TAG]
    mov     [rbp - AE_INNER + AEAD_TAG], rax
%endmacro

%macro XAEAD_WIPE 0
    xor     rax, rax
    mov     [rbp - AE_SUBKEY], rax
    mov     [rbp - AE_SUBKEY + 8], rax
    mov     [rbp - AE_SUBKEY + 16], rax
    mov     [rbp - AE_SUBKEY + 24], rax
%endmacro

cyboudb_xchacha20poly1305_seal:
    FRAME_BEGIN AE_FRAME, 1
    XAEAD_PREPARE
    lea     ARG1, [rbp - AE_INNER]
    call    cyboudb_chacha20poly1305_seal
    XAEAD_WIPE
    xor     eax, eax
    FRAME_END
    ret

cyboudb_xchacha20poly1305_open:
    FRAME_BEGIN AE_FRAME, 1
    XAEAD_PREPARE
    lea     ARG1, [rbp - AE_INNER]
    call    cyboudb_chacha20poly1305_open
    mov     r10d, eax
    XAEAD_WIPE
    mov     eax, r10d
    FRAME_END
    ret

%ifdef CybouDB_LINUX
section .note.GNU-stack noalloc noexec nowrite progbits
%endif
