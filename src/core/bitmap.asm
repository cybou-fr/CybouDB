; Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
; SPDX-License-Identifier: Apache-2.0
; COW allocation map: two bits per physical page.
; 00 available, 01 payload, 10 reserved metadata, 11 retired (span layout only).
;
; Retirement is what makes reclamation possible with two superblock copies and
; nothing else to remember. A page marked retired is not reachable from this
; generation; the generation before it may still hold a reference, and that is
; the only reason it cannot be handed out yet. When a writer starts the next
; transaction it targets the superblock copy holding that older generation and
; overwrites its half of the map pair, so the older generation ends there
; regardless - which means every page retired by the live generation is free
; for the taking, and no third state or free list is needed to know it.
;
; Two layouts share those bits, chosen once by CybouDB_FEATURE_MAP_SPAN:
;
;   flat - one checksummed page named by SB_BITMAP_ROOT, copied like any other
;          page when a transaction first allocates. One page of bits covers
;          CybouDB_COW_MAX_PAGES pages, and that is where the 63 MiB ceiling on
;          this layout comes from.
;
;   span - the map is K = ceil(total / CybouDB_MAP_LEAF_PAGES) consecutive pages,
;          and the file holds two copies of it at fixed positions right after
;          the two superblocks. Copy X belongs to the generation published in
;          superblock X, exactly like the superblock itself. That single change
;          removes everything that made a bigger map awkward: the map needs no
;          allocation of its own, so it cannot leak pages and cannot recurse
;          into the allocator, and it needs no pointer structure, because leaf
;          i of a copy is always that copy's first page plus i.
;
;          A writer mutates the inactive copy and publishes it together with
;          the superblock. It does not have to reach the disk before the
;          payload does: a torn map fails its own checksum, which rejects that
;          superblock candidate, and the reader falls back to the other copy.
;          The price is that the older of the two recoverable generations ends
;          as soon as a writer allocates, not at commit - the same trade every
;          shadow-paging engine makes to stop leaking.
%include "cyboudb.inc"
BITS 64
default rel
extern vfs_reclaim_safe
extern crc32c
extern db_catalog_validate
global db_bitmap_init, db_bitmap_validate, db_bitmap_seal
global db_bitmap_alloc, db_bitmap_alloc_run, db_bitmap_is_payload
global db_bitmap_candidate_payload, db_bitmap_leaves
global db_bitmap_retire, db_bitmap_recount, db_bitmap_headroom
global db_bitmap_is_fresh, db_bitmap_deep
section .text

; r10 = leaf address, r8 = page index inside that leaf. Return eax = state;
; preserve r8/r10.
map_get:
    mov     r11, r8
    shr     r11, 2
    movzx   eax, byte [r10 + MAP_DATA + r11]
    mov     ecx, r8d
    and     ecx, 3
    shl     ecx, 1
    shr     eax, cl
    and     eax, 3
    ret

; r10 = leaf, r8 = index inside it, r9d = state. Preserve r8/r9/r10.
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

; mark_dirty: r10 = ctx, rax = a page this transaction writes. Widens the range
; db_commit has to flush. Reclaimed pages sit below the high-water, so the
; range can no longer be derived from it. Clobbers r11.
mark_dirty:
    cmp     qword [r10 + DB_DIRTY_HI], 0
    jne     .extend
    mov     [r10 + DB_DIRTY_LO], rax
    lea     r11, [rax + 1]
    mov     [r10 + DB_DIRTY_HI], r11
    ret
.extend:
    cmp     rax, [r10 + DB_DIRTY_LO]
    jae     .high
    mov     [r10 + DB_DIRTY_LO], rax
.high:
    lea     r11, [rax + 1]
    cmp     r11, [r10 + DB_DIRTY_HI]
    jbe     .done
    mov     [r10 + DB_DIRTY_HI], r11
.done:
    ret

; db_bitmap_leaves(total_pages) -> RAX = map pages per copy in the span layout.
db_bitmap_leaves:
    mov     rax, ARG1
    add     rax, CybouDB_MAP_LEAF_PAGES - 1
    xor     edx, edx
    mov     r10, CybouDB_MAP_LEAF_PAGES
    div     r10
    ret

; map_locate(ARG1 = mapping base, ARG2 = first map page, ARG3 = page id,
;            ARG4 = nonzero in the span layout)
;   -> RAX = address of the leaf holding that page, RDX = index inside it
map_locate:
    FRAME_BEGIN 32, 0
    mov     [rbp - 8], ARG1
    mov     [rbp - 16], ARG2
    mov     [rbp - 24], ARG3
    test    ARG4, ARG4
    jz      .flat
    mov     rax, ARG3
    xor     edx, edx
    mov     r10, CybouDB_MAP_LEAF_PAGES
    div     r10
    mov     [rbp - 32], rdx
    add     rax, [rbp - 16]
    shl     rax, CybouDB_PAGE_SHIFT
    add     rax, [rbp - 8]
    mov     rdx, [rbp - 32]
    FRAME_END
    ret
.flat:
    mov     rax, [rbp - 16]
    shl     rax, CybouDB_PAGE_SHIFT
    add     rax, [rbp - 8]
    mov     rdx, [rbp - 24]
    FRAME_END
    ret

; leaf_addr(ARG1 = mapping base, ARG2 = first map page, ARG3 = leaf index)
;   -> RAX = address of that leaf
leaf_addr:
    mov     rax, ARG3
    add     rax, ARG2
    shl     rax, CybouDB_PAGE_SHIFT
    add     rax, ARG1
    ret

; zero_page(ARG1 = address)
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

; seal_leaf(ARG1 = leaf address)
seal_leaf:
    FRAME_BEGIN 16, 0
    mov     [rbp - 8], ARG1
    mov     ARG2, MAP_CRC
    call    crc32c
    mov     r10, [rbp - 8]
    mov     [r10 + MAP_CRC], eax
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  db_bitmap_init(ARG1 = mapping base, ARG2 = total pages, ARG3 = features)
;  -> RAX = first page left for payload
;
;  Lays out the allocation map of a brand new file. In the span layout both
;  copies are written identically, because db_create publishes generation 1 in
;  both superblocks.
;
;  Local slots: [rbp-8]=base, [rbp-16]=total, [rbp-24]=features,
;               [rbp-32]=leaf address, [rbp-40]=K, [rbp-48]=first free page,
;               [rbp-56]=index
; -----------------------------------------------------------------------------
db_bitmap_init:
    FRAME_BEGIN 64, 0
    mov     [rbp - 8], ARG1
    mov     [rbp - 16], ARG2
    mov     [rbp - 24], ARG3
    test    ARG3, CybouDB_FEATURE_MAP_SPAN
    jnz     .span

    mov     r10, [rbp - 8]
    add     r10, CybouDB_MIN_PAGES * CybouDB_PAGE_SIZE
    mov     [rbp - 32], r10
    mov     ARG1, r10
    call    zero_page
    mov     r10, [rbp - 32]
    mov     dword [r10 + MAP_MAGIC], CybouDB_MAP_MAGIC
    mov     dword [r10 + MAP_HEADER_SIZE], MAP_DATA
    mov     qword [r10 + MAP_PAGE_ID], CybouDB_MIN_PAGES
    mov     qword [r10 + MAP_GENERATION], 1
    mov     rax, [rbp - 16]
    mov     [r10 + MAP_TOTAL], rax
    mov     qword [r10 + MAP_ALLOC], CybouDB_COW_MIN_PAGES
    mov     byte [r10 + MAP_DATA], 0xAA ; pages 0..3 are metadata
    mov     ARG1, r10
    call    seal_leaf
    mov     eax, CybouDB_COW_MIN_PAGES
    FRAME_END
    ret

