; Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
; SPDX-License-Identifier: Apache-2.0
; Fixed-width PAX storage, optional data directories and COW batch appends.
%include "cyboudb.inc"
BITS 64
default rel
extern crc32c, db_catalog_get, db_catalog_set_data, db_catalog_set_data_stats
extern db_catalog_replace_data, db_catalog_replace_data_stats
extern db_zone_update, db_zone_reserve
extern db_zone_replace_one
extern db_bitmap_candidate_payload, db_bitmap_headroom, db_bitmap_deep
extern db_cow_alloc_page, db_cow_copy_page
extern db_cow_alloc_run, db_cow_copy_run
extern db_var_validate_chain, db_var_materialize_batch
extern pax_compress_leaf, pax_decompress_leaf_old, decompress_column
global db_pax_validate, db_pax_check_new, db_pax_insert, db_pax_read
global db_pax_update_one
global db_pax_capacity
global db_pax_scan_open, db_pax_scan_open_bound, db_pax_scan_next, db_pax_scan_batch
global db_pax_scan_batch_ex
global pax_decode_trace, pax_decode_calls, pax_const_columns, pax_bool_columns, pax_null_columns
global pax_for_columns
section .bss
align 8
; Opt-in test diagnostics, like the SQL zone counters. Disabled during timings.
pax_decode_trace: resq 1
pax_decode_calls: resq 1
pax_const_columns: resq 1
pax_bool_columns: resq 1
pax_null_columns: resq 1
pax_for_columns:  resq 1
section .text

; db_pax_capacity(ctx, validated_schema) -> rows per logical leaf.
db_pax_capacity:
    mov r10, ARG1
    mov r11, ARG2
    xor eax, eax
    test qword [r10 + DB_FEATURES], CybouDB_FEATURE_PAX_RUNS
    setnz al
    mov ARG1, r11
    mov ARG2, rax
    jmp pax_capacity

; pax_runs(ARG1 = ctx) -> RAX: 1 when a leaf in this file is a run of pages.
; Capacity is recomputed during validation and compared against what a leaf
; stores, so every caller has to ask the file which arithmetic it was written
; with rather than assume the current one.
pax_runs:
    mov r10, ARG1
    xor eax, eax
    test qword [r10 + DB_FEATURES], CybouDB_FEATURE_PAX_RUNS
    setnz al
    ret

; PAX_CAPACITY_OF <schema>, <ctx> - rows per leaf, in RAX.
; Both operands are read before anything is clobbered, so a caller may pass
; memory slots; a register holding the schema would not survive pax_runs.
%macro PAX_CAPACITY_OF 2
    mov ARG1, %2
    call pax_runs
    mov ARG2, rax
    mov ARG1, %1
    call pax_capacity
%endmacro

; PAX_RUN_OF <schema>, <ctx> - pages per leaf, in RAX.
%macro PAX_RUN_OF 2
    mov ARG1, %2
    call pax_runs
    mov ARG2, rax
    mov ARG1, %1
    call pax_run_pages
%endmacro

; Dispatch the schema data root according to the immutable file capability.
root_valid:
    mov r10, ARG1
    test qword [r10 + DB_FEATURES], CybouDB_FEATURE_PAX_MULTI
    jz page_valid
    jmp directory_valid

; dir_header_valid(ctx, candidate_sb, schema, id) -> mapped pointer or zero.
; The fields every directory carries, whichever level it sits at. The level
; itself is checked here; what it means is the caller's business.
;
; Local slots: [rbp-8]=ctx, [rbp-16]=candidate, [rbp-24]=schema, [rbp-32]=id,
;              [rbp-40]=address
dir_header_valid:
    FRAME_BEGIN 48, 0
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
    mov [rbp - 24], ARG3
    mov [rbp - 32], ARG4
    mov ARG3, ARG4
    call db_bitmap_candidate_payload
    test eax, eax
    jz .bad
    mov r10, [rbp - 8]
    mov r11, [rbp - 16]
    mov r8, [rbp - 32]
    shl r8, CybouDB_PAGE_SHIFT
    add r8, [r10 + DB_BASE]
    mov [rbp - 40], r8
    cmp dword [r8], PAX_DIR_MAGIC
    jne .bad
    cmp dword [r8 + 4], 1
    jne .bad
    mov rax, [rbp - 32]
    cmp [r8 + PAX_PAGE_ID], rax
    jne .bad
    mov rax, [r8 + PAX_GENERATION]
    test rax, rax
    jz .bad
    cmp rax, [r11 + SB_GENERATION]
    ja .bad
    mov r10, [rbp - 24]
    mov rax, [r10 + CAT_OWNER]
    cmp [r8 + PAX_OWNER], rax
    jne .bad
    ; A build without the tree feature wrote zero here, which is the level a
    ; flat directory has, so nothing older needs a special case.
    mov eax, [r8 + PAX_DIR_LEVEL]
    cmp eax, PAX_DIR_ROOT
    ja .bad
    mov rax, [r8 + 48]
    or rax, [r8 + 56]
    jnz .bad
    mov ARG3, [r8 + PAX_GENERATION]
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    call db_bitmap_deep
    test eax, eax
    jz .valid
    mov ARG1, [rbp - 40]
    mov ARG2, PAX_CRC
    call crc32c
    mov r10, [rbp - 40]
    cmp [r10 + PAX_CRC], eax
    jne .bad
.valid:
    mov rax, [rbp - 40]
    FRAME_END
    ret
.bad:
    xor eax, eax
    FRAME_END
    ret

; dir_flat_valid(ctx, candidate_sb, schema, address, capacity) -> 1 or 0.
; A level-0 directory: its entries name leaves and its row ends are its own,
; so one routine checks a whole small table and one child of a large one.
;
; Local slots: [rbp-8]=ctx, [rbp-16]=candidate, [rbp-24]=schema,
;              [rbp-40]=address, [rbp-48]=entries, [rbp-56]=rows,
;              [rbp-64]=capacity, [rbp-72]=index, [rbp-80]=scan index,
;              [rbp-88]=previous end, [rbp-96]=this end
dir_flat_valid:
    FRAME_BEGIN 112, 0
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
    mov [rbp - 24], ARG3
    mov [rbp - 40], ARG4
    mov rax, IN_ARG5
    mov [rbp - 64], rax
    mov r8, ARG4
    cmp dword [r8 + PAX_DIR_LEVEL], PAX_DIR_LEAF
    jne .bad
    mov eax, [r8 + PAX_COLUMNS]       ; number of data-page entries
    test eax, eax
    jz .bad
    cmp eax, PAX_DIR_MAX
    ja .bad
    mov [rbp - 48], rax
    mov eax, [r8 + PAX_ROWS]
    test eax, eax
    jz .bad
    mov [rbp - 56], rax
    mov rax, [rbp - 64]
    mov r10, [rbp - 40]
    cmp [r10 + PAX_CAPACITY], eax
    jne .bad
    mov rcx, rax
    mov rax, [rbp - 56]
    dec rax
    xor edx, edx
    div rcx
    inc rax
    cmp rax, [rbp - 48]
    jne .bad
    mov qword [rbp - 72], 0          ; entry index
    mov qword [rbp - 80], 0          ; scan index for the uniqueness check
    mov qword [rbp - 88], 0          ; previous row end
.entry:
    mov rax, [rbp - 72]
    shl rax, 4
    add rax, [rbp - 40]
    mov r11, [rax + PAX_DIRECTORY]
    ; Logical order is the directory's order, not the physical one. A leaf
    ; rewritten by copy-on-write keeps its place while moving to a fresh high
    ; page id, so ids must not be required to increase; only being distinct
    ; matters, and that is what rejects an aliased leaf. The table is bounded
    ; at PAX_DIR_MAX entries, so the quadratic scan stays trivially small.
    mov qword [rbp - 80], 0
.unique:
    mov rdx, [rbp - 80]
    cmp rdx, [rbp - 72]
    jae .unique_ok
    shl rdx, 4
    add rdx, [rbp - 40]
    cmp r11, [rdx + PAX_DIRECTORY]
    je .bad
    inc qword [rbp - 80]
    jmp .unique
.unique_ok:
    mov rax, [rax + PAX_DIRECTORY + 8]
    mov [rbp - 96], rax
    mov rdx, [rbp - 88]
    add rdx, [rbp - 64]
    cmp rdx, [rbp - 56]
    jbe .end_ready
    mov rdx, [rbp - 56]
.end_ready:
    cmp rax, rdx
    jne .bad
    mov ARG4, r11
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    mov ARG3, [rbp - 24]
    call page_valid
    test rax, rax
    jz .bad
    mov r10, [rbp - 40]
    mov rdx, [rax + PAX_GENERATION]
    cmp rdx, [r10 + PAX_GENERATION]
    ja .bad
    mov rdx, [rbp - 96]
    sub rdx, [rbp - 88]
    cmp [rax + PAX_ROWS], edx
    jne .bad
    mov rax, [rbp - 96]
    mov [rbp - 88], rax
    inc qword [rbp - 72]
    mov rax, [rbp - 72]
    cmp rax, [rbp - 48]
    jb .entry
    shl rax, 4
    add rax, PAX_DIRECTORY
    mov r10, [rbp - 40]
.tail:
    cmp rax, PAX_CRC
    jae .valid
    cmp byte [r10 + rax], 0
    jne .bad
    inc rax
    jmp .tail
.valid:
    mov eax, 1
    FRAME_END
    ret
.bad:
    xor eax, eax
    FRAME_END
    ret

; directory_valid(ctx, candidate_sb, schema, id) -> mapped pointer or zero.
; A directory maps logical leaf order to physical page ids and row ends. At
; level 1 it maps to level-0 directories instead, each a complete flat
; directory of its own slice of the table.
;
; Local slots: [rbp-8]=ctx, [rbp-16]=candidate, [rbp-24]=schema, [rbp-32]=id,
;              [rbp-40]=address, [rbp-48]=entries, [rbp-56]=rows,
;              [rbp-64]=rows per child, [rbp-72]=index, [rbp-80]=scan index,
;              [rbp-88]=previous end, [rbp-96]=this end, [rbp-104]=child,
;              [rbp-112]=capacity
directory_valid:
    FRAME_BEGIN 128, 1
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
    mov [rbp - 24], ARG3
    mov [rbp - 32], ARG4
    call dir_header_valid
    test rax, rax
    jz .bad
    mov [rbp - 40], rax
    PAX_CAPACITY_OF [rbp - 24], [rbp - 8]
    mov [rbp - 112], rax
    mov r10, [rbp - 40]
    cmp dword [r10 + PAX_DIR_LEVEL], PAX_DIR_LEAF
    jne .root

    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    mov ARG3, [rbp - 24]
    mov ARG4, [rbp - 40]
    mov rax, [rbp - 112]
    PASS_ARG5 rax
    call dir_flat_valid
    test eax, eax
    jz .bad
    jmp .valid

    ; --- level 1: a directory of directories ---------------------------------
.root:
    mov r10, [rbp - 8]
    test qword [r10 + DB_FEATURES], CybouDB_FEATURE_PAX_TREE
    jz .bad
    mov r10, [rbp - 40]
    mov eax, [r10 + PAX_COLUMNS]
    cmp eax, 2
    jb .bad                          ; a one-child tree would just be flat
    cmp eax, PAX_DIR_MAX
    ja .bad
    mov [rbp - 48], rax
    mov eax, [r10 + PAX_ROWS]
    test eax, eax
    jz .bad
    mov [rbp - 56], rax
    mov eax, [rbp - 112]
    cmp [r10 + PAX_CAPACITY], eax
    jne .bad
    ; A full child covers PAX_DIR_MAX leaves, so the root's own arithmetic is
    ; the flat one with that span in place of one leaf.
    mov rax, [rbp - 112]
    imul rax, PAX_DIR_MAX
    mov [rbp - 64], rax
    mov rcx, rax
    mov rax, [rbp - 56]
    dec rax
    xor edx, edx
    div rcx
    inc rax
    cmp rax, [rbp - 48]
    jne .bad
    mov qword [rbp - 72], 0
    mov qword [rbp - 88], 0
.child:
    mov rax, [rbp - 72]
    shl rax, 4
    add rax, [rbp - 40]
    mov r11, [rax + PAX_DIRECTORY]
    mov qword [rbp - 80], 0
.child_unique:
    mov rdx, [rbp - 80]
    cmp rdx, [rbp - 72]
    jae .child_unique_ok
    shl rdx, 4
    add rdx, [rbp - 40]
    cmp r11, [rdx + PAX_DIRECTORY]
    je .bad
    inc qword [rbp - 80]
    jmp .child_unique
.child_unique_ok:
    mov rax, [rax + PAX_DIRECTORY + 8]
    mov [rbp - 96], rax
    mov rdx, [rbp - 88]
    add rdx, [rbp - 64]
    cmp rdx, [rbp - 56]
    jbe .child_end_ready
    mov rdx, [rbp - 56]
.child_end_ready:
    cmp rax, rdx
    jne .bad
    mov ARG4, r11
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    mov ARG3, [rbp - 24]
    call dir_header_valid
    test rax, rax
    jz .bad
    mov [rbp - 104], rax
    mov r10, [rbp - 40]
    mov rdx, [rax + PAX_GENERATION]
    cmp rdx, [r10 + PAX_GENERATION]
    ja .bad
    mov rdx, [rbp - 96]
    sub rdx, [rbp - 88]
    cmp [rax + PAX_ROWS], edx
    jne .bad
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    mov ARG3, [rbp - 24]
    mov ARG4, [rbp - 104]
    mov rax, [rbp - 112]
    PASS_ARG5 rax
    call dir_flat_valid
    test eax, eax
    jz .bad
    mov rax, [rbp - 96]
    mov [rbp - 88], rax
    inc qword [rbp - 72]
    mov rax, [rbp - 72]
    cmp rax, [rbp - 48]
    jb .child
    shl rax, 4
    add rax, PAX_DIRECTORY
    mov r10, [rbp - 40]
.root_tail:
    cmp rax, PAX_CRC
    jae .tree_unique
    cmp byte [r10 + rax], 0
    jne .bad
    inc rax
    jmp .root_tail
.tree_unique:
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    mov ARG3, [rbp - 40]
    call tree_leaves_unique
    test eax, eax
    jz .bad
.valid:
    mov rax, [rbp - 40]
    FRAME_END
    ret
.bad:
    xor eax, eax
    FRAME_END
    ret

; All child directories have already been validated. Reject aliases between
; children using a 2 KiB bitmap window over physical page ids. Revisit the
; entries for each allocation-map-sized window instead of allocating memory
; proportional to the table or comparing every pair of leaves. The frame
; stays below one OS stack guard page on both supported ABIs.
tree_leaves_unique:
    FRAME_BEGIN 2112, 0
    mov r10, ARG1
    mov r11, ARG2
    mov [rbp - 8], ARG3
    mov rax, [r10 + DB_BASE]
    mov [rbp - 16], rax
    mov rax, [r11 + SB_ALLOC_PAGES]
    mov [rbp - 24], rax
    mov qword [rbp - 32], 0
.window:
    xor eax, eax
.clear:
    mov qword [rbp - 2112 + rax * 8], 0
    inc eax
    cmp eax, 256
    jb .clear
    mov r10, [rbp - 8]
    xor ecx, ecx
.child:
    mov rax, rcx
    shl rax, 4
    mov r11, [r10 + PAX_DIRECTORY + rax]
    shl r11, CybouDB_PAGE_SHIFT
    add r11, [rbp - 16]
    xor edx, edx
.leaf:
    mov rax, rdx
    shl rax, 4
    mov rax, [r11 + PAX_DIRECTORY + rax]
    sub rax, [rbp - 32]
    cmp rax, 16384
    jae .next_leaf
    bts qword [rbp - 2112], rax
    jc .bad
.next_leaf:
    inc edx
    cmp edx, [r11 + PAX_COLUMNS]
    jb .leaf
    inc ecx
    cmp ecx, [r10 + PAX_COLUMNS]
    jb .child
    add qword [rbp - 32], 16384
    mov rax, [rbp - 32]
    cmp rax, [rbp - 24]
    jb .window
    mov eax, 1
    FRAME_END
    ret
