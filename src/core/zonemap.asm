; Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
; SPDX-License-Identifier: Apache-2.0
; Per-leaf zone metadata: min/max and NULL statistics for every PAX leaf, kept
; in a side structure so the leaf format itself is untouched. See
; docs/ZONEMAP.md for the contract and include/zonemap.inc for the layout.
;
; The statistics are written by the insert that produces the rows, from the
; same batch, and published by the same COW transaction: the caller hands the
; new root to db_catalog_set_data_stats along with the data root, so statistics
; can never be a generation ahead of or behind the data they describe.
%include "cyboudb.inc"
BITS 64
default rel
extern crc32c
extern db_cow_alloc_page, db_cow_copy_page
extern db_bitmap_headroom
extern db_bitmap_candidate_payload, db_bitmap_deep, db_pax_capacity
extern decompress_column
global db_zone_validate
global db_zone_check_leaf
global db_zone_update, db_zone_lookup, db_zone_stride, db_zone_slots
global db_zone_reserve
global db_zone_replace_one

; The working state of one update, built on the caller's frame and passed to
; the helpers by address. An update touches a range of pages and at most one
; directory at a time, so what has to be carried between the helpers is small.
%define ZU_CTX 0
%define ZU_SCHEMA 8
%define ZU_BATCH 16
%define ZU_ROWS_BEFORE 24
%define ZU_CAPACITY 32
%define ZU_STRIDE 40
%define ZU_SLOTS 48
%define ZU_FIRST_LEAF 56
%define ZU_LAST_LEAF 64
%define ZU_FIRST_PAGE 72
%define ZU_LAST_PAGE 80
%define ZU_OLD_ROOT 88
%define ZU_OLD_LEVEL 96
%define ZU_NEW_ROOT 104
%define ZU_NEW_LEVEL 112
%define ZU_ROOT_ADDR 120
%define ZU_DIR_INDEX 128
%define ZU_DIR_ADDR 136
%define ZU_PAGE_INDEX 144
%define ZU_PAGE_ADDR 152
%define ZU_LEAF_INDEX 160
%define ZU_BATCH_ROWS 168
%define ZU_VALUES 176
%define ZU_NULLS 184
%define ZU_COLUMNS 192
%define ZU_OWNER 200
%define ZU_SIZE 208

section .text

; Non-NaN binary32 bits in EAX -> signed ordering key in EAX. Both zeros
; have key zero; negative encodings reverse their magnitude order. Integer
; operations keep subnormals and signaling NaNs independent of MXCSR.
%macro F32_ZONE_KEY 0
    mov r11d, eax
    and r11d, 0x7fffffff
    jz %%zero
    test eax, eax
    jns %%done
    xor eax, 0x7fffffff
    jmp %%done
%%zero:
    xor eax, eax
%%done:
%endmacro

; zone_stat_valid(type, stat) -> 1/0. Schema validation precedes this call.
; Bounds are canonical storage values, never ordering keys.
zone_stat_valid:
    mov r8, ARG1
    mov r9, ARG2
    mov rcx, [r9 + ZSTAT_FLAGS]
    test rcx, rcx
    jz .bad                         ; every described leaf has rows
    cmp r8d, CAT_BOOL
    je .bool
    cmp r8d, CAT_FLOAT32
    je .float
    cmp r8d, CAT_TEXT
    je .varlen
    cmp r8d, CAT_BLOB
    je .varlen
    cmp r8d, CAT_VECTOR
    je .varlen
    test rcx, ~(ZSTAT_HAS_COMPARABLE | ZSTAT_HAS_NULLS)
    jnz .bad
    test rcx, ZSTAT_HAS_COMPARABLE
    jz .empty
    mov rax, [r9 + ZSTAT_MIN]
    mov rdx, [r9 + ZSTAT_MAX]
    cmp r8d, CAT_INT32
    jne .integer
    movsxd r10, eax
    cmp r10, rax
    jne .bad
    movsxd r10, edx
    cmp r10, rdx
    jne .bad
.integer:
    cmp rax, rdx
    jg .bad
    jmp .valid
.varlen:
    test rcx, ~(ZSTAT_HAS_COMPARABLE | ZSTAT_HAS_NULLS)
    jnz .bad
    jmp .empty
.bool:
    test rcx, ~(ZSTAT_HAS_COMPARABLE | ZSTAT_HAS_NULLS | ZSTAT_HAS_TRUE | ZSTAT_HAS_FALSE)
    jnz .bad
    test rcx, ZSTAT_HAS_COMPARABLE
    jz .bool_empty
    test rcx, ZSTAT_HAS_TRUE | ZSTAT_HAS_FALSE
    jz .bad
    jmp .empty
.bool_empty:
    test rcx, ZSTAT_HAS_TRUE | ZSTAT_HAS_FALSE
    jnz .bad
    jmp .empty
.float:
    test rcx, ~(ZSTAT_HAS_COMPARABLE | ZSTAT_HAS_NULLS | ZSTAT_HAS_NAN)
    jnz .bad
    test rcx, ZSTAT_HAS_COMPARABLE
    jz .empty
    cmp dword [r9 + ZSTAT_MIN + 4], 0
    jne .bad
    cmp dword [r9 + ZSTAT_MAX + 4], 0
    jne .bad
    mov eax, [r9 + ZSTAT_MIN]
    mov edx, eax
    and edx, 0x7fffffff
    cmp edx, 0x7f800000
    ja .bad
    F32_ZONE_KEY
    mov r10d, eax
    mov eax, [r9 + ZSTAT_MAX]
    mov edx, eax
    and edx, 0x7fffffff
    cmp edx, 0x7f800000
    ja .bad
    F32_ZONE_KEY
    cmp r10d, eax
    jg .bad
    jmp .valid
.empty:
    mov rax, [r9 + ZSTAT_MIN]
    or rax, [r9 + ZSTAT_MAX]
    jnz .bad
.valid:
    mov eax, 1
    ret
.bad:
    xor eax, eax
    ret

; Validation state shared by a bounded (at most three frames) tree walk.
%define ZV_CTX 0
%define ZV_SB 8
%define ZV_SCHEMA 16
%define ZV_STRIDE 24
%define ZV_SLOTS 32
%define ZV_LEAVES 40
%define ZV_NEXT 48
%define ZV_GENERATION 56
%define ZV_SIZE 64

; zone_validate_page(state, physical_id, expected_level, parent_generation).
; ZV_NEXT is the next uncovered PAX leaf. Exact FIRST/count and fixed level
; descent reject gaps, duplicates, overlaps and cycles without a visited set.
zone_validate_page:
    FRAME_BEGIN 96, 0
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
    mov [rbp - 24], ARG3
    mov [rbp - 32], ARG4
    mov r10, ARG1
    mov ARG3, [rbp - 16]
    mov ARG1, [r10 + ZV_CTX]
    mov ARG2, [r10 + ZV_SB]
    call db_bitmap_candidate_payload
    test eax, eax
    jz .bad
    mov r10, [rbp - 8]
    mov ARG1, [r10 + ZV_CTX]
    mov ARG2, [rbp - 16]
    call zone_page_addr
    mov [rbp - 40], rax
    cmp dword [rax + ZONE_MAGIC], ZONE_MAGIC_VALUE
    jne .bad
    cmp dword [rax + ZONE_VERSION], ZONE_VERSION_VALUE
    jne .bad
    mov rcx, [rbp - 16]
    cmp [rax + ZONE_PAGE_ID], rcx
    jne .bad
    mov rcx, [rax + ZONE_GENERATION]
    test rcx, rcx
    jz .bad
    cmp rcx, [rbp - 32]
    ja .bad
    mov r10, [rbp - 8]
    cmp rcx, [r10 + ZV_GENERATION]
    ja .bad
    mov r11, [r10 + ZV_SCHEMA]
    mov rcx, [r11 + CAT_OWNER]
    cmp [rax + ZONE_OWNER], rcx
    jne .bad
    mov rcx, [rbp - 24]
    cmp [rax + ZONE_LEVEL], ecx
    jne .bad
    cmp qword [rax + ZONE_RESERVED], 0
    jne .bad
    mov rcx, [r10 + ZV_STRIDE]
    cmp [rax + ZONE_STRIDE], rcx
    jne .bad
    mov rcx, [r10 + ZV_NEXT]
    cmp [rax + ZONE_FIRST], rcx
    jne .bad
    ; A child's coverage is fixed by its level, except at the table's tail.
    mov rax, [r10 + ZV_SLOTS]
    cmp qword [rbp - 24], ZONE_ROOT
    jne .coverage
    imul rax, ZONE_DIR_MAX
.coverage:
    mov rcx, [r10 + ZV_LEAVES]
    sub rcx, [r10 + ZV_NEXT]
    jbe .bad
    cmp qword [rbp - 24], ZONE_LEAF
    je .leaf_count
    dec rcx
    xchg rax, rcx
    xor edx, edx
    div rcx
    inc rax
    mov rcx, ZONE_DIR_MAX
    cmp rax, rcx
    cmova rax, rcx
    jmp .count