.span:
    mov     ARG1, [rbp - 16]
    call    db_bitmap_leaves
    mov     [rbp - 40], rax
    shl     rax, 1
    add     rax, CybouDB_MIN_PAGES
    mov     [rbp - 48], rax             ; header, superblocks and both copies
    mov     qword [rbp - 56], 0
.header:
    mov     ARG1, [rbp - 8]
    mov     ARG2, CybouDB_MIN_PAGES
    mov     ARG3, [rbp - 56]
    call    leaf_addr
    mov     [rbp - 32], rax
    mov     ARG1, rax
    call    zero_page
    mov     r10, [rbp - 32]
    mov     dword [r10 + MAP_MAGIC], CybouDB_MAP_MAGIC
    mov     dword [r10 + MAP_HEADER_SIZE], MAP_DATA
    mov     qword [r10 + MAP_GENERATION], 1
    mov     rax, [rbp - 16]
    mov     [r10 + MAP_TOTAL], rax
    ; A leaf is identified by where it sits, so MAP_PAGE_ID stays zero and a
    ; copy from the other half of the pair is byte-identical when unchanged.
    mov     rax, [rbp - 56]
    xor     edx, edx
    div     qword [rbp - 40]            ; rdx = index of this leaf in its copy
    mov     rax, rdx
    imul    rax, CybouDB_MAP_LEAF_PAGES
    mov     [r10 + MAP_SPAN], rax
    test    rdx, rdx
    jnz     .next_header
    mov     rax, [rbp - 48]
    mov     [r10 + MAP_ALLOC], rax      ; the high-water lives in leaf zero
.next_header:
    inc     qword [rbp - 56]
    mov     rax, [rbp - 40]
    shl     rax, 1
    cmp     [rbp - 56], rax
    jb      .header

    mov     qword [rbp - 56], 0
.reserve_copy:
    mov     ARG1, [rbp - 8]
    mov     ARG2, CybouDB_MIN_PAGES
    mov     ARG3, [rbp - 56]
    imul    ARG3, [rbp - 40]
    call    leaf_addr
    mov     r10, rax                    ; leaf zero of this copy
    xor     r8d, r8d
    mov     r9d, MAP_METADATA
.reserve:
    call    map_set
    inc     r8
    cmp     r8, [rbp - 48]
    jb      .reserve
    inc     qword [rbp - 56]
    cmp     qword [rbp - 56], 2
    jb      .reserve_copy

    mov     qword [rbp - 56], 0
.seal:
    mov     ARG1, [rbp - 8]
    mov     ARG2, CybouDB_MIN_PAGES
    mov     ARG3, [rbp - 56]
    call    leaf_addr
    mov     ARG1, rax
    call    seal_leaf
    inc     qword [rbp - 56]
    mov     rax, [rbp - 40]
    shl     rax, 1
    cmp     [rbp - 56], rax
    jb      .seal
    mov     rax, [rbp - 48]
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  span_valid(ARG1 = descriptor, ARG2 = candidate superblock, ARG3 = alloc)
;  -> RAX = 1 when the whole span map of that candidate is coherent
;
;  Local slots: [rbp-8]=ctx, [rbp-16]=sb, [rbp-24]=alloc, [rbp-32]=K,
;               [rbp-40]=root, [rbp-48]=leaf index, [rbp-56]=leaf address,
;               [rbp-64]=first free page, [rbp-72]=span base
; -----------------------------------------------------------------------------
span_valid:
    FRAME_BEGIN 80, 0
    mov     [rbp - 8], ARG1
    mov     [rbp - 16], ARG2
    mov     [rbp - 24], ARG3
    mov     r11, ARG2
    mov     ARG1, [r11 + SB_TOTAL_PAGES]
    call    db_bitmap_leaves
    mov     [rbp - 32], rax
    shl     rax, 1
    add     rax, CybouDB_MIN_PAGES
    mov     [rbp - 64], rax
    cmp     rax, [rbp - 24]
    ja      .bad                        ; the pair must fit below the high-water
    mov     r11, [rbp - 16]
    mov     rax, [r11 + SB_BITMAP_ROOT]
    mov     [rbp - 40], rax
    cmp     rax, CybouDB_MIN_PAGES
    je      .root_known
    mov     rdx, [rbp - 32]
    add     rdx, CybouDB_MIN_PAGES
    cmp     rax, rdx
    jne     .bad                        ; only the two fixed positions exist
.root_known:
    mov     qword [rbp - 48], 0
.leaf:
    mov     ARG1, [rbp - 8]
    mov     r10, ARG1
    mov     ARG1, [r10 + DB_BASE]
    mov     ARG2, [rbp - 40]
    mov     ARG3, [rbp - 48]
    call    leaf_addr
    mov     [rbp - 56], rax
    mov     r10, rax
    cmp     dword [r10 + MAP_MAGIC], CybouDB_MAP_MAGIC
    jne     .bad
    cmp     dword [r10 + MAP_HEADER_SIZE], MAP_DATA
    jne     .bad
    cmp     qword [r10 + MAP_PAGE_ID], 0
    jne     .bad
    mov     rax, [r10 + MAP_GENERATION]
    test    rax, rax
    jz      .bad
    mov     r11, [rbp - 16]
    cmp     rax, [r11 + SB_GENERATION]
    ja      .bad
    mov     rax, [r11 + SB_TOTAL_PAGES]
    cmp     [r10 + MAP_TOTAL], rax
    jne     .bad
    mov     rax, [rbp - 48]
    imul    rax, CybouDB_MAP_LEAF_PAGES
    mov     [rbp - 72], rax
    cmp     [r10 + MAP_SPAN], rax
    jne     .bad
    mov     rax, [r10 + MAP_ALLOC]
    cmp     qword [rbp - 48], 0
    jne     .no_alloc
    cmp     rax, [rbp - 24]
    jne     .bad
    jmp     .alloc_checked
