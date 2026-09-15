; Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
; SPDX-License-Identifier: Apache-2.0
; =============================================================================
;  core/bitmap_leaf.asm - one allocation-map leaf, laid out once
; =============================================================================
;  This is the smallest piece of the span allocation map that two creators
;  need, and it is in a file of its own because they cannot link the same
;  object: core/bitmap.asm reaches the catalog and the allocator, and the
;  encrypted creator links neither.
;
;  docs/SPAN_MAP.md is normative for the layout; this is where it is written.
; =============================================================================

%include "cyboudb.inc"

BITS 64
default rel

global db_bitmap_leaf_build
global db_bitmap_leaves

extern crc32c

section .text

; db_bitmap_leaves(total_pages) -> RAX = map pages per copy in the span layout.
db_bitmap_leaves:
    mov     rax, ARG1
    add     rax, CybouDB_MAP_LEAF_PAGES - 1
    xor     edx, edx
    mov     r10, CybouDB_MAP_LEAF_PAGES
    div     r10
    ret

; -----------------------------------------------------------------------------
;  db_bitmap_leaf_build(ARG1 = page buffer, ARG2 = index within its copy,
;                       ARG3 = total pages, ARG4 = first free page)
;
;  One span-layout allocation-map leaf, complete and checksummed, built into a
;  buffer rather than into a mapping.
;
;  It is its own function because it now has two callers that have nothing else
;  in common: db_bitmap_init writes into a mapped file, and the encrypted
;  creator builds the same leaf in a frame and then seals it. A map that was
;  laid out in two places would eventually be laid out two ways, and the second
;  way would be discovered by an allocator that handed out a page twice.
; -----------------------------------------------------------------------------
db_bitmap_leaf_build:
    FRAME_BEGIN 48, 0
    mov     [rbp - 8], ARG1
    mov     [rbp - 16], ARG2
    mov     [rbp - 24], ARG3
    mov     [rbp - 32], ARG4

    mov     ARG1, [rbp - 8]
    call    zero_page
    mov     r10, [rbp - 8]
    mov     dword [r10 + MAP_MAGIC], CybouDB_MAP_MAGIC
    mov     dword [r10 + MAP_HEADER_SIZE], MAP_DATA
    mov     qword [r10 + MAP_GENERATION], 1
    mov     rax, [rbp - 24]
    mov     [r10 + MAP_TOTAL], rax
    ; A leaf is identified by where it sits, so MAP_PAGE_ID stays zero and a
    ; copy from the other half of the pair is byte-identical when unchanged.
    mov     rax, [rbp - 16]
    imul    rax, CybouDB_MAP_LEAF_PAGES
    mov     [r10 + MAP_SPAN], rax
    mov     [rbp - 40], rax             ; the first page this leaf describes
    cmp     qword [rbp - 16], 0
    jne     .built
    mov     rax, [rbp - 32]
    mov     [r10 + MAP_ALLOC], rax      ; the high-water lives in leaf zero
.built:

    ; The reserved pages this leaf covers, if it covers any: everything below
    ; the high-water a creator laid out before handing the file to the
    ; allocator.
    mov     rax, [rbp - 32]
    cmp     rax, [rbp - 40]
    jbe     .sealed
    sub     rax, [rbp - 40]
    cmp     rax, CybouDB_MAP_LEAF_PAGES
    jbe     .reserve_known
    mov     rax, CybouDB_MAP_LEAF_PAGES
.reserve_known:
    mov     [rbp - 48], rax
    mov     r10, [rbp - 8]
    xor     r8d, r8d
    mov     r9d, MAP_METADATA
.reserve:
    call    map_set
    inc     r8
    cmp     r8, [rbp - 48]
    jb      .reserve

.sealed:
    mov     ARG1, [rbp - 8]
    call    seal_leaf
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  The three helpers it needs. core/bitmap.asm has its own copies, four
;  instructions each; sharing them across two objects would cost more than the
;  duplication, and what must not be duplicated - the layout itself - is not.
; -----------------------------------------------------------------------------
zero_page:
    mov     r10, ARG1
    xor     eax, eax
    mov     ecx, CybouDB_PAGE_SIZE / 8
.loop:
    mov     [r10], rax
    add     r10, 8
    dec     ecx
    jnz     .loop
    ret

; map_set: r10 = leaf, r8 = page within it, r9d = state
map_set:
    mov     r11, r8
    shr     r11, 2
    mov     ecx, r8d
    and     ecx, 3
    shl     ecx, 1
    mov     eax, 3
    shl     eax, cl
    not     eax
    and     byte [r10 + MAP_DATA + r11], al
    mov     eax, r9d
    shl     eax, cl
    or      byte [r10 + MAP_DATA + r11], al
    ret

seal_leaf:
    FRAME_BEGIN 16, 0
    mov     [rbp - 8], ARG1
    mov     ARG2, MAP_CRC
    call    crc32c
    mov     r10, [rbp - 8]
    mov     [r10 + MAP_CRC], eax
    FRAME_END
    ret

%ifdef CybouDB_LINUX
section .note.GNU-stack noalloc noexec nowrite progbits
%endif
