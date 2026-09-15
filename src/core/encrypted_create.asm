; Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
; SPDX-License-Identifier: Apache-2.0
; =============================================================================
;  core/encrypted_create.asm - writing an encrypted database, from nothing
; =============================================================================
;  The counterpart to core/encrypted_open.asm. That file opens what this one
;  writes, and between them they are the first pair in this project that can
;  make a file no other build can read without a key.
;
;  The layout it chooses, once, so that attach does not have to guess. With
;  K = ceil(pages / CybouDB_MAP_LEAF_PAGES) and S the pages of one seal-tree
;  copy:
;
;      page 0              the header, plaintext: identity and the bit
;      pages 1, 2          superblock A and B, plaintext with a tag
;      pages 3 .. 3+K      allocation map copy A
;      pages 3+K .. 3+2K   allocation map copy B
;      page 3+2K           the crypto root
;      page 3+2K+1         the key slots
;      pages 3+2K+2 ..     seal-tree copy A: S pages, then copy B
;      then                everything a database actually holds
;
;  The allocation map keeps the position the plain format gives it, and the
;  crypto pages move to make room. That is the way round it has to be: the map
;  is at pages 3 and 3+K in every CybouDB file and the allocator's validator
;  says so in as many words, while the crypto root is reached through a pointer
;  in the superblock and the key slots and the directory through pointers in
;  the crypto root. Moving what is pointed at costs nothing; moving what is
;  fixed would be a second allocation-map format.
;
;  The map pages are sealed, like every other page and for the same reasons.
;  They are the only pages this creator seals: a fresh database has nothing
;  else in it, and a map nobody can move, replay or forge is what makes the
;  allocator above it mean anything.
;
;  Nodes are built bottom-up until one root remains. Every level is contiguous
;  inside each copy, using the layout shared with open and commit.
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
extern vfs_read_at
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
extern cyboudb_seal_entry
extern cyboudb_page_seal
extern db_bitmap_leaves
extern db_bitmap_leaf_build
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
;   [rbp - 88] pages in one seal-tree copy (leaves plus root node)
;   [rbp - 160] the root key, wiped before this returns
;   [rbp - 224] the metadata key, wiped with it
;   [rbp - 288] the page seal key
;   [rbp - 352] the seal tree key
;   [rbp - 384] the associated data a key slot is bound to
;   [rbp - 448] one MAC, and room
;   [rbp - 704] the KMAC context
;   [rbp - 1920] one key slot, 1176 bytes
;   [rbp - 6080] a page to build in
;   [rbp - 10240] a second page: the node, while the leaves are written, and
;                 the allocation map leaf while it is sealed into one
;   [rbp - 10304] the page numbers this file's geometry works out to
;   [rbp - 10368] the arguments one page seal takes
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
%define ECV_K        10304          ; map pages in one copy
%define ECV_CROOT    10296
%define ECV_SLOTS    10288
%define ECV_FREE     10280          ; the first page the allocator may hand out
%define ECV_MAP      10272          ; the map page being sealed
%define ECV_MAPEND   10264          ; one past the last one in this leaf
%define ECV_TMP      10256
%define EC_ARGS      10368
%define EC_FRAME     10368

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
    mov     rax, [rbp - 56]
    add     rax, [rbp - 64]
    mov     [rbp - 88], rax             ; one complete directory/tree copy

    ; Where everything lands, given the allocation map's fixed position.
    mov     rbx, [rbp - 48]
    mov     ARG1, [rbx + ECREATE_PAGES]
    call    db_bitmap_leaves
    mov     [rbp - ECV_K], rax
    shl     rax, 1
    add     rax, CybouDB_MIN_PAGES      ; past the header, both superblocks and
    mov     [rbp - ECV_CROOT], rax      ; both map copies
    inc     rax
    mov     [rbp - ECV_SLOTS], rax
    inc     rax
    mov     [rbp - 80], rax             ; the first leaf of seal-tree copy A
    mov     rcx, [rbp - 88]
    shl     rcx, 1
    add     rax, rcx
    mov     [rbp - ECV_FREE], rax       ; and the first page nothing has claimed

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
    ; The canonical profile, and the encryption bit on top of it. An encrypted
    ; database is an ordinary CybouDB database whose pages are sealed, not a
    ; second kind of database, so it claims the same capabilities - and db_open
    ; still refuses the whole file for want of a key before it looks at any of
    ; them.
    mov     qword [r10 + HDR_FLAGS_INCOMPAT], CybouDB_FEATURES_DEFAULT | CybouDB_FEATURE_ENCRYPTION
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
    cmp     rax, CybouDB_PAGE_SIZE
    jne     .write_failed

    ; --- the crypto root ------------------------------------------------------
    mov     rbx, [rbp - 48]
    lea     ARG1, [rbp - EC_PAGE]
    mov     ARG2, [rbx + ECREATE_EPOCH]
    mov     ARG3, [rbp - 80]            ; the first leaf
    mov     ARG4, [rbp - 88]            ; pages in each of the two copies
    mov     rax, [rbp - 80]
    add     rax, [rbp - 88]
    dec     rax                         ; copy A's final page is the root
    PASS_ARG5 rax
    mov     rax, [rbx + ECREATE_PAGES]
    PASS_ARG6 rax
    call    cyboudb_crypto_root_init
    test    eax, eax
    jnz     .refused

    lea     r10, [rbp - EC_PAGE]
    mov     rax, [rbp - ECV_SLOTS]
    mov     [r10 + CROOT_KEM_ROOT], rax
    lea     ARG1, [rbp - EC_PAGE]
    mov     ARG2, CROOT_CRC_LEN
    CALL_ABI crc32c
    lea     r10, [rbp - EC_PAGE]
    mov     [r10 + CROOT_CRC], eax
    mov     r12, [rbp - ECV_CROOT]
    call    write_page
    cmp     rax, CybouDB_PAGE_SIZE
    jne     .write_failed

    ; --- the key slots --------------------------------------------------------
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
    mov     r12, [rbp - ECV_SLOTS]
    call    write_page
    cmp     rax, CybouDB_PAGE_SIZE
    jne     .write_failed

    ; --- the seal directory, and the tree above it ---------------------------
    ;  A leaf is written empty unless it covers part of the allocation map,
    ;  which is the only thing in a fresh database that is a page rather than
    ;  an absence. An entry of zeroes is a page nothing has sealed yet, and
    ;  that is a fact about the database rather than a gap in it.

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

    ; --- the map pages this leaf covers, if it covers any -------------------
    ;  They are sealed here rather than after the tree is built, because the
    ;  leaf has to carry their nonces and tags before anything MACs the leaf.
    mov     rax, r13
    imul    rax, rax, CybouDB_SEAL_ENTRIES_PER_LEAF
    cmp     rax, CybouDB_MIN_PAGES
    jae     .map_first_known
    mov     rax, CybouDB_MIN_PAGES
