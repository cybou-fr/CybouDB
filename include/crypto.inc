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

; =============================================================================
;  THE CRYPTO ROOT PAGE - what feature_root points at
; =============================================================================
;  docs/ENCRYPTED_FORMAT.md, Decision 6. One page, named by SB_FEATURE_ROOT,
;  holding everything an opener needs before it can read anything else: which
;  primitives sealed this file, the salt the root key is derived with, which
;  epoch the page seals are under, where the seal directory lives, and the
;  wrapped keys themselves.
;
;  It is not sealed as a whole, and that is deliberate rather than an omission:
;
;    * the salt, the algorithm ids and the geometry have to be legible before
;      any key exists, so encrypting them would be circular;
;    * the wrapped keys carry their own tags already, each bound by associated
;      data to the file uuid, the key id and the epoch, so altering one is
;      caught by the unwrap that follows;
;    * everything else is authenticated by CRYPTO_MAC, a tag over bytes
;      [0, CRYPTO_MAC) computed under KDF(KDF_METADATA_KEK, root,
;      "crypto-root") - derived from the root key, so it can only be checked
;      after the root key is in hand, which is exactly when the geometry
;      starts to matter.
;
;  The CRC is not the authentication and never claims to be. It is here for
;  the same reason the superblock's is: to tell a torn write apart from an
;  attack, cheaply, before any crypto runs.
;
;  Offset  Size  Field              Description
;  ------  ----  -----------------  ----------------------------------------
;    +0      4   magic              'ASQK'
;    +4      4   version            1
;    +8      8   seal_epoch         which page-seal key the payload is under
;   +16      4   aead_id            which AEAD sealed this file
;   +20      4   kdf_id             which KDF derived its keys
;   +24      8   seal_dir_first     first page of seal directory copy A
;   +32      8   seal_dir_pages     S, the leaves in one copy
;   +40      8   seal_tree_root     page holding the root node of Decision 3b
;   +48      8   manifest_root      0 until step 10
;   +56      8   total_pages        the file this root was written for
;   +64     32   salt               public, and required before anything opens
;   +96     72   wrapped_root       the database root key under the user's KEK
;  +168      4   slot_count         wrapped scoped DEKs that follow
;  +172      4   reserved           zero
;  +176    3840  slots              40 x CRYPTO_SLOT_SIZE
; +4016     16   reserved_tail      zero
; +4032     16   mac                over [0, 4032)
; +4048     44   reserved_pad       zero
; +4092      4   crc32c             over [0, 4092)
;  ------  ----
;   total  4096
;
;  One slot:
;
;    +0      8   key_id             non-zero and unique within the page
;    +8      4   purpose            a KDF purpose, from the closed list
;   +12      4   flags              zero today
;   +16     72   wrapped            nonce, ciphertext, tag
;   +88      8   reserved           zero
;   total   96
; =============================================================================

%define CybouDB_CROOT_MAGIC    0x4B515341    ; 'A','S','Q','K' little-endian
%define CybouDB_CROOT_VERSION  1

%define CROOT_MAGIC          0
%define CROOT_VERSION        4
%define CROOT_SEAL_EPOCH     8
%define CROOT_AEAD_ID        16
%define CROOT_KDF_ID         20
%define CROOT_SEAL_DIR_FIRST 24
%define CROOT_SEAL_DIR_PAGES 32
%define CROOT_SEAL_TREE_ROOT 40
%define CROOT_MANIFEST_ROOT  48
%define CROOT_TOTAL_PAGES    56
%define CROOT_SALT           64
%define CROOT_SALT_SIZE      32
%define CROOT_WRAPPED_ROOT   96
%define CROOT_SLOT_COUNT     168
%define CROOT_RESERVED       172
%define CROOT_SLOTS          176
%define CROOT_RESERVED_TAIL  4016
%define CROOT_MAC            4032
%define CROOT_MAC_LEN        CROOT_MAC     ; the tag covers everything before it
%define CROOT_RESERVED_PAD   4048
%define CROOT_CRC            4092
%define CROOT_CRC_LEN        CROOT_CRC

%define CROOT_SLOT_SIZE      96
%define CybouDB_CROOT_SLOT_MAX 40

%define CSLOT_KEY_ID         0
%define CSLOT_PURPOSE        8
%define CSLOT_FLAGS          12
%define CSLOT_WRAPPED        16
%define CSLOT_RESERVED       88

; --- which primitives, by number --------------------------------------------
;  docs/CRYPTO_BACKEND.md: the file records which AEAD sealed it, so a later
;  build can refuse by name instead of guessing. One value each today; a
;  second one is a format change and gets a number, never a reinterpretation
;  of this one.
%define CROOT_AEAD_XCHACHA20_POLY1305  1
%define CROOT_KDF_SHAKE256             1

; --- what a malformed crypto root is refused with ---------------------------
;  Structural refusals only: every one of these is answerable before a key
;  exists, and none of them means the key was wrong. That distinction is the
;  whole point of a separate validator - a database that will not open must be
;  able to say which of *this is not a CybouDB crypto root*, *this file is
;  damaged*, and *this key does not open this file* is true.
%define CROOT_OK             0
%define CROOT_E_MAGIC        1          ; not a crypto root page at all
%define CROOT_E_VERSION      2          ; a crypto root a later build wrote
%define CROOT_E_CRC          3          ; damage, not an attack and not a key
%define CROOT_E_AEAD         4          ; sealed with an AEAD this build lacks
%define CROOT_E_KDF          5          ; derived with a KDF this build lacks
%define CROOT_E_GEOMETRY     6          ; the seal directory cannot be where it says
%define CROOT_E_SLOTS        7          ; the slot table contradicts itself
%define CROOT_E_RESERVED     8          ; a reserved field is not zero

%endif ; CybouDB_CRYPTO_INC
