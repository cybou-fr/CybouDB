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
;      2. both superblocks, plaintext   every copy whose checksum verifies is a
;         with their CRCs checked       candidate, newest generation first. They
;                                       cannot be encrypted: recovery has to
;                                       choose between two copies before it
;                                       knows which key anything is under
;      3. the crypto root               the seal epoch, the directory's
;                                       geometry, and where the key slots are
;      4. a key slot                    decapsulated with the caller's private
;                                       key: this is the first step that needs
;                                       a secret, and the first that can say
;                                       "this key does not open this file"
;      5. the hierarchy                 metadata, page seal and seal tree keys
;      6. the candidate's tag, and      verified NOW, with the key that step 5
;         the tree root it publishes    produced. Until this point everything
;                                       read has been believed on a checksum
;
;  Step 6 is the one that makes the rest of it mean anything. A checksum says
;  the disk did not lie; the tag says nobody did. The seal tree root the
;  superblock carries is only as good as the superblock, and the superblock is
;  only as good as this check.
;
;  Steps 3 to 6 are an attempt, and they are made against one candidate at a
;  time. This is where the recovery contract lives, and it is the same one the
;  plain engine has always had: the newest generation that *authenticates*
;  wins, and if the newest one does not, the one before it does. A checksum is
;  not enough to choose by here, because a torn commit can leave a superblock
;  whose CRC is perfect and whose tag - or whose seal tree root - is not. Only
;  a key can tell those apart, so only a key can make the choice, and a caller
;  that has already picked a copy without one has picked too early.
;
;  Falling back is a success. It is also damage: DB_DAMAGED records the
;  generation that failed, so an open returns the older database and a check
;  still says what was lost. One failure is not retried, and that is the wrong
;  key - both copies name the same key slots, so a second attempt would decide
;  the same thing more slowly.
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
extern cyboudb_seal_geometry
extern cyboudb_seal_node_validate
extern cyboudb_seal_node_verify

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

; -----------------------------------------------------------------------------
;  sb_checksummed(ARG1 = page) -> 1 if this copy is not torn
;
;  Magic, size and CRC, and nothing else. In particular not the reserved tail
;  db_open insists is zero: on an encrypted file that tail is where the seal
;  root and the tag live. This asks only "did the disk write all of it", which
;  is the most a plaintext check is entitled to say about an encrypted file.
; -----------------------------------------------------------------------------
sb_checksummed:
    FRAME_BEGIN 16, 0
    mov     [rbp - 8], ARG1
    mov     r10, ARG1
    cmp     dword [r10 + SB_MAGIC], CybouDB_SB_MAGIC
    jne     .torn
    cmp     dword [r10 + SB_SIZE], CybouDB_SB_SIZE
    jne     .torn
    mov     ARG1, [rbp - 8]
    mov     ARG2, SB_CRC_LEN
    call    crc32c
    mov     r10, [rbp - 8]
    cmp     [r10 + SB_CRC], eax
    jne     .torn
    mov     eax, 1
    FRAME_END
    ret
.torn:
    xor     eax, eax
    FRAME_END
    ret

;  Frame. Every value has a slot and a name, and the arrays are clear of the
;  argument slots and of each other:
;
;   [rbp - 8 .. - 40]  saved rbx, r12, r13, r14, r15
;   [rbp - 48] ctx     [rbp - 56] dk      [rbp - 64] cache memory
;   [rbp - 72] cache bytes               [rbp - 80] frames
;   [rbp - 88] the key id this private key belongs to
;   [rbp - 96] candidate superblocks     [rbp - 104] the one being attempted
;   [rbp - 128] the first attempt's refusal, which is what a caller is told
;               when no candidate works
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
%define EA_GEOM     4896
; The candidates, two entries of {page, generation}, newest first. They hold
; no secret and are not wiped with the rest.
%define EA_CAND     4992
%define CAND_PAGE   0
%define CAND_GEN    8
%define CAND_SIZE   16
%define EA_FRAME    5056

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
    jne     .header_damaged

    mov     rax, [rbp - EA_PAGE + HDR_FLAGS_INCOMPAT]
    test    rax, CybouDB_FEATURE_ENCRYPTION
    jz      .not_encrypted

    ; the file's identity, which every page's associated data is bound to
    mov     rbx, [rbp - 48]
    mov     rax, [rbp - EA_PAGE + HDR_UUID]
    mov     [rbx + DB_UUID], rax
    mov     rax, [rbp - EA_PAGE + HDR_UUID + 8]
    mov     [rbx + DB_UUID + 8], rax

    ; --- 2. the candidates ---------------------------------------------------
    ;  Every superblock copy whose checksum verifies, newest generation first.
    ;  Nothing here is believed: a CRC only says the copy is not torn. Which of
    ;  them is the database is decided in step 6, with a key.
    mov     rax, [rbp - EA_PAGE + HDR_SB_PAGE_A]
    cmp     rax, CybouDB_SB_PAGE_A
    jne     .header_damaged             ; version 1 fixes both locations
    mov     rax, [rbp - EA_PAGE + HDR_SB_PAGE_B]
    cmp     rax, CybouDB_SB_PAGE_B
    jne     .header_damaged

    mov     qword [rbp - 96], 0
    mov     r12, CybouDB_SB_PAGE_A
