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

; --- the associated data a sealed page is bound to ---------------------------
;  docs/ENCRYPTED_FORMAT.md, Decision 5. Forty-eight bytes, which is already a
;  multiple of sixteen - so the AEAD's padding step has nothing to pad, and the
;  MAC input for a 4096-byte page is 48 + 4096 + 16 with no gaps.
%define AAD_UUID        0               ; 16 bytes: the database's identity
%define AAD_PAGE_NO     16
%define AAD_GENERATION  24
%define AAD_PAGE_TYPE   32
%define AAD_SEAL_EPOCH  40
%define CybouDB_PAGE_AAD_SIZE 48

; --- what the AEAD produces and consumes ------------------------------------
%define CybouDB_AEAD_TAG_SIZE     16
%define CybouDB_AEAD_KEY_SIZE     32
%define CybouDB_AEAD_NONCE_SIZE   12    ; ChaCha20-Poly1305
%define CybouDB_XAEAD_NONCE_SIZE  24    ; XChaCha20-Poly1305, what the format uses

; --- key derivation ---------------------------------------------------------
;  docs/KEY_HIERARCHY.md, Decision 2. A purpose is a number in a closed list,
;  not a string a caller supplies: a KDF whose label comes from outside is an
;  oracle with a helpful interface. Adding one is a format change.
%define KDF_METADATA_KEK  1             ; wraps the data encryption keys
%define KDF_PAGE_SEAL     2             ; seals pages, one key per epoch
%define KDF_SEAL_TREE     3             ; the keyed tree over the seal directory
%define KDF_SCOPE_KEK     4             ; wraps one namespace's keys
%define KDF_MANIFEST      5             ; signs and verifies the access manifest
%define KDF_PURPOSE_MAX   5

%define CybouDB_KDF_ROOT_SIZE     32
%define CybouDB_KDF_CONTEXT_MAX   64    ; a scope id or an epoch, not a document

; --- a wrapped key ----------------------------------------------------------
;  Nonce, ciphertext and tag, in that order, because that is the order they are
;  produced in and a reader that gets the order wrong fails loudly rather than
;  quietly.
%define WRAP_NONCE   0                  ; 24 bytes, drawn per wrap
%define WRAP_CT      24                 ; the 32-byte key, sealed
%define WRAP_TAG     56                 ; 16
%define CybouDB_WRAPPED_KEY_SIZE 72

%endif ; CybouDB_CRYPTO_INC
