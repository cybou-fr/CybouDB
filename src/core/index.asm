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
extern db_bitmap_is_fresh
global db_index_build, db_index_insert, db_index_insert_unique
global db_index_delete
global db_index_search, db_index_validate, index_page_valid
global db_index_iter_open, db_index_iter_next
global db_index_node_addr, db_index_of_table, db_index_retire_tree

section .data
; Nodes this process looked at while validating. A test can prove that a
; commit stopped at the path a transaction touched rather than walking the
; index, which is a claim about cost that an assertion about results
; cannot make.
global index_nodes_walked
index_nodes_walked: dq 0

global index_child_reads
index_child_reads: dq 0

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
    mov qword [ARG1 + IDX_SUBTREE], 0
    mov qword [ARG1 + IDX_RESERVED], 0
    mov qword [ARG1 + IDX_RESERVED + 8], 0
    ret

; index_seal(ARG1 = node, ARG2 = ctx). The checksum, over everything ahead of
; it. The ctx is no longer read: it stays in the signature because every writer
; passes it and the next thing to need it will be a writer too.
;
; Sealing used to recompute IDX_SUBTREE from the node's children, which read
; one header per child - up to 251 random pages on a node that was otherwise
; four page copies. The size is maintained where the change is made instead:
; an insert adds one to every node on the path it copied, a delete takes one
; away, and a split recomputes only the half that moved.
index_seal:
    FRAME_BEGIN 32, 0
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
%define BS_SUB      336                 ; entries under the open node
%define BS_LAST_ROW 400                 ; the row that key ends at
%define BS_SIZE     464

; A slot number becomes a byte offset into IDX_ENTRIES. Both node kinds use
; the same stride, so this is the only place that knows what it is.
%macro IDX_SLOT 1
    lea %1, [%1 + %1 * 2]
    shl %1, 3
%endmacro
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
    mov rcx, [r10 + BS_SUB + rax * 8]
    mov [r11 + IDX_SUBTREE], rcx
    mov ARG1, r11
    mov r10, [rbp - 8]
    mov ARG2, [r10 + BS_CTX]
    call index_seal
    xor eax, eax
    FRAME_END
    ret

; index_push(ARG1 = state, ARG2 = level, ARG3 = key, ARG4 = row, ARG5 = payload)
;   -> RAX: result code. The pair (key, row) is what the entry is ordered by
;   at every level; the payload is a child below the leaves and zero at them.
;
; Recursive, and a full node handed to the level above is the only way it
; recurses, so its depth is the height of the tree.
;
;  Local slots: [rbp-8]=state, [rbp-16]=level, [rbp-24]=key, [rbp-32]=row,
;               [rbp-40]=a node being handed up, [rbp-48]=its largest key,
;               [rbp-56]=payload, [rbp-64]=the row that key ends at
index_push:
    FRAME_BEGIN 80, 1
    mov rax, IN_ARG5
    mov [rbp - 56], rax
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
    mov rcx, [r10 + BS_LAST_ROW + rax * 8]
    mov [rbp - 64], rcx
    mov qword [r10 + BS_OPEN + rax * 8], 0
    mov rax, [rbp - 40]
    PASS_ARG5 rax
    mov ARG1, r10
    mov ARG2, [rbp - 16]
    inc ARG2
    mov ARG3, [rbp - 48]
    mov ARG4, [rbp - 64]
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
    mov qword [r10 + BS_SUB + rax * 8], 0
    inc qword [r10 + BS_MADE + rax * 8]
.place:
    mov r10, [rbp - 8]
    mov rax, [rbp - 16]
    mov r11, [r10 + BS_ADDR + rax * 8]
    mov rcx, [r10 + BS_COUNT + rax * 8]
    mov rdx, rcx
    IDX_SLOT rdx
    mov r8, [rbp - 24]
    mov [r11 + IDX_ENTRIES + rdx + IDX_KEY], r8  ; the order, in both kinds
    mov r9, [rbp - 32]
    mov [r11 + IDX_ENTRIES + rdx + IDX_ROW], r9
    mov rcx, [rbp - 56]
    mov [r11 + IDX_ENTRIES + rdx + IDX_CHILD], rcx   ; zero at a leaf
    mov r9, rcx
    mov rcx, [r10 + BS_COUNT + rax * 8]
    inc rcx
    mov [r10 + BS_COUNT + rax * 8], rcx
    mov [r10 + BS_LAST + rax * 8], r8
    mov rcx, [rbp - 32]
    mov [r10 + BS_LAST_ROW + rax * 8], rcx
    ; What this entry adds: one row at a leaf, and at a level above, whatever
    ; the child it names already counted.
    mov rdx, 1
    cmp qword [rbp - 16], 0
    je .one_row
    mov rdx, r9
    shl rdx, CybouDB_PAGE_SHIFT
    mov r11, [r10 + BS_CTX]
    add rdx, [r11 + DB_BASE]
    mov rdx, [rdx + IDX_SUBTREE]
.one_row:
    add [r10 + BS_SUB + rax * 8], rdx
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
    FRAME_BEGIN 64 + BS_SIZE, 1
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
    mov qword [r10 + BS_SUB + rcx * 8], 0
    mov qword [r10 + BS_MADE + rcx * 8], 0
    mov qword [r10 + BS_LAST_ROW + rcx * 8], 0
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
    mov ARG3, [rax + 0]
    mov ARG4, [rax + 8]
    xor rax, rax
    PASS_ARG5 rax                       ; a leaf entry names no child
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
    mov r8, [r10 + BS_LAST_ROW + rax * 8]
    mov qword [r10 + BS_OPEN + rax * 8], 0
    PASS_ARG5 rcx
    mov ARG3, rdx
    mov ARG4, r8
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
%define II_CHILD    40                  ; the payload to place: zero at a leaf
%define II_SIZE     48