.leaf_count:
    cmp rax, rcx
    cmova rax, rcx
.count:
    mov [rbp - 56], rax
    mov r11, [rbp - 40]
    cmp [r11 + ZONE_COUNT], eax
    jne .bad
    mov ARG3, [r11 + ZONE_GENERATION]
    mov ARG1, [r10 + ZV_CTX]
    mov ARG2, [r10 + ZV_SB]
    call db_bitmap_deep
    test eax, eax
    jz .body
    mov ARG1, [rbp - 40]
    mov ARG2, ZONE_CRC
    call crc32c
    mov r11, [rbp - 40]
    cmp [r11 + ZONE_CRC], eax
    jne .bad
.body:
    mov qword [rbp - 64], 0
    cmp qword [rbp - 24], ZONE_LEAF
    je .stat_loop
.child_loop:
    mov rax, [rbp - 64]
    cmp rax, [rbp - 56]
    jae .tail_directory
    shl rax, 4
    add rax, [rbp - 40]
    mov r10, [rbp - 8]
    mov rcx, [r10 + ZV_NEXT]
    cmp [rax + ZONE_DATA + ZONE_ENTRY_FIRST], rcx
    jne .bad
    mov ARG2, [rax + ZONE_DATA + ZONE_ENTRY_PAGE]
    mov r11, [rbp - 40]
    mov ARG4, [r11 + ZONE_GENERATION]
    mov ARG3, [rbp - 24]
    dec ARG3
    mov ARG1, [rbp - 8]
    call zone_validate_page
    test eax, eax
    jz .bad
    inc qword [rbp - 64]
    jmp .child_loop
.stat_loop:
    mov rax, [rbp - 64]
    cmp rax, [rbp - 56]
    jae .tail_leaf
    mov qword [rbp - 72], 0
.column:
    mov r10, [rbp - 8]
    mov r11, [r10 + ZV_SCHEMA]
    mov rax, [rbp - 72]
    cmp eax, [r11 + CAT_COUNT]
    jae .next_stat
    shl rax, 5
    add r11, rax
    mov eax, [r11 + CAT_COLUMNS]
    mov [rbp - 80], rax
    mov eax, [r11 + CAT_COLUMNS + 4]
    mov [rbp - 88], rax
    mov rax, [rbp - 64]
    imul rax, [r10 + ZV_STRIDE]
    mov rcx, [rbp - 72]
    imul rcx, ZSTAT_SIZE
    add rax, rcx
    add rax, [rbp - 40]
    lea ARG2, [rax + ZONE_DATA]
    test qword [rbp - 88], CAT_NULLABLE
    jnz .nullable
    test qword [ARG2 + ZSTAT_FLAGS], ZSTAT_HAS_NULLS
    jnz .bad
.nullable:
    mov ARG1, [rbp - 80]
    call zone_stat_valid
    test eax, eax
    jz .bad
    inc qword [rbp - 72]
    jmp .column
.next_stat:
    mov r10, [rbp - 8]
    mov r11, [r10 + ZV_CTX]
    cmp qword [r11 + DB_VERIFY], 0
    je .stat_checked
    mov rax, [rbp - 64]
    imul rax, [r10 + ZV_STRIDE]
    add rax, [rbp - 40]
    lea ARG4, [rax + ZONE_DATA]
    mov ARG3, [r10 + ZV_NEXT]
    add ARG3, [rbp - 64]
    mov ARG2, [r10 + ZV_SCHEMA]
    mov ARG1, [r10 + ZV_CTX]
    call db_zone_check_leaf
    test eax, eax
    jz .bad
.stat_checked:
    inc qword [rbp - 64]
    jmp .stat_loop
.tail_leaf:
    mov r10, [rbp - 8]
    mov rax, [rbp - 56]
    add [r10 + ZV_NEXT], rax
    imul rax, [r10 + ZV_STRIDE]
    jmp .tail
.tail_directory:
    mov rax, [rbp - 56]
    shl rax, 4
.tail:
    add rax, ZONE_DATA
    mov r11, [rbp - 40]
.zero:
    cmp rax, ZONE_CRC
    jae .valid
    cmp byte [r11 + rax], 0
    jne .bad
    inc rax
    jmp .zero
.valid:
    mov eax, 1
    FRAME_END
    ret
.bad:
    xor eax, eax
    FRAME_END
    ret

; db_zone_validate(ctx, candidate_sb, validated_schema) -> 1 valid / 0 corrupt.
; PAX validation must succeed first; its canonical capacity and table row count
; define exactly the logical leaves that the optional statistics must cover.
db_zone_validate:
    FRAME_BEGIN ZV_SIZE + 16, 0
    lea r10, [rbp - ZV_SIZE]
    mov [r10 + ZV_CTX], ARG1
    mov [r10 + ZV_SB], ARG2
    mov [r10 + ZV_SCHEMA], ARG3
    mov r11, ARG1
    test qword [r11 + DB_FEATURES], CybouDB_FEATURE_ZONE_MAPS
    jz .valid
    mov r11, ARG3
    cmp qword [r11 + CAT_STATS_ROOT], 0
    je .valid
    mov rax, ARG2
    mov rax, [rax + SB_GENERATION]
    mov [r10 + ZV_GENERATION], rax
    mov ARG2, ARG3
    call db_pax_capacity
    test rax, rax
    jz .bad
    mov rcx, rax
    lea r10, [rbp - ZV_SIZE]
    mov r11, [r10 + ZV_SCHEMA]
    mov rax, [r11 + CAT_TABLE_ROWS]
    test rax, rax
    jz .bad
    dec rax
    xor edx, edx
    div rcx
    inc rax
    mov [r10 + ZV_LEAVES], rax
    mov qword [r10 + ZV_NEXT], 0
    mov ARG1, [r10 + ZV_SCHEMA]
    call db_zone_stride
    lea r10, [rbp - ZV_SIZE]
    mov [r10 + ZV_STRIDE], rax
    mov ARG1, [r10 + ZV_SCHEMA]
    call db_zone_slots
    lea r10, [rbp - ZV_SIZE]
    mov [r10 + ZV_SLOTS], rax
    xor ecx, ecx
    cmp [r10 + ZV_LEAVES], rax
    jbe .level
    inc ecx
    imul rax, ZONE_DIR_MAX
    cmp [r10 + ZV_LEAVES], rax
    jbe .level
    inc ecx
    imul rax, ZONE_DIR_MAX
    cmp [r10 + ZV_LEAVES], rax
    ja .bad
.level:
    mov [rbp - ZV_SIZE - 8], rcx
    mov r11, [r10 + ZV_SCHEMA]
    mov ARG4, [r11 + CAT_GENERATION]
    mov ARG2, [r11 + CAT_STATS_ROOT]
    mov ARG3, [rbp - ZV_SIZE - 8]
    lea ARG1, [rbp - ZV_SIZE]
    call zone_validate_page
    test eax, eax
    jz .bad
    lea r10, [rbp - ZV_SIZE]
    mov rax, [r10 + ZV_NEXT]
    cmp rax, [r10 + ZV_LEAVES]
    jne .bad
.valid:
    mov eax, 1
    FRAME_END
    ret
.bad:
    xor eax, eax
    FRAME_END
    ret

; db_zone_check_leaf(ctx, schema, logical_leaf, stored_stats) -> 1/0.
; Only called after the candidate's entire PAX graph has validated. Resolve
; through this schema (not DB_ROOT, which may still name another candidate).
; Recompute one column at a time from its raw values and NULL bitmap, using
; the same integer-only merge as insert. No allocation or catalog recursion.
db_zone_check_leaf:
    FRAME_BEGIN 176, 2
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
    mov [rbp - 24], ARG3
    mov [rbp - 32], ARG4
    mov r10, ARG1
    mov r11, ARG2
    mov r8, [r11 + CAT_DATA_ROOT]
    shl r8, CybouDB_PAGE_SHIFT
    add r8, [r10 + DB_BASE]
    test qword [r10 + DB_FEATURES], CybouDB_FEATURE_PAX_MULTI
    jz .leaf
    mov rcx, [rbp - 24]
    cmp dword [r8 + PAX_DIR_LEVEL], PAX_DIR_LEAF
    je .slot
    mov rax, rcx
    xor edx, edx
    mov r9, PAX_DIR_MAX
    div r9
    mov rcx, rdx
    shl rax, 4
    mov r8, [r8 + PAX_DIRECTORY + rax]
    shl r8, CybouDB_PAGE_SHIFT
    add r8, [r10 + DB_BASE]
.slot:
    shl rcx, 4
    mov r8, [r8 + PAX_DIRECTORY + rcx]
    shl r8, CybouDB_PAGE_SHIFT
    add r8, [r10 + DB_BASE]
.leaf:
    mov [rbp - 40], r8
    mov eax, [r8 + PAX_ROWS]
    mov [rbp - 48], rax
    mov qword [rbp - 56], 0
