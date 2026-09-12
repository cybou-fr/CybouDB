; Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
; SPDX-License-Identifier: Apache-2.0
; Secondary B+tree indexes: node storage, bulk build, descent and validation.
; The decisions behind the layout are in docs/INDEX.md; where the bytes are is
; in include/index.inc.
;
; A node is an ordinary copy-on-write payload page, so nothing here has a crash
; protocol of its own: a new root reaches the superblock through the index page
; and the catalog directory, in the same publication as the table it describes.
%include "cyboudb.inc"
BITS 64
default rel
extern crc32c
extern db_cow_alloc_page
extern db_bitmap_candidate_payload, db_bitmap_deep
global db_index_build, db_index_search, db_index_validate
global db_index_node_addr

section .text

; index_node_addr(ARG1 = ctx, ARG2 = page id) -> RAX: where it is mapped.
db_index_node_addr:
index_node_addr:
    mov rax, ARG2
    shl rax, CybouDB_PAGE_SHIFT
    mov r10, ARG1
    add rax, [r10 + DB_BASE]
    ret

; index_stamp(ARG1 = node, ARG2 = ctx, ARG3 = page id, ARG4 = owner index id)
; The generation is the candidate's, one past what is published: a node this
; transaction wrote belongs to the generation this transaction will publish.
index_stamp:
    mov dword [ARG1 + IDX_MAGIC], IDX_MAGIC_VALUE
    mov dword [ARG1 + IDX_VERSION], IDX_VERSION_VALUE
    mov [ARG1 + IDX_PAGE_ID], ARG3
    mov r10, ARG2
    mov rax, [r10 + DB_GENERATION]
    inc rax
    mov [ARG1 + IDX_GENERATION], rax
    mov [ARG1 + IDX_OWNER], ARG4
    mov dword [ARG1 + IDX_LEVEL], 0
    mov dword [ARG1 + IDX_COUNT], 0
    mov qword [ARG1 + IDX_NEXT], 0
    mov qword [ARG1 + IDX_RESERVED], 0
    mov qword [ARG1 + IDX_RESERVED + 8], 0
    ret

; index_seal(ARG1 = node). Everything ahead of the checksum, as everywhere.
index_seal:
    FRAME_BEGIN 16, 0
    mov [rbp - 8], ARG1
    mov ARG2, IDX_CRC
    call crc32c
    mov r10, [rbp - 8]
    mov [r10 + IDX_CRC], eax
    FRAME_END
    ret

; index_zero_body(ARG1 = node). A node hands out a page whose contents are
; whatever the allocator left; every byte past the entries it claims has to be
; zero, because validation checks it is.
index_zero_body:
    lea r10, [ARG1 + IDX_ENTRIES]
    mov ecx, (IDX_CRC - IDX_ENTRIES) / 4
.loop:
    mov dword [r10], 0
    add r10, 4
    dec ecx
    jnz .loop
    ret

; index_new_node(ARG1 = ctx, ARG2 = owner, ARG3 = level, ARG4 = out page id)
;   -> RAX: result code, and the node's address in RDX on success.
index_new_node:
    FRAME_BEGIN 48, 0
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
    mov [rbp - 24], ARG3
    mov [rbp - 32], ARG4
    mov ARG2, ARG4
    call db_cow_alloc_page
    test eax, eax
    jnz .done
    mov ARG1, [rbp - 8]
    mov r10, [rbp - 32]
    mov ARG2, [r10]
    call index_node_addr
    mov [rbp - 40], rax
    mov ARG1, rax
    mov ARG2, [rbp - 8]
    mov r10, [rbp - 32]
    mov ARG3, [r10]
    mov ARG4, [rbp - 16]
    call index_stamp
    mov ARG1, [rbp - 40]
    call index_zero_body
    mov r10, [rbp - 40]
    mov rax, [rbp - 24]
    mov [r10 + IDX_LEVEL], eax
    mov rdx, r10
    xor eax, eax
