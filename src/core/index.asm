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
extern db_cow_alloc_page, db_cow_copy_page
extern db_bitmap_candidate_payload, db_bitmap_deep, db_bitmap_retire
global db_index_build, db_index_insert, db_index_insert_unique
global db_index_delete
global db_index_search, db_index_validate, index_page_valid
global db_index_node_addr, db_index_of_table, db_index_retire_tree

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
;  Incremental insert
;
;  One row at a time, which is what an INSERT into a table that already has an
;  index does. The path from the root to the leaf is copied - every node on it
;  gets a new page and the old one is retired - so the generation that is still
;  published keeps pointing at a tree that is entirely intact. Nothing else is
;  touched: a node off the path is shared between the two generations, which is
;  what makes a one-row insert cost the height of the tree rather than its size.
;
;  A node that overflows splits in half and hands its right half to its parent,
;  and a root that splits grows a new one above it. Both halves keep 126 of the
;  252 entries the overflow produced, so a tree built this way is at worst half
;  empty and a search over it is still bounded by the same height.
; -----------------------------------------------------------------------------
%define II_CTX      0
%define II_OWNER    8
%define II_KEY      16
%define II_ROW      24
%define II_UNIQUE   32
%define II_SIZE     40

; What a level hands back to the one above it.
%define IO_NODE     0                   ; the copy that replaces the node
%define IO_SIB      8                   ; its new right half, or zero
%define IO_SIB_END  16                  ; the largest key in that half
%define IO_END      24                  ; the largest key in the copy
%define IO_SIZE     32

%define IDX_SPLIT_LEFT 126              ; (IDX_MAX_ENTRIES + 1) / 2

; index_restamp(ARG1 = node, ARG2 = ctx, ARG3 = new page id)
; A copied page still carries the id and generation of the page it came from.
index_restamp:
    mov [ARG1 + IDX_PAGE_ID], ARG3
    mov r10, ARG2
    mov rax, [r10 + DB_GENERATION]
    inc rax
    mov [ARG1 + IDX_GENERATION], rax
    ret

; index_entry_open(ARG1 = node, ARG2 = count, ARG3 = slot)
; Move entries from slot upwards one place, leaving slot free to be written.
index_entry_open:
    mov rax, ARG2
.shift:
    cmp rax, ARG3
    jbe .done
    mov r10, rax
    shl r10, 4
    mov r11, [ARG1 + IDX_ENTRIES + r10 - 16]
    mov [ARG1 + IDX_ENTRIES + r10], r11
    mov r11, [ARG1 + IDX_ENTRIES + r10 - 8]
    mov [ARG1 + IDX_ENTRIES + r10 + 8], r11
    dec rax
    jmp .shift
.done:
    ret

; index_entry_put(ARG1 = node, ARG2 = slot, ARG3 = key, ARG4 = payload)
index_entry_put:
    mov rax, ARG2
    shl rax, 4
    mov [ARG1 + IDX_ENTRIES + rax], ARG3
    mov [ARG1 + IDX_ENTRIES + rax + 8], ARG4
    ret

; index_node_end(ARG1 = node) -> RAX: the largest key it holds.
index_node_end:
    mov eax, [ARG1 + IDX_COUNT]
    dec rax
    shl rax, 4
    mov rax, [ARG1 + IDX_ENTRIES + rax]
    ret

