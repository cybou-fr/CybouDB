; Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
; SPDX-License-Identifier: Apache-2.0
; =============================================================================
;  core/encrypted_create.asm - writing an encrypted database, from nothing
; =============================================================================
;  The counterpart to core/encrypted_open.asm. That file opens what this one
;  writes, and between them they are the first pair in this project that can
;  make a file no other build can read without a key.
;
;  The layout it chooses, once, so that attach does not have to guess:
;
;      page 0              the header, plaintext: identity and the bit
;      pages 1, 2          superblock A and B, plaintext with a tag
;      page 3              the crypto root
;      page 4              the key slots
;      pages 5 .. 5+S      the seal directory, S leaves
;      page 5+S            the seal tree node above them
;      pages 5+S+1 ..      everything a database actually holds
;
;  **One node, so one level.** A node covers 251 leaves and a leaf covers 100
;  pages, so this writes files up to 25,100 pages - about 98 MiB - and refuses
;  anything larger rather than writing a tree it cannot walk. Depth two is
;  arithmetic this file does not have yet, and a create path that silently
;  produced a file its own reader could not open would be worse than a refusal.
;
;  **The root key is drawn here and never leaves.** It is sealed to the public
;  key the caller supplies, the keys below it are derived, used, and wiped with
;  the frame. Nothing returns it: a create path that handed back the root key
;  would be a create path someone could be persuaded to log.
; =============================================================================

%include "cyboudb.inc"
%include "crypto.inc"

BITS 64
default rel

global cyboudb_encrypted_create

extern os_random
extern vfs_write_at
extern vfs_sync_file
extern vfs_resize
extern crc32c
extern cyboudb_crypto_root_init
extern cyboudb_keypage_init
extern cyboudb_keypage_add
extern cyboudb_kem_key_id
extern cyboudb_kem_seal_root
extern cyboudb_kdf
extern cyboudb_seal_geometry
extern cyboudb_seal_leaf_init
extern cyboudb_seal_leaf_mac
extern cyboudb_seal_node_init
extern cyboudb_seal_node_set_child
extern cyboudb_seal_node_mac
extern cyboudb_kmac256_init
extern cyboudb_kmac256_update
extern cyboudb_kmac256_final

section .rodata
sb_label: db "CybouDB/0.7/superblock"
SB_LABEL_LEN equ $ - sb_label

section .text

; Frame, every slot named:
;   [rbp - 8 .. -40]  saved rbx, r12, r13, r14, r15
;   [rbp - 48] args     [rbp - 56] leaves     [rbp - 64] nodes
;   [rbp - 72] the key id                     [rbp - 80] the first leaf's page
;   [rbp - 160] the root key, wiped before this returns
;   [rbp - 224] the metadata key, wiped with it
;   [rbp - 288] the page seal key
;   [rbp - 352] the seal tree key
;   [rbp - 384] the associated data a key slot is bound to
;   [rbp - 448] one MAC, and room
;   [rbp - 704] the KMAC context
;   [rbp - 1920] one key slot, 1176 bytes
;   [rbp - 6080] a page to build in
;   [rbp - 10240] a second page: the node, while the leaves are written
%define EC_ROOTKEY   160
%define EC_METAKEY   224
%define EC_PAGEKEY   288
%define EC_TREEKEY   352
%define EC_AAD       384
%define EC_MAC       448
%define EC_KMAC      704
%define EC_SLOT      1920
%define EC_PAGE      6080
%define EC_NODE      10240
%define EC_FRAME     10304

%define EC_P_CROOT   3
%define EC_P_SLOTS   4
%define EC_P_DIR     5