.map_first_known:
    mov     [rbp - ECV_MAP], rax
    mov     rax, r13
    inc     rax
    imul    rax, rax, CybouDB_SEAL_ENTRIES_PER_LEAF
    mov     rcx, [rbp - ECV_K]
    shl     rcx, 1
    add     rcx, CybouDB_MIN_PAGES      ; one past the last map page
    cmp     rax, rcx
    jbe     .map_last_known
    mov     rax, rcx
.map_last_known:
    mov     [rbp - ECV_MAPEND], rax

.map_page:
    mov     rax, [rbp - ECV_MAP]
    cmp     rax, [rbp - ECV_MAPEND]
    jae     .leaf_ready

    ; which leaf of which copy it is: the two copies are laid out alike, so
    ; both hold the same leaf content for the same index
    sub     rax, CybouDB_MIN_PAGES
    xor     rdx, rdx
    div     qword [rbp - ECV_K]
    mov     [rbp - ECV_TMP], rdx
    mov     rbx, [rbp - 48]
    lea     ARG1, [rbp - EC_NODE]
    mov     ARG2, [rbp - ECV_TMP]
    mov     ARG3, [rbx + ECREATE_PAGES]
    mov     ARG4, [rbp - ECV_FREE]
    call    db_bitmap_leaf_build

    ; the entry this page owns, inside the leaf being built
    lea     ARG1, [rbp - EC_PAGE]
    mov     ARG2, [rbp - ECV_MAP]
    call    cyboudb_seal_entry
    test    rax, rax
    jz      .refused                    ; the leaf does not cover it after all
    lea     r10, [rbp - EC_ARGS]
    mov     [r10 + PSEAL_ENTRY], rax
    lea     rax, [rbp - EC_PAGEKEY]
    mov     [r10 + PSEAL_KEY], rax
    lea     rax, [rbp - EC_NODE]
    mov     [r10 + PSEAL_PAGE], rax
    mov     rbx, [rbp - 48]
    mov     rax, [rbx + ECREATE_UUID]
    mov     [r10 + PSEAL_UUID], rax
    mov     rax, [rbp - ECV_MAP]
    mov     [r10 + PSEAL_PAGE_NO], rax
    mov     rax, [rbx + ECREATE_GENERATION]
    mov     [r10 + PSEAL_GENERATION], rax
    mov     qword [r10 + PSEAL_PAGE_TYPE], CybouDB_PTYPE_MAP
    mov     rax, [rbx + ECREATE_EPOCH]
    mov     [r10 + PSEAL_EPOCH], rax
    lea     ARG1, [rbp - EC_ARGS]
    call    cyboudb_page_seal
    test    eax, eax
    jnz     .refused

    mov     r12, [rbp - ECV_MAP]
    lea     r14, [rbp - EC_NODE]
    call    write_buffer_page
    cmp     rax, CybouDB_PAGE_SIZE
    jne     .write_failed

    inc     qword [rbp - ECV_MAP]
    jmp     .map_page