.candidate:
    mov     rbx, [rbp - 48]
    mov     rax, r12
    shl     rax, CybouDB_PAGE_SHIFT
    mov     ARG1, [rbx + DB_HANDLE]
    lea     ARG2, [rbp - EA_PAGE]
    mov     ARG3, CybouDB_PAGE_SIZE
    mov     ARG4, rax
    call    vfs_read_at
    cmp     rax, CybouDB_PAGE_SIZE
    jne     .next_candidate

    lea     ARG1, [rbp - EA_PAGE]
    call    sb_checksummed
    test    eax, eax
    jz      .next_candidate

    ; Insert it in generation order. There are two, so "insert" is one compare.
    mov     r13, [rbp - EA_PAGE + SB_GENERATION]
    lea     r14, [rbp - EA_CAND]
    mov     rcx, [rbp - 96]
    test    rcx, rcx
    jz      .candidate_append
    cmp     r13, [r14 + CAND_GEN]
    jbe     .candidate_append
    mov     rax, [r14 + CAND_PAGE]      ; the one already here is older
    mov     [r14 + CAND_SIZE + CAND_PAGE], rax
    mov     rax, [r14 + CAND_GEN]
    mov     [r14 + CAND_SIZE + CAND_GEN], rax
    mov     [r14 + CAND_PAGE], r12
    mov     [r14 + CAND_GEN], r13
    inc     qword [rbp - 96]
    jmp     .next_candidate
.candidate_append:
    shl     rcx, 4
    mov     [r14 + rcx + CAND_PAGE], r12
    mov     [r14 + rcx + CAND_GEN], r13
    inc     qword [rbp - 96]
.next_candidate:
    inc     r12
    cmp     r12, CybouDB_SB_PAGE_B
    jbe     .candidate

    cmp     qword [rbp - 96], 0
    je      .header_damaged             ; neither copy even checksums
    mov     qword [rbp - 104], 0
    mov     qword [rbp - 128], 0

; -----------------------------------------------------------------------------
;  One attempt: this candidate, its crypto root, its key slot, its keys, its
;  tag and its tree root. Everything from here is re-derived per candidate,
;  including the decapsulation, because a fallback copy is free to name a
;  different crypto root and this code refuses to assume it does not.
; -----------------------------------------------------------------------------
.attempt:
    mov     rbx, [rbp - 48]
    mov     rcx, [rbp - 104]
    shl     rcx, 4
    lea     r14, [rbp - EA_CAND]
    mov     rax, [r14 + rcx + CAND_PAGE]
    mov     [rbx + DB_SB_PAGE], rax

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
    mov     [rbx + DB_SEAL_PAGES], rcx
    cmp     qword [rbx + DB_SB_PAGE], CybouDB_SB_PAGE_B
    jne     .seal_copy_selected
    add     rax, rcx                    ; superblock B owns copy B