; -----------------------------------------------------------------------------
;  index_insert_node(ARG1 = state, ARG2 = node id, ARG3 = out block)
;      -> RAX: result code
;
;  Local slots: [rbp-8]=state, [rbp-16]=node id, [rbp-24]=out, [rbp-32]=copy id,
;               [rbp-40]=copy address, [rbp-48]=count, [rbp-56]=slot,
;               [rbp-64]=sibling id, [rbp-72]=sibling address,
;               [rbp-80]=child out block (IO_SIZE), [rbp-112]=moved entries
; -----------------------------------------------------------------------------
index_insert_node:
    FRAME_BEGIN 160, 2
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
    mov [rbp - 24], ARG3
    mov qword [rbp - 64], 0

    mov r10, ARG1
    mov ARG1, [r10 + II_CTX]
    mov ARG2, [rbp - 16]
    lea ARG3, [rbp - 32]
    call db_cow_copy_page
    test eax, eax
    jnz .done
    mov r10, [rbp - 8]
    mov ARG1, [r10 + II_CTX]
    mov ARG2, [rbp - 32]
    call index_node_addr
    mov [rbp - 40], rax
    mov ARG1, rax
    mov r10, [rbp - 8]
    mov ARG2, [r10 + II_CTX]
    mov ARG3, [rbp - 32]
    call index_restamp
    mov r10, [rbp - 40]
    mov eax, [r10 + IDX_COUNT]
    mov [rbp - 48], rax
    cmp dword [r10 + IDX_LEVEL], IDX_LEAF
    jne .internal

    ; --- a leaf: find where the entry belongs ------------------------------
    ; Equal keys are ordered by the row they name, which keeps the order total
    ; and every entry distinct.
    mov r11, [rbp - 8]
    mov r8, [r11 + II_KEY]
    mov r9, [r11 + II_ROW]
    xor ecx, ecx
.leaf_slot:
    cmp rcx, [rbp - 48]
    jae .leaf_slot_ready
    mov rax, rcx
    shl rax, 4
    mov rdx, [r10 + IDX_ENTRIES + rax]
    cmp rdx, r8
    jg .leaf_slot_ready
    jl .leaf_slot_next
    cmp qword [r11 + II_UNIQUE], 0
    jne .duplicate
    mov rdx, [r10 + IDX_ENTRIES + rax + 8]
    cmp rdx, r9
    jg .leaf_slot_ready
.leaf_slot_next:
    inc rcx
    jmp .leaf_slot
.leaf_slot_ready:
    mov [rbp - 56], rcx
    jmp .place

.internal:
    ; --- an internal node: the first child that could hold the key ---------
    xor ecx, ecx
    mov r11, [rbp - 8]
    mov r8, [r11 + II_KEY]
.child_slot:
    inc rcx
    cmp rcx, [rbp - 48]
    jae .child_ready
    mov rax, rcx
    dec rax
    shl rax, 4
    mov rdx, [r10 + IDX_ENTRIES + rax]
    cmp rdx, r8
    jl .child_slot
.child_ready:
    dec rcx
    mov [rbp - 56], rcx
    mov rax, rcx
    shl rax, 4
    mov r10, [rbp - 40]
    mov rax, [r10 + IDX_ENTRIES + rax + 8]
    mov ARG1, [rbp - 8]
    mov ARG2, rax
    lea ARG3, [rbp - 112]
    call index_insert_node
    test eax, eax
    jnz .done
    ; The child was replaced by its copy, and its largest key may have grown.
    mov r10, [rbp - 40]
    mov rax, [rbp - 56]
    shl rax, 4
    mov rdx, [rbp - 112 + IO_END]
    mov [r10 + IDX_ENTRIES + rax], rdx
    mov rdx, [rbp - 112 + IO_NODE]
    mov [r10 + IDX_ENTRIES + rax + 8], rdx
    cmp qword [rbp - 112 + IO_SIB], 0
    je .finished
    ; The child split, so this node gains the entry naming its right half.
    inc qword [rbp - 56]
    mov r11, [rbp - 8]
    mov rax, [rbp - 112 + IO_SIB_END]
    mov [r11 + II_KEY], rax             ; the key and payload to place
    mov rax, [rbp - 112 + IO_SIB]
    mov [r11 + II_ROW], rax

.place:
    ; --- place one entry, splitting the node when it does not fit ----------
    mov rax, [rbp - 48]
    cmp rax, IDX_MAX_ENTRIES
    jae .split
    mov ARG1, [rbp - 40]
    mov ARG2, [rbp - 48]
    mov ARG3, [rbp - 56]
    call index_entry_open
    mov ARG1, [rbp - 40]
    mov ARG2, [rbp - 56]
    mov r11, [rbp - 8]
    mov ARG3, [r11 + II_KEY]
    mov ARG4, [r11 + II_ROW]
    call index_entry_put
    mov r10, [rbp - 40]
    mov rax, [rbp - 48]
    inc rax
    mov [r10 + IDX_COUNT], eax
    jmp .finished