.column:
    mov rax, [rbp - 56]
    mov r11, [rbp - 16]
    cmp eax, [r11 + CAT_COUNT]
    jae .valid
    shl rax, 4
    add rax, [rbp - 40]
    lea r11, [rax + PAX_DIRECTORY]
    mov eax, [r11]
    mov [rbp - 64], rax
    mov edx, [r11 + 4]
    shr edx, 8
    and edx, 0xFF
    mov [rbp - 152], rdx
    mov ecx, 4
    cmp eax, CAT_INT64
    jne .not_i64
    mov ecx, 8
.not_i64:
    cmp eax, CAT_BOOL
    jne .width
    mov ecx, 1
.width:
    cmp eax, CAT_TEXT
    je .width16
    cmp eax, CAT_BLOB
    je .width16
    cmp eax, CAT_VECTOR
    jne .width_ready
.width16:
    mov ecx, VAR_CELL_SIZE
.width_ready:
    mov [rbp - 72], rcx
    mov eax, [r11 + 8]
    add rax, [rbp - 40]
    mov [rbp - 80], rax
    mov eax, [r11 + 12]
    add rax, [rbp - 40]
    mov [rbp - 88], rax
    mov qword [rbp - 96], 0
    mov qword [rbp - 144 + ZSTAT_FLAGS], 0
    mov qword [rbp - 144 + ZSTAT_MIN], 0
    mov qword [rbp - 144 + ZSTAT_MAX], 0
.row:
    mov rcx, [rbp - 96]
    cmp rcx, [rbp - 48]
    jae .compare
    mov r11, [rbp - 80]
    bt qword [r11], rcx
    setc al
    movzx eax, al
    mov [rbp - 104], rax
    xor eax, eax
    cmp qword [rbp - 104], 0
    jne .merge

    mov rdx, [rbp - 152]
    test rdx, rdx
    jz .read_raw

    mov rax, [rbp - 64]
    PASS_ARG5 rax
    PASS_ARG6 rdx
    mov ARG1, [rbp - 88]
    mov ARG2, [rbp - 96]
    mov ARG3, 1
    lea rax, [rbp - 160]
    mov ARG4, rax
    call decompress_column

    mov rax, [rbp - 64]
    cmp rax, CAT_INT64
    je .dec_read8
    cmp rax, CAT_BOOL
    je .dec_read1
    mov eax, [rbp - 160]
    cmp qword [rbp - 64], CAT_INT32
    jne .merge
    movsxd rax, eax
    jmp .merge
.dec_read8:
    mov rax, [rbp - 160]
    jmp .merge
.dec_read1:
    movzx eax, byte [rbp - 160]
    jmp .merge

.read_raw:
    mov rcx, [rbp - 96]
    imul rcx, [rbp - 72]
    add rcx, [rbp - 88]
    cmp qword [rbp - 72], 8
    je .read8
    cmp qword [rbp - 72], 1
    je .read1
    mov eax, [rcx]
    cmp qword [rbp - 64], CAT_INT32
    jne .merge
    movsxd rax, eax
    jmp .merge
.read8:
    mov rax, [rcx]
    jmp .merge
.read1:
    movzx eax, byte [rcx]
.merge:
    mov ARG2, rax
    lea ARG1, [rbp - 144]
    mov ARG3, [rbp - 64]
    mov ARG4, [rbp - 104]
    call zone_merge
    inc qword [rbp - 96]
    jmp .row
.compare:
    mov rax, [rbp - 56]
    imul rax, ZSTAT_SIZE
    add rax, [rbp - 32]
    mov rcx, [rbp - 144 + ZSTAT_FLAGS]
    cmp [rax + ZSTAT_FLAGS], rcx
    jne .bad
    mov rcx, [rbp - 144 + ZSTAT_MIN]
    cmp [rax + ZSTAT_MIN], rcx
    jne .bad
    mov rcx, [rbp - 144 + ZSTAT_MAX]
    cmp [rax + ZSTAT_MAX], rcx
    jne .bad
    inc qword [rbp - 56]
    jmp .column
.valid:
    mov eax, 1
    FRAME_END
    ret
.bad:
    xor eax, eax
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  db_zone_stride(ARG1 = schema) -> RAX: bytes of statistics per leaf.
; -----------------------------------------------------------------------------
db_zone_stride:
    mov eax, [ARG1 + CAT_COUNT]
    imul rax, ZSTAT_SIZE
    ret

; -----------------------------------------------------------------------------
;  db_zone_slots(ARG1 = schema) -> RAX: leaves described by one zone page.
;
;  Never zero: a schema holds at most 64 columns, so the widest stride is 1536
;  bytes and two of those still fit between the header and the checksum.
; -----------------------------------------------------------------------------
db_zone_slots:
    FRAME_BEGIN 16, 0
    call db_zone_stride
    mov rcx, rax
    mov rax, ZONE_CRC - ZONE_DATA
    xor edx, edx
    div rcx
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  db_zone_reserve(ARG1 = ctx, ARG2 = schema, ARG3 = batch, ARG4 = capacity)
;      -> RAX: pages this batch's statistics will need.
;
;  The insert paths add this to their own preflight, so a database that cannot
;  hold the statistics fails before it has written anything, rather than after
;  the leaves are already down. Zero when the feature is off, and zero for a
;  table too large for two levels of directories, which keeps none.
; -----------------------------------------------------------------------------
db_zone_reserve:
    FRAME_BEGIN 64, 0
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
    mov [rbp - 24], ARG3
    mov [rbp - 32], ARG4
    mov r10, ARG1
    test qword [r10 + DB_FEATURES], CybouDB_FEATURE_ZONE_MAPS
    jz .none
    mov r11, [rbp - 16]
    cmp qword [r11 + CAT_STATS_ROOT], 0
    jne .stats_available
    cmp qword [r11 + CAT_TABLE_ROWS], 0
    jne .none                       ; absent history cannot be rebuilt by append
.stats_available:
    mov r11, ARG3
    mov rax, [r11 + BATCH_ROWS]
    test rax, rax
    jz .none
    mov [rbp - 40], rax
    mov ARG1, [rbp - 16]
    call db_zone_slots
    mov [rbp - 48], rax
    mov r11, [rbp - 16]
    mov rax, [r11 + CAT_TABLE_ROWS]
    mov [rbp - 56], rax
    mov rcx, [rbp - 32]
    xor edx, edx
    div rcx
    xor edx, edx
    mov rcx, [rbp - 48]
    div rcx
    mov [rbp - 24], rax             ; first page
    mov rax, [rbp - 56]
    add rax, [rbp - 40]
    dec rax
    xor edx, edx
    mov rcx, [rbp - 32]
    div rcx
    xor edx, edx
    mov rcx, [rbp - 48]
    div rcx
    mov [rbp - 32], rax             ; last page
    mov rcx, ZONE_DIR_MAX
    imul rcx, ZONE_DIR_MAX
    cmp rax, rcx
    jae .none                       ; beyond what two levels describe
    mov rax, [rbp - 32]
    sub rax, [rbp - 24]
    inc rax                         ; the statistics pages in range
    cmp qword [rbp - 32], 0
    je .done                        ; one page, and it is the root
    inc rax                         ; the root above the pages
    ; A table whose statistics were one page has that page relinked under the
    ; new root, so it is visited even when this batch does not touch it.
    mov [rbp - 64], rax
    mov r11, [rbp - 16]
    mov r11, [r11 + CAT_STATS_ROOT]
    test r11, r11
    jz .promotion_checked
    mov ARG1, [rbp - 8]
    mov ARG2, r11
    call zone_page_addr
    cmp dword [rax + ZONE_LEVEL], ZONE_LEAF
    jne .promotion_checked
    inc qword [rbp - 64]
.promotion_checked:
    mov rax, [rbp - 64]
    cmp qword [rbp - 32], ZONE_DIR_MAX
    jb .done
    ; A root of directories: count the directories the range hangs under.
    mov [rbp - 64], rax
    mov rax, [rbp - 32]
    xor edx, edx
    mov rcx, ZONE_DIR_MAX
    div rcx
    mov r11, rax
    mov rax, [rbp - 24]
    xor edx, edx
    div rcx
    sub r11, rax
    inc r11
    mov rax, [rbp - 64]
    add rax, r11
.done:
    FRAME_END
    ret
.none:
    xor eax, eax
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  zone_page_addr(ARG1 = ctx, ARG2 = page id) -> RAX: mapped address.
; -----------------------------------------------------------------------------
zone_page_addr:
    mov rax, ARG2
    shl rax, CybouDB_PAGE_SHIFT
    add rax, [ARG1 + DB_BASE]
    ret

; -----------------------------------------------------------------------------
;  zone_merge(ARG1 = entry, ARG2 = value, ARG3 = type, ARG4 = is_null)
;
;  Folds one cell into one column's statistics. NULLs are recorded as a flag
;  and never widen a range. Neither does NaN: it compares false against every
;  predicate, so a range that contained it could not decide anything.
; -----------------------------------------------------------------------------
zone_merge:
    test ARG4, ARG4
    jz .value
    or qword [ARG1 + ZSTAT_FLAGS], ZSTAT_HAS_NULLS
    ret