.done:
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  db_index_build(ctx, owner index id, entries, count, out_root)
;      -> RAX: result code
;
;  Entries are 16-byte (key, row) pairs, sorted ascending and distinct. The
;  tree is built bottom up: leaves are packed and chained, then each level is
;  produced by walking the chain the level below left behind, which is why no
;  scratch array is needed for a build of any size - the pages already link to
;  each other in the order the next level wants to read them.
;
;  A count of zero leaves the root at zero, which is what an empty index is.
;
;  Local slots: [rbp-8]=ctx, [rbp-16]=owner, [rbp-24]=entries, [rbp-32]=count,
;               [rbp-40]=out_root, [rbp-48]=first node of the level just built,
;               [rbp-56]=nodes in it, [rbp-64]=current node id,
;               [rbp-72]=current node address, [rbp-80]=previous node address,
;               [rbp-88]=cursor, [rbp-96]=level, [rbp-104]=source node id
; -----------------------------------------------------------------------------
db_index_build:
    FRAME_BEGIN 112, 1
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
    mov [rbp - 24], ARG3
    mov [rbp - 32], ARG4
    mov rax, IN_ARG5
    mov [rbp - 40], rax
    mov qword [rax], 0
    cmp qword [rbp - 32], 0
    je .ok

    ; --- the leaves --------------------------------------------------------
    mov qword [rbp - 48], 0
    mov qword [rbp - 56], 0
    mov qword [rbp - 80], 0
    mov qword [rbp - 88], 0
.leaf_node:
    mov rax, [rbp - 88]
    cmp rax, [rbp - 32]
    jae .leaves_done
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    xor ARG3, ARG3                  ; IDX_LEAF
    lea ARG4, [rbp - 64]
    call index_new_node
    test eax, eax
    jnz .done
    mov [rbp - 72], rdx
    ; Chain it behind the previous leaf, or remember it as the first.
    mov rax, [rbp - 80]
    test rax, rax
    jz .leaf_first
    mov rcx, [rbp - 64]
    mov [rax + IDX_NEXT], rcx
    mov ARG1, rax
    call index_seal                 ; the previous leaf is finished now
    jmp .leaf_fill
.leaf_first:
    mov rax, [rbp - 64]
    mov [rbp - 48], rax
.leaf_fill:
    mov r8, [rbp - 72]
    xor ecx, ecx                    ; entries placed in this leaf
.leaf_entry:
    cmp ecx, IDX_MAX_ENTRIES
    jae .leaf_full
    mov rax, [rbp - 88]
    cmp rax, [rbp - 32]
    jae .leaf_full
    shl rax, 4
    add rax, [rbp - 24]
    mov rdx, [rax + IDX_KEY]
    mov r9, [rax + IDX_ROW]
    mov rax, rcx
    shl rax, 4
    mov [r8 + IDX_ENTRIES + rax + IDX_KEY], rdx
    mov [r8 + IDX_ENTRIES + rax + IDX_ROW], r9
    inc qword [rbp - 88]
    inc ecx
    jmp .leaf_entry
.leaf_full:
    mov [r8 + IDX_COUNT], ecx
    mov rax, [rbp - 72]
    mov [rbp - 80], rax
    inc qword [rbp - 56]
    jmp .leaf_node
.leaves_done:
    mov rax, [rbp - 80]
    mov ARG1, rax
    call index_seal                 ; the last leaf has no successor
    mov qword [rbp - 96], 0

    ; --- one level per pass over the chain below it ------------------------
.level:
    cmp qword [rbp - 56], 1
    jbe .rooted
    mov rax, [rbp - 48]
    mov [rbp - 104], rax            ; walk the level just built
    mov qword [rbp - 48], 0
    mov qword [rbp - 56], 0
    mov qword [rbp - 80], 0
    inc qword [rbp - 96]
.parent_node:
    cmp qword [rbp - 104], 0
    je .level_done
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    mov ARG3, [rbp - 96]
    lea ARG4, [rbp - 64]
    call index_new_node
    test eax, eax
    jnz .done
    mov [rbp - 72], rdx
    mov rax, [rbp - 80]
    test rax, rax
    jz .parent_first
    mov rcx, [rbp - 64]
    mov [rax + IDX_NEXT], rcx
    mov ARG1, rax
    call index_seal
    jmp .parent_fill