; What a level hands back to the one above it. The end of a node is a pair,
; because that is what the level above orders its children by.
%define IO_NODE     0                   ; the copy that replaces the node
%define IO_SIB      8                   ; its new right half, or zero
%define IO_SIB_END  16                  ; the largest key in that half
%define IO_SIB_ROW  24                  ; and the row that key ends at
%define IO_END      32                  ; the largest key in the copy
%define IO_END_ROW  40                  ; and the row that key ends at
%define IO_SIZE     48

%define IDX_SPLIT_LEFT 84               ; (IDX_MAX_ENTRIES + 1) / 2

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
    IDX_SLOT r10
    mov r11, [ARG1 + IDX_ENTRIES + r10 - IDX_ENTRY_SIZE]
    mov [ARG1 + IDX_ENTRIES + r10], r11
    mov r11, [ARG1 + IDX_ENTRIES + r10 - IDX_ENTRY_SIZE + 8]
    mov [ARG1 + IDX_ENTRIES + r10 + 8], r11
    mov r11, [ARG1 + IDX_ENTRIES + r10 - IDX_ENTRY_SIZE + 16]
    mov [ARG1 + IDX_ENTRIES + r10 + 16], r11
    dec rax
    jmp .shift
.done:
    ret

; index_entry_put(ARG1 = node, ARG2 = slot, ARG3 = key, ARG4 = row,
;                 ARG5 = payload)
index_entry_put:
    FRAME_BEGIN 0, 0
    mov rax, ARG2
    IDX_SLOT rax
    mov [ARG1 + IDX_ENTRIES + rax + IDX_KEY], ARG3
    mov [ARG1 + IDX_ENTRIES + rax + IDX_ROW], ARG4
    mov r10, IN_ARG5
    mov [ARG1 + IDX_ENTRIES + rax + IDX_CHILD], r10
    FRAME_END
    ret

; index_node_end(ARG1 = node) -> RAX: the largest key it holds, RDX: the row
; that key ends at. The pair is what the level above orders it by.
index_node_end:
    mov eax, [ARG1 + IDX_COUNT]
    dec rax
    IDX_SLOT rax
    mov rdx, [ARG1 + IDX_ENTRIES + rax + 8]
    mov rax, [ARG1 + IDX_ENTRIES + rax]
    ret

; -----------------------------------------------------------------------------
;  index_insert_node(ARG1 = state, ARG2 = node id, ARG3 = out block)
;      -> RAX: result code
;
;  Local slots: [rbp-8]=state, [rbp-16]=node id, [rbp-24]=out, [rbp-32]=copy id,
;               [rbp-40]=copy address, [rbp-48]=count, [rbp-56]=slot,
;               [rbp-64]=sibling id, [rbp-72]=sibling address,
;               [rbp-120]..[rbp-152]=the split's own counts,
;               [rbp-224]=child out block (IO_SIZE)
; -----------------------------------------------------------------------------
index_insert_node:
    FRAME_BEGIN 240, 2
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
    IDX_SLOT rax
    mov rdx, [r10 + IDX_ENTRIES + rax + IDX_KEY]
    cmp rdx, r8
    jg .leaf_slot_ready
    jl .leaf_slot_next
    cmp qword [r11 + II_UNIQUE], 0
    jne .duplicate
    mov rdx, [r10 + IDX_ENTRIES + rax + IDX_ROW]
    cmp rdx, r9
    jg .leaf_slot_ready
.leaf_slot_next:
    inc rcx
    jmp .leaf_slot
.leaf_slot_ready:
    mov [rbp - 56], rcx
    jmp .place

.internal:
    ; --- an internal node: the first child that could hold the entry -------
    ; By the pair, because a key that names many rows spans several children
    ; and the key alone would send every one of them to the first.
    xor ecx, ecx
    mov r11, [rbp - 8]
    mov r8, [r11 + II_KEY]
    mov r9, [r11 + II_ROW]
.child_slot:
    inc rcx
    cmp rcx, [rbp - 48]
    jae .child_ready
    mov rax, rcx
    dec rax
    IDX_SLOT rax
    mov rdx, [r10 + IDX_ENTRIES + rax + IDX_KEY_END]
    cmp rdx, r8
    jl .child_slot                      ; this child ends below the key
    jg .child_ready
    mov rdx, [r10 + IDX_ENTRIES + rax + IDX_ROW_END]
    cmp rdx, r9
    jl .child_slot                      ; same key, and it ends below the row
.child_ready:
    dec rcx
    mov [rbp - 56], rcx
    mov rax, rcx
    IDX_SLOT rax
    mov r10, [rbp - 40]
    mov rax, [r10 + IDX_ENTRIES + rax + IDX_CHILD]
    mov ARG1, [rbp - 8]
    mov ARG2, rax
    lea ARG3, [rbp - 224]
    call index_insert_node
    test eax, eax
    jnz .done
    ; The child was replaced by its copy, and the pair it ends at may have
    ; grown.
    mov r10, [rbp - 40]
    mov rax, [rbp - 56]
    IDX_SLOT rax
    mov rdx, [rbp - 224 + IO_END]
    mov [r10 + IDX_ENTRIES + rax + IDX_KEY_END], rdx
    mov rdx, [rbp - 224 + IO_END_ROW]
    mov [r10 + IDX_ENTRIES + rax + IDX_ROW_END], rdx
    mov rdx, [rbp - 224 + IO_NODE]
    mov [r10 + IDX_ENTRIES + rax + IDX_CHILD], rdx
    cmp qword [rbp - 224 + IO_SIB], 0
    jne .child_split
    ; The child did not split, so this node gains no entry - but the row
    ; went in below it all the same.
    inc qword [r10 + IDX_SUBTREE]
    jmp .finished