.split:
    ; A full node becomes two halves of 126. Which half the new entry lands in
    ; decides how many entries move, and nothing else about the split changes.
    mov ARG1, [rbp - 8]
    mov r10, ARG1
    mov ARG1, [r10 + II_CTX]
    mov ARG2, [r10 + II_OWNER]
    mov r11, [rbp - 40]
    mov eax, [r11 + IDX_LEVEL]
    mov ARG3, rax
    lea ARG4, [rbp - 64]
    call index_new_node
    test eax, eax
    jnz .done
    mov [rbp - 72], rdx

    mov rax, [rbp - 56]
    cmp rax, IDX_SPLIT_LEFT
    jae .split_right

    ; The new entry belongs on the left, so the right half starts one lower.
    mov qword [rbp - 136], IDX_SPLIT_LEFT - 1
    jmp .split_move
.split_right:
    mov qword [rbp - 136], IDX_SPLIT_LEFT
.split_move:
    mov r8, [rbp - 40]
    mov r9, [rbp - 72]
    mov rcx, [rbp - 136]
    xor edx, edx
.split_copy:
    cmp rcx, [rbp - 48]
    jae .split_counts
    mov rax, rcx
    shl rax, 4
    mov r11, [r8 + IDX_ENTRIES + rax]
    mov [rbp - 120], r11
    mov r11, [r8 + IDX_ENTRIES + rax + 8]
    mov rax, rdx
    shl rax, 4
    mov [r9 + IDX_ENTRIES + rax + 8], r11
    mov r11, [rbp - 120]
    mov [r9 + IDX_ENTRIES + rax], r11
    inc rcx
    inc rdx
    jmp .split_copy
.split_counts:
    mov [r9 + IDX_COUNT], edx
    mov [rbp - 128], rdx                ; entries the right half took
    mov rax, [rbp - 136]
    mov [r8 + IDX_COUNT], eax

    mov rax, [rbp - 56]
    cmp rax, IDX_SPLIT_LEFT
    jae .split_into_right
    ; Into the left half, whose count is now IDX_SPLIT_LEFT - 1.
    mov ARG1, [rbp - 40]
    mov ARG2, [rbp - 136]
    mov ARG3, [rbp - 56]
    call index_entry_open
    mov ARG1, [rbp - 40]
    mov ARG2, [rbp - 56]
    mov r11, [rbp - 8]
    mov ARG3, [r11 + II_KEY]
    mov ARG4, [r11 + II_ROW]
    call index_entry_put
    mov r10, [rbp - 40]
    mov rax, [rbp - 136]
    inc rax
    mov [r10 + IDX_COUNT], eax
    jmp .split_seal
.split_into_right:
    mov rax, [rbp - 56]
    sub rax, [rbp - 136]
    mov [rbp - 56], rax                 ; the slot, in the right half
    mov ARG1, [rbp - 72]
    mov ARG2, [rbp - 128]
    mov ARG3, rax
    call index_entry_open
    mov ARG1, [rbp - 72]
    mov ARG2, [rbp - 56]
    mov r11, [rbp - 8]
    mov ARG3, [r11 + II_KEY]
    mov ARG4, [r11 + II_ROW]
    call index_entry_put
    mov r10, [rbp - 72]
    mov rax, [rbp - 128]
    inc rax
    mov [r10 + IDX_COUNT], eax

.split_seal:
    ; Everything above what each half now holds is zero, as every tail is.
    mov ARG1, [rbp - 72]
    call index_tail_clear
    mov ARG1, [rbp - 72]
    call index_seal
    mov ARG1, [rbp - 72]
    call index_node_end
    mov r10, [rbp - 24]
    mov [r10 + IO_SIB_END], rax
    mov rax, [rbp - 64]
    mov r10, [rbp - 24]
    mov [r10 + IO_SIB], rax

.finished:
    mov ARG1, [rbp - 40]
    call index_tail_clear
    mov ARG1, [rbp - 40]
    call index_seal
    mov ARG1, [rbp - 40]
    call index_node_end
    mov r10, [rbp - 24]
    mov [r10 + IO_END], rax
    mov rax, [rbp - 32]
    mov [r10 + IO_NODE], rax
    cmp qword [rbp - 64], 0
    jne .split_done
    mov qword [r10 + IO_SIB], 0
