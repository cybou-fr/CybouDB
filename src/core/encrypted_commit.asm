; Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
; SPDX-License-Identifier: Apache-2.0
; =============================================================================
;  core/encrypted_commit.asm - publishing a generation of an encrypted database
; =============================================================================
;  docs/ENCRYPTED_FORMAT.md, Decision 6b, in the order it gives and for the
;  reasons it gives:
;
;      1. the pages, sealed                 db_pages_flush
;      2. the leaves that cover them        db_pages_flush
;      3. the node above those leaves       here
;      ---- barrier ----                    here
;      4. the superblock, into the copy      here
;         that is not live
;      ---- barrier ----                    here
;
;  The first barrier is the whole of the safety argument. Without it a crash
;  can leave a superblock naming a seal tree root whose node never reached the
;  disk - a generation published over pages that are not there, which is
;  neither the old database nor the new one. tests/encrypted_commit_test.c
;  shows that failure happening when the order is wrong, which is the only way
;  to know the order is what prevents it.
;
;  The superblock goes to the copy that is not live. That is what makes a
;  half-written publication survivable: the old one is still whole, still
;  tagged, and still names a tree that is still on the disk, so a reader that
;  cannot verify the new copy falls back to a generation that was never in
;  doubt.
; =============================================================================

%include "cyboudb.inc"
%include "crypto.inc"

BITS 64
default rel

global db_encrypted_commit

extern db_pages_flush
extern vfs_read_at
extern vfs_write_at
extern vfs_sync_file
extern crc32c
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

; Frame:
;   [rbp - 8 .. -32]  saved rbx, r12, r13
;   [rbp - 40] ctx        [rbp - 48] the node's page
;   [rbp - 56] the generation being published
;   [rbp - 64] which superblock copy it goes to
;   [rbp - 72] active seal copy base   [rbp - 80] inactive copy base
;   [rbp - 128] one MAC
;   [rbp - 384] the KMAC context
;   [rbp - 4608] a page to read leaves and build the superblock in
;   [rbp - 8768] the inactive node
;   [rbp - 12864] the active node used to find divergent leaves
%define CM_MAC     128
%define CM_KMAC    384
%define CM_PAGE    4608
%define CM_NODE    8768
%define CM_ACTIVE_NODE 12864
%define CM_FRAME   12928

; =============================================================================
;  db_encrypted_commit(ctx) -> int
; =============================================================================
db_encrypted_commit:
    FRAME_BEGIN CM_FRAME, 2
    mov     [rbp - 8], rbx
    mov     [rbp - 16], r12
    mov     [rbp - 24], r13

    mov     rbx, ARG1
    mov     [rbp - 40], rbx

    cmp     qword [rbx + DB_CACHE], 0
    je      .not_encrypted

    ; The inactive copy may be two generations behind. Its root node and the
    ; active root tell us exactly which leaves differ, so only those leaves are
    ; copied forward before this transaction is applied.
    mov     rax, [rbx + DB_SEAL_DIR]
    mov     [rbp - 72], rax
    mov     rcx, [rbx + DB_SEAL_LEAVES]
    inc     rcx                         ; one depth-one root follows the leaves
    cmp     qword [rbx + DB_SB_PAGE], CybouDB_SB_PAGE_A
    jne     .inactive_is_a
    add     rax, rcx
    jmp     .inactive_known
.inactive_is_a:
    sub     rax, rcx
.inactive_known:
    mov     [rbp - 80], rax

    mov     rax, [rbp - 72]
    add     rax, [rbx + DB_SEAL_LEAVES]
    shl     rax, CybouDB_PAGE_SHIFT
    mov     ARG1, [rbx + DB_HANDLE]
    lea     ARG2, [rbp - CM_ACTIVE_NODE]
    mov     ARG3, CybouDB_PAGE_SIZE
    mov     ARG4, rax
    call    vfs_read_at
    cmp     rax, CybouDB_PAGE_SIZE
    jne     .failed

    mov     rbx, [rbp - 40]
    mov     rax, [rbp - 80]
    add     rax, [rbx + DB_SEAL_LEAVES]
    shl     rax, CybouDB_PAGE_SHIFT
    mov     ARG1, [rbx + DB_HANDLE]
    lea     ARG2, [rbp - CM_NODE]
    mov     ARG3, CybouDB_PAGE_SIZE
    mov     ARG4, rax
    call    vfs_read_at
    cmp     rax, CybouDB_PAGE_SIZE
    jne     .failed

    xor     r13, r13