.child_split:
    ; The child split, so this node gains the entry naming its right half.
    inc qword [rbp - 56]
    mov r11, [rbp - 8]
    mov rax, [rbp - 224 + IO_SIB_END]
    mov [r11 + II_KEY], rax             ; the pair and payload to place
    mov rax, [rbp - 224 + IO_SIB_ROW]
    mov [r11 + II_ROW], rax
    mov rax, [rbp - 224 + IO_SIB]
    mov [r11 + II_CHILD], rax

.place:
    ; --- place one entry, splitting the node when it does not fit ----------
    mov rax, [rbp - 48]
    cmp rax, IDX_MAX_ENTRIES
    jae .split
    mov ARG1, [rbp - 40]
    mov ARG2, [rbp - 48]
    mov ARG3, [rbp - 56]
    call index_entry_open
    mov r11, [rbp - 8]
    mov rax, [r11 + II_CHILD]
    PASS_ARG5 rax
    mov ARG1, [rbp - 40]
    mov ARG2, [rbp - 56]
    mov ARG3, [r11 + II_KEY]
    mov ARG4, [r11 + II_ROW]
    call index_entry_put
    mov r10, [rbp - 40]
    mov rax, [rbp - 48]
    inc rax
    mov [r10 + IDX_COUNT], eax
    inc qword [r10 + IDX_SUBTREE]
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
    IDX_SLOT rax
    mov r11, [r8 + IDX_ENTRIES + rax]
    mov [rbp - 120], r11
    mov r11, [r8 + IDX_ENTRIES + rax + 8]
    mov [rbp - 152], r11
    mov r11, [r8 + IDX_ENTRIES + rax + 16]
    mov rax, rdx
    IDX_SLOT rax
    mov [r9 + IDX_ENTRIES + rax + 16], r11
    mov r11, [rbp - 152]
    mov [r9 + IDX_ENTRIES + rax + 8], r11
    mov r11, [rbp - 120]
    mov [r9 + IDX_ENTRIES + rax], r11
    inc rcx
    inc rdx
    jmp .split_copy
.split_counts:
    mov [r9 + IDX_COUNT], edx
    mov [rbp - 128], rdx                ; entries the right half took
    ; What moved with them. A leaf entry is one row; an internal entry carries
    ; whatever its child counted, and only the moved half is read - the left
    ; keeps the remainder by subtraction.
    mov r11, [rbp - 40]
    cmp dword [r11 + IDX_LEVEL], IDX_LEAF
    je .split_rows_are_entries
    xor rax, rax
    xor ecx, ecx
.split_sum:
    cmp rcx, rdx
    jae .split_sum_done
    mov r11, rcx
    IDX_SLOT r11
    mov r11, [r9 + IDX_ENTRIES + r11 + IDX_CHILD]
    shl r11, CybouDB_PAGE_SHIFT
    mov r8, [rbp - 8]
    mov r8, [r8 + II_CTX]
    add r11, [r8 + DB_BASE]
    mov r11, [r11 + IDX_SUBTREE]
    add rax, r11
    inc ecx
    jmp .split_sum
.split_sum_done:
    jmp .split_moved
.split_rows_are_entries:
    mov rax, rdx
.split_moved:
    mov [rbp - 144], rax                ; rows the right half took
    mov r8, [rbp - 40]
    mov r9, [rbp - 72]
    mov rdx, [rbp - 128]
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
    mov r11, [rbp - 8]
    mov rax, [r11 + II_CHILD]
    PASS_ARG5 rax
    mov ARG1, [rbp - 40]
    mov ARG2, [rbp - 56]
    mov ARG3, [r11 + II_KEY]
    mov ARG4, [r11 + II_ROW]
    call index_entry_put
    mov r10, [rbp - 40]
    mov rax, [rbp - 136]
    inc rax
    mov [r10 + IDX_COUNT], eax
    ; The row went left: the right half keeps what it took and the left keeps
    ; everything else, including the one being placed.
    mov rax, [rbp - 144]
    mov r11, [rbp - 72]
    mov [r11 + IDX_SUBTREE], rax
    mov rcx, [r10 + IDX_SUBTREE]
    inc rcx
    sub rcx, rax
    mov [r10 + IDX_SUBTREE], rcx
    jmp .split_seal
.split_into_right:
    mov rax, [rbp - 56]
    sub rax, [rbp - 136]
    mov [rbp - 56], rax                 ; the slot, in the right half
    mov ARG1, [rbp - 72]
    mov ARG2, [rbp - 128]
    mov ARG3, rax
    call index_entry_open
    mov r11, [rbp - 8]
    mov rax, [r11 + II_CHILD]
    PASS_ARG5 rax
    mov ARG1, [rbp - 72]
    mov ARG2, [rbp - 56]
    mov ARG3, [r11 + II_KEY]
    mov ARG4, [r11 + II_ROW]
    call index_entry_put
    mov r10, [rbp - 72]
    mov rax, [rbp - 128]
    inc rax
    mov [r10 + IDX_COUNT], eax
    ; The row went right, so the right half keeps what it took plus this one.
    mov rax, [rbp - 144]
    inc rax
    mov [r10 + IDX_SUBTREE], rax
    mov r11, [rbp - 40]
    mov rcx, [r11 + IDX_SUBTREE]
    inc rcx
    sub rcx, rax
    mov [r11 + IDX_SUBTREE], rcx