.bad:
    xor eax, eax
    FRAME_END
    ret

; Called only after complete batch/schema validation, by pax_multi_insert,
; for a table whose leaves no longer fit one directory page.
;
; pax_tree_insert(ctx, schema, batch): the same copy-the-changed-path shape as
; the flat insert, with one level in between. A child directory is a complete
; flat directory of its own slice of the table - its row ends are its own -
; so the level below is exactly what a small table already has, and only the
; root knows the difference.
;
; Local slots: [rbp-8]=ctx, [rbp-16]=schema, [rbp-24]=batch,
;              [rbp-32]=capacity, [rbp-40]=new rows, [rbp-48]=old rows,
;              [rbp-56]=first leaf, [rbp-64]=final leaves, [rbp-72]=root id,
;              [rbp-80]=root address, [rbp-88]=old root id,
;              [rbp-96]=rows left, [rbp-104]=rows already in the tail leaf,
;              [rbp-112]=leaf index, [rbp-144..-128]=sub-batch descriptor,
;              [rbp-152]=source leaf, [rbp-160]=preflight need,
;              [rbp-168]=run pages, [rbp-176]=first child,
;              [rbp-184]=final children, [rbp-192]=child index,
;              [rbp-200]=child id, [rbp-208]=child address,
;              [rbp-216]=old root address, [rbp-224]=old root level,
;              [rbp-232]=rows per child, [rbp-240]=rows in this child,
;              [rbp-248]=leaves in this child, [rbp-256]=last leaf of the child
pax_tree_insert:
    FRAME_BEGIN 288, 1
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
    mov [rbp - 24], ARG3
    mov r10, ARG2
    mov rax, [r10 + CAT_TABLE_ROWS]
    mov [rbp - 48], rax
    mov rax, [r10 + CAT_DATA_ROOT]
    mov [rbp - 88], rax
    mov r11, ARG3
    mov rax, [r11 + BATCH_ROWS]
    mov [rbp - 96], rax
    add rax, [rbp - 48]
    mov [rbp - 40], rax
    mov rax, [r11 + BATCH_VALUES]
    mov [rbp - 136], rax
    mov rax, [r11 + BATCH_NULLS]
    mov [rbp - 128], rax
    mov qword [rbp - 120], 0
    mov ARG1, [rbp - 16]
    call schema_has_varlen
    test eax, eax
    jz .tree_lengths_loaded
    mov r11, [rbp - 24]
    mov rax, [r11 + BATCH_VAR_LENGTHS]
    mov [rbp - 120], rax
.tree_lengths_loaded:

    PAX_CAPACITY_OF [rbp - 16], [rbp - 8]
    mov [rbp - 32], rax
    mov rcx, rax
    mov rax, [rbp - 48]
    xor edx, edx
    div rcx
    mov [rbp - 56], rax             ; first changed leaf
    mov [rbp - 112], rax
    mov [rbp - 104], rdx            ; rows already in that leaf, or zero
    mov rax, [rbp - 40]
    dec rax
    xor edx, edx
    div rcx
    inc rax
    mov [rbp - 64], rax             ; leaves the table ends with

    mov rax, [rbp - 32]
    imul rax, PAX_DIR_MAX
    mov [rbp - 232], rax            ; rows one full child covers
    mov rcx, PAX_DIR_MAX
    mov rax, [rbp - 56]
    xor edx, edx
    div rcx
    mov [rbp - 176], rax            ; first changed child
    mov [rbp - 192], rax
    mov rax, [rbp - 64]
    dec rax
    xor edx, edx
    div rcx
    inc rax
    mov [rbp - 184], rax            ; children the table ends with
    cmp rax, PAX_DIR_MAX
    ja .rows

    PAX_RUN_OF [rbp - 16], [rbp - 8]
    mov [rbp - 168], rax
    mov rcx, [rbp - 64]
    sub rcx, [rbp - 56]
    imul rcx, rax                   ; leaf runs
    mov rax, [rbp - 184]
    sub rax, [rbp - 176]
    add rcx, rax                    ; child directories
    add rcx, 3                      ; root + schema + catalog root
    mov [rbp - 160], rcx
    ; The statistics of the leaves this insert touches are written by the same
    ; transaction, so their pages belong in the same preflight.
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    mov ARG3, [rbp - 24]
    mov ARG4, [rbp - 32]
    call db_zone_reserve
    add [rbp - 160], rax
    mov r11, [rbp - 24]
    test qword [r11 + BATCH_FLAGS], BATCH_VARLEN_PERSISTED
    jnz .flat_materialized                  ; roots carried over, nothing to build
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    mov ARG3, [rbp - 24]
    mov r11, [rbp - 16]
    mov ARG4, [r11 + CAT_OWNER]
    mov rax, [rbp - 160]
    PASS_ARG5 rax
    call db_var_materialize_batch
    test eax, eax
    jnz .done
.flat_materialized:
    mov ARG1, [rbp - 8]
    call db_bitmap_headroom
    cmp rax, [rbp - 160]
    jb .full

    ; --- what the table looks like today -------------------------------------
    mov qword [rbp - 216], 0
    mov qword [rbp - 224], PAX_DIR_LEAF
    cmp qword [rbp - 88], 0
    je .old_known
    mov r10, [rbp - 8]
    mov rax, [rbp - 88]
    shl rax, CybouDB_PAGE_SHIFT
    add rax, [r10 + DB_BASE]
    mov [rbp - 216], rax
    mov eax, [rax + PAX_DIR_LEVEL]
    mov [rbp - 224], rax
.old_known:

    ; --- the root ------------------------------------------------------------
    ; Already a tree: copy it, so the children this insert does not touch keep
    ; their entries and the old page is retired. Still flat: the old directory
    ; becomes child 0 and must stay alive, so the root is a fresh page.
    mov ARG1, [rbp - 8]
    cmp qword [rbp - 224], PAX_DIR_ROOT
    jne .root_fresh
    mov ARG2, [rbp - 88]
    lea ARG3, [rbp - 72]
    call db_cow_copy_page
    jmp .root_ready
.root_fresh:
    lea ARG2, [rbp - 72]
    call db_cow_alloc_page
.root_ready:
    test eax, eax
    jnz .done
    mov r10, [rbp - 8]
    mov rax, [rbp - 72]
    shl rax, CybouDB_PAGE_SHIFT
    add rax, [r10 + DB_BASE]
    mov [rbp - 80], rax
    mov dword [rax], PAX_DIR_MAGIC
    mov dword [rax + 4], 1
    mov rdx, [rbp - 72]
    mov [rax + PAX_PAGE_ID], rdx
    mov rdx, [r10 + DB_GENERATION]
    inc rdx
    mov [rax + PAX_GENERATION], rdx
    mov r11, [rbp - 16]
    mov rdx, [r11 + CAT_OWNER]
    mov [rax + PAX_OWNER], rdx
    mov edx, [rbp - 40]
    mov [rax + PAX_ROWS], edx
    mov edx, [rbp - 184]
    mov [rax + PAX_COLUMNS], edx
    mov edx, [rbp - 32]
    mov [rax + PAX_CAPACITY], edx
    mov dword [rax + PAX_DIR_LEVEL], PAX_DIR_ROOT

    ; Promotion leaves the old flat directory in place as child 0 whenever
    ; this insert does not touch it.
    cmp qword [rbp - 224], PAX_DIR_ROOT
    je .children
    cmp qword [rbp - 176], 0
    je .children
    mov r10, [rbp - 80]
    mov rdx, [rbp - 88]
    mov [r10 + PAX_DIRECTORY], rdx
    mov rdx, [rbp - 232]
    mov [r10 + PAX_DIRECTORY + 8], rdx

    ; --- one child directory at a time ---------------------------------------
.children:
    ; rows this child holds, and how many leaves that is
    mov rax, [rbp - 192]
    imul rax, [rbp - 232]
    mov rdx, [rbp - 40]
    sub rdx, rax                    ; rows from this child onwards
    cmp rdx, [rbp - 232]
    jbe .child_rows_ready
    mov rdx, [rbp - 232]
.child_rows_ready:
    mov [rbp - 240], rdx
    mov rax, rdx
    dec rax
    xor edx, edx
    div qword [rbp - 32]
    inc rax
    mov [rbp - 248], rax            ; leaves in this child
    mov rax, [rbp - 192]
    imul rax, PAX_DIR_MAX
    add rax, [rbp - 248]
    mov [rbp - 256], rax            ; one past this child's last global leaf

    ; A child that already exists is copied; a new one is a fresh page. Only
    ; the first changed child can already exist.
    mov ARG1, [rbp - 8]
    mov rax, [rbp - 192]
    cmp rax, [rbp - 176]
    jne .child_fresh
    cmp qword [rbp - 216], 0
    je .child_fresh
    cmp qword [rbp - 224], PAX_DIR_ROOT
    je .child_from_root
    ; Promotion: the old flat directory becomes child 0 and nothing else. When
    ; this insert starts past it, it is already recorded above and stays
    ; shared, so copying it here would alias it into two entries at once.
    cmp qword [rbp - 192], 0
    jne .child_fresh
    mov ARG2, [rbp - 88]
    jmp .child_copy
.child_from_root:
    mov r10, [rbp - 216]
    mov rax, [rbp - 192]
    shl rax, 4
    add rax, r10
    mov edx, [r10 + PAX_COLUMNS]
    cmp [rbp - 192], rdx
    jae .child_fresh                ; beyond what the old tree had
    mov ARG2, [rax + PAX_DIRECTORY]
.child_copy:
    lea ARG3, [rbp - 200]
    call db_cow_copy_page
    jmp .child_ready
.child_fresh:
    lea ARG2, [rbp - 200]
    call db_cow_alloc_page
.child_ready:
    test eax, eax
    jnz .done
    mov r10, [rbp - 8]
    mov rax, [rbp - 200]
    shl rax, CybouDB_PAGE_SHIFT
    add rax, [r10 + DB_BASE]
    mov [rbp - 208], rax
    mov dword [rax], PAX_DIR_MAGIC
    mov dword [rax + 4], 1
    mov rdx, [rbp - 200]
    mov [rax + PAX_PAGE_ID], rdx
    mov rdx, [r10 + DB_GENERATION]
    inc rdx
    mov [rax + PAX_GENERATION], rdx
    mov r11, [rbp - 16]
    mov rdx, [r11 + CAT_OWNER]
    mov [rax + PAX_OWNER], rdx
    mov edx, [rbp - 240]
    mov [rax + PAX_ROWS], edx
    mov edx, [rbp - 248]
    mov [rax + PAX_COLUMNS], edx
    mov edx, [rbp - 32]
    mov [rax + PAX_CAPACITY], edx
    mov dword [rax + PAX_DIR_LEVEL], PAX_DIR_LEAF

.leaf:
    mov rax, [rbp - 32]
    sub rax, [rbp - 104]
    cmp rax, [rbp - 96]
    jbe .batch_ready
    mov rax, [rbp - 96]
.batch_ready:
    mov [rbp - 144], rax            ; local sub-batch descriptor
    mov qword [rbp - 152], 0
    cmp qword [rbp - 104], 0
    je .source_ready
    ; The copied child still names the old leaf in this slot.
    mov rax, [rbp - 112]
    mov rdx, [rbp - 192]
    imul rdx, PAX_DIR_MAX
    sub rax, rdx
    shl rax, 4
    add rax, [rbp - 208]
    mov rax, [rax + PAX_DIRECTORY]
    mov [rbp - 152], rax
.source_ready:
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    mov ARG3, [rbp - 152]
    lea ARG4, [rbp - 144]
    call pax_append_page
    test eax, eax
    jnz .done
    mov rax, [rbp - 112]
    mov rcx, [rbp - 192]
    imul rcx, PAX_DIR_MAX
    sub rax, rcx                    ; slot inside this child
    mov rcx, rax
    shl rax, 4
    add rax, [rbp - 208]
    mov [rax + PAX_DIRECTORY], rdx
    inc rcx
    imul rcx, [rbp - 32]
    cmp rcx, [rbp - 240]
    jbe .end_ready
    mov rcx, [rbp - 240]
.end_ready:
    mov [rax + PAX_DIRECTORY + 8], rcx
    mov rax, [rbp - 144]
    sub [rbp - 96], rax
    mov r11, [rbp - 16]
    mov ecx, [r11 + CAT_COUNT]
    imul rax, rcx
    cmp qword [rbp - 128], 0
    je .nulls_ready
    add [rbp - 128], rax
.nulls_ready:
    shl rax, 3
    cmp qword [rbp - 120], 0
    je .tree_lengths_ready
    add [rbp - 120], rax
.tree_lengths_ready:
    add [rbp - 136], rax
    mov qword [rbp - 104], 0
    inc qword [rbp - 112]
    mov rax, [rbp - 112]
    cmp rax, [rbp - 256]
    jb .leaf

    ; --- seal the child and record it in the root ----------------------------
    mov rax, [rbp - 248]
    shl rax, 4
    add rax, PAX_DIRECTORY
    mov r10, [rbp - 208]
.child_tail:
    cmp rax, PAX_CRC
    jae .child_sealed
    mov byte [r10 + rax], 0
    inc rax
    jmp .child_tail
.child_sealed:
    mov ARG1, [rbp - 208]
    mov ARG2, PAX_CRC
    call crc32c
    mov r10, [rbp - 208]
    mov [r10 + PAX_CRC], eax
    mov rax, [rbp - 192]
    shl rax, 4
    add rax, [rbp - 80]
    mov rdx, [rbp - 200]
    mov [rax + PAX_DIRECTORY], rdx
    mov rdx, [rbp - 192]
    inc rdx
    imul rdx, [rbp - 232]
    cmp rdx, [rbp - 40]
    jbe .child_end_ready
    mov rdx, [rbp - 40]
.child_end_ready:
    mov [rax + PAX_DIRECTORY + 8], rdx
    inc qword [rbp - 192]
    mov rax, [rbp - 192]
    cmp rax, [rbp - 184]
    jb .children

    ; --- seal the root and publish -------------------------------------------
    mov rax, [rbp - 184]
    shl rax, 4
    add rax, PAX_DIRECTORY
    mov r10, [rbp - 80]
.root_tail:
    cmp rax, PAX_CRC
    jae .root_sealed
    mov byte [r10 + rax], 0
    inc rax
    jmp .root_tail
.root_sealed:
    mov ARG1, [rbp - 80]
    mov ARG2, PAX_CRC
    call crc32c
    mov r10, [rbp - 80]
    mov [r10 + PAX_CRC], eax
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    mov ARG3, [rbp - 24]
    mov ARG4, [rbp - 48]
    mov rax, [rbp - 32]
    PASS_ARG5 rax
    call db_zone_update
    test eax, eax
    jnz .done
    mov ARG4, rdx
    mov r11, [rbp - 16]
    mov ARG2, [r11 + CAT_OWNER]
    mov ARG1, [rbp - 8]
    mov ARG3, [rbp - 72]
    call db_catalog_set_data_stats
    jmp .done
.rows:
    mov eax, CybouDB_E_ROWS
    jmp .done
.full:
    mov eax, CybouDB_E_FULL
.done:
    FRAME_END
    ret

; Called only after complete batch/schema validation by db_pax_insert.
; pax_multi_insert(ctx, schema, batch): preflight and copy the whole changed path.
pax_multi_insert:
    FRAME_BEGIN 208, 1
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
    mov [rbp - 24], ARG3
    mov r10, ARG2
    mov rax, [r10 + CAT_TABLE_ROWS]
    mov [rbp - 48], rax
    mov rax, [r10 + CAT_DATA_ROOT]
    mov [rbp - 88], rax
    mov r11, ARG3
    mov rax, [r11 + BATCH_ROWS]
    mov [rbp - 96], rax
    add rax, [rbp - 48]
    mov [rbp - 40], rax
    mov rax, [r11 + BATCH_VALUES]
    mov [rbp - 136], rax
    mov rax, [r11 + BATCH_NULLS]
    mov [rbp - 128], rax
    mov qword [rbp - 120], 0
    mov ARG1, [rbp - 16]
    call schema_has_varlen
    test eax, eax
    jz .multi_lengths_loaded
    mov r11, [rbp - 24]
    mov rax, [r11 + BATCH_VAR_LENGTHS]
    mov [rbp - 120], rax