.leaf_ready:
    ; Entries were written into it, so the leaf's own checksum is stale.
    lea     ARG1, [rbp - EC_PAGE]
    mov     ARG2, SLEAF_CRC
    CALL_ABI crc32c
    lea     r10, [rbp - EC_PAGE]
    mov     [r10 + SLEAF_CRC], eax

    mov     r12, [rbp - 80]
    add     r12, r13
    call    write_page                  ; copy A
    cmp     rax, CybouDB_PAGE_SIZE
    jne     .write_failed
    add     r12, [rbp - 88]
    call    write_page                  ; copy B starts one stride later
    cmp     rax, CybouDB_PAGE_SIZE
    jne     .write_failed

    inc     r13
    jmp     .leaf

.leaves_done:
    mov     qword [rbp - 96], 0         ; previous level offset: leaves
    mov     rax, [rbp - 56]
    mov     [rbp - 104], rax            ; previous level count
    mov     [rbp - 112], rax            ; current level follows it
    mov     qword [rbp - 128], 1        ; parents of leaves
.tree_level:
    mov     rax, [rbp - 104]
    add     rax, CybouDB_SEAL_CHILDREN_PER_NODE - 1
    xor     rdx, rdx
    mov     rcx, CybouDB_SEAL_CHILDREN_PER_NODE
    div     rcx
    mov     [rbp - 120], rax            ; nodes in this level
    mov     qword [rbp - 136], 0        ; node index
.tree_node:
    mov     r13, [rbp - 136]
    cmp     r13, [rbp - 120]
    jae     .tree_level_done

    mov     rbx, [rbp - 48]
    lea     ARG1, [rbp - EC_NODE]
    mov     ARG2, r13
    mov     ARG3, [rbp - 128]
    mov     ARG4, [rbx + ECREATE_GENERATION]
    mov     rax, [rbx + ECREATE_EPOCH]
    PASS_ARG5 rax
    call    cyboudb_seal_node_init

    mov     qword [rbp - 144], 0        ; slot within this node