.no_alloc:
    test    rax, rax
    jnz     .bad
.alloc_checked:
    mov     rax, [r10 + MAP_SPAN_RESERVED]
    or      rax, [r10 + MAP_SPAN_RESERVED + 8]
    jnz     .bad
    mov     ARG3, [r10 + MAP_GENERATION]
    mov     ARG1, [rbp - 8]
    mov     ARG2, [rbp - 16]
    call    db_bitmap_deep
    test    eax, eax
    jz      .next_leaf                  ; an older generation already checked it
    mov     ARG1, [rbp - 56]
    mov     ARG2, MAP_CRC
    call    crc32c
    mov     r10, [rbp - 56]
    cmp     [r10 + MAP_CRC], eax
    jne     .bad

    ; A leaf that starts beyond the high-water can only be free, and saying so
    ; in one pass keeps opening a mostly empty large file cheap.
    mov     rax, [rbp - 72]
    cmp     rax, [rbp - 24]
    jb      .entries
    mov     r11, MAP_DATA
.blank:
    cmp     qword [r10 + r11], 0
    jne     .bad
    add     r11, 8
    cmp     r11, MAP_CRC - 12
    jbe     .blank
    cmp     dword [r10 + r11], 0        ; the entries do not end 8-byte aligned
    jne     .bad
    jmp     .next_leaf
.entries:
    xor     r8d, r8d
.entry:
    call    map_get
    mov     rdx, r8
    add     rdx, [rbp - 72]             ; the physical page this entry describes
    cmp     rdx, [rbp - 24]
    jae     .free
    cmp     rdx, [rbp - 64]
    jb      .metadata                   ; header, superblocks and both map copies
    test    eax, eax
    jz      .bad                        ; payload, metadata or retired
    jmp     .next_entry
.metadata:
    cmp     eax, MAP_METADATA
    jne     .bad
    jmp     .next_entry
.free:
    test    eax, eax
    jnz     .bad
.next_entry:
    inc     r8
    cmp     r8, CybouDB_MAP_LEAF_PAGES
    jb      .entry
.next_leaf:
    inc     qword [rbp - 48]
    mov     rax, [rbp - 48]
    cmp     rax, [rbp - 32]
    jb      .leaf
    mov     eax, 1
    FRAME_END
    ret
.bad:
    xor     eax, eax
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  flat_valid(ARG1 = descriptor, ARG2 = candidate superblock, ARG3 = alloc)
;  -> RAX = 1 when the single-page map of that candidate is coherent
;
;  Local slots: [rbp-8]=ctx, [rbp-16]=sb, [rbp-24]=alloc, [rbp-32]=map address
; -----------------------------------------------------------------------------
flat_valid:
    FRAME_BEGIN 48, 0
    mov     [rbp - 8], ARG1
    mov     [rbp - 16], ARG2
    mov     [rbp - 24], ARG3
    mov     r10, ARG1
    mov     r11, ARG2
    mov     rax, [r11 + SB_BITMAP_ROOT]
    cmp     rax, CybouDB_MIN_PAGES
    jb      .bad
    cmp     rax, [rbp - 24]
    jae     .bad
    shl     rax, CybouDB_PAGE_SHIFT
    add     rax, [r10 + DB_BASE]
    mov     [rbp - 32], rax
    mov     r10, rax
    cmp     dword [r10 + MAP_MAGIC], CybouDB_MAP_MAGIC
    jne     .bad
    cmp     dword [r10 + MAP_HEADER_SIZE], MAP_DATA
    jne     .bad
    mov     rax, [r11 + SB_BITMAP_ROOT]
    cmp     [r10 + MAP_PAGE_ID], rax
    jne     .bad
    mov     rax, [r10 + MAP_GENERATION]
    test    rax, rax
    jz      .bad
    cmp     rax, [r11 + SB_GENERATION]
    ja      .bad
    mov     rax, [r11 + SB_TOTAL_PAGES]
    cmp     [r10 + MAP_TOTAL], rax
    jne     .bad
    mov     rax, [rbp - 24]
    cmp     [r10 + MAP_ALLOC], rax
    jne     .bad
    mov     rax, [r10 + MAP_RESERVED]
    or      rax, [r10 + MAP_RESERVED + 8]
    or      rax, [r10 + MAP_RESERVED + 16]
    jnz     .bad
    mov     ARG1, r10
    mov     ARG2, MAP_CRC
    call    crc32c
    mov     r10, [rbp - 32]
    cmp     [r10 + MAP_CRC], eax
    jne     .bad

    xor     r8d, r8d
.entries:
    call    map_get
    cmp     r8, [rbp - 24]
    jae     .available
    cmp     eax, MAP_PAYLOAD
    jb      .bad
    cmp     eax, MAP_METADATA
    ja      .bad
    cmp     r8, CybouDB_MIN_PAGES
    jae     .next
    cmp     eax, MAP_METADATA
    jne     .bad
    jmp     .next
.available:
    test    eax, eax
    jnz     .bad
.next:
    inc     r8
    cmp     r8, CybouDB_COW_MAX_PAGES
    jb      .entries
    mov     r11, [rbp - 16]
    mov     r8, [r11 + SB_BITMAP_ROOT]
    call    map_get
    cmp     eax, MAP_METADATA
    jne     .bad
    mov     eax, 1
    FRAME_END
    ret
.bad:
    xor     eax, eax
    FRAME_END
    ret

; db_bitmap_validate(ctx, superblock): 1 iff this candidate's entire allocation
; state is coherent. Legacy format bypasses this check. Called BEFORE choosing
; the newest generation; a bad map invalidates its superblock candidate.
db_bitmap_validate:
    FRAME_BEGIN 48, 0
    mov     [rbp - 8], ARG1
    mov     [rbp - 16], ARG2
    mov     r10, ARG1
    cmp     qword [r10 + DB_FEATURES], 0
    je      .valid
    mov     r11, ARG2
    cmp     qword [r11 + SB_GENERATION], 0
    je      .bad
    cmp     qword [r11 + SB_FREELIST_ROOT], 0
    jne     .bad
    cmp     qword [r11 + SB_FEATURE_ROOT], 0
    jne     .bad
    mov     rax, [r11 + SB_TOTAL_PAGES]
    cmp     rax, CybouDB_COW_MIN_PAGES
    jb      .bad
    test    qword [r10 + DB_FEATURES], CybouDB_FEATURE_MAP_SPAN
    jnz     .span_bound
    cmp     rax, CybouDB_COW_MAX_PAGES
    ja      .bad
    jmp     .bounded
.span_bound:
    mov     rdx, CybouDB_SPAN_MAX_PAGES
    cmp     rax, rdx
    ja      .bad