.multi_lengths_loaded:
    PAX_CAPACITY_OF [rbp - 16], [rbp - 8]
    mov [rbp - 32], rax
    mov rcx, rax
    mov rax, [rbp - 48]
    xor edx, edx
    div rcx
    mov [rbp - 56], rax
    mov [rbp - 112], rax            ; first changed leaf index
    mov [rbp - 104], rdx            ; rows in the partial last leaf, or zero
    mov rax, [rbp - 40]
    dec rax
    xor edx, edx
    div rcx
    inc rax
    mov [rbp - 64], rax             ; final directory entry count
    ; One directory page addresses PAX_DIR_MAX leaves. Past that the table
    ; grows a level above it instead of stopping.
    cmp rax, PAX_DIR_MAX
    jbe .flat
    mov r10, [rbp - 8]
    test qword [r10 + DB_FEATURES], CybouDB_FEATURE_PAX_TREE
    jz .rows_full
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    mov ARG3, [rbp - 24]
    call pax_tree_insert
    jmp .done
.rows_full:
    mov eax, CybouDB_E_ROWS
    jmp .done
.flat:
    ; Each changed leaf costs a whole run, not a page.
    PAX_RUN_OF [rbp - 16], [rbp - 8]
    mov [rbp - 168], rax            ; pages per leaf
    mov rcx, [rbp - 64]
    sub rcx, [rbp - 56]
    imul rcx, rax
    add rcx, 3                      ; directory + schema + catalog root
    mov [rbp - 160], rcx
    ; The statistics of the leaves this insert touches are written by the same
    ; transaction, so their pages belong in the same preflight.
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    mov ARG3, [rbp - 24]
    mov ARG4, [rbp - 32]
    call db_zone_reserve
    mov rcx, [rbp - 160]
    add rcx, rax
    mov [rbp - 160], rcx
    mov r11, [rbp - 24]
    test qword [r11 + BATCH_FLAGS], BATCH_VARLEN_PERSISTED
    jnz .tree_materialized                  ; roots carried over, nothing to build
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    mov ARG3, [rbp - 24]
    mov r11, [rbp - 16]
    mov ARG4, [r11 + CAT_OWNER]
    mov rax, [rbp - 160]
    PASS_ARG5 rax
    call db_var_materialize_batch
    test eax, eax
    jnz .done
.tree_materialized:
    mov ARG1, [rbp - 8]
    call db_bitmap_headroom
    cmp rax, [rbp - 160]
    jb .full
    mov r10, [rbp - 8]
    mov ARG1, r10
    mov ARG2, [rbp - 88]
    test ARG2, ARG2
    jz .allocate
    lea ARG3, [rbp - 72]
    call db_cow_copy_page
    jmp .allocated
.allocate:
    lea ARG2, [rbp - 72]
    call db_cow_alloc_page
.allocated:
    test eax, eax
    jnz .done
    mov r10, [rbp - 8]
    mov rax, [rbp - 72]
    shl rax, CybouDB_PAGE_SHIFT
    add rax, [r10 + DB_BASE]
    mov [rbp - 80], rax
    mov dword [rax], PAX_DIR_MAGIC
    mov dword [rax + 4], 1
    mov rdx, [rbp - 72]
    mov [rax + PAX_PAGE_ID], rdx
    mov rdx, [r10 + DB_GENERATION]
    inc rdx
    mov [rax + PAX_GENERATION], rdx
    mov r11, [rbp - 16]
    mov rdx, [r11 + CAT_OWNER]
    mov [rax + PAX_OWNER], rdx
    mov edx, [rbp - 40]
    mov [rax + PAX_ROWS], edx
    mov edx, [rbp - 64]
    mov [rax + PAX_COLUMNS], edx
    mov edx, [rbp - 32]
    mov [rax + PAX_CAPACITY], edx
.leaf:
    mov rax, [rbp - 32]
    sub rax, [rbp - 104]
    cmp rax, [rbp - 96]
    jbe .batch_ready
    mov rax, [rbp - 96]
.batch_ready:
    mov [rbp - 144], rax            ; local sub-batch descriptor
    mov qword [rbp - 152], 0
    cmp qword [rbp - 104], 0
    je .source_ready
    mov rax, [rbp - 112]
    shl rax, 4
    add rax, [rbp - 80]
    mov rax, [rax + PAX_DIRECTORY]
    mov [rbp - 152], rax
.source_ready:
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    mov ARG3, [rbp - 152]
    lea ARG4, [rbp - 144]
    call pax_append_page
    test eax, eax
    jnz .done
    mov rax, [rbp - 112]
    shl rax, 4
    add rax, [rbp - 80]
    mov [rax + PAX_DIRECTORY], rdx
    mov rdx, [rbp - 112]
    inc rdx
    imul rdx, [rbp - 32]
    cmp rdx, [rbp - 40]
    jbe .end_ready
    mov rdx, [rbp - 40]
.end_ready:
    mov [rax + PAX_DIRECTORY + 8], rdx
    mov rax, [rbp - 144]
    sub [rbp - 96], rax
    mov r11, [rbp - 16]
    mov ecx, [r11 + CAT_COUNT]
    imul rax, rcx
    cmp qword [rbp - 128], 0
    je .nulls_ready
    add [rbp - 128], rax
.nulls_ready:
    shl rax, 3
    cmp qword [rbp - 120], 0
    je .lengths_ready
    add [rbp - 120], rax
.lengths_ready:
    add [rbp - 136], rax
    mov qword [rbp - 104], 0
    inc qword [rbp - 112]
    cmp qword [rbp - 96], 0
    jne .leaf
    mov ARG1, [rbp - 80]
    mov ARG2, PAX_CRC
    call crc32c
    mov r10, [rbp - 80]
    mov [r10 + PAX_CRC], eax
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    mov ARG3, [rbp - 24]
    mov ARG4, [rbp - 48]
    mov rax, [rbp - 32]
    PASS_ARG5 rax
    call db_zone_update
    test eax, eax
    jnz .done
    mov ARG4, rdx
    mov r11, [rbp - 16]
    mov ARG2, [r11 + CAT_OWNER]
    mov ARG1, [rbp - 8]
    mov ARG3, [rbp - 72]
    call db_catalog_set_data_stats
    jmp .done
.full:
    mov eax, CybouDB_E_FULL
.done:
    FRAME_END
    ret

; schema_has_varlen(schema) -> 1/0
schema_has_varlen:
    xor edx, edx
.column:
    cmp edx, [ARG1 + CAT_COUNT]
    jae .no
    mov eax, edx
    shl rax, 5
    mov eax, [ARG1 + CAT_COLUMNS + rax]
    cmp eax, CAT_TEXT
    je .yes
    cmp eax, CAT_BLOB
    je .yes
    cmp eax, CAT_VECTOR
    je .yes
    inc edx
    jmp .column
.yes:
    mov eax, 1
    ret
.no:
    xor eax, eax
    ret

; eax=validated type -> eax=width. No floating-point interpretation is needed.
type_width:
    cmp eax, CAT_TEXT
    je .sixteen
    cmp eax, CAT_BLOB
    je .sixteen
    cmp eax, CAT_VECTOR
    je .sixteen
    cmp eax, CAT_INT64
    je .eight
    cmp eax, CAT_BOOL
    je .one
    mov eax, 4
    ret
.eight:
    mov eax, 8
    ret
.one:
    mov eax, 1
    ret
.sixteen:
    mov eax, VAR_CELL_SIZE
    ret

; Bytes of a leaf that hold column data: everything after the header and the
; column directory, and before the trailing CRC.
;
;   pax_body(ARG1 = schema, ARG2 = run pages) -> RAX
;
; With one page this is the historical PAX_CRC - PAX_DIRECTORY - 16*columns.
; A longer run adds whole pages to the same body; the header, the directory
; and the CRC are paid once for the run, not once per page.
pax_body:
    mov r10, ARG1
    mov eax, [r10 + CAT_COUNT]
    shl rax, 4                      ; 16 bytes of directory per column
    mov rdx, ARG2
    shl rdx, CybouDB_PAGE_SHIFT
    sub rdx, CybouDB_PAGE_SIZE - PAX_CRC   ; the CRC sits at the end of the run
    sub rdx, PAX_DIRECTORY
    sub rdx, rax
    mov rax, rdx
    ret

; pax_crc_offset(ARG1 = run pages) -> RAX: where a leaf keeps its checksum.
; The CRC covers the whole run and sits in its last four bytes, so a one-page
; leaf keeps the historical PAX_CRC.
pax_crc_offset:
    mov rax, ARG1
    shl rax, CybouDB_PAGE_SHIFT
    sub rax, CybouDB_PAGE_SIZE - PAX_CRC
    ret

; pax_seal_leaf(ARG1 = leaf address, ARG2 = run pages)
pax_seal_leaf:
    FRAME_BEGIN 16, 0
    mov [rbp - 8], ARG1
    mov ARG1, ARG2
    call pax_crc_offset
    mov [rbp - 16], rax
    mov ARG1, [rbp - 8]
    mov ARG2, rax
    call crc32c
    mov r10, [rbp - 8]
    add r10, [rbp - 16]
    mov [r10], eax
    FRAME_END
    ret

; Pages in one leaf, for a validated schema.
;
;   pax_run_pages(ARG1 = schema, ARG2 = runs) -> RAX
;
; Without the feature a leaf is one page, which is what every database written
; before it contains.
;
; With it, the run is the smallest power of two that gets the leaf to
; PAX_RUN_TARGET rows. A 4 KiB page cannot hold 64 rows of a wide schema at
; all - 64 rows of 32 INT32 columns need 8448 bytes - so such a table would
; otherwise deliver quarter-full batches and fault a whole page for every 24
; rows it wanted. Deriving the run from the schema rather than storing it
; keeps it out of the format: it is recomputed wherever capacity is, and a
; narrow table never pays a wide table's run length.
;
; Local slots: [rbp-8]=schema, [rbp-16]=candidate pages
pax_run_pages:
    FRAME_BEGIN 32, 0
    mov qword [rbp - 16], 1
    test ARG2, ARG2
    jz .run_done
    mov [rbp - 8], ARG1
.run_try:
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    call pax_capacity_for
    cmp rax, PAX_RUN_TARGET
    jae .run_done
    cmp qword [rbp - 16], PAX_RUN_MAX
    jae .run_done
    shl qword [rbp - 16], 1
    jmp .run_try
.run_done:
    mov rax, [rbp - 16]
    FRAME_END
    ret

; Row capacity of one leaf for a validated schema.
;
;   pax_capacity(ARG1 = schema, ARG2 = runs) -> RAX
;
; Each column stores its groups' NULL masks back to back and then its values
; back to back, so a column's values stay contiguous across the whole leaf.
; Tying capacity to one group would waste most of a leaf on a narrow table -
; 64 INT32 values are 256 of 4096 bytes - while the group is what a predicate
; bitmap wants to cover, so the two are separated: the group stays 64 rows,
; the leaf holds as many of them as fit.
;
; A leaf therefore holds a whole number of groups whenever even one fits, and
; that stays true of a run: every schema that reaches 64 rows at all reaches a
; multiple of 64. Only a schema too wide for one full group in the whole run
; falls back to a partial group.
pax_capacity:
    FRAME_BEGIN 16, 0
    mov [rbp - 8], ARG1
    call pax_run_pages
    mov ARG1, [rbp - 8]
    mov ARG2, rax
    call pax_capacity_for
    FRAME_END
    ret

; Row capacity of a leaf of a given run length.
;
;   pax_capacity_for(ARG1 = schema, ARG2 = run pages) -> RAX
;
; Split out because pax_run_pages has to ask the question for a run length it
; is still choosing, which is exactly this without the choosing.
;
; Local slots: [rbp-8]=schema, [rbp-16]=columns, [rbp-24]=body bytes,
;              [rbp-32]=bytes per group, [rbp-40]=index, [rbp-48]=candidate
pax_capacity_for:
    FRAME_BEGIN 64, 0
    mov [rbp - 8], ARG1
    call pax_body
    mov [rbp - 24], rax
    mov r10, [rbp - 8]
    mov eax, [r10 + CAT_COUNT]
    mov [rbp - 16], rax
    mov qword [rbp - 32], 0
    mov qword [rbp - 40], 0
.group_column:
    mov r10, [rbp - 40]
    shl r10, 5
    add r10, [rbp - 8]
    mov eax, [r10 + CAT_COLUMNS]
    call type_width
    imul rax, PAX_GROUP_ROWS
    add rax, 8                      ; one 64-bit NULL mask per group
    add [rbp - 32], rax
    inc qword [rbp - 40]
    mov rax, [rbp - 40]
    cmp rax, [rbp - 16]
    jb .group_column
    mov rax, [rbp - 24]
    xor edx, edx
    div qword [rbp - 32]
    test rax, rax
    jz .partial_group
    shl rax, 6                      ; whole groups: no padding can appear
    FRAME_END
    ret
.partial_group:
    mov qword [rbp - 48], PAX_GROUP_ROWS - 1
.candidate:
    mov qword [rbp - 32], 0
    mov qword [rbp - 40], 0
.column:
    mov r10, [rbp - 40]
    shl r10, 5
    add r10, [rbp - 8]
    mov eax, [r10 + CAT_COLUMNS]
    call type_width
    imul rax, [rbp - 48]
    add rax, 7
    and rax, -8
    add rax, 8
    add [rbp - 32], rax
    inc qword [rbp - 40]
    mov rax, [rbp - 40]
    cmp rax, [rbp - 16]
    jb .column
    mov rax, [rbp - 32]
    cmp rax, [rbp - 24]
    jbe .found
    dec qword [rbp - 48]
    jnz .candidate
.found:
    mov rax, [rbp - 48]
    FRAME_END
    ret

; Initialize a zeroed allocation: pax_init(page, ctx, schema).
pax_init:
    FRAME_BEGIN 64, 0
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
    mov [rbp - 24], ARG3
    PAX_CAPACITY_OF [rbp - 24], [rbp - 16]
    mov [rbp - 32], rax
    mov r10, [rbp - 8]
    mov [r10 + PAX_CAPACITY], eax
    add rax, PAX_GROUP_ROWS - 1
    shr rax, 6
    shl rax, 3
    mov [rbp - 56], rax             ; NULL-mask bytes ahead of every column
    mov dword [r10], PAX_MAGIC_VALUE
    mov dword [r10 + 4], PAX_VERSION_VALUE
    mov r11, [rbp - 24]
    mov rax, [r11 + CAT_OWNER]
    mov [r10 + PAX_OWNER], rax
    mov eax, [r11 + CAT_COUNT]
    mov [r10 + PAX_COLUMNS], eax
    shl rax, 4
    add rax, PAX_DIRECTORY
    mov [rbp - 40], rax
    mov qword [rbp - 48], 0
.column:
    mov r10, [rbp - 48]
    shl r10, 5
    add r10, [rbp - 24]
    mov r11, [rbp - 48]
    shl r11, 4
    add r11, [rbp - 8]
    add r11, PAX_DIRECTORY
    mov eax, [r10 + CAT_COLUMNS]
    mov [r11], eax
    mov edx, [r10 + CAT_COLUMNS + 4]
    and edx, 0x00FF
    mov [r11 + 4], edx
    mov rdx, [rbp - 40]
    mov [r11 + 8], edx
    add rdx, [rbp - 56]
    mov [r11 + 12], edx
    call type_width
    imul rax, [rbp - 32]
    add rax, 7
    and rax, -8
    add rax, [rbp - 56]
    add [rbp - 40], rax
    inc qword [rbp - 48]
    mov r11, [rbp - 24]
    mov eax, [r11 + CAT_COUNT]
    cmp [rbp - 48], rax
    jb .column
    FRAME_END
    ret