.split_seal:
    ; Everything above what each half now holds is zero, as every tail is.
    mov ARG1, [rbp - 72]
    call index_tail_clear
    mov ARG1, [rbp - 72]
    mov r10, [rbp - 8]
    mov ARG2, [r10 + II_CTX]
    call index_seal
    mov ARG1, [rbp - 72]
    call index_node_end
    mov r10, [rbp - 24]
    mov [r10 + IO_SIB_END], rax
    mov [r10 + IO_SIB_ROW], rdx
    mov rax, [rbp - 64]
    mov r10, [rbp - 24]
    mov [r10 + IO_SIB], rax

.finished:
    mov ARG1, [rbp - 40]
    call index_tail_clear
    mov ARG1, [rbp - 40]
    mov r10, [rbp - 8]
    mov ARG2, [r10 + II_CTX]
    call index_seal
    mov ARG1, [rbp - 40]
    call index_node_end
    mov r10, [rbp - 24]
    mov [r10 + IO_END], rax
    mov [r10 + IO_END_ROW], rdx
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
    IDX_SLOT rax
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
;  Local slots: [rbp-8]=out_root, [rbp-16]=root, [rbp-80]=state (II_SIZE),
;               [rbp-88]=new root id, [rbp-96]=level, [rbp-104]=the new root,
;               [rbp-160]=out block (IO_SIZE)
; -----------------------------------------------------------------------------
db_index_insert_unique:
    mov r11d, 1
    jmp index_insert_common
db_index_insert:
    xor r11d, r11d
index_insert_common:
    FRAME_BEGIN 192, 2
    lea r10, [rbp - 80]                 ; the state, built once for the descent
    mov [r10 + II_CTX], ARG1
    mov [r10 + II_OWNER], ARG2
    mov [r10 + II_KEY], ARG4
    mov [r10 + II_UNIQUE], r11
    mov qword [r10 + II_CHILD], 0       ; a row is being placed, not a child
    mov [rbp - 16], ARG3
    mov rax, IN_ARG5
    mov [r10 + II_ROW], rax
    mov rax, IN_ARG6
    mov [rbp - 8], rax

    cmp qword [rbp - 16], 0
    jne .descend

    ; An empty index: the first entry is a leaf, and that leaf is the root.
    lea r10, [rbp - 80]
    mov ARG1, [r10 + II_CTX]
    mov ARG2, [r10 + II_OWNER]
    xor ARG3, ARG3
    lea ARG4, [rbp - 88]
    call index_new_node
    test eax, eax
    jnz .done
    xor rax, rax
    PASS_ARG5 rax
    mov ARG1, rdx
    xor ARG2, ARG2
    lea r10, [rbp - 80]
    mov ARG3, [r10 + II_KEY]
    mov ARG4, [r10 + II_ROW]
    call index_entry_put
    mov r10, [rbp - 88]
    lea r11, [rbp - 80]
    mov ARG1, [r11 + II_CTX]
    mov ARG2, r10
    call index_node_addr
    mov dword [rax + IDX_COUNT], 1
    mov qword [rax + IDX_SUBTREE], 1
    mov ARG1, rax
    lea r10, [rbp - 80]
    mov ARG2, [r10 + II_CTX]
    call index_seal
    mov rax, [rbp - 88]
    mov r10, [rbp - 8]
    mov [r10], rax
    xor eax, eax
    jmp .done

.descend:
    lea ARG1, [rbp - 80]
    mov ARG2, [rbp - 16]
    lea ARG3, [rbp - 160]
    call index_insert_node
    test eax, eax
    jnz .done
    cmp qword [rbp - 160 + IO_SIB], 0
    jne .grow
    mov rax, [rbp - 160 + IO_NODE]
    mov r10, [rbp - 8]
    mov [r10], rax
    xor eax, eax
    jmp .done

.grow:
    ; The root split, so the tree gains a level: one node naming both halves.
    lea r10, [rbp - 80]
    mov ARG1, [r10 + II_CTX]
    mov ARG2, [rbp - 160 + IO_NODE]
    call index_node_addr
    mov ecx, [rax + IDX_LEVEL]
    inc rcx
    mov [rbp - 96], rcx
    lea r10, [rbp - 80]
    mov ARG1, [r10 + II_CTX]
    mov ARG2, [r10 + II_OWNER]
    mov ARG3, [rbp - 96]
    lea ARG4, [rbp - 88]
    call index_new_node
    test eax, eax
    jnz .done
    mov [rbp - 104], rdx
    mov rax, [rbp - 160 + IO_NODE]
    PASS_ARG5 rax
    mov ARG1, rdx
    xor ARG2, ARG2
    mov ARG3, [rbp - 160 + IO_END]
    mov ARG4, [rbp - 160 + IO_END_ROW]
    call index_entry_put
    mov rax, [rbp - 160 + IO_SIB]
    PASS_ARG5 rax
    mov ARG1, [rbp - 104]
    mov ARG2, 1
    mov ARG3, [rbp - 160 + IO_SIB_END]
    mov ARG4, [rbp - 160 + IO_SIB_ROW]
    call index_entry_put
    mov r10, [rbp - 104]
    mov dword [r10 + IDX_COUNT], 2
    lea r11, [rbp - 80]
    mov r11, [r11 + II_CTX]
    mov rax, [rbp - 160 + IO_NODE]
    shl rax, CybouDB_PAGE_SHIFT
    add rax, [r11 + DB_BASE]
    mov rcx, [rax + IDX_SUBTREE]
    mov rax, [rbp - 160 + IO_SIB]
    shl rax, CybouDB_PAGE_SHIFT
    add rax, [r11 + DB_BASE]
    add rcx, [rax + IDX_SUBTREE]
    mov [r10 + IDX_SUBTREE], rcx
    mov ARG1, r10
    lea r10, [rbp - 80]
    mov ARG2, [r10 + II_CTX]
    call index_seal
    mov rax, [rbp - 88]
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
    IDX_SLOT r10
    mov r11, [ARG1 + IDX_ENTRIES + r10]
    mov [ARG1 + IDX_ENTRIES + r10 - IDX_ENTRY_SIZE], r11
    mov r11, [ARG1 + IDX_ENTRIES + r10 + 8]
    mov [ARG1 + IDX_ENTRIES + r10 - IDX_ENTRY_SIZE + 8], r11
    mov r11, [ARG1 + IDX_ENTRIES + r10 + 16]
    mov [ARG1 + IDX_ENTRIES + r10 - IDX_ENTRY_SIZE + 16], r11
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
;               [rbp-64]=copy address, [rbp-160]=child out block
; -----------------------------------------------------------------------------
index_delete_node:
    FRAME_BEGIN 192, 2
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
    IDX_SLOT rax
    mov rdx, [r10 + IDX_ENTRIES + rax + IDX_KEY]
    cmp rdx, r8
    jg .absent                          ; past where it would have been
    jne .leaf_next
    mov rdx, [r10 + IDX_ENTRIES + rax + IDX_ROW]
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
    ; --- the first child that could hold the entry -------------------------
    xor ecx, ecx
    mov r11, [rbp - 8]
    mov r8, [r11 + II_KEY]
    mov r9, [r11 + II_ROW]