.value:
    cmp ARG3, CAT_TEXT
    je .varlen
    cmp ARG3, CAT_BLOB
    je .varlen
    cmp ARG3, CAT_VECTOR
    je .varlen
    cmp ARG3, CAT_BOOL
    je .bool
    cmp ARG3, CAT_FLOAT32
    je .float
    ; INT32 arrives sign-extended into its eight-byte slot, so both integer
    ; types compare as signed 64-bit without a special case.
    test qword [ARG1 + ZSTAT_FLAGS], ZSTAT_HAS_COMPARABLE
    jz .int_first
    cmp ARG2, [ARG1 + ZSTAT_MIN]
    jge .int_max
    mov [ARG1 + ZSTAT_MIN], ARG2
.int_max:
    cmp ARG2, [ARG1 + ZSTAT_MAX]
    jle .done
    mov [ARG1 + ZSTAT_MAX], ARG2
    ret
.int_first:
    or qword [ARG1 + ZSTAT_FLAGS], ZSTAT_HAS_COMPARABLE
    mov [ARG1 + ZSTAT_MIN], ARG2
    mov [ARG1 + ZSTAT_MAX], ARG2
    ret
.varlen:
    or qword [ARG1 + ZSTAT_FLAGS], ZSTAT_HAS_COMPARABLE
    ret
.bool:
    or qword [ARG1 + ZSTAT_FLAGS], ZSTAT_HAS_COMPARABLE
    test ARG2, ARG2
    jz .bool_false
    or qword [ARG1 + ZSTAT_FLAGS], ZSTAT_HAS_TRUE
    ret
.bool_false:
    or qword [ARG1 + ZSTAT_FLAGS], ZSTAT_HAS_FALSE
    ret
.float:
    mov eax, ARG2d
    and eax, 0x7fffffff
    cmp eax, 0x7f800000
    ja .float_nan
    mov ARG2d, ARG2d                ; stored bits are zero-extended
    test qword [ARG1 + ZSTAT_FLAGS], ZSTAT_HAS_COMPARABLE
    jz .float_first
    mov eax, ARG2d
    F32_ZONE_KEY
    mov r10d, eax
    mov eax, [ARG1 + ZSTAT_MIN]
    F32_ZONE_KEY
    cmp eax, r10d                  ; signed keys, raw bits stay in MIN/MAX
    jle .float_max
    mov [ARG1 + ZSTAT_MIN], ARG2
.float_max:
    mov eax, [ARG1 + ZSTAT_MAX]
    F32_ZONE_KEY
    cmp r10d, eax
    jle .done
    mov [ARG1 + ZSTAT_MAX], ARG2
    ret
.float_first:
    or qword [ARG1 + ZSTAT_FLAGS], ZSTAT_HAS_COMPARABLE
    mov [ARG1 + ZSTAT_MIN], ARG2
    mov [ARG1 + ZSTAT_MAX], ARG2
    ret
.float_nan:
    or qword [ARG1 + ZSTAT_FLAGS], ZSTAT_HAS_NAN
.done:
    ret

; -----------------------------------------------------------------------------
;  zone_stamp(ARG1 = page, ARG2 = ctx, ARG3 = page id, ARG4 = owner)
;  Identity and generation, the fields every page type in the file carries.
; -----------------------------------------------------------------------------
zone_stamp:
    mov dword [ARG1 + ZONE_MAGIC], ZONE_MAGIC_VALUE
    mov dword [ARG1 + ZONE_VERSION], ZONE_VERSION_VALUE
    mov [ARG1 + ZONE_PAGE_ID], ARG3
    mov rax, [ARG2 + DB_GENERATION]
    inc rax                        ; this COW page belongs to the candidate
    mov [ARG1 + ZONE_GENERATION], rax
    mov [ARG1 + ZONE_OWNER], ARG4
    mov qword [ARG1 + ZONE_RESERVED], 0
    ret

; -----------------------------------------------------------------------------
;  zone_seal(ARG1 = page): checksum everything ahead of the checksum itself.
; -----------------------------------------------------------------------------
zone_seal:
    FRAME_BEGIN 16, 0
    mov [rbp - 8], ARG1
    mov ARG2, ZONE_CRC
    call crc32c
    mov r10, [rbp - 8]
    mov [r10 + ZONE_CRC], eax
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  zone_child(ARG1 = ctx, ARG2 = directory page id, ARG3 = index) -> RAX
;
;  The child a directory names at that index, or zero when the index is past
;  what it holds. Reading only; the caller decides whether to copy the result.
; -----------------------------------------------------------------------------
zone_child:
    FRAME_BEGIN 32, 0
    mov [rbp - 24], ARG3
    test ARG2, ARG2
    jz .none
    call zone_page_addr
    mov ecx, [rax + ZONE_COUNT]
    cmp [rbp - 24], rcx
    jae .none
    mov rcx, [rbp - 24]
    shl rcx, 4
    add rax, rcx
    mov rax, [rax + ZONE_DATA + ZONE_ENTRY_PAGE]
    jmp .done
.none:
    xor eax, eax
.done:
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  db_zone_lookup(ARG1 = ctx, ARG2 = schema, ARG3 = leaf index) -> RAX
;
;  The statistics of one leaf, or zero when the table has none for it - which
;  is what a table written before the feature, and one whose statistics do not
;  reach that leaf, both look like. A caller that gets zero evaluates the
;  predicate the way it always has.
; -----------------------------------------------------------------------------
db_zone_lookup:
    FRAME_BEGIN 80, 0
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
    mov [rbp - 24], ARG3
    mov r10, ARG1
    test qword [r10 + DB_FEATURES], CybouDB_FEATURE_ZONE_MAPS
    jz .none
    mov r11, ARG2
    mov rax, [r11 + CAT_STATS_ROOT]
    test rax, rax
    jz .none
    mov [rbp - 32], rax

    mov ARG1, [rbp - 16]
    call db_zone_slots
    mov rcx, rax
    mov rax, [rbp - 24]
    xor edx, edx
    div rcx
    mov [rbp - 48], rax             ; page index
    mov [rbp - 56], rdx             ; slot on that page

    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 32]
    call zone_page_addr
    mov [rbp - 72], rax
    mov ecx, [rax + ZONE_LEVEL]
    cmp ecx, ZONE_LEAF
    je .have_root_page
    cmp ecx, ZONE_DIR
    je .from_dir

    mov rax, [rbp - 48]
    xor edx, edx
    mov rcx, ZONE_DIR_MAX
    div rcx
    mov [rbp - 64], rdx
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 32]
    mov ARG3, rax
    call zone_child
    test rax, rax
    jz .none
    mov ARG1, [rbp - 8]
    mov ARG2, rax
    mov ARG3, [rbp - 64]
    call zone_child
    test rax, rax
    jz .none
    jmp .page_of_id

.from_dir:
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 32]
    mov ARG3, [rbp - 48]
    call zone_child
    test rax, rax
    jz .none
.page_of_id:
    mov ARG1, [rbp - 8]
    mov ARG2, rax
    call zone_page_addr
    mov [rbp - 72], rax
    jmp .entry

.have_root_page:
    cmp qword [rbp - 48], 0
    jne .none
.entry:
    mov r10, [rbp - 72]
    mov ecx, [r10 + ZONE_COUNT]
    cmp [rbp - 56], rcx
    jae .none
    mov ARG1, [rbp - 16]
    call db_zone_stride
    imul rax, [rbp - 56]
    add rax, [rbp - 72]
    add rax, ZONE_DATA
    jmp .done
.none:
    xor eax, eax
.done:
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  zone_old_dir(ARG1 = zu, ARG2 = directory index) -> RAX: page id or zero.
;  Where that directory lives in the tree as it stands before this update.
; -----------------------------------------------------------------------------
zone_old_dir:
    FRAME_BEGIN 32, 0
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
    mov r10, ARG1
    cmp qword [r10 + ZU_OLD_LEVEL], ZONE_ROOT
    je .from_root
    cmp qword [r10 + ZU_OLD_LEVEL], ZONE_DIR
    jne .none
    cmp qword [rbp - 16], 0
    jne .none
    mov rax, [r10 + ZU_OLD_ROOT]    ; the old root is directory zero
    jmp .done
.from_root:
    mov ARG1, [r10 + ZU_CTX]
    mov ARG2, [r10 + ZU_OLD_ROOT]
    mov ARG3, [rbp - 16]
    call zone_child
    jmp .done
.none:
    xor eax, eax
.done:
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  zone_old_page(ARG1 = zu, ARG2 = page index) -> RAX: page id or zero.
; -----------------------------------------------------------------------------
zone_old_page:
    FRAME_BEGIN 48, 0
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
    mov r10, ARG1
    cmp qword [r10 + ZU_OLD_ROOT], 0
    je .none
    cmp qword [r10 + ZU_OLD_LEVEL], ZONE_LEAF
    je .single
    cmp qword [r10 + ZU_OLD_LEVEL], ZONE_DIR
    je .from_dir

    mov rax, [rbp - 16]
    xor edx, edx
    mov rcx, ZONE_DIR_MAX
    div rcx
    mov [rbp - 24], rdx
    mov ARG1, [rbp - 8]
    mov ARG2, rax
    call zone_old_dir
    test rax, rax
    jz .none
    mov r10, [rbp - 8]
    mov ARG1, [r10 + ZU_CTX]
    mov ARG2, rax
    mov ARG3, [rbp - 24]
    call zone_child
    jmp .done