.bounded:
    shl     rax, CybouDB_PAGE_SHIFT
    cmp     rax, [r10 + DB_SIZE]
    jne     .bad
    mov     rax, [r11 + SB_ALLOC_PAGES]
    cmp     rax, CybouDB_COW_MIN_PAGES
    jb      .bad
    cmp     rax, [r11 + SB_TOTAL_PAGES]
    ja      .bad
    mov     [rbp - 24], rax

    mov     ARG1, [rbp - 8]
    mov     ARG2, [rbp - 16]
    mov     ARG3, rax
    mov     r10, [rbp - 8]
    test    qword [r10 + DB_FEATURES], CybouDB_FEATURE_MAP_SPAN
    jz      .flat_map
    call    span_valid
    jmp     .map_checked
.flat_map:
    call    flat_valid
.map_checked:
    test    eax, eax
    jz      .bad

    mov     r11, [rbp - 16]
    mov     ARG3, [r11 + SB_ROOT_PAGE]
    test    ARG3, ARG3
    jz      .valid
    mov     ARG1, [rbp - 8]
    mov     ARG2, [rbp - 16]
    call    db_bitmap_candidate_payload
    test    eax, eax
    jz      .bad
.valid:
    mov     ARG1, [rbp - 8]
    mov     ARG2, [rbp - 16]
    call    db_catalog_validate
    FRAME_END
    ret
.bad:
    xor     eax, eax
    FRAME_END
    ret

; db_bitmap_candidate_payload(ctx, candidate_superblock, id) -> eax = 1 when
; the page is a payload page of that candidate generation. Every graph walker
; asks this before dereferencing a page id, so the map lookup lives here
; rather than being spelled out again at each call site. A candidate marked
; SB_STAGED also accepts a retired page, because a graph under construction
; still names the pages it is in the middle of replacing.
db_bitmap_candidate_payload:
    FRAME_BEGIN 16, 0
    mov     r10, ARG1
    mov     r11, ARG2
    mov     r8, ARG3
    cmp     r8, CybouDB_MIN_PAGES
    jb      .bad
    cmp     r8, [r11 + SB_ALLOC_PAGES]
    jae     .bad
    mov     eax, [r11 + SB_STAGED]
    mov     [rbp - 8], rax
    mov     ARG4, [r10 + DB_FEATURES]
    and     ARG4, CybouDB_FEATURE_MAP_SPAN
    mov     ARG2, [r11 + SB_BITMAP_ROOT]
    mov     ARG1, [r10 + DB_BASE]
    mov     ARG3, r8
    call    map_locate
    mov     r10, rax
    mov     r8, rdx
    call    map_get
    cmp     eax, MAP_PAYLOAD
    je      .yes
    cmp     eax, MAP_RETIRED
    jne     .bad
    cmp     qword [rbp - 8], 0
    je      .bad
.yes:
    mov     eax, 1
    FRAME_END
    ret
.bad:
    xor     eax, eax
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  db_bitmap_deep(ctx, candidate_superblock, page generation) -> eax = 1 when
;  this page has to be checked byte for byte.
;
;  A page is written once, by the generation that created it, and copy-on-write
;  never touches it again. The commit that published it checked it in full, so
;  every later open and every later commit that inherits it would only be
;  repeating that work - which is what made opening a database, and inserting a
;  single row, cost the size of the whole database rather than the size of the
;  change. Only pages carrying the candidate's own generation can be
;  half-written, and those are exactly the ones a torn commit leaves behind, so
;  checking them is what preserves the fallback to the previous generation.
;
;  DB_VERIFY forces the exhaustive walk; `cyboudb check` is what sets it.
; -----------------------------------------------------------------------------
db_bitmap_deep:
    mov     r10, ARG1
    mov     r11, ARG2
    cmp     qword [r10 + DB_VERIFY], 0
    jne     .yes
    mov     rax, [r11 + SB_GENERATION]
    cmp     ARG3, rax
    jne     .no
.yes:
    mov     eax, 1
    ret
.no:
    xor     eax, eax
    ret

; db_bitmap_is_payload(ctx, id): membership, independent of payload magic.
db_bitmap_is_payload:
    FRAME_BEGIN 16, 0
    mov     r10, ARG1
    mov     r8, ARG2
    cmp     r8, [r10 + DB_ALLOC]
    jae     .bad
    mov     ARG4, [r10 + DB_FEATURES]
    and     ARG4, CybouDB_FEATURE_MAP_SPAN
    mov     ARG2, [r10 + DB_BITMAP]
    mov     ARG1, [r10 + DB_BASE]
    mov     ARG3, r8
    call    map_locate
    mov     r10, rax
    mov     r8, rdx
    call    map_get
    cmp     eax, MAP_PAYLOAD
    sete    al
    movzx   eax, al
    FRAME_END
    ret
.bad:
    xor     eax, eax
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  span_stage(ARG1 = descriptor)
;
;  Switches the writer to the inactive copy of the map, once per transaction.
;  Only the leaves that the live generation actually changed are copied: a leaf
;  whose two halves carry the same creation generation was never rewritten in
;  either, so it is already identical. That keeps the cost of a transaction
;  proportional to what it touches rather than to the size of the file.
;
;  Local slots: [rbp-8]=ctx, [rbp-16]=K, [rbp-24]=live root, [rbp-32]=other
;               root, [rbp-40]=index, [rbp-48]=source, [rbp-56]=destination
; -----------------------------------------------------------------------------
span_stage:
    FRAME_BEGIN 64, 0
    mov     [rbp - 8], ARG1
    mov     r10, ARG1
    mov     r11, [r10 + DB_SB_PTR]
    mov     rax, [r11 + SB_BITMAP_ROOT]
    cmp     rax, [r10 + DB_BITMAP]
    jne     .done                       ; already on the inactive copy
    mov     [rbp - 24], rax
    mov     ARG1, [r10 + DB_PAGES]
    call    db_bitmap_leaves
    mov     [rbp - 16], rax
    mov     rdx, [rbp - 24]
    cmp     rdx, CybouDB_MIN_PAGES
    jne     .to_first
    add     rax, CybouDB_MIN_PAGES
    mov     [rbp - 32], rax
    jmp     .other_known
.to_first:
    mov     qword [rbp - 32], CybouDB_MIN_PAGES
.other_known:
    mov     qword [rbp - 40], 0
.leaf:
    mov     r10, [rbp - 8]
    mov     ARG1, [r10 + DB_BASE]
    mov     ARG2, [rbp - 24]
    mov     ARG3, [rbp - 40]
    call    leaf_addr
    mov     [rbp - 48], rax
    mov     r10, [rbp - 8]
    mov     ARG1, [r10 + DB_BASE]
    mov     ARG2, [rbp - 32]
    mov     ARG3, [rbp - 40]
    call    leaf_addr
    mov     [rbp - 56], rax
    mov     r10, [rbp - 48]
    mov     r11, rax
    mov     rax, [r10 + MAP_GENERATION]
    cmp     rax, [r11 + MAP_GENERATION]
    je      .next                       ; neither half has been rewritten since
    mov     ecx, CybouDB_PAGE_SIZE / 8