.parent_first:
    mov rax, [rbp - 64]
    mov [rbp - 48], rax
.parent_fill:
    ; The counter lives in a slot rather than a register: reading a child's
    ; header goes through index_node_addr, and ARG1 is a volatile register on
    ; one of the two ABIs this builds for.
    mov qword [rbp - 112], 0
.parent_entry:
    cmp qword [rbp - 112], IDX_MAX_ENTRIES
    jae .parent_full
    cmp qword [rbp - 104], 0
    je .parent_full
    ; The child, and the largest key anywhere beneath it - which is the last
    ; key of its last entry, whichever kind of node it is.
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 104]
    call index_node_addr
    mov r8, [rbp - 72]
    mov r9d, [rax + IDX_COUNT]
    dec r9
    shl r9, 4
    mov rdx, [rax + IDX_ENTRIES + r9 + 8]   ; IDX_ROW aliases IDX_KEY_END
    cmp dword [rax + IDX_LEVEL], IDX_LEAF
    jne .parent_end_ready
    mov rdx, [rax + IDX_ENTRIES + r9 + IDX_KEY]
.parent_end_ready:
    mov r9, [rbp - 104]
    mov rax, [rax + IDX_NEXT]
    mov [rbp - 104], rax
    mov rax, [rbp - 112]
    shl rax, 4
    mov [r8 + IDX_ENTRIES + rax + IDX_CHILD], r9
    mov [r8 + IDX_ENTRIES + rax + IDX_KEY_END], rdx
    inc qword [rbp - 112]
    jmp .parent_entry
.parent_full:
    mov r8, [rbp - 72]
    mov rax, [rbp - 112]
    mov [r8 + IDX_COUNT], eax
    mov rax, [rbp - 72]
    mov [rbp - 80], rax
    inc qword [rbp - 56]
    jmp .parent_node
.level_done:
    mov ARG1, [rbp - 80]
    call index_seal
    jmp .level

.rooted:
    mov rax, [rbp - 48]
    mov r10, [rbp - 40]
    mov [r10], rax
.ok:
    xor eax, eax
.done:
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  db_index_search(ctx, root page, key, out_leaf, out_slot) -> RAX: result
;
;  Positions on the first entry whose key is not smaller than the one asked
;  for, which is what both a point lookup and the start of a range want. A
;  position past the last entry of the last leaf is reported as slot equal to
;  that leaf's count, so a caller walks IDX_NEXT and stops naturally.
;
;  The descent trusts the node headers, which validation has already proved:
;  db_index_validate runs before a generation is published, so a tree reached
;  through a live superblock has the shape this walk assumes.
;
;  Local slots: [rbp-8]=ctx, [rbp-16]=node id, [rbp-24]=key,
;               [rbp-32]=out_leaf, [rbp-40]=out_slot, [rbp-48]=node address
; -----------------------------------------------------------------------------
db_index_search:
    FRAME_BEGIN 64, 1
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
    mov [rbp - 24], ARG3
    mov [rbp - 32], ARG4
    mov rax, IN_ARG5
    mov [rbp - 40], rax
    mov r10, ARG4
    mov qword [r10], 0
    mov qword [rax], 0
    cmp qword [rbp - 16], 0
    je .empty
.descend:
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    call index_node_addr
    mov [rbp - 48], rax
    cmp dword [rax + IDX_LEVEL], IDX_LEAF
    je .leaf
    ; The first child whose largest key is not smaller than the one wanted,
    ; and the last child when none is: a key past everything belongs at the end.
    mov r8, rax
    mov r9d, [r8 + IDX_COUNT]
    xor ecx, ecx
.child:
    inc ecx
    cmp ecx, r9d
    jae .child_ready
    mov rax, rcx
    dec rax
    shl rax, 4
    mov rdx, [r8 + IDX_ENTRIES + rax + IDX_KEY_END]
    cmp rdx, [rbp - 24]
    jl .child
.child_ready:
    dec ecx
    mov rax, rcx
    shl rax, 4
    mov rax, [r8 + IDX_ENTRIES + rax + IDX_CHILD]
    mov [rbp - 16], rax
    jmp .descend