.from_dir:
    mov ARG1, [r10 + ZU_CTX]
    mov ARG2, [r10 + ZU_OLD_ROOT]
    mov ARG3, [rbp - 16]
    call zone_child
    jmp .done
.single:
    cmp qword [rbp - 16], 0
    jne .none
    mov rax, [r10 + ZU_OLD_ROOT]
    jmp .done
.none:
    xor eax, eax
.done:
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  zone_new_root(ARG1 = zu) -> EAX: error.
;
;  Copies the old root when the tree keeps its depth, so untouched entries
;  survive, and allocates a fresh one when it grows. A directory root that has
;  just been promoted keeps the old root as its first child.
; -----------------------------------------------------------------------------
zone_new_root:
    FRAME_BEGIN 48, 0
    mov [rbp - 8], ARG1
    mov r10, ARG1
    mov rax, [r10 + ZU_NEW_LEVEL]
    cmp rax, [r10 + ZU_OLD_LEVEL]
    jne .fresh
    cmp qword [r10 + ZU_OLD_ROOT], 0
    je .fresh
    mov ARG1, [r10 + ZU_CTX]
    mov ARG2, [r10 + ZU_OLD_ROOT]
    lea ARG3, [rbp - 16]
    call db_cow_copy_page
    test eax, eax
    jnz .done
    jmp .ready
.fresh:
    mov r10, [rbp - 8]
    mov ARG1, [r10 + ZU_CTX]
    lea ARG2, [rbp - 16]
    call db_cow_alloc_page
    test eax, eax
    jnz .done
.ready:
    mov r10, [rbp - 8]
    mov rax, [rbp - 16]
    mov [r10 + ZU_NEW_ROOT], rax
    mov ARG1, [r10 + ZU_CTX]
    mov ARG2, rax
    call zone_page_addr
    mov r10, [rbp - 8]
    mov [r10 + ZU_ROOT_ADDR], rax
    mov ARG1, rax
    mov ARG2, [r10 + ZU_CTX]
    mov ARG3, [rbp - 16]
    mov ARG4, [r10 + ZU_OWNER]
    call zone_stamp
    mov r10, [rbp - 8]
    mov rax, [r10 + ZU_ROOT_ADDR]
    mov rcx, [r10 + ZU_NEW_LEVEL]
    mov [rax + ZONE_LEVEL], ecx
    mov rcx, [r10 + ZU_STRIDE]
    mov [rax + ZONE_STRIDE], rcx
    mov rcx, [r10 + ZU_OLD_LEVEL]
    cmp [r10 + ZU_NEW_LEVEL], rcx
    je .keep_count
    cmp qword [r10 + ZU_NEW_LEVEL], ZONE_LEAF
    je .keep_count
    ; A fresh directory starts empty; entries appear as pages are opened.
    mov dword [rax + ZONE_COUNT], 0
    mov qword [rax + ZONE_FIRST], 0
    ; Promoting a directory to a root of directories keeps what it described:
    ; the old root becomes directory zero, and may not be visited again.
    cmp qword [r10 + ZU_OLD_LEVEL], ZONE_DIR
    jne .keep_count
    cmp qword [r10 + ZU_NEW_LEVEL], ZONE_ROOT
    jne .keep_count
    mov rcx, [r10 + ZU_OLD_ROOT]
    mov [rax + ZONE_DATA + ZONE_ENTRY_PAGE], rcx
    mov qword [rax + ZONE_DATA + ZONE_ENTRY_FIRST], 0
    mov dword [rax + ZONE_COUNT], 1
.keep_count:
    xor eax, eax
.done:
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  zone_link(ARG1 = parent page, ARG2 = index, ARG3 = child id, ARG4 = first)
;  Writes one directory entry and extends the entry count if it has to.
; -----------------------------------------------------------------------------
zone_link:
    mov rax, ARG2
    shl rax, 4
    add rax, ARG1
    mov [rax + ZONE_DATA + ZONE_ENTRY_PAGE], ARG3
    mov [rax + ZONE_DATA + ZONE_ENTRY_FIRST], ARG4
    ; RCX is the first argument on Windows, so the count is read into a
    ; scratch register rather than over the page pointer.
    mov r11d, [ARG1 + ZONE_COUNT]
    cmp ARG2, r11
    jb .done
    mov eax, ARG2d
    inc eax
    mov [ARG1 + ZONE_COUNT], eax
.done:
    ret

; -----------------------------------------------------------------------------
;  zone_open_dir(ARG1 = zu, ARG2 = directory index) -> EAX: error.
;  Only used by a two-level tree. Seals the directory being left behind.
; -----------------------------------------------------------------------------
zone_open_dir:
    FRAME_BEGIN 48, 0
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
    mov r10, ARG1
    mov rax, [r10 + ZU_DIR_INDEX]
    cmp rax, ARG2
    jne .switch
    cmp qword [r10 + ZU_DIR_ADDR], 0
    je .switch
    xor eax, eax
    jmp .done
.switch:
    cmp qword [r10 + ZU_DIR_ADDR], 0
    je .no_previous
    mov ARG1, [r10 + ZU_DIR_ADDR]
    call zone_seal
.no_previous:
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    call zone_old_dir
    mov [rbp - 24], rax
    mov r10, [rbp - 8]
    test rax, rax
    jz .dir_fresh
    mov ARG1, [r10 + ZU_CTX]
    mov ARG2, rax
    lea ARG3, [rbp - 32]
    call db_cow_copy_page
    test eax, eax
    jnz .done
    jmp .dir_ready
.dir_fresh:
    mov ARG1, [r10 + ZU_CTX]
    lea ARG2, [rbp - 32]
    call db_cow_alloc_page
    test eax, eax
    jnz .done
.dir_ready:
    mov r10, [rbp - 8]
    mov ARG1, [r10 + ZU_CTX]
    mov ARG2, [rbp - 32]
    call zone_page_addr
    mov r10, [rbp - 8]
    mov [r10 + ZU_DIR_ADDR], rax
    mov rcx, [rbp - 16]
    mov [r10 + ZU_DIR_INDEX], rcx
    mov ARG1, rax
    mov ARG2, [r10 + ZU_CTX]
    mov ARG3, [rbp - 32]
    mov ARG4, [r10 + ZU_OWNER]
    call zone_stamp
    mov r10, [rbp - 8]
    mov rax, [r10 + ZU_DIR_ADDR]
    mov dword [rax + ZONE_LEVEL], ZONE_DIR
    mov rcx, [r10 + ZU_STRIDE]
    mov [rax + ZONE_STRIDE], rcx
    cmp qword [rbp - 24], 0
    jne .dir_counted
    mov dword [rax + ZONE_COUNT], 0
.dir_counted:
    mov rcx, [rbp - 16]
    imul rcx, ZONE_DIR_MAX
    imul rcx, [r10 + ZU_SLOTS]
    mov [rax + ZONE_FIRST], rcx
    mov [rbp - 40], rcx

    ; Link it under the root, which is already a copy of its own.
    mov ARG1, [r10 + ZU_ROOT_ADDR]
    mov ARG2, [rbp - 16]
    mov ARG3, [rbp - 32]
    mov ARG4, [rbp - 40]
    call zone_link
    xor eax, eax
.done:
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  zone_open_page(ARG1 = zu) -> EAX: error.
;
;  Makes ZU_PAGE_INDEX's statistics page writable - copied when it existed,
;  allocated and stamped when it did not - and links it under whatever stands
;  above it. In a one-page tree the root is that page.
; -----------------------------------------------------------------------------
zone_open_page:
    FRAME_BEGIN 64, 0
    mov [rbp - 8], ARG1
    mov r10, ARG1
    cmp qword [r10 + ZU_NEW_LEVEL], ZONE_LEAF
    jne .indexed
    mov rax, [r10 + ZU_ROOT_ADDR]
    mov [r10 + ZU_PAGE_ADDR], rax
    mov qword [rax + ZONE_FIRST], 0
    xor eax, eax
    jmp .done
.indexed:
    cmp qword [r10 + ZU_NEW_LEVEL], ZONE_ROOT
    jne .parent_is_root
    mov rax, [r10 + ZU_PAGE_INDEX]
    xor edx, edx
    mov rcx, ZONE_DIR_MAX
    div rcx
    mov [rbp - 16], rdx             ; index inside the directory
    mov ARG1, [rbp - 8]
    mov ARG2, rax
    call zone_open_dir
    test eax, eax
    jnz .done
    mov r10, [rbp - 8]
    mov rax, [r10 + ZU_DIR_ADDR]
    mov [rbp - 24], rax
    jmp .parent_ready