.copy_leaf:
    mov     rbx, [rbp - 40]
    cmp     r13, [rbx + DB_SEAL_LEAVES]
    jae     .copy_done
    mov     rax, r13
    shl     rax, 4
    lea     r10, [rbp - CM_ACTIVE_NODE + SNODE_CHILDREN]
    lea     r11, [rbp - CM_NODE + SNODE_CHILDREN]
    mov     rcx, [r10 + rax]
    xor     rcx, [r11 + rax]
    mov     rdx, [r10 + rax + 8]
    xor     rdx, [r11 + rax + 8]
    or      rcx, rdx
    jz      .next_copy_leaf

    mov     rax, [rbp - 72]
    add     rax, r13
    shl     rax, CybouDB_PAGE_SHIFT
    mov     ARG1, [rbx + DB_HANDLE]
    lea     ARG2, [rbp - CM_PAGE]
    mov     ARG3, CybouDB_PAGE_SIZE
    mov     ARG4, rax
    call    vfs_read_at
    cmp     rax, CybouDB_PAGE_SIZE
    jne     .failed

    mov     rbx, [rbp - 40]
    mov     rax, [rbp - 80]
    add     rax, r13
    shl     rax, CybouDB_PAGE_SHIFT
    mov     ARG1, [rbx + DB_HANDLE]
    lea     ARG2, [rbp - CM_PAGE]
    mov     ARG3, CybouDB_PAGE_SIZE
    mov     ARG4, rax
    call    vfs_write_at
    cmp     rax, CybouDB_PAGE_SIZE
    jne     .failed
.next_copy_leaf:
    inc     r13
    jmp     .copy_leaf
.copy_done:

    ; --- 1 and 2: the pages and the leaves that describe them ----------------
    mov     rbx, [rbp - 40]
    mov     ARG1, rbx
    call    db_pages_flush
    test    eax, eax
    jnz     .failed

    ; --- 3: the node above the leaves ----------------------------------------
    ;  Rebuilt from the leaves as they now stand on the disk rather than from
    ;  anything remembered: what the node must attest to is what a reader will
    ;  find, and the only way to be sure of that is to read it.
    mov     rbx, [rbp - 40]
    mov     rax, [rbp - 80]
    add     rax, [rbx + DB_SEAL_LEAVES]
    mov     [rbp - 48], rax             ; the node's page

    mov     rax, [rbx + DB_GENERATION]
    inc     rax
    mov     [rbp - 56], rax             ; the generation being published

    lea     ARG1, [rbp - CM_NODE]
    xor     ARG2, ARG2
    mov     ARG3, 1
    mov     ARG4, [rbp - 56]
    mov     rax, [rbx + DB_SEAL_EPOCH]
    PASS_ARG5 rax
    call    cyboudb_seal_node_init

    xor     r13, r13
.leaf:
    mov     rbx, [rbp - 40]
    cmp     r13, [rbx + DB_SEAL_LEAVES]
    jae     .leaves_done

    mov     rax, [rbp - 80]
    add     rax, r13
    shl     rax, CybouDB_PAGE_SHIFT
    mov     ARG1, [rbx + DB_HANDLE]
    lea     ARG2, [rbp - CM_PAGE]
    mov     ARG3, CybouDB_PAGE_SIZE
    mov     ARG4, rax
    call    vfs_read_at
    cmp     rax, CybouDB_PAGE_SIZE
    jne     .failed

    mov     rbx, [rbp - 40]
    lea     ARG1, [rbp - CM_MAC]
    lea     ARG2, [rbx + DB_TREE_KEY]
    lea     ARG3, [rbp - CM_PAGE]
    call    cyboudb_seal_leaf_mac

    lea     ARG1, [rbp - CM_NODE]
    mov     ARG2, r13
    lea     ARG3, [rbp - CM_MAC]
    call    cyboudb_seal_node_set_child
    test    eax, eax
    jnz     .failed

    inc     r13
    jmp     .leaf

.leaves_done:
    lea     ARG1, [rbp - CM_NODE]
    mov     ARG2, SNODE_CRC
    CALL_ABI crc32c
    lea     r10, [rbp - CM_NODE]
    mov     [r10 + SNODE_CRC], eax

    mov     rbx, [rbp - 40]
    lea     ARG1, [rbp - CM_MAC]
    lea     ARG2, [rbx + DB_TREE_KEY]
    lea     ARG3, [rbp - CM_NODE]
    call    cyboudb_seal_node_mac

    mov     rbx, [rbp - 40]
    mov     ARG1, [rbx + DB_HANDLE]
    lea     ARG2, [rbp - CM_NODE]
    mov     ARG3, CybouDB_PAGE_SIZE
    mov     rax, [rbp - 48]
    shl     rax, CybouDB_PAGE_SHIFT
    mov     ARG4, rax
    call    vfs_write_at
    cmp     rax, CybouDB_PAGE_SIZE
    jne     .failed

    ; --- the first barrier ---------------------------------------------------
    ;  Everything the new generation needs is now on the disk except the claim
    ;  that it exists. A crash from here on leaves the old generation whole.
    mov     rbx, [rbp - 40]
    mov     ARG1, [rbx + DB_HANDLE]
    call    vfs_sync_file
    test    eax, eax
    jnz     .failed

    ; --- 4: the superblock, into the copy that is not live -------------------
    mov     rbx, [rbp - 40]
    mov     rax, [rbx + DB_SB_PAGE]
    cmp     rax, CybouDB_SB_PAGE_A
    jne     .to_a
    mov     qword [rbp - 64], CybouDB_SB_PAGE_B
    jmp     .have_target