.split_done:
    xor eax, eax
.done:
    FRAME_END
    ret
.duplicate:
    mov eax, CybouDB_E_VALUE
    FRAME_END
    ret

; index_tail_clear(ARG1 = node). Zero everything above the entries it holds:
; a split leaves the vacated half of a node naming pages it no longer owns.
index_tail_clear:
    mov eax, [ARG1 + IDX_COUNT]
    shl rax, 4
    lea r10, [ARG1 + IDX_ENTRIES + rax]
    lea r11, [ARG1 + IDX_CRC]
.loop:
    cmp r10, r11
    jae .done
    mov dword [r10], 0
    add r10, 4
    jmp .loop
.done:
    ret

; -----------------------------------------------------------------------------
;  db_index_insert(ctx, owner, root, key, row, out_root) -> RAX: result code
;  db_index_insert_unique(...) is the same with the constraint enforced, and
;  answers CybouDB_E_VALUE when the tree already holds that key.
;
;  Two entry points rather than a seventh argument: six is what the ABI passes
;  in registers on both platforms, and the flag is a property of the index
;  rather than of the row being inserted.
;
;  Local slots: [rbp-8]=out_root, [rbp-16]=root, [rbp-64]=state (II_SIZE),
;               [rbp-96]=new root id, [rbp-128]=out block, [rbp-144]=level
; -----------------------------------------------------------------------------
db_index_insert_unique:
    mov r11d, 1
    jmp index_insert_common
db_index_insert:
    xor r11d, r11d
index_insert_common:
    FRAME_BEGIN 192, 2
    lea r10, [rbp - 64]                 ; the state, built once for the descent
    mov [r10 + II_CTX], ARG1
    mov [r10 + II_OWNER], ARG2
    mov [r10 + II_KEY], ARG4
    mov [r10 + II_UNIQUE], r11
    mov [rbp - 16], ARG3
    mov rax, IN_ARG5
    mov [r10 + II_ROW], rax
    mov rax, IN_ARG6
    mov [rbp - 8], rax

    cmp qword [rbp - 16], 0
    jne .descend

    ; An empty index: the first entry is a leaf, and that leaf is the root.
    lea r10, [rbp - 64]
    mov ARG1, [r10 + II_CTX]
    mov ARG2, [r10 + II_OWNER]
    xor ARG3, ARG3
    lea ARG4, [rbp - 96]
    call index_new_node
    test eax, eax
    jnz .done
    mov ARG1, rdx
    xor ARG2, ARG2
    lea r10, [rbp - 64]
    mov ARG3, [r10 + II_KEY]
    mov ARG4, [r10 + II_ROW]
    call index_entry_put
    mov r10, [rbp - 96]
    lea r11, [rbp - 64]
    mov ARG1, [r11 + II_CTX]
    mov ARG2, r10
    call index_node_addr
    mov dword [rax + IDX_COUNT], 1
    mov ARG1, rax
    call index_seal
    mov rax, [rbp - 96]
    mov r10, [rbp - 8]
    mov [r10], rax
    xor eax, eax
    jmp .done

.descend:
    lea ARG1, [rbp - 64]
    mov ARG2, [rbp - 16]
    lea ARG3, [rbp - 128]
    call index_insert_node
    test eax, eax
    jnz .done
    cmp qword [rbp - 128 + IO_SIB], 0
    jne .grow
    mov rax, [rbp - 128 + IO_NODE]
    mov r10, [rbp - 8]
    mov [r10], rax
    xor eax, eax
    jmp .done

