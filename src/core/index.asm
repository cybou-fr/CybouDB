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
    mov qword [ARG1 + IDX_RESERVED], 0
    mov qword [ARG1 + IDX_RESERVED + 8], 0
    mov qword [ARG1 + IDX_RESERVED + 16], 0
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
;  Bulk build
;
;  One node per level is open at a time, and a finished node is handed to the
;  level above as soon as the next one starts. So a build of any size costs the
;  eight-level state below and nothing else: no scratch array proportional to
;  the table, and no second pass over what was just written.
;
;  A node is pushed upwards when the next entry arrives rather than when it
;  fills, which is what makes the last node of every level the open one at the
;  end - and that is what lets the finish decide the root by asking which level
;  made exactly one node.
; -----------------------------------------------------------------------------
%define BS_CTX      0
%define BS_OWNER    8
%define BS_OPEN     16                  ; 8 qwords: the open node's page id
%define BS_ADDR     80                  ; where it is mapped
%define BS_COUNT    144                 ; entries placed in it
%define BS_LAST     208                 ; the largest key under it so far
%define BS_MADE     272                 ; nodes created at this level
%define BS_SIZE     336
%define IDX_MAX_LEVELS 8

; index_close(ARG1 = state, ARG2 = level): write the open node's count and seal
; it. The node stays in the state; what happens to it next is the caller's.
index_close:
    FRAME_BEGIN 32, 0
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
    mov r10, ARG1
    mov rax, ARG2
    mov r11, [r10 + BS_ADDR + rax * 8]
    mov rcx, [r10 + BS_COUNT + rax * 8]
    mov [r11 + IDX_COUNT], ecx
    mov ARG1, r11
    call index_seal
    xor eax, eax
    FRAME_END
    ret

; index_push(ARG1 = state, ARG2 = level, ARG3 = key, ARG4 = payload)
;   -> RAX: result code.
;
; Recursive, and a full node handed to the level above is the only way it
; recurses, so its depth is the height of the tree.
;
;  Local slots: [rbp-8]=state, [rbp-16]=level, [rbp-24]=key, [rbp-32]=payload,
;               [rbp-40]=a node being handed up, [rbp-48]=its largest key
index_push:
    FRAME_BEGIN 64, 0
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
    mov [rbp - 24], ARG3
    mov [rbp - 32], ARG4
    cmp ARG2, IDX_MAX_LEVELS
    jae .too_deep
    mov r10, ARG1
    mov rax, ARG2
    cmp qword [r10 + BS_OPEN + rax * 8], 0
    je .open_one
    cmp qword [r10 + BS_COUNT + rax * 8], IDX_MAX_ENTRIES
    jb .place
    ; Full, and something else has arrived: this node is finished.
    mov ARG1, r10
    mov ARG2, [rbp - 16]
    call index_close
    mov r10, [rbp - 8]
    mov rax, [rbp - 16]
    mov rcx, [r10 + BS_OPEN + rax * 8]
    mov [rbp - 40], rcx
    mov rcx, [r10 + BS_LAST + rax * 8]
    mov [rbp - 48], rcx
    mov qword [r10 + BS_OPEN + rax * 8], 0
    mov ARG1, r10
    mov ARG2, [rbp - 16]
    inc ARG2
    mov ARG3, [rbp - 48]
    mov ARG4, [rbp - 40]
    call index_push
    test eax, eax
    jnz .done
    mov r10, [rbp - 8]
.open_one:
    mov ARG1, [r10 + BS_CTX]
    mov ARG2, [r10 + BS_OWNER]
    mov ARG3, [rbp - 16]
    mov rax, [rbp - 16]
    lea ARG4, [r10 + BS_OPEN + rax * 8]
    call index_new_node
    test eax, eax
    jnz .done
    mov r10, [rbp - 8]
    mov rax, [rbp - 16]
    mov [r10 + BS_ADDR + rax * 8], rdx
    mov qword [r10 + BS_COUNT + rax * 8], 0
    inc qword [r10 + BS_MADE + rax * 8]
.place:
    mov r10, [rbp - 8]
    mov rax, [rbp - 16]
    mov r11, [r10 + BS_ADDR + rax * 8]
    mov rcx, [r10 + BS_COUNT + rax * 8]
    mov rdx, rcx
    shl rdx, 4
    mov r8, [rbp - 24]
    mov [r11 + IDX_ENTRIES + rdx], r8            ; the key, in both node kinds
    mov r9, [rbp - 32]
    mov [r11 + IDX_ENTRIES + rdx + 8], r9        ; the row, or the child
    inc rcx
    mov [r10 + BS_COUNT + rax * 8], rcx
    mov [r10 + BS_LAST + rax * 8], r8
    xor eax, eax