; Validate data against a candidate allocation map and schema. Return pointer
; or zero. All offsets are checked against the computed layout before use.
; page_valid(ctx, candidate_sb, schema, id)
page_valid:
    FRAME_BEGIN 160, 1
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
    mov [rbp - 24], ARG3
    mov [rbp - 32], ARG4
    ; A leaf may span several pages, and every one of them has to belong to
    ; this candidate: a run whose tail is metadata, free, or owned by someone
    ; else is exactly the aliasing this check exists to reject.
    PAX_RUN_OF [rbp - 24], [rbp - 8]
    mov [rbp - 144], rax
    mov qword [rbp - 152], 0
.run_page:
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    mov ARG3, [rbp - 32]
    add ARG3, [rbp - 152]
    call db_bitmap_candidate_payload
    test eax, eax
    jz .bad
    inc qword [rbp - 152]
    mov rax, [rbp - 152]
    cmp rax, [rbp - 144]
    jb .run_page
    mov r10, [rbp - 8]
    mov r11, [rbp - 16]
    mov r8, [rbp - 32]
    shl r8, CybouDB_PAGE_SHIFT
    add r8, [r10 + DB_BASE]
    mov [rbp - 40], r8
    cmp dword [r8], PAX_MAGIC_VALUE
    jne .bad
    cmp dword [r8 + 4], PAX_VERSION_VALUE
    jne .bad
    mov rax, [rbp - 32]
    cmp [r8 + PAX_PAGE_ID], rax
    jne .bad
    mov rax, [r8 + PAX_GENERATION]
    test rax, rax
    jz .bad
    cmp rax, [r11 + SB_GENERATION]
    ja .bad
    mov r10, [rbp - 24]
    mov rax, [r10 + CAT_OWNER]
    cmp [r8 + PAX_OWNER], rax
    jne .bad
    mov eax, [r10 + CAT_COUNT]
    cmp [r8 + PAX_COLUMNS], eax
    jne .bad
    cmp dword [r8 + 44], 0
    jne .bad
    mov rax, [r8 + 48]
    or rax, [r8 + 56]
    jnz .bad
    mov ARG3, [r8 + PAX_GENERATION]
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    call db_bitmap_deep
    mov [rbp - 136], rax
    test eax, eax
    jz .layout
    mov ARG1, [rbp - 144]
    call pax_crc_offset
    mov [rbp - 152], rax
    mov ARG1, [rbp - 40]
    mov ARG2, rax
    call crc32c
    mov r10, [rbp - 40]
    add r10, [rbp - 152]
    cmp [r10], eax
    jne .bad
.layout:
    PAX_CAPACITY_OF [rbp - 24], [rbp - 8]
    mov [rbp - 48], rax
    mov r10, [rbp - 40]
    cmp [r10 + PAX_CAPACITY], eax
    jne .bad
    mov ecx, [r10 + PAX_ROWS]
    test ecx, ecx
    jz .bad
    cmp rcx, rax
    ja .bad
    mov [rbp - 56], rcx
    mov rax, [rbp - 48]
    add rax, PAX_GROUP_ROWS - 1
    shr rax, 6
    mov [rbp - 104], rax            ; 64-row groups stored on this page
    mov eax, [r10 + PAX_COLUMNS]
    shl rax, 4
    add rax, PAX_DIRECTORY
    mov [rbp - 72], rax
    mov qword [rbp - 64], 0
.column:
    mov r10, [rbp - 64]
    shl r10, 4
    add r10, [rbp - 40]
    add r10, PAX_DIRECTORY
    mov r11, [rbp - 64]
    shl r11, 5
    add r11, [rbp - 24]
    mov eax, [r11 + CAT_COLUMNS]
    cmp [r10], eax
    jne .bad
    mov edx, [r11 + CAT_COLUMNS + 4]
    and edx, 0x00FF
    mov ecx, [r10 + 4]
    test ecx, 0xFFFF0000
    jnz .bad
    mov eax, ecx
    and eax, 0x00FF
    cmp eax, edx
    jne .bad
    shr ecx, 8
    and ecx, 0xFF                   ; ecx = codec
    mov r8, [rbp - 8]               ; ctx
    test qword [r8 + DB_FEATURES], CybouDB_FEATURE_COMPRESSION
    jnz .codec_with_feat
    test ecx, ecx
    jnz .bad
    jmp .codec_checked
.codec_with_feat:
    cmp ecx, PAX_CODEC_FOR
    ja .bad
.codec_checked:
    mov [rbp - 120], rdx
    mov eax, [r10]
    call type_width
    mov [rbp - 80], rax
    mov rax, [rbp - 72]
    cmp [r10 + 8], eax
    jne .bad
    mov rdx, rax
    add rdx, [rbp - 40]
    mov [rbp - 112], rdx            ; the column's run of NULL masks
    mov rdx, [rbp - 104]
    shl rdx, 3
    add rax, rdx
    cmp [r10 + 12], eax
    jne .bad
    add rax, [rbp - 40]
    mov [rbp - 88], rax

    ; Varlen columns always use raw 16-byte persistent descriptors. Even for
    ; an older (shallow-checked) PAX leaf, walk each live chain so every extent
    ; is proven to belong to the candidate allocation graph.
    mov r11, [rbp - 64]
    shl r11, 5
    add r11, [rbp - 24]
    mov eax, [r11 + CAT_COLUMNS]
    cmp eax, CAT_TEXT
    je .varlen_dispatch
    cmp eax, CAT_BLOB
    je .varlen_dispatch
    cmp eax, CAT_VECTOR
    je .varlen_dispatch
    cmp qword [rbp - 136], 0
    je .shallow_column
.deep_masks:
    ; Every mask bit above the last stored row of its group must be zero.
    mov qword [rbp - 128], 0
.group:
    mov rax, [rbp - 128]
    shl rax, 3
    add rax, [rbp - 112]
    mov rax, [rax]
    mov rcx, [rbp - 128]
    shl rcx, 6
    mov rdx, [rbp - 56]
    sub rdx, rcx
    jbe .group_checked              ; the group lies entirely past the rows
    cmp rdx, PAX_GROUP_ROWS
    jae .group_full
    mov ecx, edx
    shr rax, cl
    jmp .group_checked
.group_full:
    xor eax, eax
.group_checked:
    test rax, rax
    jnz .bad
    inc qword [rbp - 128]
    mov rax, [rbp - 128]
    cmp rax, [rbp - 104]
    jb .group

    mov r11, [rbp - 64]
    shl r11, 5
    add r11, [rbp - 24]
    mov eax, [r11 + CAT_COLUMNS]
    cmp eax, CAT_TEXT
    je .varlen_values
    cmp eax, CAT_BLOB
    je .varlen_values
    cmp eax, CAT_VECTOR
    je .varlen_values

    mov r10, [rbp - 64]
    shl r10, 4
    add r10, [rbp - 40]
    add r10, PAX_DIRECTORY
    mov ecx, [r10 + 4]
    shr ecx, 8
    and ecx, 0xFF                   ; ecx = codec
    test ecx, ecx
    jz .raw_values

    ; Check compressed values:
    cmp ecx, PAX_CODEC_CONST
    je .valid_const
    cmp ecx, PAX_CODEC_FOR
    je .valid_for
    jmp .bad

.valid_const:
    mov rax, [rbp - 88]             ; values_ptr
    cmp qword [rbp - 80], 1         ; BOOL?
    jne .const_slot_pad
    cmp qword [rax], 1
    jbe .const_slot_pad
    jmp .bad
.const_slot_pad:
    mov rax, [rbp - 48]
    imul rax, [rbp - 80]
    add rax, 7
    and rax, -8
    mov rdx, [rbp - 88]
    add rdx, 8
    add rax, [rbp - 88]             ; slot end
.const_zero_check:
    cmp rdx, rax
    jae .column_done
    cmp byte [rdx], 0
    je .czc_ok
    jmp .bad
.czc_ok:
    inc rdx
    jmp .const_zero_check

.valid_for:
    mov rax, [rbp - 88]             ; in_stream
    movzx ecx, byte [rax + 8]       ; B (bit_width)
    test ecx, ecx
    jnz .vf_b_ok
    jmp .bad
.vf_b_ok:
    cmp qword [rbp - 80], 1         ; BOOL?
    jne .for_check_i32
    cmp ecx, 1
    je .for_header_pad
    jmp .bad
.for_check_i32:
    cmp qword [rbp - 80], 4         ; INT32?
    jne .for_check_i64
    cmp ecx, 32
    jb .for_header_pad
    jmp .bad
.for_check_i64:
    cmp ecx, 64
    jbe .for_header_pad
    jmp .bad
.for_header_pad:
    cmp dword [rax + 9], 0
    je .fhp_9_ok
    jmp .bad
.fhp_9_ok:
    cmp word [rax + 13], 0
    je .fhp_13_ok
    jmp .bad
.fhp_13_ok:
    cmp byte [rax + 15], 0
    je .fhp_15_ok
    jmp .bad
.fhp_15_ok:
    mov rax, [rbp - 56]             ; rows
    imul rax, rcx                   ; rows * B
    add rax, 7
    shr rax, 3
    add rax, 16
    add rax, 7
    and rax, -8                     ; aligned compressed bytes
    mov rdx, [rbp - 48]
    imul rdx, [rbp - 80]
    add rdx, 7
    and rdx, -8
    cmp rax, rdx
    jbe .csz_ok
    jmp .bad
.csz_ok:
    mov r8, [rbp - 88]
    add r8, rax
    add rdx, [rbp - 88]
.for_zero_check:
    cmp r8, rdx
    jae .column_done
    cmp byte [r8], 0
    je .fzc_ok
    jmp .bad
.fzc_ok:
    inc r8
    jmp .for_zero_check

.raw_values:
    mov qword [rbp - 96], 0
.value:
    mov rax, [rbp - 96]
    imul rax, [rbp - 80]
    add rax, [rbp - 88]
    cmp qword [rbp - 80], 8
    je .read8
    cmp qword [rbp - 80], 1
    je .read1
    mov edx, [rax]
    jmp .read_done
.read8:
    mov rdx, [rax]
    jmp .read_done
.read1:
    movzx edx, byte [rax]
.read_done:
    mov rax, [rbp - 112]
    mov rcx, [rbp - 96]
    cmp rcx, [rbp - 56]
    jae .unused
    bt qword [rax], rcx             ; the memory form spans the whole run
    jc .null
    cmp qword [rbp - 80], 1
    jne .next_value
    cmp rdx, 1
    ja .bad
    jmp .next_value
.null:
    cmp qword [rbp - 120], CAT_NULLABLE
    jne .bad
    test rdx, rdx
    jnz .bad
    jmp .next_value
.unused:
    test rdx, rdx                   ; the group scan already cleared the mask
    jnz .bad
.next_value:
    inc qword [rbp - 96]
    mov rax, [rbp - 96]
    cmp rax, [rbp - 48]
    jb .value
    imul rax, [rbp - 80]
    mov rdx, rax
    add rdx, 7
    and rdx, -8
    add rdx, [rbp - 88]
    add rax, [rbp - 88]
.padding:
    cmp rax, rdx
    jae .column_done
    cmp byte [rax], 0
    jne .bad
    inc rax
    jmp .padding

.varlen_dispatch:
    cmp qword [rbp - 136], 0
    je .varlen_values
    jmp .deep_masks

.varlen_values:
    mov r10, [rbp - 64]
    shl r10, 4
    add r10, [rbp - 40]
    add r10, PAX_DIRECTORY
    test dword [r10 + 4], PAX_COL_CODEC_MASK
    jnz .bad
    mov qword [rbp - 96], 0
.varlen_value:
    mov rax, [rbp - 96]
    shl rax, 4
    add rax, [rbp - 88]
    mov r10, [rbp - 96]
    cmp r10, [rbp - 56]
    jae .varlen_zero
    mov r11, [rbp - 112]
    bt qword [r11], r10
    jc .varlen_null
    mov r11, [rbp - 64]
    shl r11, 5
    add r11, [rbp - 24]
    cmp dword [r11 + CAT_COLUMNS], CAT_VECTOR
    jne .varlen_chain
    mov edx, [r11 + CAT_COLUMNS + 4]
    shr edx, 16
    shl edx, 2
    cmp [rax + VAR_CELL_LENGTH], rdx
    jne .bad
.varlen_chain:
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    mov ARG3, [rax + VAR_CELL_ROOT]
    mov ARG4, [rax + VAR_CELL_LENGTH]
    mov r11, [rbp - 24]
    mov r10, [r11 + CAT_OWNER]
    PASS_ARG5 r10
    call db_var_validate_chain
    test eax, eax
    jz .bad
    jmp .varlen_next
.varlen_null:
    mov r11, [rbp - 64]
    shl r11, 5
    add r11, [rbp - 24]
    cmp qword [rbp - 136], 0
    jz .varlen_null_shallow
    test dword [r11 + CAT_COLUMNS + 4], CAT_NULLABLE
    jz .bad
    mov rdx, [rax + VAR_CELL_ROOT]
    or rdx, [rax + VAR_CELL_LENGTH]
    jnz .bad
    jmp .varlen_next
.varlen_null_shallow:
    cmp dword [r11 + CAT_COLUMNS], CAT_VECTOR
    jne .varlen_next
    mov rdx, [rax + VAR_CELL_ROOT]
    or rdx, [rax + VAR_CELL_LENGTH]
    jnz .bad
    jmp .varlen_next
.varlen_zero:
    cmp qword [rbp - 136], 0
    je .varlen_next                 ; old leaf contents were checked at publish
    mov rdx, [rax + VAR_CELL_ROOT]
    or rdx, [rax + VAR_CELL_LENGTH]
    jnz .bad
.varlen_next:
    inc qword [rbp - 96]
    mov rax, [rbp - 96]
    cmp rax, [rbp - 48]
    jb .varlen_value
    shl rax, 4
    add rax, [rbp - 88]
    mov rdx, rax
    jmp .column_done
.shallow_column:
    ; An older generation published this page and checked its contents then.
    ; Only the layout arithmetic is needed, to place the next column.
    mov rax, [rbp - 48]
    imul rax, [rbp - 80]
    add rax, 7
    and rax, -8
    add rax, [rbp - 88]
    mov rdx, rax
.column_done:
    sub rdx, [rbp - 40]
    mov [rbp - 72], rdx
    inc qword [rbp - 64]
    mov r10, [rbp - 24]
    mov eax, [r10 + CAT_COUNT]
    cmp [rbp - 64], rax
    jb .column
    mov r10, [rbp - 40]
    cmp qword [rbp - 136], 0
    je .valid
    mov [rbp - 152], rdx
    mov ARG1, [rbp - 144]
    call pax_crc_offset
    mov rcx, rax                    ; the body ends where the CRC begins
    mov rdx, [rbp - 152]
    mov r10, [rbp - 40]
.tail:
    cmp rdx, rcx
    jae .valid
    cmp byte [r10 + rdx], 0
    jne .bad
    inc rdx
    jmp .tail
.valid:
    mov rax, [rbp - 40]
    FRAME_END
    ret
.bad:
    xor eax, eax
    FRAME_END
    ret

; Called during graph validation, after schema and map validation.
db_pax_validate:
    FRAME_BEGIN 16, 0
    mov [rbp - 8], ARG3
    mov r10, ARG1
    test qword [r10 + DB_FEATURES], CybouDB_FEATURE_PAX
    jz .valid
    mov r11, ARG3
    mov ARG4, [r11 + CAT_DATA_ROOT]
    test ARG4, ARG4
    jnz .page
    cmp qword [r11 + CAT_TABLE_ROWS], 0
    jne .bad
    jmp .valid
.page:
    call root_valid
    test rax, rax
    jz .bad
    mov r11, [rbp - 8]
    mov ecx, [rax + PAX_ROWS]
    cmp rcx, [r11 + CAT_TABLE_ROWS]
    jne .bad
    mov rcx, [rax + PAX_GENERATION]
    cmp rcx, [r11 + CAT_GENERATION]
    ja .bad
.valid:
    mov eax, 1
    FRAME_END
    ret
