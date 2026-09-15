; Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
; SPDX-License-Identifier: Apache-2.0
; =============================================================================
;  core/encrypted_open.asm - what the engine does before it can read a page
; =============================================================================
;  docs/ENCRYPTED_ENGINE.md. The resolver knows how to fetch an encrypted page
;  given a context with keys in it. This is what puts them there.
;
;  The order is forced, and it is worth reading once because every step of it
;  is a thing that must already be true before the next one can happen:
;
;      1. the header, plaintext         the file's identity, and the bit that
;                                       says it is encrypted at all
;      2. the superblock, plaintext     which generation is live, and where
;         with its CRC checked          the crypto root is. It cannot be
;                                       encrypted: recovery has to choose
;                                       between two copies before it knows
;                                       which key anything is under
;      3. the crypto root               the seal epoch, the directory's
;                                       geometry, and where the key slots are
;      4. a key slot                    decapsulated with the caller's private
;                                       key: this is the first step that needs
;                                       a secret, and the first that can say
;                                       "this key does not open this file"
;      5. the hierarchy                 metadata, page seal and seal tree keys
;      6. the superblock's tag          verified NOW, with the key that step 5
;                                       produced. Until this point everything
;                                       read has been believed on a checksum
;
;  Step 6 is the one that makes the rest of it mean anything. A checksum says
;  the disk did not lie; the tag says nobody did. The seal tree root the
;  superblock carries is only as good as the superblock, and the superblock is
;  only as good as this check.
; =============================================================================

%include "cyboudb.inc"
%include "crypto.inc"

BITS 64
default rel

global db_encrypted_attach

extern vfs_read_at
extern crc32c
extern cyboudb_crypto_root_validate
extern cyboudb_keypage_validate
extern cyboudb_keypage_find
extern cyboudb_kem_key_id
extern cyboudb_kem_open_root
extern cyboudb_kdf
extern cyboudb_kmac256_init
extern cyboudb_kmac256_update
extern cyboudb_kmac256_final
extern cyboudb_pcache_init

; The encryption bit is NOT in include/format.inc, and that is deliberate:
; docs/ENCRYPTED_ENGINE.md keeps it out of the normative header until the whole
; chain works through the engine, because the first file in the world carrying
; it is a public commitment. Until then it lives here, where only this file and
; the tests that build encrypted files can see it.
%define CybouDB_FEATURE_ENCRYPTION 131072

section .rodata
sb_label: db "CybouDB/0.7/superblock"
SB_LABEL_LEN equ $ - sb_label

section .text

;  Frame. Every value has a slot and a name, and the arrays are clear of the
;  argument slots and of each other:
;
;   [rbp - 8 .. - 40]  saved rbx, r12, r13, r14, r15
;   [rbp - 48] ctx     [rbp - 56] dk      [rbp - 64] cache memory
;   [rbp - 72] cache bytes               [rbp - 80] frames
;   [rbp - 88] the key id this private key belongs to
;   [rbp - 160] the root key, 32 bytes, wiped before this returns
;   [rbp - 224] the metadata key, 32, wiped with it
;   [rbp - 256] the associated data a key slot is bound to, 24
;   [rbp - 288] the tag the superblock carries, 16
;   [rbp - 320] the tag computed from the file, 16
;   [rbp - 448] the superblock bytes the tag covers, 64
;   [rbp - 704] the KMAC context, 232
;   [rbp - 4864] one page: header, then superblock, then crypto root, then key
;                slots - none of them needed once the next is read
%define EA_ROOTKEY  160
%define EA_METAKEY  224
%define EA_AAD      256
%define EA_TAG      288
%define EA_WANT     320
%define EA_COVER    448
%define EA_KMAC     704
%define EA_PAGE     4864
%define EA_FRAME    4928