.grow:
    ; The root split, so the tree gains a level: one node naming both halves.
    lea r10, [rbp - 64]
    mov ARG1, [r10 + II_CTX]
    mov ARG2, [rbp - 128 + IO_NODE]
    call index_node_addr
    mov ecx, [rax + IDX_LEVEL]
    inc rcx
    mov [rbp - 144], rcx
    lea r10, [rbp - 64]
    mov ARG1, [r10 + II_CTX]
    mov ARG2, [r10 + II_OWNER]
    mov ARG3, [rbp - 144]
    lea ARG4, [rbp - 96]
    call index_new_node
    test eax, eax
    jnz .done
    mov [rbp - 152], rdx
    mov ARG1, rdx
    xor ARG2, ARG2
    mov ARG3, [rbp - 128 + IO_END]
    mov ARG4, [rbp - 128 + IO_NODE]
    call index_entry_put
    mov ARG1, [rbp - 152]
    mov ARG2, 1
    mov ARG3, [rbp - 128 + IO_SIB_END]
    mov ARG4, [rbp - 128 + IO_SIB]
    call index_entry_put
    mov r10, [rbp - 152]
    mov dword [r10 + IDX_COUNT], 2
    mov ARG1, r10
    call index_seal
    mov rax, [rbp - 96]
    mov r10, [rbp - 8]
    mov [r10], rax
    xor eax, eax
.done:
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  Delete
;
;  One entry, named by both its key and the row it points at, because a
;  non-unique index holds several entries under one key and only one of them
;  belongs to the row being removed.
;
;  A node is copied only once it is known to survive. The alternative - copy
;  first, discover the node is now empty, abandon the copy - would leave an
;  allocated page nothing references, and the allocation map would be right to
;  object. So the descent reads the node it is standing on and copies it after
;  the child below has reported, which is also when its new contents are known.
;
;  Nothing is merged or rebalanced. A node that loses its last entry is dropped
;  from its parent and a root left with one child collapses into it, so the
;  height never drifts upwards; a node that merely thins out stays thin. A
;  table that deletes enough to matter is compacted by the rewrite in
;  docs/TOMBSTONES.md, and the rewrite rebuilds every index of that table.
; -----------------------------------------------------------------------------

; index_node_drop(ARG1 = ctx, ARG2 = page id): the new tree does not reference
; this node. Retiring it is what db_cow_copy_page does for a node that is
; replaced rather than removed.
index_node_drop:
    jmp db_bitmap_retire

; index_entry_close(ARG1 = node, ARG2 = count, ARG3 = slot)
; Move the entries above slot down one place, covering it.
index_entry_close:
    mov rax, ARG3
.shift:
    inc rax
    cmp rax, ARG2
    jae .done
    mov r10, rax
    shl r10, 4
    mov r11, [ARG1 + IDX_ENTRIES + r10]
    mov [ARG1 + IDX_ENTRIES + r10 - 16], r11
    mov r11, [ARG1 + IDX_ENTRIES + r10 + 8]
    mov [ARG1 + IDX_ENTRIES + r10 - 8], r11
    jmp .shift
.done:
    ret

; index_copy_for_edit(ARG1 = state, ARG2 = node id, ARG3 = out id)
;   -> RAX: result, RDX: the copy's address.
index_copy_for_edit:
    FRAME_BEGIN 32, 0
    mov [rbp - 8], ARG1
    mov [rbp - 24], ARG3
    mov r10, ARG1
    mov ARG1, [r10 + II_CTX]
    call db_cow_copy_page
    test eax, eax
    jnz .done
    mov r10, [rbp - 8]
    mov ARG1, [r10 + II_CTX]
    mov r11, [rbp - 24]
    mov ARG2, [r11]
    call index_node_addr
    mov [rbp - 16], rax
    mov ARG1, rax
    mov r10, [rbp - 8]
    mov ARG2, [r10 + II_CTX]
    mov r11, [rbp - 24]
    mov ARG3, [r11]
    call index_restamp
    mov rdx, [rbp - 16]
    xor eax, eax
.done:
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  index_delete_node(ARG1 = state, ARG2 = node id, ARG3 = out block)
;      -> RAX: result code. IO_NODE is zero when the node no longer exists.
;
;  Local slots: [rbp-8]=state, [rbp-16]=node id, [rbp-24]=out, [rbp-32]=address,
;               [rbp-40]=count, [rbp-48]=slot, [rbp-56]=copy id,
;               [rbp-64]=copy address, [rbp-96]=child out block
; -----------------------------------------------------------------------------
index_delete_node:
    FRAME_BEGIN 128, 2
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
    mov [rbp - 24], ARG3

    mov r10, ARG1
    mov ARG1, [r10 + II_CTX]
    mov ARG2, [rbp - 16]
    call index_node_addr
    mov [rbp - 32], rax
    mov r10, rax
    mov ecx, [r10 + IDX_COUNT]
    mov [rbp - 40], rcx
    cmp dword [r10 + IDX_LEVEL], IDX_LEAF
    jne .internal

    ; --- the leaf holding it, if it holds it at all ------------------------
    mov r11, [rbp - 8]
    mov r8, [r11 + II_KEY]
    mov r9, [r11 + II_ROW]
    xor ecx, ecx