.parent_is_root:
    mov rax, [r10 + ZU_PAGE_INDEX]
    mov [rbp - 16], rax
    mov rax, [r10 + ZU_ROOT_ADDR]
    mov [rbp - 24], rax
.parent_ready:
    mov ARG1, [rbp - 8]
    mov r10, ARG1
    mov ARG2, [r10 + ZU_PAGE_INDEX]
    call zone_old_page
    mov [rbp - 32], rax
    mov r10, [rbp - 8]
    test rax, rax
    jz .page_fresh
    mov ARG1, [r10 + ZU_CTX]
    mov ARG2, rax
    lea ARG3, [rbp - 40]
    call db_cow_copy_page
    test eax, eax
    jnz .done
    jmp .page_ready
.page_fresh:
    mov ARG1, [r10 + ZU_CTX]
    lea ARG2, [rbp - 40]
    call db_cow_alloc_page
    test eax, eax
    jnz .done
.page_ready:
    mov r10, [rbp - 8]
    mov ARG1, [r10 + ZU_CTX]
    mov ARG2, [rbp - 40]
    call zone_page_addr
    mov r10, [rbp - 8]
    mov [r10 + ZU_PAGE_ADDR], rax
    mov ARG1, rax
    mov ARG2, [r10 + ZU_CTX]
    mov ARG3, [rbp - 40]
    mov ARG4, [r10 + ZU_OWNER]
    call zone_stamp
    mov r10, [rbp - 8]
    mov rax, [r10 + ZU_PAGE_ADDR]
    mov dword [rax + ZONE_LEVEL], ZONE_LEAF
    mov rcx, [r10 + ZU_STRIDE]
    mov [rax + ZONE_STRIDE], rcx
    cmp qword [rbp - 32], 0
    jne .page_counted
    mov dword [rax + ZONE_COUNT], 0
.page_counted:
    mov rcx, [r10 + ZU_PAGE_INDEX]
    imul rcx, [r10 + ZU_SLOTS]
    mov [rax + ZONE_FIRST], rcx
    mov [rbp - 48], rcx

    mov ARG1, [rbp - 24]
    mov ARG2, [rbp - 16]
    mov ARG3, [rbp - 40]
    mov ARG4, [rbp - 48]
    call zone_link
    xor eax, eax
.done:
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  zone_merge_leaf(ARG1 = zu)
;
;  Folds the batch rows that land in ZU_LEAF_INDEX into that leaf's entries. A
;  leaf this insert created starts from nothing; one it appends to keeps what
;  earlier inserts recorded, which is why a merge and not a rewrite.
;
;  Local slots: [rbp-8]=zu, [rbp-16]=entry base, [rbp-24]=first batch row,
;               [rbp-32]=last batch row, [rbp-40]=row, [rbp-48]=column,
;               [rbp-56]=cell index, [rbp-64]=schema
; -----------------------------------------------------------------------------
zone_merge_leaf:
    FRAME_BEGIN 96, 0
    mov [rbp - 8], ARG1
    mov r10, ARG1
    mov rax, [r10 + ZU_SCHEMA]
    mov [rbp - 64], rax

    ; Where this leaf's entries sit on the page that describes it
    mov rax, [r10 + ZU_LEAF_INDEX]
    mov rcx, [r10 + ZU_PAGE_INDEX]
    imul rcx, [r10 + ZU_SLOTS]
    sub rax, rcx                    ; slot
    imul rax, [r10 + ZU_STRIDE]
    add rax, [r10 + ZU_PAGE_ADDR]
    add rax, ZONE_DATA
    mov [rbp - 16], rax

    ; Rows of this leaf, as batch row numbers
    mov rax, [r10 + ZU_LEAF_INDEX]
    imul rax, [r10 + ZU_CAPACITY]   ; first table row of the leaf
    mov rcx, [r10 + ZU_ROWS_BEFORE]
    cmp rax, rcx
    jb .started                     ; the leaf already held rows
    ; A leaf that starts inside this batch has no history to keep
    sub rax, rcx
    mov [rbp - 24], rax
    mov ARG1, [rbp - 16]
    mov r10, [rbp - 8]
    mov ARG2, [r10 + ZU_STRIDE]
    call zone_reset_leaf
    jmp .range_end
.started:
    mov qword [rbp - 24], 0
.range_end:
    mov r10, [rbp - 8]
    mov rax, [r10 + ZU_LEAF_INDEX]
    inc rax
    imul rax, [r10 + ZU_CAPACITY]   ; first table row of the next leaf
    sub rax, [r10 + ZU_ROWS_BEFORE]
    cmp rax, [r10 + ZU_BATCH_ROWS]
    jbe .have_end
    mov rax, [r10 + ZU_BATCH_ROWS]
.have_end:
    mov [rbp - 32], rax

    ; The count a page reports covers the leaves it describes, and this one is
    ; described from here on.
    mov rax, [r10 + ZU_LEAF_INDEX]
    mov rcx, [r10 + ZU_PAGE_INDEX]
    imul rcx, [r10 + ZU_SLOTS]
    sub rax, rcx
    inc rax
    mov r11, [r10 + ZU_PAGE_ADDR]
    mov ecx, [r11 + ZONE_COUNT]
    cmp rax, rcx
    jbe .counted
    mov [r11 + ZONE_COUNT], eax
.counted:

    mov rax, [rbp - 24]
    mov [rbp - 40], rax
.row_loop:
    mov rax, [rbp - 40]
    cmp rax, [rbp - 32]
    jae .rows_done
    mov r10, [rbp - 8]
    imul rax, [r10 + ZU_COLUMNS]
    mov [rbp - 56], rax
    mov qword [rbp - 48], 0
.cell_loop:
    mov r10, [rbp - 8]
    mov rax, [rbp - 48]
    cmp rax, [r10 + ZU_COLUMNS]
    jae .cells_done

    ; The cell's value, its NULL byte and its declared type are read into
    ; locals first: an argument register on one ABI is a scratch register on
    ; the other, and the cell index would not survive being written over.
    mov rcx, [rbp - 56]
    add rcx, rax
    mov r11, [r10 + ZU_VALUES]
    mov rax, [r11 + rcx * 8]
    mov [rbp - 72], rax
    xor eax, eax
    mov r11, [r10 + ZU_NULLS]
    test r11, r11
    jz .have_null
    movzx eax, byte [r11 + rcx]
.have_null:
    mov [rbp - 80], rax
    mov rax, [rbp - 48]
    shl rax, 5
    add rax, [rbp - 64]
    mov eax, [rax + CAT_COLUMNS]
    mov [rbp - 88], rax

    mov rax, [rbp - 48]
    imul rax, ZSTAT_SIZE
    add rax, [rbp - 16]
    mov ARG1, rax
    mov ARG2, [rbp - 72]
    mov ARG3, [rbp - 88]
    mov ARG4, [rbp - 80]
    call zone_merge

    inc qword [rbp - 48]
    jmp .cell_loop
.cells_done:
    inc qword [rbp - 40]
    jmp .row_loop
.rows_done:
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  zone_reset_leaf(ARG1 = entry base, ARG2 = stride): a leaf with no history.
; -----------------------------------------------------------------------------
zone_reset_leaf:
    mov rax, ARG1
    mov rcx, ARG2
    xor edx, edx
.clear:
    cmp rdx, rcx
    jae .done
    mov qword [rax + rdx], 0
    add rdx, 8
    jmp .clear
.done:
    ret

; zone_recompute_column(ctx, schema, leaf, column, out_stat)
; Rebuild one exact ZSTAT from a validated, possibly compressed PAX leaf.
zone_recompute_column:
    FRAME_BEGIN 112, 2
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
    mov [rbp - 24], ARG3
    mov [rbp - 32], ARG4
    mov rax, IN_ARG5
    mov [rbp - 40], rax
    mov qword [rax + ZSTAT_FLAGS], 0
    mov qword [rax + ZSTAT_MIN], 0
    mov qword [rax + ZSTAT_MAX], 0
    mov rax, [rbp - 32]
    shl rax, 4
    add rax, [rbp - 24]
    add rax, PAX_DIRECTORY
    mov eax, [rax]
    mov [rbp - 48], rax            ; type
    mov rax, [rbp - 32]
    shl rax, 4
    add rax, [rbp - 24]
    add rax, PAX_DIRECTORY
    mov edx, [rax + 4]
    shr edx, 8
    and edx, 0xFF
    mov [rbp - 56], rdx            ; codec
    mov edx, [rax + 8]
    add rdx, [rbp - 24]
    mov [rbp - 64], rdx            ; NULL masks
    mov edx, [rax + 12]
    add rdx, [rbp - 24]
    mov [rbp - 72], rdx            ; values
    mov rcx, 4
    cmp qword [rbp - 48], CAT_INT64
    jne .recompute_not_i64
    mov rcx, 8
.recompute_not_i64:
    cmp qword [rbp - 48], CAT_BOOL
    jne .recompute_not_bool
    mov rcx, 1