.child_slot:
    inc rcx
    cmp rcx, [rbp - 40]
    jae .child_ready
    mov rax, rcx
    dec rax
    IDX_SLOT rax
    mov rdx, [r10 + IDX_ENTRIES + rax + IDX_KEY_END]
    cmp rdx, r8
    jl .child_slot
    jg .child_ready
    mov rdx, [r10 + IDX_ENTRIES + rax + IDX_ROW_END]
    cmp rdx, r9
    jl .child_slot
.child_ready:
    dec rcx
    mov [rbp - 48], rcx
    mov rax, rcx
    IDX_SLOT rax
    mov r10, [rbp - 32]
    mov rax, [r10 + IDX_ENTRIES + rax + IDX_CHILD]
    mov ARG1, [rbp - 8]
    mov ARG2, rax
    lea ARG3, [rbp - 160]
    call index_delete_node
    test eax, eax
    jnz .done
    cmp qword [rbp - 160 + IO_NODE], 0
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
    IDX_SLOT rax
    mov rcx, [rbp - 160 + IO_END]
    mov [rdx + IDX_ENTRIES + rax + IDX_KEY_END], rcx
    mov rcx, [rbp - 160 + IO_END_ROW]
    mov [rdx + IDX_ENTRIES + rax + IDX_ROW_END], rcx
    mov rcx, [rbp - 160 + IO_NODE]
    mov [rdx + IDX_ENTRIES + rax + IDX_CHILD], rcx
    mov r10, [rbp - 64]
    mov rax, [rbp - 40]
    mov [r10 + IDX_COUNT], eax
    jmp .one_fewer

.shrunk:
    mov r10, [rbp - 64]
    mov rax, [rbp - 40]
    dec rax
    mov [r10 + IDX_COUNT], eax
.one_fewer:
    ; Exactly one row leaves the tree, so every node on the path holds one
    ; fewer - including a node that lost a whole child, because a child is
    ; dropped only when the entry it lost was its last.
    mov r10, [rbp - 64]
    dec qword [r10 + IDX_SUBTREE]
.sealed:
    mov ARG1, [rbp - 64]
    call index_tail_clear
    mov ARG1, [rbp - 64]
    mov r10, [rbp - 8]
    mov ARG2, [r10 + II_CTX]
    call index_seal
    mov ARG1, [rbp - 64]
    call index_node_end
    mov r10, [rbp - 24]
    mov [r10 + IO_END], rax
    mov [r10 + IO_END_ROW], rdx
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
;  Local slots: [rbp-8]=out_root, [rbp-16]=root, [rbp-80]=state (II_SIZE),
;               [rbp-88]=root address, [rbp-96]=the child that replaces it,
;               [rbp-160]=out block (IO_SIZE)
; -----------------------------------------------------------------------------
db_index_delete:
    FRAME_BEGIN 192, 2
    lea r10, [rbp - 80]
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

    lea ARG1, [rbp - 80]
    mov ARG2, [rbp - 16]
    lea ARG3, [rbp - 160]
    call index_delete_node
    test eax, eax
    jnz .done
    mov rax, [rbp - 160 + IO_NODE]
    test rax, rax
    jz .publish                         ; the tree is empty now

    ; A root left naming one child is a level nobody needs.
    lea r10, [rbp - 80]
    mov ARG1, [r10 + II_CTX]
    mov ARG2, rax
    call index_node_addr
    mov [rbp - 88], rax
    cmp dword [rax + IDX_LEVEL], IDX_LEAF
    je .keep_root
    cmp dword [rax + IDX_COUNT], 1
    jne .keep_root
    mov rcx, [rax + IDX_ENTRIES + IDX_CHILD]  ; its only child is the root
    mov [rbp - 96], rcx
    lea r10, [rbp - 80]
    mov ARG1, [r10 + II_CTX]
    mov ARG2, [rbp - 160 + IO_NODE]
    call index_node_drop
    mov rax, [rbp - 96]
    jmp .publish
.keep_root:
    mov rax, [rbp - 160 + IO_NODE]
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
    IDX_SLOT rax
    mov rdx, [r8 + IDX_ENTRIES + rax + IDX_KEY_END]
    cmp rdx, [rbp - 24]
    jl .child