.bad:
    xor eax, eax
    FRAME_END
    ret

; Internal: validate a newly built page against the staged allocation state.
; db_pax_check_new(ctx, schema, page_id) -> pointer or zero
db_pax_check_new:
    FRAME_BEGIN CybouDB_SB_SIZE, 0
    mov r10, ARG1
    mov r11, ARG2
    mov r8, ARG3
    mov rax, [r10 + DB_GENERATION]
    inc rax
    mov [rbp - CybouDB_SB_SIZE + SB_GENERATION], rax
    mov rax, [r10 + DB_ALLOC]
    mov [rbp - CybouDB_SB_SIZE + SB_ALLOC_PAGES], rax
    mov rax, [r10 + DB_BITMAP]
    mov [rbp - CybouDB_SB_SIZE + SB_BITMAP_ROOT], rax
    mov dword [rbp - CybouDB_SB_SIZE + SB_STAGED], 1
    mov ARG4, r8
    mov ARG3, r11
    lea ARG2, [rbp - CybouDB_SB_SIZE]
    call root_valid
    FRAME_END
    ret

; db_pax_insert(ctx, table_id, batch): append a nonempty row-major batch.
; Validate every cell and capacity before touching allocation state.
db_pax_insert:
    FRAME_BEGIN 144, 1
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
    mov [rbp - 24], ARG3
    mov r10, ARG1
    cmp qword [r10 + DB_WRITABLE], 0
    je .readonly
    cmp qword [r10 + DB_MODE], 1
    jne .state
    test qword [r10 + DB_FEATURES], CybouDB_FEATURE_PAX
    jz .state
    cmp qword [r10 + DB_GENERATION], -1
    je .generation
    lea ARG3, [rbp - 32]
    call db_catalog_get
    test eax, eax
    jnz .done
    mov r10, [rbp - 8]
    mov rax, [rbp - 32]
    shl rax, CybouDB_PAGE_SHIFT
    add rax, [r10 + DB_BASE]
    mov [rbp - 40], rax
    mov rcx, [rax + CAT_TABLE_ROWS]
    mov [rbp - 56], rcx
    PAX_CAPACITY_OF [rbp - 40], [rbp - 8]
    mov [rbp - 48], rax
    mov r10, [rbp - 8]
    test qword [r10 + DB_FEATURES], CybouDB_FEATURE_PAX_MULTI
    jz .capacity_ready
    test qword [r10 + DB_FEATURES], CybouDB_FEATURE_PAX_TREE
    jz .one_directory
    imul rax, PAX_TREE_MAX          ; a root of directories, each of leaves
    jmp .capacity_ready
.one_directory:
    imul rax, PAX_DIR_MAX
.capacity_ready:
    sub rax, [rbp - 56]
    mov r10, [rbp - 24]
    mov rcx, [r10 + BATCH_ROWS]
    test rcx, rcx
    jz .rows
    cmp rcx, rax
    ja .rows
    mov [rbp - 64], rcx
    mov rax, [r10 + BATCH_VALUES]
    test rax, rax
    jz .value_error
    mov [rbp - 72], rax
    mov rax, [r10 + BATCH_NULLS]
    mov [rbp - 80], rax
    mov qword [rbp - 104], 0
    mov qword [rbp - 120], 0
.check_row:
    mov qword [rbp - 112], 0
.check_cell:
    mov r10, [rbp - 112]
    shl r10, 5
    add r10, [rbp - 40]
    mov rax, [rbp - 120]
    mov r11, [rbp - 80]
    test r11, r11
    jz .nonnull
    movzx ecx, byte [r11 + rax]
    cmp ecx, 1
    ja .value_error
    test ecx, ecx
    jz .nonnull
    test dword [r10 + CAT_COLUMNS + 4], CAT_NULLABLE
    jz .value_error
    jmp .checked_cell
.nonnull:
    mov r11, [rbp - 72]
    mov rax, [r11 + rax * 8]
    mov ecx, [r10 + CAT_COLUMNS]
    cmp ecx, CAT_TEXT
    je .checked_cell
    cmp ecx, CAT_BLOB
    je .checked_cell
    cmp ecx, CAT_VECTOR
    je .checked_cell
    cmp ecx, CAT_INT64
    je .checked_cell
    cmp ecx, CAT_INT32
    je .int32
    cmp ecx, CAT_BOOL
    je .bool
    shr rax, 32                     ; FLOAT32 input is a zero-extended bit pattern
    jnz .value_error
    jmp .checked_cell
.int32:
    movsxd r11, eax
    cmp rax, r11
    jne .value_error
    jmp .checked_cell
.bool:
    cmp rax, 1
    ja .value_error
.checked_cell:
    inc qword [rbp - 120]
    inc qword [rbp - 112]
    mov r10, [rbp - 40]
    mov eax, [r10 + CAT_COUNT]
    cmp [rbp - 112], rax
    jb .check_cell
    inc qword [rbp - 104]
    mov rax, [rbp - 104]
    cmp rax, [rbp - 64]
    jb .check_row
    mov r10, [rbp - 8]
    test qword [r10 + DB_FEATURES], CybouDB_FEATURE_PAX_MULTI
    jnz .multi
    mov ARG1, r10
    call db_bitmap_headroom
    mov [rbp - 96], rax
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 40]
    mov ARG3, [rbp - 24]
    mov ARG4, [rbp - 48]
    call db_zone_reserve
    add rax, 3                      ; PAX page, schema, directory
    cmp [rbp - 96], rax
    jb .full
    mov r10, [rbp - 8]
    mov r10, [rbp - 8]
    mov r11, [rbp - 40]
    mov ARG3, [r11 + CAT_DATA_ROOT]
    mov ARG1, [rbp - 8]
    mov ARG2, r11
    mov ARG4, [rbp - 24]
    call pax_append_page
    test eax, eax
    jnz .done
    mov [rbp - 88], rdx             ; the data root this insert produced
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 40]
    mov ARG3, [rbp - 24]
    mov ARG4, [rbp - 56]
    mov rax, [rbp - 48]
    PASS_ARG5 rax
    call db_zone_update
    test eax, eax
    jnz .done
    mov ARG4, rdx
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    mov ARG3, [rbp - 88]
    call db_catalog_set_data_stats
    jmp .done
.multi:
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 40]
    mov ARG3, [rbp - 24]
    call pax_multi_insert
    jmp .done
.readonly:
    mov eax, CybouDB_E_READONLY
    jmp .done
.state:
    mov eax, CybouDB_E_STATE
    jmp .done
.generation:
    mov eax, CybouDB_E_GENERATION
    jmp .done
.rows:
    mov eax, CybouDB_E_ROWS
    jmp .done
.value_error:
    mov eax, CybouDB_E_VALUE
    jmp .done
.full:
    mov eax, CybouDB_E_FULL
.done:
    FRAME_END
    ret

; Internal: append validated cells to a single leaf, without publishing it.
; pax_append_page(ctx, schema, old_page_or_zero, batch) -> eax=error, rdx=id.
pax_append_page:
    FRAME_BEGIN 144, 0
    mov [rbp - 8], ARG1
    mov [rbp - 40], ARG2
    mov [rbp - 32], ARG3
    mov [rbp - 24], ARG4
    mov r10, ARG4
    mov rax, [r10 + BATCH_ROWS]
    mov [rbp - 64], rax
    mov rax, [r10 + BATCH_VALUES]
    mov [rbp - 72], rax
    mov rax, [r10 + BATCH_NULLS]
    mov [rbp - 80], rax
    mov qword [rbp - 136], 0
    mov qword [rbp - 144], 0
.append_find_varlen:
    mov rax, [rbp - 144]
    mov r11, [rbp - 40]
    cmp eax, [r11 + CAT_COUNT]
    jae .append_lengths_ready
    mov rcx, rax
    shl rcx, 5
    mov ecx, [r11 + CAT_COLUMNS + rcx]
    cmp ecx, CAT_TEXT
    je .append_load_lengths
    cmp ecx, CAT_BLOB
    je .append_load_lengths
    cmp ecx, CAT_VECTOR
    je .append_load_lengths
    inc qword [rbp - 144]
    jmp .append_find_varlen
.append_load_lengths:
    mov rax, [r10 + BATCH_VAR_LENGTHS]
    mov [rbp - 136], rax
.append_lengths_ready:
    mov qword [rbp - 56], 0
    mov rax, [rbp - 32]
    test rax, rax
    jz .old_ready
    shl rax, CybouDB_PAGE_SHIFT
    mov r10, [rbp - 8]
    add rax, [r10 + DB_BASE]
    mov eax, [rax + PAX_ROWS]
    mov [rbp - 56], rax
.old_ready:
    PAX_RUN_OF [rbp - 40], [rbp - 8]
    mov [rbp - 128], rax                ; pages in this table's leaf
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 32]
    test ARG2, ARG2
    jz .allocate
    mov ARG3, [rbp - 128]
    lea ARG4, [rbp - 88]
    call db_cow_copy_run
    jmp .allocated
.allocate:
    mov ARG2, [rbp - 128]
    lea ARG3, [rbp - 88]
    call db_cow_alloc_run
.allocated:
    test eax, eax
    jnz .done
    mov r10, [rbp - 8]
    mov rax, [rbp - 88]
    shl rax, CybouDB_PAGE_SHIFT
    add rax, [r10 + DB_BASE]
    mov [rbp - 96], rax
    cmp qword [rbp - 56], 0
    jne .initialized
    mov ARG1, rax
    mov ARG2, r10
    mov ARG3, [rbp - 40]
    call pax_init
.initialized:
    cmp qword [rbp - 56], 0
    jz .decomp_ready
    mov ARG1, [rbp - 96]
    mov ARG2, [rbp - 40]
    mov ARG3, [rbp - 56]
    call pax_decompress_leaf_old
.decomp_ready:
    mov r10, [rbp - 96]
    mov rax, [rbp - 88]
    mov [r10 + PAX_PAGE_ID], rax
    mov r11, [rbp - 8]
    mov rax, [r11 + DB_GENERATION]
    inc rax
    mov [r10 + PAX_GENERATION], rax
    mov qword [rbp - 104], 0
    mov qword [rbp - 120], 0
.append_row:
    mov qword [rbp - 112], 0
.append_cell:
    mov r10, [rbp - 112]
    shl r10, 4
    add r10, [rbp - 96]
    add r10, PAX_DIRECTORY
    mov rcx, [rbp - 104]
    add rcx, [rbp - 56]
    mov rax, [rbp - 120]
    mov r11, [rbp - 80]
    test r11, r11
    jz .write_value
    cmp byte [r11 + rax], 0
    je .write_value
    mov edx, [r10 + 8]
    add rdx, [rbp - 96]
    bts qword [rdx], rcx
    jmp .appended_cell              ; NULL payload stays canonical zero
.write_value:
    mov eax, [r10]
    call type_width
    imul rcx, rax
    mov r11d, [r10 + 12]
    add r11, [rbp - 96]
    add r11, rcx
    mov rdx, [rbp - 120]
    mov r10, [rbp - 72]
    mov rdx, [r10 + rdx * 8]
    cmp eax, VAR_CELL_SIZE
    je .write16
    cmp eax, 8
    je .write8
    cmp eax, 1
    je .write1
    mov [r11], edx
    jmp .appended_cell
.write8:
    mov [r11], rdx
    jmp .appended_cell
.write16:
    mov [r11 + VAR_CELL_ROOT], rdx
    mov r10, [rbp - 136]
    mov rdx, [rbp - 120]
    mov rax, [r10 + rdx * 8]
    mov [r11 + VAR_CELL_LENGTH], rax
    jmp .appended_cell
.write1:
    mov [r11], dl
.appended_cell:
    inc qword [rbp - 120]
    inc qword [rbp - 112]
    mov r10, [rbp - 40]
    mov eax, [r10 + CAT_COUNT]
    cmp [rbp - 112], rax
    jb .append_cell
    inc qword [rbp - 104]
    mov rax, [rbp - 104]
    cmp rax, [rbp - 64]
    jb .append_row
    add rax, [rbp - 56]
    mov r10, [rbp - 96]
    mov [r10 + PAX_ROWS], eax
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 40]
    mov ARG3, r10
    call pax_compress_leaf
    mov r10, [rbp - 96]
    mov ARG1, r10
    mov ARG2, [rbp - 128]
    call pax_seal_leaf
    mov rdx, [rbp - 88]
    xor eax, eax
.done:
    FRAME_END
    ret

; db_pax_update_one(ctx, table_id, col_idx, value, is_null, update_group)
; rewrites all predicate spans in one fixed-width leaf with one COW copy.
; Every unsupported shape is rejected before the first allocation. This is the
; deliberately narrow UPDATE-V1 primitive; later versions can copy several
; changed paths while retaining this publication contract.
db_pax_update_one:
    FRAME_BEGIN 336, 1
    mov [rbp - 8], ARG1             ; ctx
    mov [rbp - 16], ARG2            ; table id
    mov [rbp - 24], ARG3            ; column index
    mov [rbp - 32], ARG4            ; normalized value bits
    mov qword [rbp - 296], 0        ; is_tree = 0
    mov rax, IN_ARG5
    mov [rbp - 40], rax             ; is_null
    mov rax, IN_ARG6
    test rax, rax
    jz .upd_rows
    mov rdx, [rax + UPDATE_GROUP_SPANS]
    test rdx, rdx
    jz .upd_rows
    mov [rbp - 232], rdx            ; first span
    mov rcx, [rax + UPDATE_GROUP_COUNT]
    test rcx, rcx
    jz .upd_rows
    mov [rbp - 240], rcx            ; spans in this leaf
    mov qword [rbp - 248], 0
    mov rax, rdx
    mov rdx, [rax + UPDATE_SPAN_START]
    mov [rbp - 184], rdx            ; global first row of this mask
    mov rax, [rax + UPDATE_SPAN_MASK]
    mov [rbp - 48], rax             ; selection mask
    test rax, rax
    jz .upd_success                 ; no matching rows, no publication

    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    lea ARG3, [rbp - 56]
    call db_catalog_get
    test eax, eax
    jnz .upd_done
    mov r10, [rbp - 8]
    mov rax, [rbp - 56]
    shl rax, CybouDB_PAGE_SHIFT
    add rax, [r10 + DB_BASE]
    mov [rbp - 64], rax             ; current schema
    mov ecx, [rax + CAT_COUNT]
    cmp [rbp - 24], rcx
    jae .upd_value
    mov rcx, [rax + CAT_TABLE_ROWS]
    test rcx, rcx
    jz .upd_rows
    cmp [rbp - 184], rcx
    jae .upd_rows
    sub rcx, [rbp - 184]
    cmp rcx, 64
    jbe .upd_lanes_ready
    mov rcx, 64
.upd_lanes_ready:
    mov [rbp - 192], rcx
    mov rax, [rbp - 24]
    shl rax, 5
    add rax, [rbp - 64]
    mov ecx, [rax + CAT_COLUMNS]
    cmp ecx, CAT_TEXT
    je .upd_check_varlen
    cmp ecx, CAT_BLOB
    je .upd_check_varlen
    cmp ecx, CAT_VECTOR
    je .upd_check_vector
    jmp .upd_check_null
.upd_check_vector:
    mov r11, [rbp - 8]
    test qword [r11 + DB_FEATURES], CybouDB_FEATURE_VECTOR
    jz .upd_value
    jmp .upd_check_null
.upd_check_varlen:
    mov r11, [rbp - 8]              ; ctx
    test qword [r11 + DB_FEATURES], CybouDB_FEATURE_VARLEN
    jz .upd_value
.upd_check_null:
    cmp qword [rbp - 40], 0
    je .upd_shape
    test dword [rax + CAT_COLUMNS + 4], CAT_NULLABLE
    jz .upd_value

.upd_shape:
    PAX_CAPACITY_OF [rbp - 64], [rbp - 8]
    mov [rbp - 200], rax            ; rows per leaf
    mov rcx, rax
    mov rax, [rbp - 184]
    xor edx, edx
    div rcx
    mov [rbp - 208], rax            ; logical leaf index
    mov [rbp - 216], rdx            ; first row inside that leaf
    mov rax, [rbp - 200]
    sub rax, rdx
    cmp [rbp - 192], rax
    jbe .upd_span_in_leaf
    mov [rbp - 192], rax