; =============================================================================
;  db_encrypted_attach(ctx, dk, cache_mem, cache_bytes, frames) -> int
;
;  ARG1  uint8_t *ctx          a context whose handle is already open
;  ARG2  const uint8_t *dk     2400 bytes of decapsulation key
;  ARG3  uint8_t *cache_mem    page-aligned, for the plaintext cache
;  ARG4  uint64_t cache_bytes
;  ARG5  uint64_t frames
; =============================================================================
db_encrypted_attach:
    FRAME_BEGIN EA_FRAME, 2
    mov     [rbp - 8], rbx
    mov     [rbp - 16], r12
    mov     [rbp - 24], r13
    mov     [rbp - 32], r14
    mov     [rbp - 40], r15

    mov     [rbp - 48], ARG1
    mov     [rbp - 56], ARG2
    mov     [rbp - 64], ARG3
    mov     [rbp - 72], ARG4
    mov     rax, IN_ARG5
    mov     [rbp - 80], rax

    mov     rbx, [rbp - 48]

    ; --- 1. the header ------------------------------------------------------
    mov     ARG1, [rbx + DB_HANDLE]
    lea     ARG2, [rbp - EA_PAGE]
    mov     ARG3, CybouDB_PAGE_SIZE
    xor     ARG4, ARG4
    call    vfs_read_at
    cmp     rax, CybouDB_PAGE_SIZE
    jne     .damaged

    mov     rax, [rbp - EA_PAGE + HDR_FLAGS_INCOMPAT]
    test    rax, CybouDB_FEATURE_ENCRYPTION
    jz      .not_encrypted

    ; the file's identity, which every page's associated data is bound to
    mov     rbx, [rbp - 48]
    mov     rax, [rbp - EA_PAGE + HDR_UUID]
    mov     [rbx + DB_UUID], rax
    mov     rax, [rbp - EA_PAGE + HDR_UUID + 8]
    mov     [rbx + DB_UUID + 8], rax

    ; --- 2. the superblock ---------------------------------------------------
    ;  The live one has already been chosen by the ordinary open path, which
    ;  compared generations and checksums without needing a key. Its page
    ;  number is in the context.
    mov     rax, [rbx + DB_SB_PAGE]
    shl     rax, CybouDB_PAGE_SHIFT
    mov     ARG1, [rbx + DB_HANDLE]
    lea     ARG2, [rbp - EA_PAGE]
    mov     ARG3, CybouDB_PAGE_SIZE
    mov     ARG4, rax
    call    vfs_read_at
    cmp     rax, CybouDB_PAGE_SIZE
    jne     .damaged

    ; where the crypto root lives, and which generation is live
    mov     rbx, [rbp - 48]
    mov     r14, [rbp - EA_PAGE + SB_FEATURE_ROOT]
    test    r14, r14
    jz      .no_crypto_root
    mov     rax, [rbp - EA_PAGE + SB_GENERATION]
    mov     [rbx + DB_GENERATION], rax

    ; the superblock's tag, kept for step 6 - the page itself is about to be
    ; overwritten by the next read
    mov     rax, [rbp - EA_PAGE + SB_SEAL_TAG]
    mov     [rbp - EA_TAG], rax
    mov     rax, [rbp - EA_PAGE + SB_SEAL_TAG + 8]
    mov     [rbp - EA_TAG + 8], rax
    ; and the bytes it covers
    lea     r10, [rbp - EA_COVER]
    lea     r11, [rbp - EA_PAGE]
    xor     rcx, rcx
.copy_covered:
    mov     rax, [r11 + rcx]
    mov     [r10 + rcx], rax
    add     rcx, 8
    cmp     rcx, SB_SEAL_TAG_COVERS
    jb      .copy_covered

    ; --- 3. the crypto root --------------------------------------------------
    mov     rax, r14
    shl     rax, CybouDB_PAGE_SHIFT
    mov     ARG1, [rbx + DB_HANDLE]
    lea     ARG2, [rbp - EA_PAGE]
    mov     ARG3, CybouDB_PAGE_SIZE
    mov     ARG4, rax
    call    vfs_read_at
    cmp     rax, CybouDB_PAGE_SIZE
    jne     .damaged

    lea     ARG1, [rbp - EA_PAGE]
    call    cyboudb_crypto_root_validate
    test    eax, eax
    jnz     .crypto_root_bad

    mov     rbx, [rbp - 48]
    mov     rax, [rbp - EA_PAGE + CROOT_SEAL_EPOCH]
    mov     [rbx + DB_SEAL_EPOCH], rax
    mov     rax, [rbp - EA_PAGE + CROOT_SEAL_DIR_FIRST]
    mov     rcx, [rbp - EA_PAGE + CROOT_SEAL_DIR_PAGES]
    cmp     qword [rbx + DB_SB_PAGE], CybouDB_SB_PAGE_B
    jne     .seal_copy_selected
    add     rax, rcx                    ; superblock B owns copy B