.seal_copy_selected:
    mov     [rbx + DB_SEAL_DIR], rax    ; active copy's first leaf
    mov     rax, [rbp - EA_PAGE + CROOT_TOTAL_PAGES]
    mov     [rbx + DB_PAGES], rax
    lea     ARG1, [rbp - EA_GEOM]
    mov     ARG2, rax
    call    cyboudb_seal_geometry
    mov     rbx, [rbp - 48]
    mov     rax, [rbp - EA_GEOM]
    mov     [rbx + DB_SEAL_LEAVES], rax
    mov     rax, [rbp - EA_GEOM + 16]
    mov     [rbx + DB_SEAL_DEPTH], rax
    mov     rax, [rbp - EA_GEOM + 24]
    shr     rax, 1
    cmp     rax, [rbx + DB_SEAL_PAGES]
    jne     .crypto_root_bad
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

    ; The authenticated superblock publishes the root MAC. Prove the root page
    ; now; individual page resolves continue from it down to their leaf.
    mov     rax, [rbp - EA_COVER + SB_SEAL_ROOT]
    mov     [rbx + DB_SEAL_ROOT], rax
    mov     rax, [rbp - EA_COVER + SB_SEAL_ROOT + 8]
    mov     [rbx + DB_SEAL_ROOT + 8], rax
    mov     rax, [rbx + DB_SEAL_DIR]
    add     rax, [rbx + DB_SEAL_PAGES]
    dec     rax
    shl     rax, CybouDB_PAGE_SHIFT
    mov     ARG1, [rbx + DB_HANDLE]
    lea     ARG2, [rbp - EA_PAGE]
    mov     ARG3, CybouDB_PAGE_SIZE
    mov     ARG4, rax
    call    vfs_read_at
    cmp     rax, CybouDB_PAGE_SIZE
    jne     .damaged
    lea     ARG1, [rbp - EA_PAGE]
    call    cyboudb_seal_node_validate
    test    eax, eax
    jnz     .crypto_root_bad
    mov     rbx, [rbp - 48]
    mov     rax, [rbx + DB_SEAL_DEPTH]
    cmp     [rbp - EA_PAGE + SNODE_LEVEL], rax
    jne     .crypto_root_bad
    cmp     qword [rbp - EA_PAGE + SNODE_INDEX], 0
    jne     .crypto_root_bad
    lea     ARG1, [rbx + DB_TREE_KEY]
    lea     ARG2, [rbp - EA_PAGE]
    lea     ARG3, [rbx + DB_SEAL_ROOT]
    call    cyboudb_seal_node_verify
    test    eax, eax
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

.attempt_failed:
    ; A context that failed an attempt must not keep a key. Anything that
    ; derived one before the refusal leaves it here otherwise, and the next
    ; candidate - or a caller retrying with a different key - would be running
    ; with half of the last attempt still in place.
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

    ; What the caller is told is what the newest candidate said. A fallback
    ; that fails for its own, older reasons must not rename the failure.
    cmp     qword [rbp - 128], 0
    jne     .first_error_kept
    mov     [rbp - 128], r10
.first_error_kept:

    ; This generation did not authenticate. Whether or not an older one does,
    ; that is damage, and it is recorded the way the plain engine records it:
    ; the newest generation known to be bad.
    mov     rcx, [rbp - 104]
    shl     rcx, 4
    lea     r14, [rbp - EA_CAND]
    mov     rax, [r14 + rcx + CAND_GEN]
    cmp     rax, [rbx + DB_DAMAGED]
    jbe     .damage_recorded
    mov     [rbx + DB_DAMAGED], rax
.damage_recorded:

    ; The wrong key is not a reason to look at the other copy. Both copies
    ; name the same key slots, so the second attempt would spend a full
    ; decapsulation to reach the same refusal.
    cmp     r10d, CybouDB_E_KEY
    je      .give_up
    mov     rax, [rbp - 104]
    inc     rax
    cmp     rax, [rbp - 96]
    jae     .give_up
    mov     [rbp - 104], rax
    jmp     .attempt

.give_up:
    mov     eax, [rbp - 128]
    jmp     .done

.not_encrypted:
    mov     eax, CybouDB_E_STATE
    jmp     .done
.no_crypto_root:
.no_key_slots:
.crypto_root_bad:
    mov     r10d, CybouDB_E_CRYPTO_ROOT
    jmp     .attempt_failed
.no_slot:
.wrong_key:
    mov     r10d, CybouDB_E_KEY
    jmp     .attempt_failed
.superblock_forged:
    mov     r10d, CybouDB_E_SEAL
    jmp     .attempt_failed
.damaged:
    mov     r10d, CybouDB_E_CRYPTO_CRC
    jmp     .attempt_failed
.header_damaged:
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