.recompute_not_bool:
    cmp qword [rbp - 48], CAT_TEXT
    je .recompute_varlen_width
    cmp qword [rbp - 48], CAT_BLOB
    je .recompute_varlen_width
    cmp qword [rbp - 48], CAT_VECTOR
    jne .recompute_width_ready
.recompute_varlen_width:
    mov rcx, VAR_CELL_SIZE
.recompute_width_ready:
    mov [rbp - 80], rcx
    mov qword [rbp - 88], 0
.recompute_row:
    mov rcx, [rbp - 88]
    mov r10, [rbp - 24]
    cmp ecx, [r10 + PAX_ROWS]
    jae .recompute_done
    mov r11, [rbp - 64]
    bt qword [r11], rcx
    setc al
    movzx eax, al
    mov [rbp - 96], rax
    xor eax, eax
    cmp qword [rbp - 96], 0
    jne .recompute_merge
    cmp qword [rbp - 48], CAT_TEXT
    je .recompute_merge
    cmp qword [rbp - 48], CAT_BLOB
    je .recompute_merge
    cmp qword [rbp - 48], CAT_VECTOR
    je .recompute_merge
    mov rdx, [rbp - 56]
    test rdx, rdx
    jz .recompute_raw
    mov rax, [rbp - 48]
    PASS_ARG5 rax
    PASS_ARG6 rdx
    mov ARG1, [rbp - 72]
    mov ARG2, [rbp - 88]
    mov ARG3, 1
    lea ARG4, [rbp - 104]
    call decompress_column
    cmp qword [rbp - 48], CAT_INT64
    je .recompute_dec8
    cmp qword [rbp - 48], CAT_BOOL
    je .recompute_dec1
    mov eax, [rbp - 104]
    cmp qword [rbp - 48], CAT_INT32
    jne .recompute_merge
    movsxd rax, eax
    jmp .recompute_merge
.recompute_dec8:
    mov rax, [rbp - 104]
    jmp .recompute_merge
.recompute_dec1:
    movzx eax, byte [rbp - 104]
    jmp .recompute_merge
.recompute_raw:
    mov rax, [rbp - 88]
    imul rax, [rbp - 80]
    add rax, [rbp - 72]
    cmp qword [rbp - 80], 8
    je .recompute_read8
    cmp qword [rbp - 80], 1
    je .recompute_read1
    mov eax, [rax]
    cmp qword [rbp - 48], CAT_INT32
    jne .recompute_merge
    movsxd rax, eax
    jmp .recompute_merge
.recompute_read8:
    mov rax, [rax]
    jmp .recompute_merge
.recompute_read1:
    movzx eax, byte [rax]
.recompute_merge:
    mov ARG2, rax
    mov ARG1, [rbp - 40]
    mov ARG3, [rbp - 48]
    mov ARG4, [rbp - 96]
    call zone_merge
    inc qword [rbp - 88]
    jmp .recompute_row
.recompute_done:
    xor eax, eax
    FRAME_END
    ret

; -----------------------------------------------------------------------------
; db_zone_replace_one(ctx, schema, logical_leaf, new_leaf, column)
;     -> EAX error, RDX replacement statistics root (zero when unavailable).
; Copies only the zone path that owns logical_leaf and recomputes the changed
; column exactly; every other leaf/column statistic remains byte-identical.
db_zone_replace_one:
    FRAME_BEGIN ZU_SIZE + 64, 1
    lea r10, [rbp - ZU_SIZE]
    mov [r10 + ZU_CTX], ARG1
    mov [r10 + ZU_SCHEMA], ARG2
    mov [r10 + ZU_LEAF_INDEX], ARG3
    mov [rbp - ZU_SIZE - 8], ARG4
    mov rax, IN_ARG5
    mov [rbp - ZU_SIZE - 16], rax
    mov r11, ARG1
    test qword [r11 + DB_FEATURES], CybouDB_FEATURE_ZONE_MAPS
    jz .replace_disabled
    mov r11, ARG2
    mov rax, [r11 + CAT_STATS_ROOT]
    mov [r10 + ZU_OLD_ROOT], rax
    test rax, rax
    jz .replace_disabled
    mov eax, [r11 + CAT_COUNT]
    mov [r10 + ZU_COLUMNS], rax
    mov rax, [r11 + CAT_OWNER]
    mov [r10 + ZU_OWNER], rax
    mov ARG1, [r10 + ZU_SCHEMA]
    call db_zone_stride
    lea r10, [rbp - ZU_SIZE]
    mov [r10 + ZU_STRIDE], rax
    mov ARG1, [r10 + ZU_SCHEMA]
    call db_zone_slots
    lea r10, [rbp - ZU_SIZE]
    mov [r10 + ZU_SLOTS], rax
    mov rcx, rax
    mov rax, [r10 + ZU_LEAF_INDEX]
    xor edx, edx
    div rcx
    mov [r10 + ZU_PAGE_INDEX], rax
    mov [r10 + ZU_FIRST_PAGE], rax
    mov [r10 + ZU_LAST_PAGE], rax
    mov ARG1, [r10 + ZU_CTX]
    mov ARG2, [r10 + ZU_SCHEMA]
    call db_pax_capacity
    lea r10, [rbp - ZU_SIZE]
    mov [r10 + ZU_CAPACITY], rax
    mov ARG1, [r10 + ZU_CTX]
    mov ARG2, [r10 + ZU_OLD_ROOT]
    call zone_page_addr
    lea r10, [rbp - ZU_SIZE]
    mov eax, [rax + ZONE_LEVEL]
    mov [r10 + ZU_OLD_LEVEL], rax
    mov [r10 + ZU_NEW_LEVEL], rax
    mov qword [r10 + ZU_DIR_ADDR], 0
    mov qword [r10 + ZU_DIR_INDEX], -1

    mov rax, 1                     ; copied statistics page
    cmp qword [r10 + ZU_NEW_LEVEL], ZONE_LEAF
    je .replace_need_ready
    inc rax                         ; root directory
    cmp qword [r10 + ZU_NEW_LEVEL], ZONE_ROOT
    jne .replace_need_ready
    inc rax                         ; middle directory
.replace_need_ready:
    mov [rbp - ZU_SIZE - 24], rax
    mov ARG1, [r10 + ZU_CTX]
    call db_bitmap_headroom
    cmp rax, [rbp - ZU_SIZE - 24]
    jb .replace_full
    lea ARG1, [rbp - ZU_SIZE]
    call zone_new_root
    test eax, eax
    jnz .replace_failed
    lea ARG1, [rbp - ZU_SIZE]
    call zone_open_page
    test eax, eax
    jnz .replace_failed

    lea r10, [rbp - ZU_SIZE]
    mov rax, [r10 + ZU_PAGE_INDEX]
    imul rax, [r10 + ZU_SLOTS]
    mov rcx, [r10 + ZU_LEAF_INDEX]
    sub rcx, rax
    imul rcx, [r10 + ZU_STRIDE]
    add rcx, [r10 + ZU_PAGE_ADDR]
    add rcx, ZONE_DATA
    mov rax, [rbp - ZU_SIZE - 16]
    imul rax, ZSTAT_SIZE
    add rcx, rax
    PASS_ARG5 rcx
    mov ARG1, [r10 + ZU_CTX]
    mov ARG2, [r10 + ZU_SCHEMA]
    mov ARG3, [rbp - ZU_SIZE - 8]
    mov ARG4, [rbp - ZU_SIZE - 16]
    call zone_recompute_column

    lea r10, [rbp - ZU_SIZE]
    mov ARG1, [r10 + ZU_PAGE_ADDR]
    call zone_seal
    lea r10, [rbp - ZU_SIZE]
    cmp qword [r10 + ZU_DIR_ADDR], 0
    je .replace_seal_root
    mov ARG1, [r10 + ZU_DIR_ADDR]
    call zone_seal
    lea r10, [rbp - ZU_SIZE]
.replace_seal_root:
    cmp qword [r10 + ZU_NEW_LEVEL], ZONE_LEAF
    je .replace_published
    mov ARG1, [r10 + ZU_ROOT_ADDR]
    call zone_seal
    lea r10, [rbp - ZU_SIZE]
.replace_published:
    mov rdx, [r10 + ZU_NEW_ROOT]
    xor eax, eax
    jmp .replace_done
.replace_disabled:
    xor edx, edx
    xor eax, eax
    jmp .replace_done
.replace_full:
    mov eax, CybouDB_E_FULL
    xor edx, edx
    jmp .replace_done
.replace_failed:
    xor edx, edx