.tree_child:
    cmp     qword [rbp - 144], CybouDB_SEAL_CHILDREN_PER_NODE
    jae     .tree_node_ready
    mov     rax, [rbp - 136]
    imul    rax, rax, CybouDB_SEAL_CHILDREN_PER_NODE
    add     rax, [rbp - 144]            ; child index in previous level
    cmp     rax, [rbp - 104]
    jae     .tree_node_ready

    add     rax, [rbp - 96]
    add     rax, [rbp - 80]
    shl     rax, CybouDB_PAGE_SHIFT
    mov     rbx, [rbp - 48]
    mov     ARG1, [rbx + ECREATE_HANDLE]
    lea     ARG2, [rbp - EC_PAGE]
    mov     ARG3, CybouDB_PAGE_SIZE
    mov     ARG4, rax
    call    vfs_read_at
    cmp     rax, CybouDB_PAGE_SIZE
    jne     .write_failed

    lea     ARG1, [rbp - EC_MAC]
    lea     ARG2, [rbp - EC_TREEKEY]
    lea     ARG3, [rbp - EC_PAGE]
    cmp     qword [rbp - 128], 1
    jne     .child_is_node
    call    cyboudb_seal_leaf_mac
    jmp     .child_mac_ready
.child_is_node:
    call    cyboudb_seal_node_mac
.child_mac_ready:
    lea     ARG1, [rbp - EC_NODE]
    mov     ARG2, [rbp - 144]
    lea     ARG3, [rbp - EC_MAC]
    call    cyboudb_seal_node_set_child
    test    eax, eax
    jnz     .refused
    inc     qword [rbp - 144]
    jmp     .tree_child

.tree_node_ready:
    mov     r12, [rbp - 80]
    add     r12, [rbp - 112]
    add     r12, [rbp - 136]
    lea     r14, [rbp - EC_NODE]
    call    write_buffer_page           ; copy A
    cmp     rax, CybouDB_PAGE_SIZE
    jne     .write_failed
    add     r12, [rbp - 88]
    call    write_buffer_page           ; copy B
    cmp     rax, CybouDB_PAGE_SIZE
    jne     .write_failed
    inc     qword [rbp - 136]
    jmp     .tree_node

.tree_level_done:
    cmp     qword [rbp - 120], 1
    je      .tree_done
    mov     rax, [rbp - 112]
    mov     [rbp - 96], rax
    mov     rax, [rbp - 120]
    mov     [rbp - 104], rax
    add     [rbp - 112], rax
    inc     qword [rbp - 128]
    jmp     .tree_level

.tree_done:
    lea     ARG1, [rbp - EC_MAC]
    lea     ARG2, [rbp - EC_TREEKEY]
    lea     ARG3, [rbp - EC_NODE]
    call    cyboudb_seal_node_mac

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
    mov     rax, [rbp - ECV_FREE]
    mov     [r10 + SB_ALLOC_PAGES], rax
    mov     qword [r10 + SB_BITMAP_ROOT], CybouDB_MIN_PAGES
    mov     rax, [rbp - ECV_CROOT]
    mov     [r10 + SB_FEATURE_ROOT], rax

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
    cmp     rax, CybouDB_PAGE_SIZE
    jne     .write_failed
    mov     r12, CybouDB_SB_PAGE_B
    call    write_page
    cmp     rax, CybouDB_PAGE_SIZE
    jne     .write_failed

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

; r12 is the page number and r14 is a page-sized buffer.
write_buffer_page:
    push    rbp
    mov     rbp, rsp
    sub     rsp, 32 + SHADOW_SPACE
    mov     r10, [rbp]
    mov     rax, [r10 - 48]
    mov     ARG1, [rax + ECREATE_HANDLE]
    mov     ARG2, r14
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