.copy:
    mov     rax, [r10]
    mov     [r11], rax
    add     r10, 8
    add     r11, 8
    dec     ecx
    jnz     .copy
.next:
    inc     qword [rbp - 40]
    mov     rax, [rbp - 40]
    cmp     rax, [rbp - 16]
    jb      .leaf
    mov     r10, [rbp - 8]
    mov     rax, [rbp - 32]
    mov     [r10 + DB_BITMAP], rax
.done:
    FRAME_END
    ret

; span_mark(ARG1 = descriptor, ARG2 = page id, ARG3 = state). The staged copy
; only; stamps the leaf so db_bitmap_seal knows to reseal it.
span_mark:
    FRAME_BEGIN 32, 0
    mov     [rbp - 8], ARG1
    mov     [rbp - 24], ARG3
    mov     r10, ARG1
    mov     ARG4, 1
    mov     ARG3, ARG2
    mov     ARG2, [r10 + DB_BITMAP]
    mov     ARG1, [r10 + DB_BASE]
    call    map_locate
    mov     r10, rax
    mov     r8, rdx
    mov     r11, [rbp - 8]
    mov     rax, [r11 + DB_GENERATION]
    inc     rax
    mov     [r10 + MAP_GENERATION], rax
    mov     r9, [rbp - 24]
    call    map_set
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  db_bitmap_alloc(ctx, out_id). Caller has already checked writer state.
;
;  Local slots: [rbp-8]=ctx, [rbp-16]=out, [rbp-24]=first unused page,
;               [rbp-32]=page handed out, [rbp-40]=staged map address
; -----------------------------------------------------------------------------
; -----------------------------------------------------------------------------
;  db_bitmap_alloc_run(ctx, pages, out_first) - allocate `pages` consecutive
;  payload pages and report the first.
;
;  Growth is what hands out consecutive ids, so this first checks that the file
;  has room to grow by the whole run: that is what makes db_bitmap_alloc take
;  the growth path for every page of it. When there is no room, the span layout
;  looks for a run-shaped hole among the pages it has reclaimed - which is the
;  shape they come in, since a leaf is retired the way it was allocated.
;
;  Local slots: [rbp-8]=ctx, [rbp-16]=pages, [rbp-24]=out, [rbp-32]=index,
;               [rbp-40]=first id, [rbp-48]=id handed out
; -----------------------------------------------------------------------------
db_bitmap_alloc_run:
    FRAME_BEGIN 64, 0
    mov     [rbp - 8], ARG1
    mov     [rbp - 16], ARG2
    mov     [rbp - 24], ARG3
    cmp     qword [rbp - 16], 2
    jb      .single

    mov     r10, ARG1
    mov     rax, [r10 + DB_ALLOC]
    cmp     rax, [r10 + DB_COW_FLOOR]
    jae     .run_floor
    mov     rax, [r10 + DB_COW_FLOOR]
.run_floor:
    mov     rdx, [r10 + DB_PAGES]
    cmp     rax, rdx
    jae     .run_reclaim                ; nothing left to grow into
    sub     rdx, rax                    ; pages the file can still grow by
    mov     rax, [rbp - 16]
    test    qword [r10 + DB_FEATURES], CybouDB_FEATURE_MAP_SPAN
    jnz     .run_need_ready
    mov     rcx, [r10 + DB_BITMAP]
    cmp     rcx, [r10 + DB_COW_FLOOR]
    jae     .run_need_ready
    inc     rax                         ; the first allocation also copies the map
.run_need_ready:
    cmp     rdx, rax
    jb      .run_reclaim

    mov     qword [rbp - 32], 0
.run_page:
    mov     ARG1, [rbp - 8]
    lea     ARG2, [rbp - 48]
    call    db_bitmap_alloc
    test    eax, eax
    jnz     .run_done
    mov     rax, [rbp - 48]
    cmp     qword [rbp - 32], 0
    jne     .run_contiguous
    mov     [rbp - 40], rax
    jmp     .run_next
.run_contiguous:
    mov     rdx, [rbp - 40]
    add     rdx, [rbp - 32]
    cmp     rax, rdx
    jne     .run_full                   ; the growth path promised otherwise
.run_next:
    inc     qword [rbp - 32]
    mov     rax, [rbp - 32]
    cmp     rax, [rbp - 16]
    jb      .run_page
    mov     r11, [rbp - 24]
    mov     rax, [rbp - 40]
    mov     [r11], rax
    xor     eax, eax
.run_done:
    FRAME_END
    ret
.single:
    mov     ARG1, [rbp - 8]
    mov     ARG2, [rbp - 24]
    call    db_bitmap_alloc
    FRAME_END
    ret

    ; No room to grow. Only the span layout reclaims anything.
.run_reclaim:
    mov     r10, [rbp - 8]
    test    qword [r10 + DB_FEATURES], CybouDB_FEATURE_MAP_SPAN
    jz      .run_full
    mov     ARG1, [r10 + DB_HANDLE]
    call    vfs_reclaim_safe
    test    eax, eax
    jz      .run_full
    mov     r10, [rbp - 8]
    mov     ARG1, r10
    call    span_stage                  ; the map costs no page of its own
    mov     ARG1, [rbp - 8]
    mov     ARG2, [rbp - 16]
    call    span_reuse_run
    test    rax, rax
    jz      .run_full
    mov     [rbp - 40], rax
    mov     qword [rbp - 32], 0
.run_claim:
    mov     rax, [rbp - 40]
    add     rax, [rbp - 32]
    mov     [rbp - 48], rax
    mov     ARG1, [rbp - 8]
    mov     ARG2, rax
    mov     ARG3, MAP_PAYLOAD
    call    span_mark
    mov     r10, [rbp - 8]
    mov     rax, [rbp - 48]
    call    mark_dirty
    mov     r10, [rbp - 8]
    mov     rax, [rbp - 48]
    shl     rax, CybouDB_PAGE_SHIFT
    add     rax, [r10 + DB_BASE]
    mov     ARG1, rax
    call    zero_page
    inc     qword [rbp - 32]
    mov     rax, [rbp - 32]
    cmp     rax, [rbp - 16]
    jb      .run_claim
    mov     r11, [rbp - 24]
    mov     rax, [rbp - 40]
    mov     [r11], rax
    xor     eax, eax
    FRAME_END
    ret
.run_full:
    mov     eax, CybouDB_E_FULL
    FRAME_END
    ret