.seal_copy_selected:
    mov     [rbx + DB_SEAL_DIR], rax    ; active copy's first leaf
    dec     rcx                         ; depth one: one root after the leaves
    mov     [rbx + DB_SEAL_LEAVES], rcx
    mov     r15, [rbp - EA_PAGE + CROOT_KEM_ROOT]
    test    r15, r15
    jz      .no_key_slots

    ; --- 4. the key slot -----------------------------------------------------
    mov     rax, r15
    shl     rax, CybouDB_PAGE_SHIFT
    mov     ARG1, [rbx + DB_HANDLE]
    lea     ARG2, [rbp - EA_PAGE]
    mov     ARG3, CybouDB_PAGE_SIZE
    mov     ARG4, rax
    call    vfs_read_at
    cmp     rax, CybouDB_PAGE_SIZE
    jne     .damaged

    lea     ARG1, [rbp - EA_PAGE]
    call    cyboudb_keypage_validate
    test    eax, eax
    jnz     .crypto_root_bad

    ; which slot might be ours: the key id of the public key this private key
    ; belongs to. The decapsulation key carries its own public key, which is
    ; what FIPS 203 puts in it.
    mov     rbx, [rbp - 48]
    mov     ARG1, 0
    mov     ARG2, [rbp - 56]
    add     ARG2, CybouDB_MLKEM_DK_EK_OFFSET        ; ek lives inside dk
    call    cyboudb_kem_key_id
    mov     [rbp - 88], rax

    lea     ARG1, [rbp - EA_PAGE]
    mov     ARG2, [rbp - 88]
    call    cyboudb_keypage_find
    test    rax, rax
    jz      .no_slot
    mov     r12, rax                            ; the slot

    ; the associated data a slot is bound to: this file, and this key id
    mov     rbx, [rbp - 48]
    lea     r10, [rbp - EA_AAD]
    mov     rax, [rbx + DB_UUID]
    mov     [r10], rax
    mov     rax, [rbx + DB_UUID + 8]
    mov     [r10 + 8], rax
    mov     rax, [rbp - 88]
    mov     [r10 + 16], rax

    lea     ARG1, [rbp - EA_ROOTKEY]
    mov     ARG2, r12
    mov     ARG3, [rbp - 56]
    lea     ARG4, [rbp - EA_AAD]
    mov     rax, 24
    PASS_ARG5 rax
    call    cyboudb_kem_open_root
    test    eax, eax
    jnz     .wrong_key

    ; --- 5. the hierarchy ----------------------------------------------------
    mov     rbx, [rbp - 48]
    lea     ARG1, [rbx + DB_SEAL_KEY]
    mov     ARG2, 32
    mov     ARG3, KDF_PAGE_SEAL
    lea     ARG4, [rbp - EA_ROOTKEY]
    lea     rax, [rbx + DB_SEAL_EPOCH]
    PASS_ARG5 rax
    mov     rax, 8
    PASS_ARG6 rax
    call    cyboudb_kdf
    test    eax, eax
    jnz     .crypto_root_bad

    ; the seal tree key, which every commit needs to re-MAC the directory
    lea     ARG1, [rbx + DB_TREE_KEY]
    mov     ARG2, 32
    mov     ARG3, KDF_SEAL_TREE
    lea     ARG4, [rbp - EA_ROOTKEY]
    lea     rax, [rbx + DB_SEAL_EPOCH]
    PASS_ARG5 rax
    mov     rax, 8
    PASS_ARG6 rax
    call    cyboudb_kdf
    test    eax, eax
    jnz     .crypto_root_bad
    mov     rbx, [rbp - 48]

    ; the metadata key goes into the context: every commit needs it, and the
    ; root key it comes from is about to be wiped
    lea     ARG1, [rbx + DB_META_KEY]
    mov     ARG2, 32
    mov     ARG3, KDF_METADATA_KEK
    lea     ARG4, [rbp - EA_ROOTKEY]
    xor     rax, rax
    PASS_ARG5 rax
    xor     rax, rax
    PASS_ARG6 rax
    call    cyboudb_kdf
    test    eax, eax
    jnz     .crypto_root_bad

    ; --- 6. and now the superblock is checked --------------------------------
    mov     rbx, [rbp - 48]
    lea     ARG1, [rbp - EA_KMAC]
    lea     ARG2, [rbx + DB_META_KEY]
    mov     ARG3, 32
    lea     ARG4, [sb_label]
    mov     rax, SB_LABEL_LEN
    PASS_ARG5 rax
    call    cyboudb_kmac256_init
    test    eax, eax
    jnz     .crypto_root_bad

    lea     ARG1, [rbp - EA_KMAC]
    lea     ARG2, [rbp - EA_COVER]
    mov     ARG3, SB_SEAL_TAG_COVERS
    call    cyboudb_kmac256_update

    lea     ARG1, [rbp - EA_KMAC]
    lea     ARG2, [rbp - EA_WANT]
    mov     ARG3, SB_SEAL_TAG_SIZE
    call    cyboudb_kmac256_final

    mov     rax, [rbp - EA_WANT]
    xor     rax, [rbp - EA_TAG]
    mov     rdx, [rbp - EA_WANT + 8]
    xor     rdx, [rbp - EA_TAG + 8]
    or      rax, rdx
    jnz     .superblock_forged

    ; --- the cache, and the switch the page macro branches on ----------------
    mov     ARG1, [rbp - 64]
    mov     ARG2, [rbp - 72]
    mov     ARG3, [rbp - 80]
    call    cyboudb_pcache_init
    test    eax, eax
    jnz     .bad_cache

    mov     rbx, [rbp - 48]
    mov     rax, [rbp - 64]
    mov     [rbx + DB_CACHE], rax       ; from here the engine reads through it
    mov     qword [rbx + DB_ENC_ERROR], 0
    xor     eax, eax
    jmp     .done