.upd_span_in_leaf:
    mov rcx, [rbp - 192]
    cmp rcx, 64
    je .upd_mask_ok
    mov rax, [rbp - 48]
    shr rax, cl
    test rax, rax
    jnz .upd_rows
.upd_mask_ok:
    ; Validate the whole group before allocating anything. The executor emits
    ; these in scan order, but the storage boundary independently guarantees
    ; that every mask belongs to this leaf and addresses real rows.
    mov qword [rbp - 248], 1
.upd_group_preflight:
    mov rax, [rbp - 248]
    cmp rax, [rbp - 240]
    jae .upd_group_preflight_done
    shl rax, 4
    add rax, [rbp - 232]
    mov r8, [rax + UPDATE_SPAN_START]
    mov r9, [rax + UPDATE_SPAN_MASK]
    test r9, r9
    jz .upd_rows
    mov r10, [rbp - 64]
    cmp r8, [r10 + CAT_TABLE_ROWS]
    jae .upd_rows
    mov rax, r8
    xor edx, edx
    div qword [rbp - 200]
    cmp rax, [rbp - 208]
    jne .upd_rows
    mov rcx, [rbp - 200]
    sub rcx, rdx
    mov rax, [r10 + CAT_TABLE_ROWS]
    sub rax, r8
    cmp rcx, rax
    jbe .upd_group_preflight_leaf_end
    mov rcx, rax
.upd_group_preflight_leaf_end:
    cmp rcx, 64
    jbe .upd_group_preflight_lanes
    mov rcx, 64
.upd_group_preflight_lanes:
    cmp rcx, 64
    je .upd_group_preflight_next
    mov rax, r9
    shr rax, cl
    test rax, rax
    jnz .upd_rows
.upd_group_preflight_next:
    inc qword [rbp - 248]
    jmp .upd_group_preflight
.upd_group_preflight_done:
    mov qword [rbp - 248], 0
    mov r10, [rbp - 64]
    mov rax, [r10 + CAT_DATA_ROOT]
    test rax, rax
    jz .upd_rows
    mov [rbp - 72], rax             ; old data root
    mov r11, [rbp - 8]
    shl rax, CybouDB_PAGE_SHIFT
    add rax, [r11 + DB_BASE]
    mov [rbp - 80], rax             ; old root address
    mov qword [rbp - 88], 0         ; old directory id (zero = direct leaf)
    cmp dword [rax], PAX_DIR_MAGIC
    jne .upd_direct_leaf
    cmp dword [rax + PAX_DIR_LEVEL], PAX_DIR_LEAF
    je .upd_flat_dir
    cmp dword [rax + PAX_DIR_LEVEL], PAX_DIR_ROOT
    jne .upd_rows

    ; --- Tree directory (level 1) ---
    mov qword [rbp - 296], 1        ; is_tree = 1
    mov rdx, [rbp - 72]
    mov [rbp - 88], rdx             ; old root id (non-zero directory)
    mov rax, [rbp - 208]            ; logical leaf index
    xor edx, edx
    mov rcx, PAX_DIR_MAX
    div rcx
    mov [rbp - 272], rax            ; child_dir_idx
    mov [rbp - 280], rdx            ; slot_idx in child dir
    mov r10, [rbp - 80]             ; root addr
    cmp eax, [r10 + PAX_COLUMNS]
    jae .upd_rows
    shl rax, 4
    mov rax, [r10 + PAX_DIRECTORY + rax]
    test rax, rax
    jz .upd_rows
    mov [rbp - 264], rax            ; old child dir id
    mov r11, [rbp - 8]              ; ctx
    shl rax, CybouDB_PAGE_SHIFT
    add rax, [r11 + DB_BASE]
    mov [rbp - 288], rax            ; old child dir addr
    cmp dword [rax], PAX_DIR_MAGIC
    jne .upd_rows
    cmp dword [rax + PAX_DIR_LEVEL], PAX_DIR_LEAF
    jne .upd_rows
    mov rdx, [rbp - 280]            ; slot_idx
    cmp edx, [rax + PAX_COLUMNS]
    jae .upd_rows
    shl rdx, 4
    mov rax, [rax + PAX_DIRECTORY + rdx]
    test rax, rax
    jz .upd_rows
    jmp .upd_leaf_known

.upd_flat_dir:
    mov rdx, [rbp - 208]
    cmp edx, [rax + PAX_COLUMNS]
    jae .upd_rows
    mov rdx, [rbp - 72]
    mov [rbp - 88], rdx
    mov rdx, [rbp - 208]
    shl rdx, 4
    mov rax, [rax + PAX_DIRECTORY + rdx]
    jmp .upd_leaf_known
.upd_direct_leaf:
    cmp qword [rbp - 208], 0
    jne .upd_rows
    mov [rbp - 96], rax             ; old leaf id
.upd_leaf_known:
    mov [rbp - 96], rax             ; old leaf id

    ; Derive the exact row count of this leaf.
    mov r10, [rbp - 64]
    mov rax, [r10 + CAT_TABLE_ROWS]
    mov [rbp - 224], rax
    cmp qword [rbp - 88], 0
    je .upd_leaf_rows_ready
    cmp qword [rbp - 296], 0
    jne .upd_tree_leaf_rows
    mov r10, [rbp - 80]
    mov rax, [rbp - 208]
    mov rcx, rax
    shl rax, 4
    mov rdx, [r10 + PAX_DIRECTORY + rax + 8]
    test rcx, rcx
    jz .upd_first_leaf_rows
    dec rcx
    shl rcx, 4
    sub rdx, [r10 + PAX_DIRECTORY + rcx + 8]
.upd_first_leaf_rows:
    mov [rbp - 224], rdx
    jmp .upd_leaf_rows_ready

.upd_tree_leaf_rows:
    mov r10, [rbp - 288]            ; old child dir addr
    mov rax, [rbp - 280]            ; slot_idx in child dir
    mov rcx, rax
    shl rax, 4
    mov rdx, [r10 + PAX_DIRECTORY + rax + 8]
    test rcx, rcx
    jz .upd_tree_first_leaf_rows
    dec rcx
    shl rcx, 4
    sub rdx, [r10 + PAX_DIRECTORY + rcx + 8]
.upd_tree_first_leaf_rows:
    mov [rbp - 224], rdx
.upd_leaf_rows_ready:

    PAX_RUN_OF [rbp - 64], [rbp - 8]
    mov [rbp - 104], rax
    add rax, 2                      ; replacement schema + catalog root
    cmp qword [rbp - 88], 0
    je .upd_need_ready
    inc rax                         ; copied flat directory (or child dir in tree)
    cmp qword [rbp - 296], 0
    je .upd_need_ready
    inc rax                         ; copied root directory in tree mode
.upd_need_ready:
    mov [rbp - 112], rax
    mov ARG1, [rbp - 8]
    call db_bitmap_headroom
    cmp rax, [rbp - 112]
    jb .upd_full

    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 96]
    mov ARG3, [rbp - 104]
    lea ARG4, [rbp - 120]
    call db_cow_copy_run
    test eax, eax
    jnz .upd_done
    mov r10, [rbp - 8]
    mov rax, [rbp - 120]
    shl rax, CybouDB_PAGE_SHIFT
    add rax, [r10 + DB_BASE]
    mov [rbp - 128], rax            ; writable leaf copy
    mov ARG1, rax
    mov ARG2, [rbp - 64]
    mov ARG3, [rbp - 224]
    call pax_decompress_leaf_old

    mov rax, [rbp - 24]
    shl rax, 4
    add rax, [rbp - 128]
    add rax, PAX_DIRECTORY
    mov [rbp - 136], rax            ; target leaf column descriptor
    mov edx, [rax + 8]
    add rdx, [rbp - 128]
    mov [rbp - 160], rdx            ; complete leaf NULL-mask array
    mov r10, [rbp - 136]
    mov eax, [r10]
    call type_width
    mov [rbp - 144], rax
    mov r10, [rbp - 136]
    mov edx, [r10 + 12]
    add rdx, [rbp - 128]
    mov [rbp - 152], rdx
    mov r11, [rbp - 48]
    xor ecx, ecx
.upd_row:
    bt r11, rcx
    jnc .upd_next_row
    mov rax, [rbp - 216]
    add rax, rcx                    ; absolute row inside the only leaf
    mov rdx, [rbp - 160]
    cmp qword [rbp - 40], 0
    je .upd_clear_row_null
    bts qword [rdx], rax
    jmp .upd_row_null_done
.upd_clear_row_null:
    btr qword [rdx], rax
.upd_row_null_done:
    mov rdx, [rbp - 152]
    mov rax, [rbp - 216]
    add rax, rcx
    imul rax, [rbp - 144]
    add rdx, rax
    cmp qword [rbp - 40], 0
    jne .upd_zero_value
    mov rax, [rbp - 32]
    cmp qword [rbp - 144], 16
    je .upd_store16
    cmp qword [rbp - 144], 8
    je .upd_store8
    cmp qword [rbp - 144], 4
    je .upd_store4
    mov [rdx], al
    jmp .upd_next_row
.upd_store4:
    mov [rdx], eax
    jmp .upd_next_row
.upd_store8:
    mov [rdx], rax
    jmp .upd_next_row
.upd_store16:
    mov r8, [rax]
    mov [rdx], r8
    mov r8, [rax + 8]
    mov [rdx + 8], r8
    jmp .upd_next_row
.upd_zero_value:
    cmp qword [rbp - 144], 16
    je .upd_zero16
    cmp qword [rbp - 144], 8
    je .upd_zero8
    cmp qword [rbp - 144], 4
    je .upd_zero4
    mov byte [rdx], 0
    jmp .upd_next_row
.upd_zero4:
    mov dword [rdx], 0
    jmp .upd_next_row
.upd_zero8:
    mov qword [rdx], 0
    jmp .upd_next_row
.upd_zero16:
    mov qword [rdx], 0
    mov qword [rdx + 8], 0
.upd_next_row:
    inc ecx
    cmp rcx, [rbp - 192]
    jb .upd_row

    inc qword [rbp - 248]
    mov rax, [rbp - 248]
    cmp rax, [rbp - 240]
    jae .upd_group_done
    shl rax, 4
    add rax, [rbp - 232]
    mov rdx, [rax + UPDATE_SPAN_START]
    mov [rbp - 184], rdx
    mov rax, [rax + UPDATE_SPAN_MASK]
    mov [rbp - 48], rax
    test rax, rax
    jz .upd_rows
    mov r10, [rbp - 64]
    mov rcx, [r10 + CAT_TABLE_ROWS]
    cmp [rbp - 184], rcx
    jae .upd_rows
    sub rcx, [rbp - 184]
    cmp rcx, 64
    jbe .upd_group_lanes_ready
    mov rcx, 64
.upd_group_lanes_ready:
    mov [rbp - 192], rcx
    mov rcx, [rbp - 200]
    mov rax, [rbp - 184]
    xor edx, edx
    div rcx
    cmp rax, [rbp - 208]
    jne .upd_rows
    mov [rbp - 216], rdx
    mov rax, [rbp - 200]
    sub rax, rdx
    cmp [rbp - 192], rax
    jbe .upd_group_span_in_leaf
    mov [rbp - 192], rax
.upd_group_span_in_leaf:
    mov rcx, [rbp - 192]
    cmp rcx, 64
    je .upd_group_mask_ok
    mov rax, [rbp - 48]
    shr rax, cl
    test rax, rax
    jnz .upd_rows
.upd_group_mask_ok:
    mov r11, [rbp - 48]
    xor ecx, ecx
    jmp .upd_row
.upd_group_done:

    mov r10, [rbp - 128]
    mov rax, [rbp - 120]
    mov [r10 + PAX_PAGE_ID], rax
    mov r11, [rbp - 8]
    mov rax, [r11 + DB_GENERATION]
    inc rax
    mov [r10 + PAX_GENERATION], rax
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 64]
    mov ARG3, r10
    call pax_compress_leaf
    mov ARG1, [rbp - 128]
    mov ARG2, [rbp - 104]
    call pax_seal_leaf

    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 64]
    mov ARG3, [rbp - 208]
    mov ARG4, [rbp - 128]
    mov rax, [rbp - 24]
    PASS_ARG5 rax
    call db_zone_replace_one
    test eax, eax
    jnz .upd_done
    mov [rbp - 256], rdx            ; exact replacement statistics root

    cmp qword [rbp - 88], 0
    je .upd_publish_leaf
    cmp qword [rbp - 296], 0
    jne .upd_publish_tree

    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 88]
    lea ARG3, [rbp - 160]
    call db_cow_copy_page
    test eax, eax
    jnz .upd_done
    mov r10, [rbp - 8]
    mov rax, [rbp - 160]
    shl rax, CybouDB_PAGE_SHIFT
    add rax, [r10 + DB_BASE]
    mov [rbp - 168], rax
    mov rdx, [rbp - 160]
    mov [rax + PAX_PAGE_ID], rdx
    mov rdx, [r10 + DB_GENERATION]
    inc rdx
    mov [rax + PAX_GENERATION], rdx
    mov rdx, [rbp - 208]
    shl rdx, 4
    add rax, rdx
    mov rdx, [rbp - 120]
    mov [rax + PAX_DIRECTORY], rdx
    mov ARG1, [rbp - 168]
    mov ARG2, PAX_CRC
    call crc32c
    mov r10, [rbp - 168]
    mov [r10 + PAX_CRC], eax
    mov rdx, [rbp - 160]
    mov [rbp - 176], rdx
    jmp .upd_publish

.upd_publish_tree:
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 264]           ; old child dir id
    lea ARG3, [rbp - 160]
    call db_cow_copy_page
    test eax, eax
    jnz .upd_done
    mov r10, [rbp - 8]
    mov rax, [rbp - 160]
    shl rax, CybouDB_PAGE_SHIFT
    add rax, [r10 + DB_BASE]
    mov [rbp - 168], rax            ; new child dir addr
    mov rdx, [rbp - 160]
    mov [rax + PAX_PAGE_ID], rdx
    mov rdx, [r10 + DB_GENERATION]
    inc rdx
    mov [rax + PAX_GENERATION], rdx
    mov rdx, [rbp - 280]            ; slot_idx in child dir
    shl rdx, 4
    add rax, rdx
    mov rdx, [rbp - 120]            ; new leaf id
    mov [rax + PAX_DIRECTORY], rdx
    mov ARG1, [rbp - 168]
    mov ARG2, PAX_CRC
    call crc32c
    mov r10, [rbp - 168]
    mov [r10 + PAX_CRC], eax

    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 72]            ; old root id
    lea ARG3, [rbp - 304]
    call db_cow_copy_page
    test eax, eax
    jnz .upd_done
    mov r10, [rbp - 8]
    mov rax, [rbp - 304]
    shl rax, CybouDB_PAGE_SHIFT
    add rax, [r10 + DB_BASE]
    mov [rbp - 312], rax            ; new root addr
    mov rdx, [rbp - 304]
    mov [rax + PAX_PAGE_ID], rdx
    mov rdx, [r10 + DB_GENERATION]
    inc rdx
    mov [rax + PAX_GENERATION], rdx
    mov rdx, [rbp - 272]            ; child_dir_idx
    shl rdx, 4
    add rax, rdx
    mov rdx, [rbp - 160]            ; new child dir id
    mov [rax + PAX_DIRECTORY], rdx
    mov ARG1, [rbp - 312]
    mov ARG2, PAX_CRC
    call crc32c
    mov r10, [rbp - 312]
    mov [r10 + PAX_CRC], eax
    mov rdx, [rbp - 304]
    mov [rbp - 176], rdx
    jmp .upd_publish

.upd_publish_leaf:
    mov rdx, [rbp - 120]
    mov [rbp - 176], rdx
.upd_publish:
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    mov ARG3, [rbp - 176]
    mov ARG4, [rbp - 256]
    call db_catalog_replace_data_stats
    jmp .upd_done