db_bitmap_alloc:
    FRAME_BEGIN 48, 0
    mov     [rbp - 8], ARG1
    mov     [rbp - 16], ARG2
    mov     r10, ARG1
    test    qword [r10 + DB_FEATURES], CybouDB_FEATURE_MAP_SPAN
    jnz     .span
    mov     rax, [r10 + DB_ALLOC]
    cmp     rax, [r10 + DB_COW_FLOOR]
    jae     .floor
    mov     rax, [r10 + DB_COW_FLOOR]
.floor:
    cmp     rax, [r10 + DB_PAGES]
    jae     .full                    ; reject impossible bounds before addition
    mov     [rbp - 24], rax           ; first unused page
    mov     r11, [r10 + DB_BITMAP]
    cmp     r11, [r10 + DB_COW_FLOOR]
    jae     .have_map
    inc     rax                     ; reserve a fresh map as well
.have_map:
    cmp     rax, [r10 + DB_PAGES]
    jae     .full
    mov     [rbp - 32], rax          ; payload page id
    cmp     r11, [r10 + DB_COW_FLOOR]
    jae     .map_ready
    shl     r11, CybouDB_PAGE_SHIFT
    add     r11, [r10 + DB_BASE]     ; old map
    mov     rax, [rbp - 24]
    mov     [r10 + DB_BITMAP], rax
    shl     rax, CybouDB_PAGE_SHIFT
    add     rax, [r10 + DB_BASE]     ; new map
    mov     ecx, CybouDB_PAGE_SIZE / 8
.copy:
    mov     rdx, [r11]
    mov     [rax], rdx
    add     r11, 8
    add     rax, 8
    dec     ecx
    jnz     .copy
    mov     r8, [r10 + DB_ALLOC]
    mov     rax, [r10 + DB_BITMAP]
    shl     rax, CybouDB_PAGE_SHIFT
    add     rax, [r10 + DB_BASE]
    mov     r10, rax
    mov     r9d, MAP_METADATA
.reserve:
    ; Gaps protected by an older generation stay reserved, never reused.
    call    map_set
    inc     r8
    cmp     r8, [rbp - 32]
    jb      .reserve
.map_ready:
    mov     r10, [rbp - 8]
    mov     rax, [r10 + DB_BITMAP]
    shl     rax, CybouDB_PAGE_SHIFT
    add     rax, [r10 + DB_BASE]
    mov     [rbp - 40], rax
    mov     r10, rax
    mov     r8, [rbp - 32]
    mov     r9d, MAP_PAYLOAD
    call    map_set
    mov     r11, [rbp - 8]
    mov     rax, [r11 + DB_BITMAP]
    mov     [r10 + MAP_PAGE_ID], rax
    mov     rax, [r11 + DB_GENERATION]
    inc     rax
    mov     [r10 + MAP_GENERATION], rax
    lea     rax, [r8 + 1]
    mov     [r11 + DB_ALLOC], rax
    mov     [r10 + MAP_ALLOC], rax
    jmp     .publish

.span:
    mov     rax, [r10 + DB_ALLOC]
    cmp     rax, [r10 + DB_COW_FLOOR]
    jae     .span_floor
    mov     rax, [r10 + DB_COW_FLOOR]
.span_floor:
    mov     [rbp - 24], rax             ; where the file would have to grow
    cmp     rax, [r10 + DB_PAGES]
    jb      .span_room
    cmp     qword [r10 + DB_REUSABLE], 0
    je      .full
    mov     ARG1, [r10 + DB_HANDLE]
    call    vfs_reclaim_safe
    test    eax, eax
    jz      .full
    mov     r10, [rbp - 8]
.span_room:
    mov     ARG1, r10
    call    span_stage                  ; the map costs no page of its own
    mov     r10, [rbp - 8]
    mov     rax, [rbp - 24]
    cmp     rax, [r10 + DB_PAGES]
    jb      .span_grow                  ; grow first, reclaim once full
    mov     ARG1, r10
    call    span_reuse
    test    rax, rax
    jz      .full
    mov     [rbp - 32], rax
    mov     ARG1, [rbp - 8]
    mov     ARG2, rax
    mov     ARG3, MAP_PAYLOAD
    call    span_mark
    jmp     .publish
.span_grow:
    mov     r10, [rbp - 8]
    mov     rax, [rbp - 24]
    mov     [rbp - 32], rax
    mov     r8, [r10 + DB_ALLOC]
.span_gap:
    ; Pages a rejected newer candidate still claims stay reserved, never reused.
    cmp     r8, [rbp - 32]
    jae     .span_gap_done
    mov     ARG1, [rbp - 8]
    mov     ARG2, r8
    mov     ARG3, MAP_METADATA
    mov     [rbp - 24], r8
    call    span_mark
    mov     r8, [rbp - 24]
    inc     r8
    jmp     .span_gap
.span_gap_done:
    mov     ARG1, [rbp - 8]
    mov     ARG2, [rbp - 32]
    mov     ARG3, MAP_PAYLOAD
    call    span_mark
    mov     r10, [rbp - 8]
    mov     rax, [rbp - 32]
    inc     rax
    mov     [r10 + DB_ALLOC], rax
    mov     ARG1, [r10 + DB_BASE]
    mov     ARG2, [r10 + DB_BITMAP]
    xor     ARG3, ARG3
    call    leaf_addr
    mov     r10, [rbp - 8]
    mov     rdx, [rbp - 32]
    inc     rdx
    mov     [rax + MAP_ALLOC], rdx
    ; Leaf zero changes even when the new payload belongs to a later map
    ; leaf. Stamp it so sealing and the next span_stage copy include it.
    mov     rdx, [r10 + DB_GENERATION]
    inc     rdx
    mov     [rax + MAP_GENERATION], rdx

.publish:
    mov     r10, [rbp - 8]
    mov     rax, [rbp - 24]
    call    mark_dirty                  ; the flat map copy lands here too
    mov     r10, [rbp - 8]
    mov     rax, [rbp - 32]
    call    mark_dirty
    mov     r11, [rbp - 8]
    mov     rax, [rbp - 32]
    shl     rax, CybouDB_PAGE_SHIFT
    add     rax, [r11 + DB_BASE]
    mov     ARG1, rax
    call    zero_page
    mov     r11, [rbp - 16]
    mov     rax, [rbp - 32]
    mov     [r11], rax
    xor     eax, eax
    FRAME_END
    ret
.full:
    mov     eax, CybouDB_E_FULL
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  db_bitmap_seal(ctx). Seals only an unpublished map: a root-only commit can
;  reuse an immutable one. In the span layout that means every leaf this
;  transaction stamped with the generation it is about to publish.
;
;  Local slots: [rbp-8]=ctx, [rbp-16]=K, [rbp-24]=index, [rbp-32]=leaf address
; -----------------------------------------------------------------------------
db_bitmap_seal:
    FRAME_BEGIN 48, 0
    mov     [rbp - 8], ARG1
    mov     r10, ARG1
    cmp     qword [r10 + DB_FEATURES], 0
    je      .done
    test    qword [r10 + DB_FEATURES], CybouDB_FEATURE_MAP_SPAN
    jnz     .span
    mov     rax, [r10 + DB_BITMAP]
    cmp     rax, [r10 + DB_COW_FLOOR]
    jb      .done
    shl     rax, CybouDB_PAGE_SHIFT
    add     rax, [r10 + DB_BASE]
    mov     ARG1, rax
    call    seal_leaf
    jmp     .done