.clear_and_fail:
    ; A context that failed to attach must not keep a key. Anything that
    ; derived one before the refusal leaves it here otherwise, and a caller
    ; retrying with a different key would be running with half of the last
    ; attempt still in place.
    mov     rbx, [rbp - 48]
    xor     rcx, rcx
    xor     r11, r11
.clear_meta:
    mov     [rbx + DB_META_KEY + rcx], r11
    mov     [rbx + DB_TREE_KEY + rcx], r11
    mov     [rbx + DB_SEAL_KEY + rcx], r11
    add     rcx, 8
    cmp     rcx, 32
    jb      .clear_meta
    mov     eax, r10d
    jmp     .done

.not_encrypted:
    mov     eax, CybouDB_E_STATE
    jmp     .done
.no_crypto_root:
.no_key_slots:
.crypto_root_bad:
    mov     r10d, CybouDB_E_CRYPTO_ROOT
    jmp     .clear_and_fail
.no_slot:
.wrong_key:
    mov     r10d, CybouDB_E_KEY
    jmp     .clear_and_fail
.superblock_forged:
    mov     r10d, CybouDB_E_SEAL
    jmp     .clear_and_fail
.damaged:
    mov     eax, CybouDB_E_CRYPTO_CRC
    jmp     .done
.bad_cache:
    mov     eax, CybouDB_E_STATE

.done:
    ; The root key and the metadata key were in this frame, and the frame is
    ; about to be someone else's stack. The seal key stays, in the context,
    ; because the resolver needs it on every miss - that is the one key this
    ; engine holds for as long as the database is open.
    push    rax
    lea     r10, [rbp - EA_KMAC]
    xor     rax, rax
    xor     rcx, rcx
.wipe:
    mov     [r10 + rcx], rax
    add     rcx, 8
    cmp     rcx, EA_KMAC - 88           ; from the KMAC context up to the key id
    jb      .wipe
    pop     rax

    mov     rbx, [rbp - 8]
    mov     r12, [rbp - 16]
    mov     r13, [rbp - 24]
    mov     r14, [rbp - 32]
    mov     r15, [rbp - 40]
    FRAME_END
    ret

%ifdef CybouDB_LINUX
section .note.GNU-stack noalloc noexec nowrite progbits
%endif