.to_a:
    mov     qword [rbp - 64], CybouDB_SB_PAGE_A
.have_target:

    ; built from the live one, so every field this code does not know about
    ; travels forward rather than being lost
    mov     rax, [rbx + DB_SB_PAGE]
    shl     rax, CybouDB_PAGE_SHIFT
    mov     ARG1, [rbx + DB_HANDLE]
    lea     ARG2, [rbp - CM_PAGE]
    mov     ARG3, CybouDB_PAGE_SIZE
    mov     ARG4, rax
    call    vfs_read_at
    cmp     rax, CybouDB_PAGE_SIZE
    jne     .failed

    lea     r10, [rbp - CM_PAGE]
    mov     rax, [rbp - 56]
    mov     [r10 + SB_GENERATION], rax
    mov     rax, [rbp - CM_MAC]
    mov     [r10 + SB_SEAL_ROOT], rax
    mov     rax, [rbp - CM_MAC + 8]
    mov     [r10 + SB_SEAL_ROOT + 8], rax

    mov     rbx, [rbp - 40]
    lea     ARG1, [rbp - CM_KMAC]
    lea     ARG2, [rbx + DB_META_KEY]
    mov     ARG3, 32
    lea     ARG4, [sb_label]
    mov     rax, SB_LABEL_LEN
    PASS_ARG5 rax
    call    cyboudb_kmac256_init
    test    eax, eax
    jnz     .failed

    lea     ARG1, [rbp - CM_KMAC]
    lea     ARG2, [rbp - CM_PAGE]
    mov     ARG3, SB_SEAL_TAG_COVERS
    call    cyboudb_kmac256_update

    lea     ARG1, [rbp - CM_KMAC]
    lea     ARG2, [rbp - CM_PAGE + SB_SEAL_TAG]
    mov     ARG3, SB_SEAL_TAG_SIZE
    call    cyboudb_kmac256_final

    lea     ARG1, [rbp - CM_PAGE]
    mov     ARG2, SB_CRC_LEN
    CALL_ABI crc32c
    lea     r10, [rbp - CM_PAGE]
    mov     [r10 + SB_CRC], eax

    mov     rbx, [rbp - 40]
    mov     ARG1, [rbx + DB_HANDLE]
    lea     ARG2, [rbp - CM_PAGE]
    mov     ARG3, CybouDB_PAGE_SIZE
    mov     rax, [rbp - 64]
    shl     rax, CybouDB_PAGE_SHIFT
    mov     ARG4, rax
    call    vfs_write_at
    cmp     rax, CybouDB_PAGE_SIZE
    jne     .failed

    ; --- the second barrier --------------------------------------------------
    ;  It buys one thing: that the commit is acknowledged. A crash between the
    ;  superblock write and this is indistinguishable from a crash before it,
    ;  and both leave a whole database.
    mov     ARG1, [rbx + DB_HANDLE]
    call    vfs_sync_file
    test    eax, eax
    jnz     .failed

    ; the new generation is the live one now
    mov     rax, [rbp - 56]
    mov     [rbx + DB_GENERATION], rax
    mov     rax, [rbp - 64]
    mov     [rbx + DB_SB_PAGE], rax
    mov     rax, [rbp - 80]
    mov     [rbx + DB_SEAL_DIR], rax

    xor     eax, eax
    jmp     .done

.not_encrypted:
    mov     eax, CybouDB_E_STATE
    jmp     .done
.failed:
    mov     rbx, [rbp - 40]
    ; As in the plain commit path, an I/O failure can mean either generation
    ; reached durable storage. Continuing through this handle could then build
    ; on a generation different from the one a reopen would select.
    mov     qword [rbx + DB_MODE], -1   ; outcome uncertain; reopen required
    mov     qword [rbx + DB_ENC_ERROR], CybouDB_E_SYNC
    mov     eax, CybouDB_E_SYNC

.done:
    mov     rbx, [rbp - 8]
    mov     r12, [rbp - 16]
    mov     r13, [rbp - 24]
    FRAME_END
    ret

%ifdef CybouDB_LINUX
section .note.GNU-stack noalloc noexec nowrite progbits
%endif