.child_ready:
    dec ecx
    mov rax, rcx
    IDX_SLOT rax
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
    IDX_SLOT rax
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
    IDX_SLOT rax
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
;  only an index knows: a zero tail, a tree that is the tree this page says it
;  is, and a table it actually belongs to.
;
;  The last one is a cross-object check, and open has to make it rather than
;  trusting that the writer did. CREATE INDEX proves the table exists, is a
;  table, has that column and that the column is a type this version orders -
;  but a file arrives from a disk, not from this build's binder, and every one
;  of those four facts is a page id or an offset something else will follow.
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
    mov eax, [r11 + IDX_FLAGS]
    cmp eax, IDX_UNIQUE
    ja .bad
    cmp qword [r11 + IDX_TABLE], 0
    je .bad

    ; The table this index is on, found where every other object is found.
    mov r10, ARG2
    mov rax, [r10 + SB_ROOT_PAGE]
    test rax, rax
    jz .bad                         ; an index with no catalog to belong to
    mov r10, ARG1
    shl rax, CybouDB_PAGE_SHIFT
    add rax, [r10 + DB_BASE]
    mov r8, rax
    mov ecx, [r8 + CAT_COUNT]
    mov r9, [r11 + IDX_TABLE]
    xor edx, edx
.find_table:
    cmp edx, ecx
    jae .bad                        ; it names a table the catalog does not have
    mov rax, rdx
    shl rax, 4
    cmp [r8 + CAT_DATA + rax], r9
    je .table_entry
    inc edx
    jmp .find_table
.table_entry:
    mov rax, [r8 + CAT_DATA + rax + 8]
    mov [rbp - 32], rax
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    mov ARG3, rax
    call db_bitmap_candidate_payload
    test eax, eax
    jz .bad
    mov r10, [rbp - 8]
    mov rax, [rbp - 32]
    shl rax, CybouDB_PAGE_SHIFT
    add rax, [r10 + DB_BASE]
    cmp dword [rax + CAT_TYPE], CAT_SCHEMA
    jne .bad                        ; and what it names has to be a table
    mov r11, [rbp - 24]
    mov ecx, [r11 + IDX_COLUMN]
    cmp ecx, [rax + CAT_COUNT]
    jae .bad                        ; a column that table does not have
    imul rcx, CAT_COLUMN_SIZE
    mov ecx, [rax + CAT_COLUMNS + rcx]
    cmp ecx, CAT_INT32
    je .column_ok
    cmp ecx, CAT_INT64
    jne .bad                        ; or one this version cannot order
.column_ok:
    mov r11, [rbp - 24]

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
;  Walking a tree in key order
;
;  A search lands on one entry. Reading the entries after it is a different
;  problem, and the obvious answer - descend again from the key that follows -
;  does not work here: entries with equal keys are ordered by the row they
;  name, and a descent knows only the key. It would land in the first leaf
;  whose largest key reaches the one wanted, which may be a leaf whose
;  matching entries were all consumed already.
;
;  So the walk keeps the path it came down. Moving to the next leaf is walking
;  up to the deepest node that still has a child to the right, and descending
;  its leftmost edge - which is what a sibling pointer would have done, without
;  a pointer that copy-on-write would have to maintain backwards. The path is
;  at most four nodes for any table this format can hold.
;
;  The iterator is a value the caller owns, like every other cursor here.
; -----------------------------------------------------------------------------

; db_index_iter_open(ctx, root, key, iter) -> RAX: 1 when positioned, 0 when
; the tree holds nothing at or after that key.
;
;  Local slots: [rbp-8]=ctx, [rbp-16]=node, [rbp-24]=key, [rbp-32]=iter,
;               [rbp-40]=address
db_index_iter_open:
    FRAME_BEGIN 64, 0
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
    mov [rbp - 24], ARG3
    mov [rbp - 32], ARG4
    mov r10, ARG4
    mov [r10 + ITER_CTX], ARG1
    mov qword [r10 + ITER_DEPTH], 0
    cmp qword [rbp - 16], 0
    je .empty

.descend:
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    call index_node_addr
    mov [rbp - 40], rax
    mov r10, [rbp - 32]
    mov rcx, [r10 + ITER_DEPTH]
    cmp rcx, IDX_ITER_MAX
    jae .empty
    mov rdx, [rbp - 16]
    mov [r10 + ITER_NODE + rcx * 8], rdx
    mov r8, [rbp - 40]
    cmp dword [r8 + IDX_LEVEL], IDX_LEAF
    je .leaf

    ; The first child whose largest key reaches the one wanted, and the last
    ; child when none does.
    mov r9d, [r8 + IDX_COUNT]
    xor ecx, ecx
.child:
    inc ecx
    cmp ecx, r9d
    jae .child_ready
    mov rax, rcx
    dec rax
    IDX_SLOT rax
    mov rdx, [r8 + IDX_ENTRIES + rax + IDX_KEY_END]
    cmp rdx, [rbp - 24]
    jl .child
.child_ready:
    dec ecx
    mov r10, [rbp - 32]
    mov rax, [r10 + ITER_DEPTH]
    mov [r10 + ITER_SLOT + rax * 8], rcx
    inc qword [r10 + ITER_DEPTH]
    mov rax, rcx
    IDX_SLOT rax
    mov rax, [r8 + IDX_ENTRIES + rax + IDX_CHILD]
    mov [rbp - 16], rax
    jmp .descend

.leaf:
    mov r9d, [r8 + IDX_COUNT]
    xor ecx, ecx
.slot:
    cmp ecx, r9d
    jae .slot_ready
    mov rax, rcx
    IDX_SLOT rax
    mov rdx, [r8 + IDX_ENTRIES + rax + IDX_KEY]
    cmp rdx, [rbp - 24]
    jge .slot_ready
    inc ecx
    jmp .slot