.upd_success:
    xor eax, eax
    jmp .upd_done
.upd_rows:
    mov eax, CybouDB_E_ROWS
    jmp .upd_done
.upd_value:
    mov eax, CybouDB_E_VALUE
    jmp .upd_done
.upd_full:
    mov eax, CybouDB_E_FULL
.upd_done:
    FRAME_END
    ret

; db_pax_read(ctx, table_id, row_index, output): scalar row materialization.
; Output arrays must be caller-owned, outside the file mapping.
db_pax_read:
    FRAME_BEGIN 80, 2
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG3
    mov [rbp - 24], ARG4
    mov r10, ARG1
    test qword [r10 + DB_FEATURES], CybouDB_FEATURE_PAX
    jz .state
    lea ARG3, [rbp - 32]
    call db_catalog_get
    test eax, eax
    jnz .done
    mov r10, [rbp - 8]
    mov rax, [rbp - 32]
    shl rax, CybouDB_PAGE_SHIFT
    add rax, [r10 + DB_BASE]
    mov rcx, [rbp - 16]
    cmp rcx, [rax + CAT_TABLE_ROWS]
    jae .rows
    mov rax, [rax + CAT_DATA_ROOT]
    shl rax, CybouDB_PAGE_SHIFT
    add rax, [r10 + DB_BASE]
    test qword [r10 + DB_FEATURES], CybouDB_FEATURE_PAX_MULTI
    jz .leaf_ready
    mov r11, rax
    mov rax, [rbp - 16]
    xor edx, edx
    mov ecx, [r11 + PAX_CAPACITY]
    div rcx
    mov [rbp - 16], rdx             ; row inside its leaf
    cmp dword [r11 + PAX_DIR_LEVEL], PAX_DIR_LEAF
    je .leaf_slot
    ; A level above the leaves: the child directory first, then the slot in it.
    xor edx, edx
    mov r9, PAX_DIR_MAX
    div r9
    mov rcx, rdx
    shl rax, 4
    mov rax, [r11 + PAX_DIRECTORY + rax]
    shl rax, CybouDB_PAGE_SHIFT
    add rax, [r10 + DB_BASE]
    mov r11, rax
    mov rax, rcx
.leaf_slot:
    shl rax, 4
    mov rax, [r11 + PAX_DIRECTORY + rax]
    shl rax, CybouDB_PAGE_SHIFT
    add rax, [r10 + DB_BASE]
.leaf_ready:
    mov [rbp - 40], rax
    mov r10, [rbp - 24]
    mov rax, [r10 + ROW_VALUES]
    test rax, rax
    jz .state
    mov [rbp - 48], rax
    mov rax, [r10 + ROW_NULLS]
    test rax, rax
    jz .state
    mov [rbp - 56], rax
    mov qword [rbp - 64], 0
.column:
    mov r10, [rbp - 64]
    shl r10, 4
    add r10, [rbp - 40]
    add r10, PAX_DIRECTORY
    mov r11d, [r10 + 8]
    add r11, [rbp - 40]
    mov rcx, [rbp - 16]
    bt qword [r11], rcx
    setc dl
    mov r11, [rbp - 56]
    mov rax, [rbp - 64]
    mov [r11 + rax], dl
    test dl, dl
    mov edx, 0
    jnz .store

    mov edx, [r10 + 4]
    shr edx, 8
    and edx, 0xFF
    jz .read_raw

    mov rax, [r10]
    PASS_ARG5 rax
    PASS_ARG6 rdx

    mov r11d, [r10 + 12]
    add r11, [rbp - 40]
    mov ARG1, r11
    mov ARG2, [rbp - 16]
    mov ARG3, 1
    lea rax, [rbp - 72]
    mov ARG4, rax
    call decompress_column

    mov r10, [rbp - 64]
    shl r10, 4
    add r10, [rbp - 40]
    add r10, PAX_DIRECTORY
    cmp dword [r10], CAT_INT64
    je .dec_read8
    cmp dword [r10], CAT_BOOL
    je .dec_read1
    mov edx, [rbp - 72]
    cmp dword [r10], CAT_INT32
    jne .store
    movsxd rdx, edx
    jmp .store
.dec_read8:
    mov rdx, [rbp - 72]
    jmp .store
.dec_read1:
    movzx edx, byte [rbp - 72]
    jmp .store

.read_raw:
    mov eax, [r10]
    call type_width
    imul rcx, rax
    mov r11d, [r10 + 12]
    add r11, [rbp - 40]
    add r11, rcx
    cmp eax, 8
    je .read8
    cmp eax, 1
    je .read1
    mov edx, [r11]
    cmp dword [r10], CAT_INT32
    jne .store
    movsxd rdx, edx
    jmp .store
.read8:
    mov rdx, [r11]
    jmp .store
.read1:
    movzx edx, byte [r11]
.store:
    mov r11, [rbp - 48]
    mov rax, [rbp - 64]
    mov [r11 + rax * 8], rdx
    inc qword [rbp - 64]
    mov r10, [rbp - 40]
    mov eax, [r10 + PAX_COLUMNS]
    cmp [rbp - 64], rax
    jb .column
    xor eax, eax
    jmp .done
.state:
    mov eax, CybouDB_E_STATE
    jmp .done
.rows:
    mov eax, CybouDB_E_ROWS
.done:
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  db_pax_scan_open(ctx, table_id, cursor) -> eax = error
;
;  Validates the table's graph once and remembers where its rows are. Reading
;  a table with db_pax_read costs a full catalog/directory/leaf validation per
;  row, so scanning n rows that way is quadratic in the size of the database;
;  a cursor pays that once and then walks leaves directly.
;
;  The snapshot is the graph as it stands at open. Copy-on-write never
;  rewrites a published page, so the rows a cursor sees stay put even while a
;  writer stages an append - the cursor simply does not see it. A commit ends
;  the snapshot: the cursor then refuses to continue and must be reopened.
;
;  Local slots: [rbp-8]=ctx, [rbp-16]=cursor, [rbp-24]=schema page,
;               [rbp-32]=schema address, [rbp-40]=capacity
; -----------------------------------------------------------------------------
;  db_pax_scan_open_bound(ctx, schema_ptr, cursor) -> eax = error
;
;  Initializes a scan cursor directly from a known schema address without
;  revalidating the catalog graph. Used when the caller knows the generation
;  has not changed since the statement was bound.
;
;  Local slots: [rbp-8]=ctx, [rbp-16]=schema_ptr, [rbp-24]=cursor, [rbp-32]=capacity
; -----------------------------------------------------------------------------
db_pax_scan_open_bound:
    FRAME_BEGIN 48, 0
    mov     [rbp - 8], ARG1
    mov     [rbp - 16], ARG2
    mov     [rbp - 24], ARG3
    mov     r10, ARG1
    test    qword [r10 + DB_FEATURES], CybouDB_FEATURE_PAX
    jz      .bound_state
    test    ARG2, ARG2
    jz      .bound_state
    test    ARG3, ARG3
    jz      .bound_state

    PAX_CAPACITY_OF [rbp - 16], [rbp - 8]
    mov     [rbp - 32], rax
    mov     r10, [rbp - 8]
    mov     r11, [rbp - 16]
    mov     r8, [rbp - 24]
    mov     [r8 + SCAN_CTX], r10
    mov     rax, [r11 + CAT_TABLE_ROWS]
    mov     [r8 + SCAN_ROWS], rax
    mov     qword [r8 + SCAN_NEXT], 0
    mov     rax, [rbp - 32]
    mov     [r8 + SCAN_CAPACITY], rax
    mov     eax, [r11 + CAT_COUNT]
    mov     [r8 + SCAN_COLUMNS], rax
    mov     rax, [r10 + DB_GENERATION]
    mov     [r8 + SCAN_GENERATION], rax
    mov     qword [r8 + SCAN_LEAF], 0
    mov     qword [r8 + SCAN_LEAF_INDEX], 0
    PAX_RUN_OF [rbp - 16], [rbp - 8]
    mov     r8, [rbp - 24]
    mov     [r8 + SCAN_RUN_PAGES], rax
    mov     r10, [rbp - 8]
    mov     r11, [rbp - 16]
    mov     rax, [r11 + CAT_DATA_ROOT]
    test    rax, rax
    jz      .bound_root_ready
    shl     rax, CybouDB_PAGE_SHIFT
    add     rax, [r10 + DB_BASE]
.bound_root_ready:
    mov     [r8 + SCAN_ROOT], rax
    xor     eax, eax
    jmp     .bound_done
.bound_state:
    mov     eax, CybouDB_E_STATE
.bound_done:
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  db_pax_scan_open(ctx, table_id, cursor) -> eax = error
;
;  Validates the table's graph once and remembers where its rows are. Reading
;  a table with db_pax_read costs a full catalog/directory/leaf validation per
;  row, so scanning n rows that way is quadratic in the size of the database;
;  a cursor pays that once and then walks leaves directly.
;
;  The snapshot is the graph as it stands at open. Copy-on-write never
;  rewrites a published page, so the rows a cursor sees stay put even while a
;  writer stages an append - the cursor simply does not see it. A commit ends
;  the snapshot: the cursor then refuses to continue and must be reopened.
;
;  Local slots: [rbp-8]=ctx, [rbp-16]=cursor, [rbp-24]=schema page
; -----------------------------------------------------------------------------
db_pax_scan_open:
    FRAME_BEGIN 48, 0
    mov     [rbp - 8], ARG1
    mov     [rbp - 16], ARG3
    mov     r10, ARG1
    test    qword [r10 + DB_FEATURES], CybouDB_FEATURE_PAX
    jz      .state
    test    ARG3, ARG3
    jz      .state
    lea     ARG3, [rbp - 24]
    call    db_catalog_get              ; validates the whole graph, once
    test    eax, eax
    jnz     .done
    mov     r10, [rbp - 8]
    mov     rax, [rbp - 24]
    shl     rax, CybouDB_PAGE_SHIFT
    add     rax, [r10 + DB_BASE]
    mov     ARG2, rax                   ; schema_ptr
    mov     ARG1, r10                   ; ctx
    mov     ARG3, [rbp - 16]            ; cursor
    call    db_pax_scan_open_bound
    jmp     .done
.state:
    mov     eax, CybouDB_E_STATE
.done:
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  db_pax_scan_next(cursor, output) -> eax = error, rdx = rows produced
;
;  Produces the next rows of the snapshot, at most SCAN_MAX of them and never
;  across a leaf boundary; rdx = 0 means the scan is finished. Output is
;  row-major and laid out exactly like the input of db_pax_insert, so a scan
;  result can be fed straight back into an append.
;
;  Columns are copied one at a time, which is what the page layout is for: a
;  column's values are contiguous across the whole page, so the inner loop
;  walks memory forwards, and it is the place a vector kernel will later go.
;
;  Local slots: [rbp-8]=cursor, [rbp-16]=output, [rbp-24]=values,
;               [rbp-32]=NULL bytes, [rbp-40]=maximum rows, [rbp-48]=leaf
;               index, [rbp-56]=row offset in the leaf, [rbp-64]=leaf address,
;               [rbp-72]=rows to produce, [rbp-80]=column, [rbp-88]=width,
;               [rbp-96]=mask run, [rbp-104]=value array, [rbp-112]=row,
;               [rbp-120]=flat cell index, [rbp-128]=columns
; -----------------------------------------------------------------------------
db_pax_scan_next:
    FRAME_BEGIN 160, 2
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
    mov r10, ARG1
    test r10, r10
    jz .state
    test ARG2, ARG2
    jz .state
    mov r11, [r10 + SCAN_CTX]
    test r11, r11
    jz .state
    cmp qword [r11 + DB_BASE], 0
    je .state
    cmp qword [r11 + DB_MODE], -1
    je .state
    mov rax, [r11 + DB_GENERATION]
    cmp rax, [r10 + SCAN_GENERATION]
    jne .state                       ; a commit ended the snapshot
    mov r11, ARG2
    mov rax, [r11 + SCAN_VALUES]
    test rax, rax
    jz .state
    mov [rbp - 24], rax
    mov rax, [r11 + SCAN_NULLS]
    test rax, rax
    jz .state
    mov [rbp - 32], rax
    mov rax, [r11 + SCAN_MAX]
    test rax, rax
    jz .rows
    mov [rbp - 40], rax
    mov rax, [r10 + SCAN_COLUMNS]
    mov [rbp - 128], rax
    mov rax, [r10 + SCAN_NEXT]
    cmp rax, [r10 + SCAN_ROWS]
    jae .end
    xor edx, edx
    div qword [r10 + SCAN_CAPACITY]
    mov [rbp - 48], rax
    mov [rbp - 56], rdx
    mov r8, [r10 + SCAN_LEAF]
    test r8, r8
    jz .load_leaf
    cmp rax, [r10 + SCAN_LEAF_INDEX]
    je .leaf_ready
.load_leaf:
    mov r8, [r10 + SCAN_ROOT]
    mov r11, [r10 + SCAN_CTX]
    test qword [r11 + DB_FEATURES], CybouDB_FEATURE_PAX_MULTI
    jz .leaf_known
    mov rcx, [rbp - 48]
    cmp dword [r8 + PAX_DIR_LEVEL], PAX_DIR_LEAF
    je .leaf_slot
    ; A level above the leaves: the child directory first, then the slot in it.
    mov rax, rcx
    xor edx, edx
    mov r9, PAX_DIR_MAX
    div r9
    mov rcx, rdx
    shl rax, 4
    mov r8, [r8 + PAX_DIRECTORY + rax]
    shl r8, CybouDB_PAGE_SHIFT
    add r8, [r11 + DB_BASE]
.leaf_slot:
    shl rcx, 4
    mov r8, [r8 + PAX_DIRECTORY + rcx]
    shl r8, CybouDB_PAGE_SHIFT
    add r8, [r11 + DB_BASE]
.leaf_known:
    mov [r10 + SCAN_LEAF], r8
    mov rcx, [rbp - 48]
    mov [r10 + SCAN_LEAF_INDEX], rcx
.leaf_ready:
    mov [rbp - 64], r8
    mov eax, [r8 + PAX_ROWS]
    sub rax, [rbp - 56]
    cmp rax, [rbp - 40]
    jbe .count_ready
    mov rax, [rbp - 40]
.count_ready:
    mov [rbp - 72], rax
    mov qword [rbp - 80], 0
.column:
    mov r9, [rbp - 80]
    shl r9, 4
    add r9, [rbp - 64]
    add r9, PAX_DIRECTORY
    mov eax, [r9]
    call type_width
    mov [rbp - 88], rax
    mov r11d, [r9 + 8]
    add r11, [rbp - 64]
    mov [rbp - 96], r11
    mov r11d, [r9 + 12]
    add r11, [rbp - 64]
    mov [rbp - 104], r11
    mov qword [rbp - 112], 0
.row:
    mov rcx, [rbp - 112]
    add rcx, [rbp - 56]
    mov r11, [rbp - 96]
    bt qword [r11], rcx
    setc dl
    mov rax, [rbp - 112]
    imul rax, [rbp - 128]
    add rax, [rbp - 80]
    mov [rbp - 120], rax
    mov r11, [rbp - 32]
    mov [r11 + rax], dl
    test dl, dl
    mov edx, 0
    jnz .store

    mov edx, [r9 + 4]
    shr edx, 8
    and edx, 0xFF
    jz .scan_read_raw

    mov r11d, [r9 + 12]
    add r11, [rbp - 64]
    mov eax, [r9]
    PASS_ARG5 rax
    PASS_ARG6 rdx
    mov ARG1, r11
    mov rax, [rbp - 56]
    add rax, [rbp - 112]
    mov ARG2, rax
    mov ARG3, 1
    lea rax, [rbp - 144]
    mov ARG4, rax
    call decompress_column

    mov rax, [rbp - 80]
    shl rax, 4
    add rax, [rbp - 64]
    lea r9, [rax + PAX_DIRECTORY]
    cmp dword [r9], CAT_INT64
    je .scan_dec_read8
    cmp dword [r9], CAT_BOOL
    je .scan_dec_read1
    mov edx, [rbp - 144]
    cmp dword [r9], CAT_INT32
    jne .store
    movsxd rdx, edx
    jmp .store