.leaf:
    mov r8, [rbp - 48]
    mov r9d, [r8 + IDX_COUNT]
    xor ecx, ecx
.slot:
    cmp ecx, r9d
    jae .slot_ready
    mov rax, rcx
    shl rax, 4
    mov rdx, [r8 + IDX_ENTRIES + rax + IDX_KEY]
    cmp rdx, [rbp - 24]
    jge .slot_ready
    inc ecx
    jmp .slot
.slot_ready:
    mov rax, [rbp - 32]
    mov rdx, [rbp - 16]
    mov [rax], rdx
    mov rax, [rbp - 40]
    mov [rax], rcx
.empty:
    xor eax, eax
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  db_index_validate(ctx, candidate_sb, index page) -> RAX: 1 or 0
;
;  Walks every node of one index and proves the tree is the tree its index
;  page claims: each node is payload of this candidate, checksums, belongs to
;  this index, sits at the level its parent says, holds no more entries than a
;  node can and no fewer than one, and orders them strictly. Entries below the
;  count are checked; bytes above it are checked to be zero.
;
;  What it does not check is that a leaf entry names the row that actually
;  holds that key: the rows live in the PAX graph, and `cyboudb check` is where
;  the two structures are compared.
;
;  Local slots: [rbp-8]=ctx, [rbp-16]=sb, [rbp-24]=index page, [rbp-32]=root,
;               [rbp-40]=seen entries, [rbp-48]=level of the root
; -----------------------------------------------------------------------------
db_index_validate:
    FRAME_BEGIN 64, 2
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
    mov [rbp - 24], ARG3
    mov qword [rbp - 40], 0
    mov r10, ARG3
    mov rax, [r10 + IDX_ROOT]
    mov [rbp - 32], rax
    test rax, rax
    jnz .walk
    cmp qword [r10 + IDX_ROWS], 0
    jne .bad                        ; an empty tree holds no rows
    jmp .good
.walk:
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    mov ARG3, [rbp - 24]
    mov ARG4, [rbp - 32]
    mov rax, -1
    PASS_ARG5 rax                   ; the root's level is whatever it says
    lea rax, [rbp - 40]
    PASS_ARG6 rax
    call index_node_validate
    test eax, eax
    jz .bad
    mov r10, [rbp - 24]
    mov rax, [rbp - 40]
    cmp rax, [r10 + IDX_ROWS]
    jne .bad                        ; the leaves hold what the index claims
.good:
    mov eax, 1
    FRAME_END
    ret
.bad:
    xor eax, eax
    FRAME_END
    ret

; index_node_validate(ctx, sb, index page, node id, expected level, seen)
;   -> RAX: 1 or 0. Recursive: a tree of 28 million rows is four levels deep,
;   so the depth of this recursion is bounded by the format rather than by the
;   data. An expected level of -1 accepts whatever the node says, which is how
;   the root is entered.
;
;  Local slots: [rbp-8]=ctx, [rbp-16]=sb, [rbp-24]=index page, [rbp-32]=node id,
;               [rbp-40]=expected level, [rbp-48]=seen, [rbp-56]=address,
;               [rbp-64]=count, [rbp-72]=index, [rbp-80]=previous key end
index_node_validate:
    FRAME_BEGIN 96, 2
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
    mov [rbp - 24], ARG3
    mov [rbp - 32], ARG4
    mov rax, IN_ARG5
    mov [rbp - 40], rax
    mov rax, IN_ARG6
    mov [rbp - 48], rax
    mov qword [rbp - 88], 0         ; leaf entries this node holds

    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    mov ARG3, [rbp - 32]
    call db_bitmap_candidate_payload
    test eax, eax
    jz .bad

    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 32]
    call index_node_addr
    mov [rbp - 56], rax
    cmp dword [rax + IDX_MAGIC], IDX_MAGIC_VALUE
    jne .bad
    cmp dword [rax + IDX_VERSION], IDX_VERSION_VALUE
    jne .bad
    mov rcx, [rbp - 32]
    cmp [rax + IDX_PAGE_ID], rcx
    jne .bad
    mov rcx, [rax + IDX_GENERATION]
    test rcx, rcx
    jz .bad
    mov r11, [rbp - 16]
    cmp rcx, [r11 + SB_GENERATION]
    ja .bad
    mov r11, [rbp - 24]
    mov rdx, [r11 + CAT_OWNER]
    cmp [rax + IDX_OWNER], rdx
    jne .bad
    cmp qword [rax + IDX_RESERVED], 0
    jne .bad
    cmp qword [rax + IDX_RESERVED + 8], 0
    jne .bad
    mov rdx, [rbp - 40]
    cmp rdx, -1
    je .level_ok
    cmp [rax + IDX_LEVEL], edx
    jne .bad