.slot_ready:
    mov r10, [rbp - 32]
    mov rax, [r10 + ITER_DEPTH]
    mov [r10 + ITER_SLOT + rax * 8], rcx
    inc qword [r10 + ITER_DEPTH]
    cmp ecx, r9d
    jb .positioned
    ; Everything in this leaf sorts below the key: the answer, if there is
    ; one, is in the leaf after it.
    mov ARG1, [rbp - 32]
    call iter_next_leaf
    test eax, eax
    jz .empty
.positioned:
    mov eax, 1
    FRAME_END
    ret
.empty:
    mov r10, [rbp - 32]
    mov qword [r10 + ITER_DEPTH], 0
    xor eax, eax
    FRAME_END
    ret

; iter_next_leaf(ARG1 = iter) -> RAX: 1 when a following leaf exists and the
; iterator now stands at its first entry.
;
;  Local slots: [rbp-8]=iter, [rbp-16]=level, [rbp-24]=address
iter_next_leaf:
    FRAME_BEGIN 32, 0
    mov [rbp - 8], ARG1
    mov r10, ARG1
    mov rax, [r10 + ITER_DEPTH]
    test rax, rax
    jz .none
    dec rax                             ; the leaf's own level
.up:
    test rax, rax
    jz .none                            ; the root has no sibling to the right
    dec rax
    mov [rbp - 16], rax
    mov r10, [rbp - 8]
    mov ARG1, [r10 + ITER_CTX]
    mov ARG2, [r10 + ITER_NODE + rax * 8]
    call index_node_addr
    mov [rbp - 24], rax
    mov r10, [rbp - 8]
    mov rcx, [rbp - 16]
    mov rdx, [r10 + ITER_SLOT + rcx * 8]
    inc rdx
    mov r8, [rbp - 24]
    mov eax, [r8 + IDX_COUNT]
    cmp rdx, rax
    jae .up_again
    mov [r10 + ITER_SLOT + rcx * 8], rdx
    ; Down the left edge of everything under it.
    mov rax, rdx
    IDX_SLOT rax
    mov rax, [r8 + IDX_ENTRIES + rax + IDX_CHILD]
    mov rcx, [rbp - 16]
    inc rcx
    mov [r10 + ITER_DEPTH], rcx
.down:
    mov r10, [rbp - 8]
    mov rcx, [r10 + ITER_DEPTH]
    cmp rcx, IDX_ITER_MAX
    jae .none
    mov [r10 + ITER_NODE + rcx * 8], rax
    mov qword [r10 + ITER_SLOT + rcx * 8], 0
    inc qword [r10 + ITER_DEPTH]
    mov ARG1, [r10 + ITER_CTX]
    mov ARG2, rax
    call index_node_addr
    cmp dword [rax + IDX_LEVEL], IDX_LEAF
    je .landed
    mov rax, [rax + IDX_ENTRIES + IDX_CHILD]
    jmp .down
.landed:
    mov eax, 1
    FRAME_END
    ret
.up_again:
    mov rax, [rbp - 16]
    jmp .up
.none:
    mov r10, [rbp - 8]
    mov qword [r10 + ITER_DEPTH], 0
    xor eax, eax
    FRAME_END
    ret

; db_index_iter_next(ctx, iter, out_key, out_row) -> RAX: 1 when an entry was
; produced. The iterator then stands on the one after it.
;
;  Local slots: [rbp-8]=ctx, [rbp-16]=iter, [rbp-24]=out_key, [rbp-32]=out_row
db_index_iter_next:
    FRAME_BEGIN 48, 0
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
    mov [rbp - 24], ARG3
    mov [rbp - 32], ARG4
    mov r10, ARG2
    mov rax, [r10 + ITER_DEPTH]
    test rax, rax
    jz .done
    dec rax
    mov [rbp - 40], rax                 ; the leaf's level
    mov ARG1, [rbp - 8]
    mov ARG2, [r10 + ITER_NODE + rax * 8]
    call index_node_addr
    mov r10, [rbp - 16]
    mov rcx, [rbp - 40]
    mov rdx, [r10 + ITER_SLOT + rcx * 8]
    mov ecx, [rax + IDX_COUNT]
    cmp rdx, rcx
    jb .take
    ; This leaf is spent. The next one starts at its first entry.
    mov ARG1, [rbp - 16]
    call iter_next_leaf
    test eax, eax
    jz .done
    mov r10, [rbp - 16]
    mov rax, [r10 + ITER_DEPTH]
    dec rax
    mov [rbp - 40], rax
    mov ARG1, [rbp - 8]
    mov ARG2, [r10 + ITER_NODE + rax * 8]
    call index_node_addr
    mov r10, [rbp - 16]
    mov rcx, [rbp - 40]
    mov rdx, [r10 + ITER_SLOT + rcx * 8]
.take:
    mov r8, rdx
    IDX_SLOT r8
    mov r9, [rax + IDX_ENTRIES + r8 + IDX_KEY]
    mov r11, [rax + IDX_ENTRIES + r8 + IDX_ROW]
    mov rax, [rbp - 24]
    mov [rax], r9
    mov rax, [rbp - 32]
    mov [rax], r11
    inc rdx
    mov r10, [rbp - 16]
    mov rcx, [rbp - 40]
    mov [r10 + ITER_SLOT + rcx * 8], rdx
    mov eax, 1
    FRAME_END
    ret
.done:
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
    mov r10, [rbp - 8]
    cmp qword [r10 + DB_VERIFY], 0
    jne .counted
    ; The root says what the whole tree holds and the index page says
    ; what it should be: one page against one page.
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 32]
    call index_node_addr
    mov r10, [rbp - 24]
    mov rdx, [rax + IDX_SUBTREE]
    cmp rdx, [r10 + IDX_ROWS]
    jne .bad
    jmp .good