.span:
    mov     ARG1, [r10 + DB_PAGES]
    call    db_bitmap_leaves
    mov     [rbp - 16], rax
    mov     qword [rbp - 24], 0
.leaf:
    mov     r10, [rbp - 8]
    mov     ARG1, [r10 + DB_BASE]
    mov     ARG2, [r10 + DB_BITMAP]
    mov     ARG3, [rbp - 24]
    call    leaf_addr
    mov     [rbp - 32], rax
    mov     r10, [rbp - 8]
    mov     r11, [r10 + DB_GENERATION]
    inc     r11
    mov     r10, [rbp - 32]
    cmp     [r10 + MAP_GENERATION], r11
    jne     .next
    mov     ARG1, r10
    call    seal_leaf
.next:
    inc     qword [rbp - 24]
    mov     rax, [rbp - 24]
    cmp     rax, [rbp - 16]
    jb      .leaf
.done:
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  db_bitmap_retire(ctx, page id)
;
;  Records that this generation no longer reaches the page. The flat layout
;  has nowhere to put the answer and keeps growing instead.
; -----------------------------------------------------------------------------
db_bitmap_retire:
    FRAME_BEGIN 16, 0
    mov     r10, ARG1
    test    qword [r10 + DB_FEATURES], CybouDB_FEATURE_MAP_SPAN
    jz      .done
    mov     ARG3, MAP_RETIRED
    call    span_mark
.done:
    xor     eax, eax
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  span_reuse(ARG1 = descriptor) -> RAX = a page to hand out, or 0
;
;  Sweeps the published map - never the staged one - for a page the live
;  generation retired. Reading the published map is what makes the sweep
;  correct on its own: a page allocated earlier in this transaction is free
;  there, and a page retired earlier in this transaction is still payload
;  there, so neither can be picked up twice. The cursor only moves forward, so
;  one transaction costs one sweep of the map however many pages it takes.
;
;  Local slots: [rbp-8]=ctx, [rbp-16]=published map, [rbp-24]=candidate
; -----------------------------------------------------------------------------
; -----------------------------------------------------------------------------
;  span_reuse_run(ARG1 = ctx, ARG2 = pages) -> RAX: first page of a retired run
;  of that length, or 0.
;
;  A leaf is a run, so reclaimed space is only useful to it when enough retired
;  pages sit next to each other. They usually do: a leaf is retired the way it
;  was allocated, as a whole run, so the holes this leaves are run-shaped.
;
;  Failing to find one proves nothing about single pages, so unlike span_reuse
;  this leaves the reuse cursor and the reusable count alone on failure.
;
;  Local slots: [rbp-8]=ctx, [rbp-16]=map root, [rbp-24]=cursor,
;               [rbp-32]=pages wanted, [rbp-40]=run start, [rbp-48]=run length
; -----------------------------------------------------------------------------
span_reuse_run:
    FRAME_BEGIN 64, 0
    mov     [rbp - 8], ARG1
    mov     [rbp - 32], ARG2
    mov     r10, ARG1
    mov     rax, [r10 + DB_REUSABLE]
    cmp     rax, ARG2
    jb      .none
    ; A page joins a run only if it is retired in both maps.
    ;
    ; The published map rules out pages this transaction has just retired: the
    ; generation still on disk references them, and overwriting one before the
    ; commit publishes would destroy the copy a crash has to fall back to.
    ; The staged map rules out pages this transaction has already handed out.
    ; span_reuse needs only the first test, because its rolling cursor never
    ; revisits a page; a run scan starts from the bottom every time.
    mov     r11, [r10 + DB_SB_PTR]
    mov     rax, [r11 + SB_BITMAP_ROOT]
    mov     [rbp - 16], rax
    mov     rax, [r10 + DB_BITMAP]
    mov     [rbp - 56], rax
    ; From the bottom of the file rather than from the rolling reuse cursor:
    ; single-page allocations move that cursor past holes a run still needs,
    ; and what matters here is contiguity, not fairness. Metadata pages below
    ; the payload are simply not retired, so the scan walks past them.
    mov     qword [rbp - 24], CybouDB_MIN_PAGES
    mov     qword [rbp - 40], 0
    mov     qword [rbp - 48], 0
.scan_run:
    mov     r10, [rbp - 8]
    mov     rax, [rbp - 24]
    cmp     rax, [r10 + DB_ALLOC]
    jae     .none
    mov     ARG4, 1
    mov     ARG3, rax
    mov     ARG2, [rbp - 16]
    mov     ARG1, [r10 + DB_BASE]
    call    map_locate
    mov     r10, rax
    mov     r8, rdx
    call    map_get
    cmp     eax, MAP_RETIRED
    jne     .broken
    mov     r10, [rbp - 8]
    mov     ARG4, 1
    mov     ARG3, [rbp - 24]
    mov     ARG2, [rbp - 56]
    mov     ARG1, [r10 + DB_BASE]
    call    map_locate
    mov     r10, rax
    mov     r8, rdx
    call    map_get
    cmp     eax, MAP_RETIRED
    jne     .broken
    cmp     qword [rbp - 48], 0
    jne     .extend_run
    mov     rax, [rbp - 24]
    mov     [rbp - 40], rax
.extend_run:
    inc     qword [rbp - 48]
    mov     rax, [rbp - 48]
    cmp     rax, [rbp - 32]
    jae     .found_run
    jmp     .next_run
.broken:
    mov     qword [rbp - 48], 0
.next_run:
    inc     qword [rbp - 24]
    jmp     .scan_run
.found_run:
    mov     r10, [rbp - 8]
    mov     rax, [rbp - 40]
    mov     rdx, [r10 + DB_REUSABLE]
    sub     rdx, [rbp - 32]
    mov     [r10 + DB_REUSABLE], rdx
    FRAME_END
    ret
.none:
    xor     eax, eax
    FRAME_END
    ret

span_reuse:
    FRAME_BEGIN 32, 0
    mov     [rbp - 8], ARG1
    mov     r10, ARG1
    cmp     qword [r10 + DB_REUSABLE], 0
    je      .none
    mov     r11, [r10 + DB_SB_PTR]
    mov     rax, [r11 + SB_BITMAP_ROOT]
    mov     [rbp - 16], rax
    mov     rax, [r10 + DB_REUSE_NEXT]
    mov     [rbp - 24], rax