.scan_dec_read8:
    mov rdx, [rbp - 144]
    jmp .store
.scan_dec_read1:
    movzx edx, byte [rbp - 144]
    jmp .store

.scan_read_raw:
    mov rax, [rbp - 88]
    imul rcx, rax
    add rcx, [rbp - 104]
    cmp rax, 8
    je .read8
    cmp rax, 1
    je .read1
    mov edx, [rcx]
    cmp dword [r9], CAT_INT32
    jne .store
    movsxd rdx, edx
    jmp .store
.read8:
    mov rdx, [rcx]
    jmp .store
.read1:
    movzx edx, byte [rcx]
.store:
    mov r11, [rbp - 24]
    mov rax, [rbp - 120]
    mov [r11 + rax * 8], rdx
    inc qword [rbp - 112]
    mov rax, [rbp - 112]
    cmp rax, [rbp - 72]
    jb .row
    inc qword [rbp - 80]
    mov rax, [rbp - 80]
    cmp rax, [rbp - 128]
    jb .column
    mov r10, [rbp - 8]
    mov rax, [rbp - 72]
    add [r10 + SCAN_NEXT], rax
    mov rdx, rax
    xor eax, eax
    FRAME_END
    ret
.end:
    xor edx, edx
    xor eax, eax
    FRAME_END
    ret
.state:
    xor edx, edx
    mov eax, CybouDB_E_STATE
    FRAME_END
    ret
.rows:
    xor edx, edx
    mov eax, CybouDB_E_ROWS
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  db_pax_scan_batch(cursor, batch_view, required_cols, decode_storage)
;    -> eax = error, rdx = rows produced
;
;  Produces borrowed typed views (up to 64 rows). RAW views reference mapped
;  storage; encoded views use caller-owned PAX_DECODE_MAX_BYTES storage, which
;  must remain live until the caller consumes the batch. NULL is RAW-only.
;  Only required_cols bits are populated, indexed by physical column number.
;  Unrequested slots are untouched and must not be read. Zero mask advances
;  rows without building views. Out-of-schema bits return CybouDB_E_STATE before
;  cursor advancement. BATCH_VIEW_ROWS is zero on end/error for valid output.
;  Each column view contains: values_ptr, null_mask, type, width.
;
;  Local slots: [rbp-8]=cursor, [rbp-16]=batch_view, [rbp-24]=leaf_index,
;               [rbp-32]=row_in_leaf, [rbp-40]=leaf_addr,
;               [rbp-48]=rows_to_produce, [rbp-56]=col_count,
;               [rbp-64]=col_idx, [rbp-72]=width, [rbp-96]=pending columns
; -----------------------------------------------------------------------------
db_pax_scan_batch:
    FRAME_BEGIN 128, 2
    mov qword [rbp - 120], 0
    jmp pax_scan_batch_body
; Extended internal scanner: ARG5 points to private NULL-only/encoded options.
db_pax_scan_batch_ex:
    FRAME_BEGIN 128, 2
    mov rax, IN_ARG5
    mov [rbp - 120], rax
pax_scan_batch_body:
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
    mov [rbp - 96], ARG3             ; pending required-column bits
    mov rax, ARG4
    mov [rbp - 104], rax
    mov [rbp - 80], rdi
    mov [rbp - 88], rsi
    test ARG2, ARG2
    jz .state
    mov r11, ARG2
    mov qword [r11 + BATCH_VIEW_ROWS], 0
    mov r10, ARG1
    test r10, r10
    jz .state

    mov r11, [r10 + SCAN_CTX]
    test r11, r11
    jz .state
    cmp qword [r11 + DB_BASE], 0
    je .state
    cmp qword [r11 + DB_MODE], -1
    je .state
    mov rax, [r11 + DB_GENERATION]
    cmp rax, [r10 + SCAN_GENERATION]
    jne .state                       ; a commit ended the snapshot

    mov rax, [r10 + SCAN_COLUMNS]
    mov [rbp - 56], rax
    cmp rax, 64
    je .mask_valid
    mov rcx, rax
    mov rax, [rbp - 96]
    shr rax, cl
    test rax, rax
    jnz .state
.mask_valid:
    mov rax, [r10 + SCAN_NEXT]
    cmp rax, [r10 + SCAN_ROWS]
    jae .end

    xor edx, edx
    div qword [r10 + SCAN_CAPACITY]
    mov [rbp - 24], rax              ; leaf_index
    mov [rbp - 32], rdx              ; row_in_leaf
    mov r8, [r10 + SCAN_LEAF]
    test r8, r8
    jz .load_leaf
    cmp rax, [r10 + SCAN_LEAF_INDEX]
    je .leaf_ready

.load_leaf:
    mov r8, [r10 + SCAN_ROOT]
    mov r11, [r10 + SCAN_CTX]
    test qword [r11 + DB_FEATURES], CybouDB_FEATURE_PAX_MULTI
    jz .leaf_known
    mov rcx, [rbp - 24]
    cmp dword [r8 + PAX_DIR_LEVEL], PAX_DIR_LEAF
    je .leaf_slot
    ; A level above the leaves: the child directory first, then the slot in it.
    mov rax, rcx
    xor edx, edx
    mov r9, PAX_DIR_MAX
    div r9
    mov rcx, rdx
    shl rax, 4
    mov r8, [r8 + PAX_DIRECTORY + rax]
    shl r8, CybouDB_PAGE_SHIFT
    add r8, [r11 + DB_BASE]
.leaf_slot:
    shl rcx, 4
    mov r8, [r8 + PAX_DIRECTORY + rcx]
    shl r8, CybouDB_PAGE_SHIFT
    add r8, [r11 + DB_BASE]

.leaf_known:
    mov [r10 + SCAN_LEAF], r8
    mov rcx, [rbp - 24]
    mov [r10 + SCAN_LEAF_INDEX], rcx

.leaf_ready:
    mov [rbp - 40], r8               ; leaf_addr
    mov eax, [r8 + PAX_ROWS]
    sub rax, [rbp - 32]              ; leaf_rows - row_in_leaf
    cmp rax, 64                      ; max batch is 64 rows
    jbe .count_ready
    mov rax, 64

.count_ready:
    mov [rbp - 48], rax              ; rows_to_produce
    mov rdi, [rbp - 16]
    mov [rdi + BATCH_VIEW_ROWS], rax ; record in batch_view

    cmp qword [rbp - 96], 0
    je .advance

.col_loop:
    bsf r9, [rbp - 96]
    btr qword [rbp - 96], r9
    mov [rbp - 64], r9
    shl r9, 4                        ; 16 bytes per col entry in PAX_DIRECTORY
    add r9, [rbp - 40]               ; + leaf_addr
    add r9, PAX_DIRECTORY            ; r9 points to leaf column descriptor

    mov eax, [r9]                    ; col_type
    call type_width
    mov [rbp - 72], rax              ; width

    ; Target colview slot in batch_view
    mov rdi, [rbp - 16]              ; batch_view
    add rdi, BATCH_VIEW_COLUMNS
    mov rax, [rbp - 64]              ; col_idx
    imul rax, CybouDB_COLVIEW_SIZE
    add rdi, rax                     ; rdi points to CybouDB_COLVIEW

    mov eax, [r9]                    ; col_type
    mov [rdi + COLVIEW_TYPE], eax
    mov eax, [rbp - 72]              ; width
    mov [rdi + COLVIEW_WIDTH], eax

    mov r11, [rbp - 120]
    test r11, r11
    jz .typed_column
    mov rcx, [rbp - 64]
    bt [r11 + PAX_SCANOPT_NULL_ONLY], rcx
    jc .null_only_column
    cmp qword [r11 + PAX_SCANOPT_ENCODED], 0
    je .typed_column
    mov rax, rcx
    shl rax, 4
    lea r10, [r11 + PAX_SCANOPT_VIEWS + rax]
    mov [rbp - 128], r10
    mov qword [r10 + PAX_ENC_KIND], 0
    bt [r11 + PAX_SCANOPT_ENCODED], rcx
    jnc .typed_column
    mov edx, [r9 + 4]
    shr edx, 8
    and edx, 0xFF
    cmp edx, PAX_CODEC_CONST
    je .encoded_const
    cmp edx, PAX_CODEC_FOR
    jne .typed_column
    ; FOR codec: check bit_width to pick BOOL, FOR8, or FOR16 fast paths
    mov edx, [r9 + 12]
    add rdx, [rbp - 40]             ; rdx = FOR stream header ptr
    movzx eax, byte [rdx + 8]       ; eax = bit_width
    cmp eax, 1
    je .encoded_for_bool
    cmp eax, 8
    je .check_direct_for8
    cmp eax, 16
    je .check_direct_for16
    jmp .typed_column               ; exact-width FOR > 16: fall through to decode

.check_direct_for8:
    test qword [r11 + PAX_SCANOPT_FLAGS], PAX_SCANOPT_DIRECT_FOR
    jnz .encoded_for8
    jmp .typed_column

.check_direct_for16:
    test qword [r11 + PAX_SCANOPT_FLAGS], PAX_SCANOPT_DIRECT_FOR
    jnz .encoded_for16
    jmp .typed_column

.encoded_for_bool:
    ; BOOL-in-FOR path: base must be 0, bit_width already confirmed 1
    cmp qword [rdx], 0
    jne .typed_column
    ; extract 64-bit truth mask aligned to row_in_leaf
    mov rcx, [rbp - 32]             ; row_in_leaf
    mov rax, rcx
    shr rax, 3                      ; byte_off = row_in_leaf / 8
    and ecx, 7                      ; bit_off  = row_in_leaf & 7
    lea r8, [rdx + 16 + rax]        ; &stream[byte_off]
    mov rax, [r8]                   ; load 64 bits
    jz .packed_bool_ready           ; aligned: done
    movzx r8d, byte [r8 + 8]        ; one extra byte for cross-boundary shift
    shrd rax, r8, cl
    jmp .packed_bool_ready
.packed_bool_ready:
    mov [r10 + PAX_ENC_DATA], rax
    mov qword [r10 + PAX_ENC_KIND], PAX_ENC_KIND_BOOL
    cmp qword [pax_decode_trace], 0
    je .encoded_values_ready
    inc qword [pax_bool_columns]
    jmp .encoded_values_ready

.encoded_for8:
    ; FOR width=8: DATA = pointer to stream header, META encodes first_row
    mov rax, [rbp - 32]             ; first_row_in_leaf
    shl rax, 8
    or  rax, PAX_ENC_KIND_FOR8
    mov [r10 + PAX_ENC_META], rax
    ; rdx still points to stream header (set above)
    mov [r10 + PAX_ENC_DATA], rdx
    cmp qword [pax_decode_trace], 0
    je .encoded_values_ready
    inc qword [pax_for_columns]
    jmp .encoded_values_ready

.encoded_for16:
    ; FOR width=16: DATA = pointer to stream header, META encodes first_row
    mov rax, [rbp - 32]             ; first_row_in_leaf
    shl rax, 8
    or  rax, PAX_ENC_KIND_FOR16
    mov [r10 + PAX_ENC_META], rax
    mov [r10 + PAX_ENC_DATA], rdx
    cmp qword [pax_decode_trace], 0
    je .encoded_values_ready
    inc qword [pax_for_columns]
    jmp .encoded_values_ready

.encoded_const:
    mov edx, [r9 + 12]
    add rdx, [rbp - 40]
    mov rax, [rdx]
    mov [r10 + PAX_ENC_DATA], rax
    mov qword [r10 + PAX_ENC_KIND], PAX_ENC_KIND_CONST
    cmp qword [pax_decode_trace], 0
    je .encoded_values_ready
    inc qword [pax_const_columns]
    jmp .encoded_values_ready
.null_only_column:
    cmp qword [pax_decode_trace], 0
    je .encoded_values_ready
    inc qword [pax_null_columns]
.encoded_values_ready:
    mov qword [rdi + COLVIEW_VALUES_PTR], 0
    jmp .col_values_ready
.typed_column:

    mov edx, [r9 + 4]
    shr edx, 8
    and edx, 0xFF
    jz .col_raw

    mov rsi, [rbp - 104]
    test rsi, rsi
    jz .state
    mov rax, [rbp - 64]
    shl rax, 9
    add rsi, rax

    mov edx, [r9 + 12]
    add rdx, [rbp - 40]
    mov [rbp - 112], rdx
    mov eax, [r9]
    mov edx, [r9 + 4]
    shr edx, 8
    and edx, 0xFF
    PASS_ARG5 rax
    PASS_ARG6 rdx
    mov rdx, [rbp - 112]
    mov ARG4, rsi
    mov ARG1, rdx
    mov ARG2, [rbp - 32]
    mov ARG3, [rbp - 48]
    cmp qword [pax_decode_trace], 0
    je .decode_column
    inc qword [pax_decode_calls]
.decode_column:
    call decompress_column

    mov rdi, [rbp - 16]
    add rdi, BATCH_VIEW_COLUMNS
    mov rax, [rbp - 64]
    imul rax, CybouDB_COLVIEW_SIZE
    add rdi, rax

    mov rax, [rbp - 64]
    shl rax, 9
    add rax, [rbp - 104]
    mov [rdi + COLVIEW_VALUES_PTR], rax

    mov r9, [rbp - 64]
    shl r9, 4
    add r9, [rbp - 40]
    add r9, PAX_DIRECTORY
    jmp .col_values_ready

.col_raw:
    mov edx, [r9 + 12]
    add rdx, [rbp - 40]
    mov rcx, [rbp - 32]
    imul rcx, [rbp - 72]
    add rdx, rcx
    mov [rdi + COLVIEW_VALUES_PTR], rdx

.col_values_ready:

    ; NULL bitmask: check if column is nullable
    mov eax, [r9 + 4]                ; flags
    test eax, CAT_NULLABLE
    jz .col_not_nullable

    ; Column is nullable. Read NULL bitmap from leaf.
    mov edx, [r9 + 8]                ; null_offset
    add rdx, [rbp - 40]              ; rdx = pointer to null bitmap
    mov rcx, [rbp - 32]              ; row_in_leaf
    mov r8, rcx
    shr r8, 6                        ; group = row_in_leaf / 64
    shl r8, 3                        ; byte offset = group * 8
    add rdx, r8                      ; rdx points to 64-bit word of group
    and ecx, 63                      ; bit_offset = row_in_leaf & 63

    mov rax, [rdx]                   ; low 64 bits
    test ecx, ecx
    jz .null_aligned

    mov r8, [rbp - 48]              ; rows_to_produce
    add r8, rcx
    cmp r8, 64
    jbe .null_shift_only
    mov r8, [rdx + 8]
    shrd rax, r8, cl
    jmp .null_aligned

.null_shift_only:
    shr rax, cl

.null_aligned:
    ; Mask to rows_to_produce bits
    mov rcx, [rbp - 48]              ; rows_to_produce
    cmp rcx, 64
    jae .store_null_mask
    mov r8, 1
    shl r8, cl
    dec r8
    and rax, r8
    jmp .store_null_mask

.col_not_nullable:
    xor eax, eax                     ; null_mask = 0 (no nulls)

.store_null_mask:
    mov [rdi + COLVIEW_NULL_MASK], rax

    cmp qword [rbp - 96], 0
    jne .col_loop

.advance:
    ; Advance cursor
    mov r10, [rbp - 8]
    mov rax, [rbp - 48]
    add [r10 + SCAN_NEXT], rax
    mov rdx, rax                     ; rows produced
    xor eax, eax                     ; success
    mov rdi, [rbp - 80]
    mov rsi, [rbp - 88]
    FRAME_END
    ret

.end:
    xor edx, edx
    xor eax, eax
    mov rdi, [rbp - 80]
    mov rsi, [rbp - 88]
    FRAME_END
    ret

.state:
    xor edx, edx
    mov eax, CybouDB_E_STATE
    mov rdi, [rbp - 80]
    mov rsi, [rbp - 88]
    FRAME_END
    ret