.level_ok:
    mov edx, [rax + IDX_COUNT]
    test edx, edx
    jz .bad                         ; a node that is reached holds something
    cmp edx, IDX_MAX_ENTRIES
    ja .bad
    mov [rbp - 64], rdx

    ; The checksum, and only where the file's own rules ask for it.
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    mov r10, [rbp - 56]
    mov ARG3, [r10 + IDX_GENERATION]
    call db_bitmap_deep
    test eax, eax
    jz .body
    mov ARG1, [rbp - 56]
    mov ARG2, IDX_CRC
    call crc32c
    mov r10, [rbp - 56]
    cmp [r10 + IDX_CRC], eax
    jne .bad

.body:
    ; Everything past the entries this node claims is zero, as every tail in
    ; this format is.
    mov r8, [rbp - 56]
    mov rax, [rbp - 64]
    shl rax, 4
    lea r9, [r8 + IDX_ENTRIES + rax]
    lea r11, [r8 + IDX_CRC]
.tail:
    cmp r9, r11
    jae .ordered
    cmp dword [r9], 0
    jne .bad
    add r9, 4
    jmp .tail

.ordered:
    mov qword [rbp - 72], 0
    mov rax, 0x8000000000000000
    mov [rbp - 80], rax             ; nothing can sort below this
    mov r8, [rbp - 56]
    cmp dword [r8 + IDX_LEVEL], IDX_LEAF
    je .leaf_entries

.child_entries:
    mov rax, [rbp - 72]
    cmp rax, [rbp - 64]
    jae .entries_done
    shl rax, 4
    mov r8, [rbp - 56]
    mov rdx, [r8 + IDX_ENTRIES + rax + IDX_KEY_END]
    mov rcx, [rbp - 72]
    test rcx, rcx
    jz .child_end_ok
    cmp rdx, [rbp - 80]
    jle .bad                        ; strictly increasing by the key it ends at
.child_end_ok:
    mov [rbp - 80], rdx
    mov rcx, [r8 + IDX_ENTRIES + rax + IDX_CHILD]
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    mov ARG3, [rbp - 24]
    mov ARG4, rcx
    mov r10, [rbp - 56]
    mov eax, [r10 + IDX_LEVEL]
    dec rax
    PASS_ARG5 rax
    mov rax, [rbp - 48]
    PASS_ARG6 rax
    call index_node_validate
    test eax, eax
    jz .bad
    inc qword [rbp - 72]
    jmp .child_entries

.leaf_entries:
    mov rax, [rbp - 72]
    cmp rax, [rbp - 64]
    jae .entries_done
    shl rax, 4
    mov r8, [rbp - 56]
    mov rdx, [r8 + IDX_ENTRIES + rax + IDX_KEY]
    mov rcx, [rbp - 72]
    test rcx, rcx
    jz .leaf_key_ok
    cmp rdx, [rbp - 80]
    jl .bad                         ; keys never go backwards inside a leaf
.leaf_key_ok:
    mov [rbp - 80], rdx
    inc qword [rbp - 72]
    inc qword [rbp - 88]
    jmp .leaf_entries

.entries_done:
    mov r8, [rbp - 56]
    cmp dword [r8 + IDX_LEVEL], IDX_LEAF
    jne .valid
    mov rax, [rbp - 48]
    mov rdx, [rbp - 88]
    add [rax], rdx
.valid:
    mov eax, 1
    FRAME_END
    ret
.bad:
    xor eax, eax
    FRAME_END
    ret

%ifdef CybouDB_LINUX
section .note.GNU-stack noalloc noexec nowrite progbits
%endif