.scan:
    mov     r10, [rbp - 8]
    mov     rax, [rbp - 24]
    cmp     rax, [r10 + DB_ALLOC]
    jae     .none
    mov     ARG4, 1
    mov     ARG3, rax
    mov     ARG2, [rbp - 16]
    mov     ARG1, [r10 + DB_BASE]
    call    map_locate
    mov     r10, rax
    mov     r8, rdx
    call    map_get
    cmp     eax, MAP_RETIRED
    jne     .next
    ; The rolling cursor alone no longer proves a page is unclaimed: a run
    ; allocation scans from the bottom of the file and may already have taken
    ; this one. The staged map is where that shows.
    mov     r10, [rbp - 8]
    mov     ARG4, 1
    mov     ARG3, [rbp - 24]
    mov     ARG2, [r10 + DB_BITMAP]
    mov     ARG1, [r10 + DB_BASE]
    call    map_locate
    mov     r10, rax
    mov     r8, rdx
    call    map_get
    cmp     eax, MAP_RETIRED
    je      .found
.next:
    inc     qword [rbp - 24]
    jmp     .scan
.found:
    mov     r10, [rbp - 8]
    mov     rax, [rbp - 24]
    lea     rdx, [rax + 1]
    mov     [r10 + DB_REUSE_NEXT], rdx
    dec     qword [r10 + DB_REUSABLE]
    FRAME_END
    ret
.none:
    mov     r10, [rbp - 8]
    mov     rax, [r10 + DB_ALLOC]
    mov     [r10 + DB_REUSE_NEXT], rax
    mov     qword [r10 + DB_REUSABLE], 0
    xor     eax, eax
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  db_bitmap_recount(ctx)
;
;  Counts what the allocator may reuse and restarts its sweep. Called once when
;  a database is opened and once at the end of every commit, walking leaf by
;  leaf and stopping at the high-water, so a mostly empty file costs almost
;  nothing. Keeping this exact rather than incremental is what lets a full file
;  report its real headroom to the space preflights.
;
;  Local slots: [rbp-8]=ctx, [rbp-16]=count, [rbp-24]=leaf index,
;               [rbp-32]=leaf address, [rbp-40]=span base, [rbp-48]=entries
; -----------------------------------------------------------------------------
db_bitmap_recount:
    FRAME_BEGIN 64, 0
    mov     [rbp - 8], ARG1
    mov     r10, ARG1
    mov     qword [r10 + DB_REUSE_NEXT], CybouDB_MIN_PAGES
    mov     qword [r10 + DB_REUSABLE], 0
    test    qword [r10 + DB_FEATURES], CybouDB_FEATURE_MAP_SPAN
    jz      .done
    mov     qword [rbp - 16], 0
    mov     qword [rbp - 24], 0
.leaf:
    mov     r10, [rbp - 8]
    mov     rax, [rbp - 24]
    imul    rax, CybouDB_MAP_LEAF_PAGES
    mov     [rbp - 40], rax
    cmp     rax, [r10 + DB_ALLOC]
    jae     .counted
    mov     rdx, [r10 + DB_ALLOC]
    sub     rdx, rax
    cmp     rdx, CybouDB_MAP_LEAF_PAGES
    jbe     .entries_known
    mov     rdx, CybouDB_MAP_LEAF_PAGES
.entries_known:
    mov     [rbp - 48], rdx
    mov     ARG1, [r10 + DB_BASE]
    mov     ARG2, [r10 + DB_BITMAP]
    mov     ARG3, [rbp - 24]
    call    leaf_addr
    mov     [rbp - 32], rax
    mov     r10, rax
    xor     r8d, r8d
.entry:
    call    map_get
    cmp     eax, MAP_RETIRED
    jne     .next_entry
    inc     qword [rbp - 16]
.next_entry:
    inc     r8
    cmp     r8, [rbp - 48]
    jb      .entry
    inc     qword [rbp - 24]
    jmp     .leaf
.counted:
    mov     r10, [rbp - 8]
    mov     rax, [rbp - 16]
    mov     [r10 + DB_REUSABLE], rax
.done:
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  db_bitmap_headroom(ctx) -> RAX = pages the allocator can still hand out
;
;  One answer for every space preflight: what is left above the high-water,
;  plus what the live generation retired, minus the page the flat layout still
;  spends on copying its map.
; -----------------------------------------------------------------------------
db_bitmap_headroom:
    FRAME_BEGIN 16, 0
    mov     r10, ARG1
    mov     rax, [r10 + DB_ALLOC]
    cmp     rax, [r10 + DB_COW_FLOOR]
    jae     .floor
    mov     rax, [r10 + DB_COW_FLOOR]
.floor:
    mov     rdx, [r10 + DB_PAGES]
    cmp     rax, rdx
    jae     .empty
    sub     rdx, rax
    test    qword [r10 + DB_FEATURES], CybouDB_FEATURE_MAP_SPAN
    jz      .flat
    add     rdx, [r10 + DB_REUSABLE]
    mov     rax, rdx
    FRAME_END
    ret
.flat:
    mov     rax, [r10 + DB_BITMAP]
    cmp     rax, [r10 + DB_COW_FLOOR]
    jae     .no_map
    dec     rdx                         ; the first allocation also copies it
.no_map:
    mov     rax, rdx
    FRAME_END
    ret
.empty:
    mov     rax, [r10 + DB_REUSABLE]
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  db_bitmap_is_fresh(ctx, page id) -> eax = 1 when this transaction allocated
;  it. Above the high-water of the last commit that is simply its position;
;  a reclaimed page instead is payload now and was not payload when the live
;  generation published its map.
; -----------------------------------------------------------------------------
db_bitmap_is_fresh:
    FRAME_BEGIN 32, 0
    mov     [rbp - 8], ARG1
    mov     [rbp - 16], ARG2
    call    db_bitmap_is_payload
    test    eax, eax
    jz      .no
    mov     r10, [rbp - 8]
    mov     rax, [rbp - 16]
    cmp     rax, [r10 + DB_COW_FLOOR]
    jae     .yes
    test    qword [r10 + DB_FEATURES], CybouDB_FEATURE_MAP_SPAN
    jz      .no
    mov     r11, [r10 + DB_SB_PTR]
    mov     ARG4, 1
    mov     ARG3, rax
    mov     ARG2, [r11 + SB_BITMAP_ROOT]
    mov     ARG1, [r10 + DB_BASE]
    call    map_locate
    mov     r10, rax
    mov     r8, rdx
    call    map_get
    cmp     eax, MAP_PAYLOAD
    je      .no
    cmp     eax, MAP_METADATA
    je      .no
.yes:
    mov     eax, 1
    FRAME_END
    ret
.no:
    xor     eax, eax
    FRAME_END
    ret
