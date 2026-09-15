; Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
; SPDX-License-Identifier: Apache-2.0
; =============================================================================
;  crypto/crypto_status.asm - what an encrypted database tells the person
;                             holding the key
; =============================================================================
;  Two functions, no dependencies, and one rule between them: a refusal that a
;  reader could reach without a key is never reported as a key problem, and a
;  refusal that needed a key is never reported as damage.
;
;  The second half is the one that matters in practice. A database that will
;  not open is frightening, and the sentence the engine picks decides what the
;  person does next. "Damaged" sends someone to their backups, to recovery
;  tools, to a support thread about a corrupt file - for a file that is
;  byte-perfect and simply locked with a different key than the one offered.
;  0.6 drew this line once already, between a capability refusal and damage;
;  this is the same line drawn again where a key is involved.
; =============================================================================

%include "cyboudb.inc"
%include "crypto.inc"

BITS 64
default rel

global cyboudb_crypto_root_status
global cyboudb_key_status

section .text

; =============================================================================
;  cyboudb_crypto_root_status(croot_err) -> a CybouDB_E_* code
;
;  The validator speaks in structural terms; a user is owed a sentence. This
;  is the single place the two are joined, so the engine cannot acquire a
;  second opinion about what a malformed crypto root means.
;
;    magic, geometry, slots, reserved -> E_CRYPTO_ROOT  the metadata is wrong
;    crc                              -> E_CRYPTO_CRC   the page is damaged
;    version, aead, kdf               -> E_FEATURES     a file from a build
;                                                       that knows more
;
;  None of them is E_KEY, and that is the property worth stating: nothing a
;  reader can determine without a key is ever reported as a key problem.
; =============================================================================
cyboudb_crypto_root_status:
    mov     eax, ARG1d
    cmp     eax, CROOT_OK
    je      .none
    cmp     eax, CROOT_E_CRC
    je      .crc
    cmp     eax, CROOT_E_VERSION
    je      .features
    cmp     eax, CROOT_E_AEAD
    je      .features
    cmp     eax, CROOT_E_KDF
    je      .features
    ; Everything else, including a code from a future validator this build has
    ; not heard of, is "the encryption metadata is wrong" - which is true of an
    ; unknown structural refusal too.
    mov     eax, CybouDB_E_CRYPTO_ROOT
    ret
.crc:
    mov     eax, CybouDB_E_CRYPTO_CRC
    ret
.features:
    mov     eax, CybouDB_E_FEATURES
    ret
.none:
    xor     eax, eax
    ret

; =============================================================================
;  cyboudb_key_status(unwrap_rc) -> 0, or CybouDB_E_KEY
;
;  Every failed unwrap, without exception and without inspection. An AEAD tag
;  that does not verify looks identical whether the key was wrong, a bit was
;  flipped, or someone edited the file; the engine cannot tell, so it says the
;  one thing that is safe to say and does not accuse the disk.
; =============================================================================
cyboudb_key_status:
    xor     eax, eax
    test    ARG1d, ARG1d
    jz      .ok
    mov     eax, CybouDB_E_KEY
.ok:
    ret