.leaf_slot:
    cmp rcx, [rbp - 40]
    jae .absent
    mov rax, rcx
    shl rax, 4
    mov rdx, [r10 + IDX_ENTRIES + rax]
    cmp rdx, r8
    jg .absent                          ; past where it would have been
    jne .leaf_next
    mov rdx, [r10 + IDX_ENTRIES + rax + 8]
    cmp rdx, r9
    je .leaf_found
.leaf_next:
    inc rcx
    jmp .leaf_slot
.leaf_found:
    mov [rbp - 48], rcx
    cmp qword [rbp - 40], 1
    jne .leaf_shrink
    ; Its last entry: the leaf goes rather than being copied empty.
    mov r10, [rbp - 8]
    mov ARG1, [r10 + II_CTX]
    mov ARG2, [rbp - 16]
    call index_node_drop
    mov r10, [rbp - 24]
    mov qword [r10 + IO_NODE], 0
    xor eax, eax
    jmp .done
.leaf_shrink:
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    lea ARG3, [rbp - 56]
    call index_copy_for_edit
    test eax, eax
    jnz .done
    mov [rbp - 64], rdx
    mov ARG1, rdx
    mov ARG2, [rbp - 40]
    mov ARG3, [rbp - 48]
    call index_entry_close
    jmp .shrunk

.internal:
    ; --- the first child that could hold the key ---------------------------
    xor ecx, ecx
    mov r11, [rbp - 8]
    mov r8, [r11 + II_KEY]
.child_slot:
    inc rcx
    cmp rcx, [rbp - 40]
    jae .child_ready
    mov rax, rcx
    dec rax
    shl rax, 4
    mov rdx, [r10 + IDX_ENTRIES + rax]
    cmp rdx, r8
    jl .child_slot
.child_ready:
    dec rcx
    mov [rbp - 48], rcx
    mov rax, rcx
    shl rax, 4
    mov r10, [rbp - 32]
    mov rax, [r10 + IDX_ENTRIES + rax + 8]
    mov ARG1, [rbp - 8]
    mov ARG2, rax
    lea ARG3, [rbp - 96]
    call index_delete_node
    test eax, eax
    jnz .done
    cmp qword [rbp - 96 + IO_NODE], 0
    jne .child_kept

    ; The child is gone. If it was the only one, so is this node.
    cmp qword [rbp - 40], 1
    jne .child_removed
    mov r10, [rbp - 8]
    mov ARG1, [r10 + II_CTX]
    mov ARG2, [rbp - 16]
    call index_node_drop
    mov r10, [rbp - 24]
    mov qword [r10 + IO_NODE], 0
    xor eax, eax
    jmp .done
.child_removed:
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    lea ARG3, [rbp - 56]
    call index_copy_for_edit
    test eax, eax
    jnz .done
    mov [rbp - 64], rdx
    mov ARG1, rdx
    mov ARG2, [rbp - 40]
    mov ARG3, [rbp - 48]
    call index_entry_close
    jmp .shrunk

.child_kept:
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    lea ARG3, [rbp - 56]
    call index_copy_for_edit
    test eax, eax
    jnz .done
    mov [rbp - 64], rdx
    mov rax, [rbp - 48]
    shl rax, 4
    mov rcx, [rbp - 96 + IO_END]
    mov [rdx + IDX_ENTRIES + rax], rcx
    mov rcx, [rbp - 96 + IO_NODE]
    mov [rdx + IDX_ENTRIES + rax + 8], rcx
    mov r10, [rbp - 64]
    mov rax, [rbp - 40]
    mov [r10 + IDX_COUNT], eax
    jmp .sealed