.counted:
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
;               [rbp-64]=count, [rbp-72]=index, [rbp-80]=previous key end,
;               [rbp-88]=leaf entries here, [rbp-96]=count on the way in,
;               [rbp-104]=previous row (or the child being entered),
;               [rbp-112]=the row the previous child ends at
index_node_validate:
    FRAME_BEGIN 160, 2
    inc qword [rel index_nodes_walked]
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
    mov [rbp - 24], ARG3
    mov [rbp - 32], ARG4
    mov rax, IN_ARG5
    mov [rbp - 40], rax
    mov rax, IN_ARG6
    mov [rbp - 48], rax
    mov qword [rbp - 88], 0         ; leaf entries this node holds
    mov rax, IN_ARG6
    mov rax, [rax]
    mov [rbp - 96], rax             ; what the count stood at on the way in

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

    ; The checksum, and only where the file's own rules ask for it - which is
    ; also where this walk stops. A node older than the candidate generation
    ; was proved when it was written and cannot have changed since: under
    ; copy-on-write a change would have produced a new page. So its recorded
    ; subtree size is taken rather than walked for, and a commit proves the
    ; path a transaction touched instead of the whole index.
    ;
    ; `cyboudb check` sets DB_VERIFY, which makes db_bitmap_deep say yes to
    ; everything, and then the sizes are recomputed and compared rather than
    ; believed.
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    mov r10, [rbp - 56]
    mov ARG3, [r10 + IDX_GENERATION]
    call db_bitmap_deep
    test eax, eax
    jnz .deep
    mov r10, [rbp - 56]
    mov rax, [r10 + IDX_SUBTREE]
    test rax, rax
    jz .bad                         ; a node that is reached holds something
    mov rdx, [rbp - 48]
    add [rdx], rax
    mov eax, 1
    FRAME_END
    ret
.deep:
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
    IDX_SLOT rax
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
    mov qword [rbp - 104], 0        ; nor before the first row
    mov qword [rbp - 112], 0        ; nor before the row a child ends at
    mov r8, [rbp - 56]
    cmp dword [r8 + IDX_LEVEL], IDX_LEAF
    je .leaf_entries

.child_entries:
    mov rax, [rbp - 72]
    cmp rax, [rbp - 64]
    jae .entries_done
    IDX_SLOT rax
    mov r8, [rbp - 56]
    mov rdx, [r8 + IDX_ENTRIES + rax + IDX_KEY_END]
    mov rcx, [rbp - 72]
    test rcx, rcx
    jz .child_end_ok
    cmp rdx, [rbp - 80]
    jl .bad                         ; never decreasing by the key it ends at
    jg .child_end_ok
    ; The same key can end two children, because a key may name more rows than
    ; one leaf holds. What separates them is the row, and it has to rise.
    mov rcx, [r8 + IDX_ENTRIES + rax + IDX_ROW_END]
    cmp rcx, [rbp - 112]
    jbe .bad
.child_end_ok:
    mov rcx, [r8 + IDX_ENTRIES + rax + IDX_ROW_END]
    mov [rbp - 112], rcx
    mov [rbp - 80], rdx
    ; The child goes into a register no argument aliases: ARG1 is RCX on
    ; one of the two ABIs, and loading it would take the child with it.
    mov r9, [r8 + IDX_ENTRIES + rax + IDX_CHILD]
    mov [rbp - 104], r9
    ; Ask the map, not the page: reading a child's header to find out it
    ; is old costs exactly the page fault this is here to avoid.
    mov r10, [rbp - 8]
    cmp qword [r10 + DB_VERIFY], 0
    jne .enter_child
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 104]
    call db_bitmap_is_fresh
    test eax, eax
    jz .child_skipped
.enter_child:
    mov r9, [rbp - 104]
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
.child_skipped:
    inc qword [rbp - 72]
    jmp .child_entries

.leaf_entries:
    mov rax, [rbp - 72]
    cmp rax, [rbp - 64]
    jae .entries_done
    IDX_SLOT rax
    mov r8, [rbp - 56]
    mov rdx, [r8 + IDX_ENTRIES + rax + IDX_KEY]
    mov rcx, [rbp - 72]
    test rcx, rcx
    jz .leaf_key_ok
    cmp rdx, [rbp - 80]
    jl .bad                         ; keys never go backwards inside a leaf
    jg .leaf_key_ok
    ; Equal keys are ordered by the row they name, which is what keeps every
    ; entry distinct and the order total.
    mov rcx, [r8 + IDX_ENTRIES + rax + IDX_ROW]
    cmp rcx, [rbp - 104]
    jbe .bad
.leaf_key_ok:
    mov rcx, [r8 + IDX_ENTRIES + rax + IDX_ROW]
    mov [rbp - 104], rcx
    mov [rbp - 80], rdx
    inc qword [rbp - 72]
    inc qword [rbp - 88]
    jmp .leaf_entries

.entries_done:
    mov r8, [rbp - 56]
    cmp dword [r8 + IDX_LEVEL], IDX_LEAF
    jne .subtree_checked
    mov rax, [rbp - 48]
    mov rdx, [rbp - 88]
    add [rax], rdx
    mov rax, [rbp - 64]
    cmp [r8 + IDX_SUBTREE], rax
    jne .bad                        ; a leaf holds exactly what it says
    jmp .valid
.subtree_checked:
    ; What the children reported against what this node claims - which
    ; only means anything when every child was visited.
    mov r10, [rbp - 8]
    cmp qword [r10 + DB_VERIFY], 0
    je .valid
    mov rax, [rbp - 48]
    mov rax, [rax]
    sub rax, [rbp - 96]
    cmp [r8 + IDX_SUBTREE], rax
    jne .bad
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