.replace_done:
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  db_zone_update(ctx, schema, batch, rows_before, capacity)
;      -> EAX = error, RDX = the statistics root to publish
;
;  Merges a validated batch into the statistics of the leaves it lands in, by
;  the copy-the-changed-path rule the data itself follows. The caller stores
;  the returned root in the schema page it is already copying, so the data and
;  the statistics that describe it are published by one transaction.
; -----------------------------------------------------------------------------
db_zone_update:
    FRAME_BEGIN ZU_SIZE + 64, 0
    lea r10, [rbp - ZU_SIZE]
    mov [r10 + ZU_CTX], ARG1
    mov [r10 + ZU_SCHEMA], ARG2
    mov [r10 + ZU_BATCH], ARG3
    mov [r10 + ZU_ROWS_BEFORE], ARG4
    mov rax, IN_ARG5
    mov [r10 + ZU_CAPACITY], rax
    mov qword [r10 + ZU_DIR_ADDR], 0
    mov qword [r10 + ZU_DIR_INDEX], -1
    mov qword [r10 + ZU_NEW_ROOT], 0

    mov r11, ARG1
    test qword [r11 + DB_FEATURES], CybouDB_FEATURE_ZONE_MAPS
    jz .disabled

    mov r11, ARG2
    mov rax, [r11 + CAT_STATS_ROOT]
    mov [r10 + ZU_OLD_ROOT], rax
    test rax, rax
    jnz .stats_available
    cmp qword [r10 + ZU_ROWS_BEFORE], 0
    jne .disabled                   ; retain absent stats, never publish a suffix
.stats_available:
    mov eax, [r11 + CAT_COUNT]
    mov [r10 + ZU_COLUMNS], rax
    mov rax, [r11 + CAT_OWNER]
    mov [r10 + ZU_OWNER], rax

    mov r11, ARG3
    mov rax, [r11 + BATCH_ROWS]
    mov [r10 + ZU_BATCH_ROWS], rax
    test rax, rax
    jz .keep
    mov rax, [r11 + BATCH_VALUES]
    mov [r10 + ZU_VALUES], rax
    mov rax, [r11 + BATCH_NULLS]
    mov [r10 + ZU_NULLS], rax

    mov ARG1, [r10 + ZU_SCHEMA]
    call db_zone_stride
    lea r10, [rbp - ZU_SIZE]
    mov [r10 + ZU_STRIDE], rax
    mov ARG1, [r10 + ZU_SCHEMA]
    call db_zone_slots
    lea r10, [rbp - ZU_SIZE]
    mov [r10 + ZU_SLOTS], rax

    ; Which leaves the batch lands in, and which pages describe them
    mov rcx, [r10 + ZU_CAPACITY]
    mov rax, [r10 + ZU_ROWS_BEFORE]
    xor edx, edx
    div rcx
    mov [r10 + ZU_FIRST_LEAF], rax
    mov rax, [r10 + ZU_ROWS_BEFORE]
    add rax, [r10 + ZU_BATCH_ROWS]
    dec rax
    xor edx, edx
    div rcx
    mov [r10 + ZU_LAST_LEAF], rax

    mov rcx, [r10 + ZU_SLOTS]
    mov rax, [r10 + ZU_FIRST_LEAF]
    xor edx, edx
    div rcx
    mov [r10 + ZU_FIRST_PAGE], rax
    mov rax, [r10 + ZU_LAST_LEAF]
    xor edx, edx
    div rcx
    mov [r10 + ZU_LAST_PAGE], rax

    ; Depth is earned: one page needs no directory, and a root of directories
    ; only appears when one directory runs out of entries.
    mov rax, [r10 + ZU_LAST_PAGE]
    inc rax
    cmp rax, 1
    jbe .level_leaf
    cmp rax, ZONE_DIR_MAX
    jbe .level_dir
    mov qword [r10 + ZU_NEW_LEVEL], ZONE_ROOT
    jmp .level_known
.level_dir:
    mov qword [r10 + ZU_NEW_LEVEL], ZONE_DIR
    jmp .level_known
.level_leaf:
    mov qword [r10 + ZU_NEW_LEVEL], ZONE_LEAF
.level_known:

    ; Two levels of directories describe every table PAX itself can address.
    ; A table beyond that keeps no statistics rather than partial ones.
    mov rax, [r10 + ZU_LAST_PAGE]
    mov rcx, ZONE_DIR_MAX
    imul rcx, ZONE_DIR_MAX
    cmp rax, rcx
    jae .abandon

    ; What the tree looks like today
    mov qword [r10 + ZU_OLD_LEVEL], ZONE_LEAF
    cmp qword [r10 + ZU_OLD_ROOT], 0
    je .old_known
    mov ARG1, [r10 + ZU_CTX]
    mov ARG2, [r10 + ZU_OLD_ROOT]
    call zone_page_addr
    lea r10, [rbp - ZU_SIZE]
    mov ecx, [rax + ZONE_LEVEL]
    mov [r10 + ZU_OLD_LEVEL], rcx
.old_known:

    ; A single page promoted into a tree has to be relinked, and it is one
    ; page, so the cheapest correct thing is to visit it.
    cmp qword [r10 + ZU_OLD_LEVEL], ZONE_LEAF
    jne .range_ready
    cmp qword [r10 + ZU_OLD_ROOT], 0
    je .range_ready
    cmp qword [r10 + ZU_NEW_LEVEL], ZONE_LEAF
    je .range_ready
    mov qword [r10 + ZU_FIRST_PAGE], 0
.range_ready:

    ; Preflight: every statistics page the update rewrites, the directory
    ; each one hangs under, and the root above them.
    mov rax, [r10 + ZU_LAST_PAGE]
    sub rax, [r10 + ZU_FIRST_PAGE]
    inc rax
    cmp qword [r10 + ZU_NEW_LEVEL], ZONE_LEAF
    je .need_ready                  ; the root is the one page
    inc rax
    cmp qword [r10 + ZU_NEW_LEVEL], ZONE_ROOT
    jne .need_ready
    mov [rbp - ZU_SIZE - 8], rax
    mov rax, [r10 + ZU_LAST_PAGE]
    xor edx, edx
    mov rcx, ZONE_DIR_MAX
    div rcx
    mov r11, rax
    mov rax, [r10 + ZU_FIRST_PAGE]
    xor edx, edx
    div rcx
    sub r11, rax
    inc r11
    mov rax, [rbp - ZU_SIZE - 8]
    add rax, r11
.need_ready:
    mov [rbp - ZU_SIZE - 8], rax
    mov ARG1, [r10 + ZU_CTX]
    call db_bitmap_headroom
    cmp rax, [rbp - ZU_SIZE - 8]
    jb .full

    lea ARG1, [rbp - ZU_SIZE]
    call zone_new_root
    test eax, eax
    jnz .failed

    lea r10, [rbp - ZU_SIZE]
    mov rax, [r10 + ZU_FIRST_PAGE]
    mov [r10 + ZU_PAGE_INDEX], rax
.page_loop:
    lea ARG1, [rbp - ZU_SIZE]
    call zone_open_page
    test eax, eax
    jnz .failed

    lea r10, [rbp - ZU_SIZE]
    mov rax, [r10 + ZU_PAGE_INDEX]
    imul rax, [r10 + ZU_SLOTS]
    mov [r10 + ZU_LEAF_INDEX], rax
.leaf_loop:
    lea r10, [rbp - ZU_SIZE]
    mov rax, [r10 + ZU_LEAF_INDEX]
    cmp rax, [r10 + ZU_FIRST_LEAF]
    jb .next_leaf
    cmp rax, [r10 + ZU_LAST_LEAF]
    ja .page_done
    lea ARG1, [rbp - ZU_SIZE]
    call zone_merge_leaf
.next_leaf:
    lea r10, [rbp - ZU_SIZE]
    inc qword [r10 + ZU_LEAF_INDEX]
    mov rax, [r10 + ZU_PAGE_INDEX]
    inc rax
    imul rax, [r10 + ZU_SLOTS]
    cmp [r10 + ZU_LEAF_INDEX], rax
    jb .leaf_loop
.page_done:
    lea r10, [rbp - ZU_SIZE]
    mov ARG1, [r10 + ZU_PAGE_ADDR]
    call zone_seal
    lea r10, [rbp - ZU_SIZE]
    inc qword [r10 + ZU_PAGE_INDEX]
    mov rax, [r10 + ZU_PAGE_INDEX]
    cmp rax, [r10 + ZU_LAST_PAGE]
    jbe .page_loop

    ; Seal whatever stands above the pages, innermost first.
    cmp qword [r10 + ZU_DIR_ADDR], 0
    je .root_seal
    mov ARG1, [r10 + ZU_DIR_ADDR]
    call zone_seal
    lea r10, [rbp - ZU_SIZE]
.root_seal:
    cmp qword [r10 + ZU_NEW_LEVEL], ZONE_LEAF
    je .published                   ; the root is the page, already sealed
    mov ARG1, [r10 + ZU_ROOT_ADDR]
    call zone_seal
    lea r10, [rbp - ZU_SIZE]
.published:
    mov rdx, [r10 + ZU_NEW_ROOT]
    xor eax, eax
    jmp .done

.keep:
    mov rdx, [r10 + ZU_OLD_ROOT]
    xor eax, eax
    jmp .done
.disabled:
.abandon:
    xor edx, edx
    xor eax, eax
    jmp .done
.full:
    mov eax, CybouDB_E_FULL
    xor edx, edx
    jmp .done
.failed:
    xor edx, edx
.done:
    FRAME_END
    ret