.shrunk:
    mov r10, [rbp - 64]
    mov rax, [rbp - 40]
    dec rax
    mov [r10 + IDX_COUNT], eax
.sealed:
    mov ARG1, [rbp - 64]
    call index_tail_clear
    mov ARG1, [rbp - 64]
    call index_seal
    mov ARG1, [rbp - 64]
    call index_node_end
    mov r10, [rbp - 24]
    mov [r10 + IO_END], rax
    mov rax, [rbp - 56]
    mov [r10 + IO_NODE], rax
    xor eax, eax
.done:
    FRAME_END
    ret
.absent:
    mov eax, CybouDB_E_NOTFOUND
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  db_index_delete(ctx, owner, root, key, row, out_root) -> RAX: result code,
;  CybouDB_E_NOTFOUND when the tree holds no such entry.
;
;  Local slots: [rbp-8]=out_root, [rbp-16]=root, [rbp-64]=state,
;               [rbp-96]=out block, [rbp-104]=root address
; -----------------------------------------------------------------------------
db_index_delete:
    FRAME_BEGIN 128, 2
    lea r10, [rbp - 64]
    mov [r10 + II_CTX], ARG1
    mov [r10 + II_OWNER], ARG2
    mov [r10 + II_KEY], ARG4
    mov qword [r10 + II_UNIQUE], 0
    mov [rbp - 16], ARG3
    mov rax, IN_ARG5
    mov [r10 + II_ROW], rax
    mov rax, IN_ARG6
    mov [rbp - 8], rax

    cmp qword [rbp - 16], 0
    je .absent

    lea ARG1, [rbp - 64]
    mov ARG2, [rbp - 16]
    lea ARG3, [rbp - 96]
    call index_delete_node
    test eax, eax
    jnz .done
    mov rax, [rbp - 96 + IO_NODE]
    test rax, rax
    jz .publish                         ; the tree is empty now

    ; A root left naming one child is a level nobody needs.
    lea r10, [rbp - 64]
    mov ARG1, [r10 + II_CTX]
    mov ARG2, rax
    call index_node_addr
    mov [rbp - 104], rax
    cmp dword [rax + IDX_LEVEL], IDX_LEAF
    je .keep_root
    cmp dword [rax + IDX_COUNT], 1
    jne .keep_root
    mov rcx, [rax + IDX_ENTRIES + 8]    ; its only child becomes the root
    mov [rbp - 112], rcx
    lea r10, [rbp - 64]
    mov ARG1, [r10 + II_CTX]
    mov ARG2, [rbp - 96 + IO_NODE]
    call index_node_drop
    mov rax, [rbp - 112]
    jmp .publish
.keep_root:
    mov rax, [rbp - 96 + IO_NODE]
.publish:
    mov r10, [rbp - 8]
    mov [r10], rax
    xor eax, eax
.done:
    FRAME_END
    ret
.absent:
    mov eax, CybouDB_E_NOTFOUND
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
;  db_index_of_table(ctx, table id, after this index id, out index id)
;      -> RAX: the index page's address, or zero when there is no next one.
;
;  Every index of a table, one call at a time, in id order: pass zero to start
;  and the id it hands back to continue. Walking the directory is what having
;  no second structure to keep consistent costs, and the directory is one page.
;
;  Local slots: [rbp-8]=ctx, [rbp-16]=table id, [rbp-24]=after, [rbp-32]=out
; -----------------------------------------------------------------------------
db_index_of_table:
    FRAME_BEGIN 48, 0
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
    mov [rbp - 24], ARG3
    mov [rbp - 32], ARG4
    mov r10, ARG1
    test qword [r10 + DB_FEATURES], CybouDB_FEATURE_INDEX
    jz .none
    mov rax, [r10 + DB_ROOT]
    test rax, rax
    jz .none
    shl rax, CybouDB_PAGE_SHIFT
    add rax, [r10 + DB_BASE]
    mov r8, rax                     ; the directory
    mov ecx, [r8 + CAT_COUNT]
    test ecx, ecx
    jz .none
    xor edx, edx