.done:
    FRAME_END
    ret
.too_deep:
    mov eax, CybouDB_E_FULL
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  db_index_build(ctx, owner index id, entries, count, out_root)
;      -> RAX: result code
;
;  Entries are 16-byte (key, row) pairs, sorted ascending and distinct. A count
;  of zero leaves the root at zero, which is what an empty index is.
;
;  Local slots: [rbp-8]=entries, [rbp-16]=count, [rbp-24]=out_root,
;               [rbp-32]=cursor, [rbp-40]=level; the builder state sits below.
; -----------------------------------------------------------------------------
db_index_build:
    FRAME_BEGIN 64 + BS_SIZE, 0
    mov [rbp - 8], ARG3
    mov [rbp - 16], ARG4
    mov rax, IN_ARG5
    mov [rbp - 24], rax
    mov qword [rax], 0

    lea r10, [rbp - 64 - BS_SIZE]
    mov [r10 + BS_CTX], ARG1
    mov [r10 + BS_OWNER], ARG2
    xor ecx, ecx
.clear:
    mov qword [r10 + BS_OPEN + rcx * 8], 0
    mov qword [r10 + BS_ADDR + rcx * 8], 0
    mov qword [r10 + BS_COUNT + rcx * 8], 0
    mov qword [r10 + BS_LAST + rcx * 8], 0
    mov qword [r10 + BS_MADE + rcx * 8], 0
    inc ecx
    cmp ecx, IDX_MAX_LEVELS
    jb .clear

    cmp qword [rbp - 16], 0
    je .ok
    mov qword [rbp - 32], 0
.entry:
    mov rax, [rbp - 32]
    cmp rax, [rbp - 16]
    jae .finish
    shl rax, 4
    add rax, [rbp - 8]
    mov ARG3, [rax + IDX_KEY]
    mov ARG4, [rax + IDX_ROW]
    lea ARG1, [rbp - 64 - BS_SIZE]
    xor ARG2, ARG2                      ; level 0, the leaves
    call index_push
    test eax, eax
    jnz .done
    inc qword [rbp - 32]
    jmp .entry

    ; --- which level holds the root ----------------------------------------
    ; Every non-empty level ends with exactly one open node. The lowest level
    ; that made only one is the root, and every level below it is closed and
    ; handed upwards on the way there.
.finish:
    mov qword [rbp - 40], 0
.level:
    lea r10, [rbp - 64 - BS_SIZE]
    mov rax, [rbp - 40]
    cmp qword [r10 + BS_MADE + rax * 8], 1
    je .root
    lea ARG1, [rbp - 64 - BS_SIZE]
    mov ARG2, [rbp - 40]
    call index_close
    lea r10, [rbp - 64 - BS_SIZE]
    mov rax, [rbp - 40]
    mov rcx, [r10 + BS_OPEN + rax * 8]
    mov rdx, [r10 + BS_LAST + rax * 8]
    mov qword [r10 + BS_OPEN + rax * 8], 0
    mov ARG3, rdx
    mov ARG4, rcx
    lea ARG1, [rbp - 64 - BS_SIZE]
    mov ARG2, [rbp - 40]
    inc ARG2
    call index_push
    test eax, eax
    jnz .done
    inc qword [rbp - 40]
    cmp qword [rbp - 40], IDX_MAX_LEVELS
    jb .level
    mov eax, CybouDB_E_FULL
    jmp .done
.root:
    lea ARG1, [rbp - 64 - BS_SIZE]
    mov ARG2, [rbp - 40]
    call index_close
    lea r10, [rbp - 64 - BS_SIZE]
    mov rax, [rbp - 40]
    mov rcx, [r10 + BS_OPEN + rax * 8]
    mov r11, [rbp - 24]
    mov [r11], rcx
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
;  key past everything this tree holds is reported as the slot equal to the
;  last leaf's count, which is the position one past its last entry.
;
;  There is no sibling pointer to continue along: a range scan re-descends,
;  or keeps the path it came down. See include/index.inc for why a leaf chain
;  and copy-on-write cannot both be right.
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
    cmp qword [rax + IDX_RESERVED + 16], 0
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