; =============================================================================
;  cyboudb_encrypted_create(args) -> int
;
;  ARG1  const uint8_t *args, laid out in crypto.inc as ECREATE_*
; =============================================================================
cyboudb_encrypted_create:
    FRAME_BEGIN EC_FRAME, 2
    mov     [rbp - 8], rbx
    mov     [rbp - 16], r12
    mov     [rbp - 24], r13
    mov     [rbp - 32], r14
    mov     [rbp - 40], r15

    mov     rbx, ARG1
    mov     [rbp - 48], rbx

    ; --- the geometry, from the one place that knows it ----------------------
    lea     ARG1, [rbp - EC_MAC]        ; four qwords: leaves, nodes, depth, pages
    mov     ARG2, [rbx + ECREATE_PAGES]
    call    cyboudb_seal_geometry
    mov     rax, [rbp - EC_MAC]
    mov     [rbp - 56], rax             ; leaves
    mov     rax, [rbp - EC_MAC + 8]
    mov     [rbp - 64], rax             ; nodes
    cmp     qword [rbp - EC_MAC + 16], 1
    ja      .too_big                    ; depth two is not written here yet
    mov     qword [rbp - 80], EC_P_DIR

    ; --- the root key, and everything under it -------------------------------
    lea     ARG1, [rbp - EC_ROOTKEY]
    mov     ARG2, 32
    call    os_random
    test    eax, eax
    jnz     .no_randomness

    mov     rbx, [rbp - 48]
    lea     ARG1, [rbp - EC_METAKEY]
    mov     ARG2, 32
    mov     ARG3, KDF_METADATA_KEK
    lea     ARG4, [rbp - EC_ROOTKEY]
    xor     rax, rax
    PASS_ARG5 rax
    xor     rax, rax
    PASS_ARG6 rax
    call    cyboudb_kdf
    test    eax, eax
    jnz     .refused

    mov     rbx, [rbp - 48]
    lea     ARG1, [rbp - EC_PAGEKEY]
    mov     ARG2, 32
    mov     ARG3, KDF_PAGE_SEAL
    lea     ARG4, [rbp - EC_ROOTKEY]
    lea     rax, [rbx + ECREATE_EPOCH]
    PASS_ARG5 rax
    mov     rax, 8
    PASS_ARG6 rax
    call    cyboudb_kdf
    test    eax, eax
    jnz     .refused

    mov     rbx, [rbp - 48]
    lea     ARG1, [rbp - EC_TREEKEY]
    mov     ARG2, 32
    mov     ARG3, KDF_SEAL_TREE
    lea     ARG4, [rbp - EC_ROOTKEY]
    lea     rax, [rbx + ECREATE_EPOCH]
    PASS_ARG5 rax
    mov     rax, 8
    PASS_ARG6 rax
    call    cyboudb_kdf
    test    eax, eax
    jnz     .refused

    ; --- page 0: the header --------------------------------------------------
    call    zero_page
    mov     rbx, [rbp - 48]
    lea     r10, [rbp - EC_PAGE]
    mov     dword [r10 + HDR_MAGIC], CybouDB_MAGIC
    mov     dword [r10 + HDR_HEADER_SIZE], CybouDB_HDR_SIZE
    mov     dword [r10 + HDR_VERSION], CybouDB_VERSION
    mov     dword [r10 + HDR_PAGE_SIZE], CybouDB_PAGE_SIZE
    mov     qword [r10 + HDR_FLAGS_INCOMPAT], CybouDB_FEATURE_ENCRYPTION
    mov     qword [r10 + HDR_SB_PAGE_A], CybouDB_SB_PAGE_A
    mov     qword [r10 + HDR_SB_PAGE_B], CybouDB_SB_PAGE_B
    mov     r11, [rbx + ECREATE_UUID]
    mov     rax, [r11]
    mov     [r10 + HDR_UUID], rax
    mov     rax, [r11 + 8]
    mov     [r10 + HDR_UUID + 8], rax

    lea     ARG1, [rbp - EC_PAGE]
    mov     ARG2, HDR_CRC_LEN
    CALL_ABI crc32c
    lea     r10, [rbp - EC_PAGE]
    mov     [r10 + HDR_CRC], eax
    xor     r12, r12                    ; page 0
    call    write_page

    ; --- page 3: the crypto root ---------------------------------------------
    mov     rbx, [rbp - 48]
    lea     ARG1, [rbp - EC_PAGE]
    mov     ARG2, [rbx + ECREATE_EPOCH]
    mov     ARG3, [rbp - 80]            ; the first leaf
    mov     ARG4, [rbp - 56]            ; how many
    mov     rax, [rbp - 80]
    add     rax, [rbp - 56]             ; the node sits above the leaves
    PASS_ARG5 rax
    mov     rax, [rbx + ECREATE_PAGES]
    PASS_ARG6 rax
    call    cyboudb_crypto_root_init
    test    eax, eax
    jnz     .refused

    lea     r10, [rbp - EC_PAGE]
    mov     qword [r10 + CROOT_KEM_ROOT], EC_P_SLOTS
    lea     ARG1, [rbp - EC_PAGE]
    mov     ARG2, CROOT_CRC_LEN
    CALL_ABI crc32c
    lea     r10, [rbp - EC_PAGE]
    mov     [r10 + CROOT_CRC], eax
    mov     r12, EC_P_CROOT
    call    write_page

    ; --- page 4: the key slots -----------------------------------------------
    mov     rbx, [rbp - 48]
    lea     ARG1, [rbp - 72]
    mov     ARG2, [rbx + ECREATE_EK]
    call    cyboudb_kem_key_id

    mov     rbx, [rbp - 48]
    lea     r10, [rbp - EC_AAD]
    mov     r11, [rbx + ECREATE_UUID]
    mov     rax, [r11]
    mov     [r10], rax
    mov     rax, [r11 + 8]
    mov     [r10 + 8], rax
    mov     rax, [rbp - 72]
    mov     [r10 + 16], rax

    lea     ARG1, [rbp - EC_SLOT]
    mov     ARG2, [rbx + ECREATE_EK]
    lea     ARG3, [rbp - EC_ROOTKEY]
    mov     ARG4, [rbp - 72]
    lea     rax, [rbp - EC_AAD]
    PASS_ARG5 rax
    mov     rax, 24
    PASS_ARG6 rax
    call    cyboudb_kem_seal_root
    test    eax, eax
    jnz     .refused

    lea     ARG1, [rbp - EC_PAGE]
    xor     ARG2, ARG2
    mov     rbx, [rbp - 48]
    mov     ARG3, [rbx + ECREATE_GENERATION]
    call    cyboudb_keypage_init
    lea     ARG1, [rbp - EC_PAGE]
    lea     ARG2, [rbp - EC_SLOT]
    call    cyboudb_keypage_add
    test    eax, eax
    jnz     .refused
    mov     r12, EC_P_SLOTS
    call    write_page

    ; --- the seal directory, and the node above it ---------------------------
    ;  Every leaf is written empty: a database with no pages sealed yet has a
    ;  directory of entries that are all zero, and that is a fact about it
    ;  rather than an absence. The node records each leaf's MAC as it goes.
    mov     rbx, [rbp - 48]
    lea     ARG1, [rbp - EC_NODE]
    xor     ARG2, ARG2
    mov     ARG3, 1                     ; level one: the parent of leaves
    mov     ARG4, [rbx + ECREATE_GENERATION]
    mov     rax, [rbx + ECREATE_EPOCH]
    PASS_ARG5 rax
    call    cyboudb_seal_node_init

    xor     r13, r13                    ; which leaf
