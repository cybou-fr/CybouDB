; Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
; SPDX-License-Identifier: Apache-2.0
; =============================================================================
;  include/crypto.inc - the shape of the page seal's working state
; =============================================================================
;  The AEAD needs Poly1305 over three pieces that are not next to each other in
;  memory - the associated data, the ciphertext, and the two lengths - so the
;  authenticator needs a context that survives between them rather than the
;  one-shot the first version had. This is that context's layout, shared by
;  src/crypto/poly1305.asm and src/crypto/aead.asm.
;
;  The caller owns the memory. Nothing here allocates.
; =============================================================================

%ifndef CybouDB_CRYPTO_INC
%define CybouDB_CRYPTO_INC

; --- Poly1305 streaming context ---------------------------------------------
;  Each power of r is five qwords: r0, r1, r2, then r1*20 and r2*20, which is
;  the 2^130 = 5 reduction folded into the multiply.
%define PCTX_R        0                 ; r
%define PCTX_R2       40                ; r^2
%define PCTX_R3       80                ; r^3
%define PCTX_R4       120               ; r^4
%define PCTX_ACC      160               ; four accumulators, three limbs each
%define PCTX_PAD0     256
%define PCTX_PAD1     264
%define PCTX_BUF      272               ; up to 63 bytes not yet in a group
%define PCTX_LEFT     336               ; how many of them there are
%define CybouDB_POLY1305_CTX_SIZE 352

; --- the AEAD's argument struct ---------------------------------------------
;  Seven arguments, and the second calling convention puts everything past the
;  fourth on the stack. One pointer is cheaper to get right than four stack
;  slots, and the C header declares the same fields in the same order.
%define AEAD_KEY       0                ; const uint8_t *, 32 bytes
%define AEAD_NONCE     8                ; const uint8_t *, 12 or 24 bytes
%define AEAD_AAD       16               ; const uint8_t *, may be null if empty
%define AEAD_AAD_LEN   24
%define AEAD_BUF       32               ; uint8_t *, sealed or opened in place
%define AEAD_BUF_LEN   40
%define AEAD_TAG       48               ; uint8_t *, written by seal, read by open
%define CybouDB_AEAD_ARGS_SIZE 56

; --- what the AEAD produces and consumes ------------------------------------
%define CybouDB_AEAD_TAG_SIZE     16
%define CybouDB_AEAD_KEY_SIZE     32
%define CybouDB_AEAD_NONCE_SIZE   12    ; ChaCha20-Poly1305
%define CybouDB_XAEAD_NONCE_SIZE  24    ; XChaCha20-Poly1305, what the format uses

%endif ; CybouDB_CRYPTO_INC