.entry:
    cmp edx, ecx
    jae .none
    mov rax, rdx
    shl rax, 4
    mov r9, [r8 + CAT_DATA + rax]   ; the id this entry names
    cmp r9, [rbp - 24]
    jbe .next
    mov r11, [r8 + CAT_DATA + rax + 8]
    shl r11, CybouDB_PAGE_SHIFT
    add r11, [r10 + DB_BASE]
    cmp dword [r11 + CAT_TYPE], CAT_INDEX
    jne .next
    mov rax, [rbp - 16]
    cmp [r11 + IDX_TABLE], rax
    jne .next
    mov rax, [rbp - 32]
    mov [rax], r9
    mov rax, r11
    FRAME_END
    ret
.next:
    inc edx
    jmp .entry
.none:
    xor eax, eax
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  db_index_retire_tree(ctx, root) -> RAX: 0
;
;  Every node of a tree the new generation will not name. Retirement is
;  recorded, not derived: db_bitmap_recount counts what the map says, so a node
;  left marked payload with nothing pointing at it is a page nobody ever hands
;  out again. A rebuild, an emptied index and a dropped one all leave a whole
;  tree behind, and this is what stops each of them from being a leak.
;
;  Local slots: [rbp-8]=ctx, [rbp-16]=node, [rbp-24]=address, [rbp-32]=index
; -----------------------------------------------------------------------------
db_index_retire_tree:
    FRAME_BEGIN 48, 0
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
    cmp ARG2, 0
    je .done
    mov r10, ARG1
    test qword [r10 + DB_FEATURES], CybouDB_FEATURE_INDEX
    jz .done
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    call index_node_addr
    mov [rbp - 24], rax
    cmp dword [rax + IDX_MAGIC], IDX_MAGIC_VALUE
    jne .done                       ; not a node: retire nothing on a guess
    cmp dword [rax + IDX_LEVEL], IDX_LEAF
    je .retire
    mov qword [rbp - 32], 0
.child:
    mov r10, [rbp - 24]
    mov eax, [r10 + IDX_COUNT]
    cmp [rbp - 32], rax
    jae .retire
    mov rax, [rbp - 32]
    shl rax, 4
    mov r9, [r10 + IDX_ENTRIES + rax + IDX_CHILD]
    mov ARG1, [rbp - 8]
    mov ARG2, r9
    call db_index_retire_tree
    inc qword [rbp - 32]
    jmp .child
.retire:
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    call db_bitmap_retire
.done:
    xor eax, eax
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  index_page_valid(ctx, candidate_sb, index page) -> RAX: 1 or 0
;
;  The catalog directory has already proved this page is payload of the
;  candidate, checksums, and carries the id that names it. What is left is what
;  only an index knows: a column that exists, no flag bit nobody defined, a
;  table to belong to, a zero tail, and a tree that is the tree this page says
;  it is.
; -----------------------------------------------------------------------------
index_page_valid:
    FRAME_BEGIN 32, 2
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
    mov [rbp - 24], ARG3
    mov r10, ARG1
    test qword [r10 + DB_FEATURES], CybouDB_FEATURE_INDEX
    jz .bad
    mov r11, ARG3
    mov eax, [r11 + IDX_COLUMN]
    cmp eax, CAT_MAX_COLUMNS
    jae .bad
    mov eax, [r11 + IDX_FLAGS]
    cmp eax, IDX_UNIQUE
    ja .bad
    cmp qword [r11 + IDX_TABLE], 0
    je .bad

    ; Everything past the table it names is zero, as every tail in this format.
    lea r8, [r11 + IDX_TABLE + 8]
    lea r9, [r11 + CAT_CRC]
.tail:
    cmp r8, r9
    jae .tree
    cmp dword [r8], 0
    jne .bad
    add r8, 4
    jmp .tail

.tree:
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    mov ARG3, [rbp - 24]
    call db_index_validate
    test eax, eax
    jz .bad
    mov eax, 1
    FRAME_END
    ret
.bad:
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
    mov rcx, [rbp - 32]
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
    ; The child goes into a register no argument aliases: ARG1 is RCX on
    ; one of the two ABIs, and loading it would take the child with it.
    mov r9, [r8 + IDX_ENTRIES + rax + IDX_CHILD]
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    mov ARG3, [rbp - 24]
    mov ARG4, r9
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