.leaf:
    cmp     r13, [rbp - 56]
    jae     .leaves_done

    mov     rbx, [rbp - 48]
    lea     ARG1, [rbp - EC_PAGE]
    mov     ARG2, r13
    mov     ARG3, [rbx + ECREATE_GENERATION]
    mov     ARG4, [rbx + ECREATE_EPOCH]
    call    cyboudb_seal_leaf_init

    lea     ARG1, [rbp - EC_MAC]
    lea     ARG2, [rbp - EC_TREEKEY]
    lea     ARG3, [rbp - EC_PAGE]
    call    cyboudb_seal_leaf_mac

    lea     ARG1, [rbp - EC_NODE]
    mov     ARG2, r13
    lea     ARG3, [rbp - EC_MAC]
    call    cyboudb_seal_node_set_child
    test    eax, eax
    jnz     .refused

    mov     r12, [rbp - 80]
    add     r12, r13
    call    write_page

    inc     r13
    jmp     .leaf

.leaves_done:
    ; the node, and its own MAC, which is what the superblock will publish
    lea     ARG1, [rbp - EC_NODE]
    mov     ARG2, SNODE_CRC
    CALL_ABI crc32c
    lea     r10, [rbp - EC_NODE]
    mov     [r10 + SNODE_CRC], eax

    lea     ARG1, [rbp - EC_MAC]
    lea     ARG2, [rbp - EC_TREEKEY]
    lea     ARG3, [rbp - EC_NODE]
    call    cyboudb_seal_node_mac

    ; the node page goes out of its own buffer, not the shared one
    mov     rbx, [rbp - 48]
    mov     ARG1, [rbx + ECREATE_HANDLE]
    lea     ARG2, [rbp - EC_NODE]
    mov     ARG3, CybouDB_PAGE_SIZE
    mov     rax, [rbp - 80]
    add     rax, [rbp - 56]
    shl     rax, CybouDB_PAGE_SHIFT
    mov     ARG4, rax
    call    vfs_write_at
    cmp     rax, CybouDB_PAGE_SIZE
    jne     .write_failed

    ; --- the superblocks, which publish all of it ----------------------------
    call    zero_page
    mov     rbx, [rbp - 48]
    lea     r10, [rbp - EC_PAGE]
    mov     dword [r10 + SB_MAGIC], CybouDB_SB_MAGIC
    mov     dword [r10 + SB_SIZE], CybouDB_SB_SIZE
    mov     rax, [rbx + ECREATE_GENERATION]
    mov     [r10 + SB_GENERATION], rax
    mov     rax, [rbx + ECREATE_PAGES]
    mov     [r10 + SB_TOTAL_PAGES], rax
    mov     rax, [rbp - 80]
    add     rax, [rbp - 56]
    add     rax, [rbp - 64]             ; the first page a database may use
    mov     [r10 + SB_ALLOC_PAGES], rax
    mov     qword [r10 + SB_FEATURE_ROOT], EC_P_CROOT

    ; the seal tree root goes in, and then the tag over everything above it
    lea     r10, [rbp - EC_PAGE]
    mov     rax, [rbp - EC_MAC]
    mov     [r10 + SB_SEAL_ROOT], rax
    mov     rax, [rbp - EC_MAC + 8]
    mov     [r10 + SB_SEAL_ROOT + 8], rax

    lea     ARG1, [rbp - EC_KMAC]
    lea     ARG2, [rbp - EC_METAKEY]
    mov     ARG3, 32
    lea     ARG4, [sb_label]
    mov     rax, SB_LABEL_LEN
    PASS_ARG5 rax
    call    cyboudb_kmac256_init
    test    eax, eax
    jnz     .refused

    lea     ARG1, [rbp - EC_KMAC]
    lea     ARG2, [rbp - EC_PAGE]
    mov     ARG3, SB_SEAL_TAG_COVERS
    call    cyboudb_kmac256_update

    lea     ARG1, [rbp - EC_KMAC]
    lea     ARG2, [rbp - EC_PAGE + SB_SEAL_TAG]
    mov     ARG3, SB_SEAL_TAG_SIZE
    call    cyboudb_kmac256_final

    lea     ARG1, [rbp - EC_PAGE]
    mov     ARG2, SB_CRC_LEN
    CALL_ABI crc32c
    lea     r10, [rbp - EC_PAGE]
    mov     [r10 + SB_CRC], eax

    mov     r12, CybouDB_SB_PAGE_A
    call    write_page
    mov     r12, CybouDB_SB_PAGE_B
    call    write_page

    ; --- the file is as long as it says it is --------------------------------
    ;  Without this the file ends after the metadata, and the first page a
    ;  database allocates is past the end of it - which the resolver reports as
    ;  a page that does not verify, because from where it stands a short read
    ;  and a torn page look the same.
    mov     rbx, [rbp - 48]
    mov     ARG1, [rbx + ECREATE_HANDLE]
    mov     rax, [rbx + ECREATE_PAGES]
    shl     rax, CybouDB_PAGE_SHIFT
    mov     ARG2, rax
    call    vfs_resize
    test    eax, eax
    jnz     .write_failed

    ; --- and it has to reach the disk ----------------------------------------
    mov     rbx, [rbp - 48]
    mov     ARG1, [rbx + ECREATE_HANDLE]
    call    vfs_sync_file
    test    eax, eax
    jnz     .write_failed

    xor     eax, eax
    jmp     .done

.too_big:
    mov     eax, CybouDB_E_COW_PAGES
    jmp     .done
.no_randomness:
    mov     eax, CybouDB_E_STATE
    jmp     .done
.write_failed:
    mov     eax, CybouDB_E_SYNC
    jmp     .done
.refused:
    mov     eax, CybouDB_E_STATE

.done:
    push    rax
    lea     r10, [rbp - EC_KMAC]
    xor     rax, rax
    xor     rcx, rcx
.wipe:
    mov     [r10 + rcx], rax
    add     rcx, 8
    cmp     rcx, EC_KMAC - 88
    jb      .wipe
    pop     rax

    mov     rbx, [rbp - 8]
    mov     r12, [rbp - 16]
    mov     r13, [rbp - 24]
    mov     r14, [rbp - 32]
    mov     r15, [rbp - 40]
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  zero_page / write_page - the shared page buffer, cleared and written.
;  write_page takes the page number in r12 and uses the caller's frame, which
;  is why both are here rather than being calls with arguments: they exist to
;  stop the same six lines appearing eleven times.
; -----------------------------------------------------------------------------
zero_page:
    push    rbp
    mov     rbp, rsp
    mov     r10, [rbp]
    lea     r11, [r10 - EC_PAGE]
    xor     rax, rax
    xor     rcx, rcx
.zero:
    mov     [r11 + rcx], rax
    add     rcx, 8
    cmp     rcx, CybouDB_PAGE_SIZE
    jb      .zero
    pop     rbp
    ret

write_page:
    push    rbp
    mov     rbp, rsp
    sub     rsp, 32 + SHADOW_SPACE
    mov     r10, [rbp]
    mov     rax, [r10 - 48]             ; args
    mov     ARG1, [rax + ECREATE_HANDLE]
    lea     ARG2, [r10 - EC_PAGE]
    mov     ARG3, CybouDB_PAGE_SIZE
    mov     rax, r12
    shl     rax, CybouDB_PAGE_SHIFT
    mov     ARG4, rax
    call    vfs_write_at
    mov     rsp, rbp
    pop     rbp
    ret

%ifdef CybouDB_LINUX
section .note.GNU-stack noalloc noexec nowrite progbits
%endif
