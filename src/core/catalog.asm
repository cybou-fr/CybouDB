; Fixed-height COW catalog: sorted table-id directory -> schema pages.
; Optional PAX data roots; no deletion or B-tree splits.
%include "cyboudb.inc"
BITS 64
default rel
extern crc32c
extern db_bitmap_candidate_payload, db_bitmap_headroom, db_bitmap_is_fresh
extern db_bitmap_deep
extern db_cow_alloc_page, db_cow_copy_page, db_cow_set_root
extern db_pax_validate, db_pax_check_new
extern db_zone_validate
global db_catalog_validate, db_catalog_put, db_catalog_get
global db_catalog_set_data, db_catalog_set_data_stats
section .text

; name_valid(pointer, width): nonempty ASCII identifier, NUL and zero padding.
name_valid:
    mov r10, ARG1
    mov r11, ARG2
    xor r8d, r8d
.char:
    movzx eax, byte [r10]
    test eax, eax
    jz .padding
    cmp eax, '_'
    je .next
    cmp eax, 'A'
    jb .digit
    cmp eax, 'Z'
    jbe .next
    cmp eax, 'a'
    jb .bad
    cmp eax, 'z'
    jbe .next
.digit:
    test r8, r8
    jz .bad
    cmp eax, '0'
    jb .bad
    cmp eax, '9'
    ja .bad
.next:
    inc r10
    inc r8
    dec r11
    jnz .char
.bad:
    xor eax, eax
    ret
.padding:
    test r8, r8
    jz .bad
.zero:
    cmp byte [r10], 0
    jne .bad
    inc r10
    dec r11
    jnz .zero
    mov eax, 1
    ret

; equal_name(a, b, padded_width), widths are multiples of eight.
equal_name:
    mov r10, ARG1
    mov r11, ARG2
    mov r8, ARG3
.loop:
    mov rax, [r10]
    cmp rax, [r11]
    jne .no
    add r10, 8
    add r11, 8
    sub r8, 8
    jnz .loop
    mov eax, 1
    ret
.no:
    xor eax, eax
    ret

; zero_tail(page, first_unused_offset), excluding the trailing checksum.
zero_tail:
    mov r10, ARG1
    mov r11, ARG2
.loop:
    cmp r11, CAT_CRC
    jae .yes
    cmp byte [r10 + r11], 0
    jne .no
    inc r11
    jmp .loop
.yes:
    mov eax, 1
    ret
.no:
    xor eax, eax
    ret

; schema_valid(image, ctx): header is stamped by put; validate count/body and
; gate incompatible column types on the database capability set.
schema_valid:
    FRAME_BEGIN 48, 0
    mov [rbp - 8], ARG1
    mov [rbp - 48], ARG2
    mov r10, ARG1
    mov eax, [r10 + CAT_COUNT]
    test eax, eax
    jz .bad
    cmp eax, CAT_MAX_COLUMNS
    ja .bad
    mov [rbp - 16], rax
    lea ARG1, [r10 + CAT_TABLE_NAME]
    mov ARG2, 32
    call name_valid
    test eax, eax
    jz .bad
    mov qword [rbp - 24], 0
.column:
    mov r10, [rbp - 24]
    shl r10, 5
    add r10, [rbp - 8]
    add r10, CAT_COLUMNS
    mov eax, [r10]
    cmp eax, CAT_INT32
    jb .bad
    cmp eax, CAT_BOOL
    jbe .type_ok
    cmp eax, CAT_BLOB
    ja .bad
    mov r11, [rbp - 48]
    test qword [r11 + DB_FEATURES], CybouDB_FEATURE_VARLEN
    jz .bad
.type_ok:
    test dword [r10 + 4], ~CAT_NULLABLE
    jnz .bad
    lea rax, [r10 + 8]
    mov [rbp - 40], rax
    mov ARG1, rax
    mov ARG2, 24
    call name_valid
    test eax, eax
    jz .bad
    mov qword [rbp - 32], 0
.duplicate:
    mov rax, [rbp - 32]
    cmp rax, [rbp - 24]
    jae .next
    shl rax, 5
    add rax, [rbp - 8]
    lea ARG2, [rax + CAT_COLUMNS + 8]
    mov ARG1, [rbp - 40]
    mov ARG3, 24
    call equal_name
    test eax, eax
    jnz .bad
    inc qword [rbp - 32]
    jmp .duplicate
.next:
    inc qword [rbp - 24]
    mov rax, [rbp - 24]
    cmp rax, [rbp - 16]
    jb .column
    shl rax, 5
    lea ARG2, [rax + CAT_COLUMNS]
    mov ARG1, [rbp - 8]
    call zero_tail
    FRAME_END
    ret
.bad:
    xor eax, eax
    FRAME_END
    ret

; page_valid(ctx, candidate_sb, id): mapped pointer or zero. Candidate map has
; already been validated by the allocation layer; check membership before use.
page_valid:
    FRAME_BEGIN 48, 0
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
    mov [rbp - 24], ARG3
    call db_bitmap_candidate_payload
    test eax, eax
    jz .bad
    mov r10, [rbp - 8]
    mov r11, [rbp - 16]
    mov r8, [rbp - 24]
    shl r8, CybouDB_PAGE_SHIFT
    add r8, [r10 + DB_BASE]
    mov [rbp - 32], r8
    cmp dword [r8 + CAT_MAGIC], CAT_MAGIC_VALUE
    jne .bad
    cmp dword [r8 + CAT_VERSION], CAT_VERSION_VALUE
    jne .bad
    mov rax, [rbp - 24]
    cmp [r8 + CAT_PAGE_ID], rax
    jne .bad
    mov rax, [r8 + CAT_GENERATION]
    test rax, rax
    jz .bad
    cmp rax, [r11 + SB_GENERATION]
    ja .bad
    mov r10, [rbp - 8]
    test qword [r10 + DB_FEATURES], CybouDB_FEATURE_PAX
    jz .reserved_all
    cmp dword [r8 + CAT_TYPE], CAT_SCHEMA
    jne .reserved_all
    ; The statistics root is the one reserved field a schema page may fill in,
    ; and only in a database created with the zone-map feature. Its graph is
    ; validated where the rest of the table's pages are, not here.
    cmp qword [r8 + CAT_STATS_ROOT], 0
    je .reserved_done
    test qword [r10 + DB_FEATURES], CybouDB_FEATURE_ZONE_MAPS
    jz .bad
    jmp .reserved_done
.reserved_all:
    mov rax, [r8 + CAT_RESERVED]
    or rax, [r8 + CAT_RESERVED + 8]
    or rax, [r8 + CAT_RESERVED + 16]
    jnz .bad
.reserved_done:
    mov r10, [rbp - 32]
    mov ARG3, [r10 + CAT_GENERATION]
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    call db_bitmap_deep
    test eax, eax
    jz .shallow
    mov ARG1, [rbp - 32]
    mov ARG2, CAT_CRC
    call crc32c
    mov r10, [rbp - 32]
    cmp [r10 + CAT_CRC], eax
    jne .bad
.shallow:
    mov rax, [rbp - 32]
    FRAME_END
    ret
.bad:
    xor eax, eax
    FRAME_END
    ret

; db_catalog_validate(ctx, candidate_sb): entire typed graph, no mutations.
db_catalog_validate:
    FRAME_BEGIN 80, 0
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
    mov r10, ARG1
    test qword [r10 + DB_FEATURES], CybouDB_FEATURE_CATALOG
    jz .valid
    mov r11, ARG2
    mov ARG3, [r11 + SB_ROOT_PAGE]
    test ARG3, ARG3
    jz .valid
    call page_valid
    test rax, rax
    jz .bad
    mov [rbp - 24], rax
    cmp dword [rax + CAT_TYPE], CAT_DIRECTORY
    jne .bad
    cmp qword [rax + CAT_OWNER], 0
    jne .bad
    mov ecx, [rax + CAT_COUNT]
    test ecx, ecx
    jz .bad
    cmp ecx, CAT_MAX_TABLES
    ja .bad
    mov [rbp - 32], rcx
    shl rcx, 4
    lea ARG2, [rcx + CAT_DATA]
    mov ARG1, rax
    call zero_tail
    test eax, eax
    jz .bad
    mov qword [rbp - 40], 0
    mov qword [rbp - 48], 0
.leaf:
    mov r10, [rbp - 40]
    shl r10, 4
    add r10, [rbp - 24]
    mov rax, [r10 + CAT_DATA]
    cmp rax, [rbp - 48]
    jbe .bad                        ; IDs nonzero and strictly increasing
    mov [rbp - 48], rax
    mov ARG3, [r10 + CAT_DATA + 8]
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    call page_valid
    test rax, rax
    jz .bad
    mov [rbp - 56], rax
    cmp dword [rax + CAT_TYPE], CAT_SCHEMA
    jne .bad
    mov r10, [rbp - 48]
    cmp [rax + CAT_OWNER], r10
    jne .bad
    mov r10, [rbp - 24]
    mov r11, [rax + CAT_GENERATION]
    cmp r11, [r10 + CAT_GENERATION]
    ja .bad
    mov ARG1, rax
    mov ARG2, [rbp - 8]
    call schema_valid
    test eax, eax
    jz .bad
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    mov ARG3, [rbp - 56]
    call db_pax_validate
    test eax, eax
    jz .bad
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    mov ARG3, [rbp - 56]
    call db_zone_validate
    test eax, eax
    jz .bad
    mov qword [rbp - 64], 0
.duplicate:
    mov r10, [rbp - 64]
    cmp r10, [rbp - 40]
    jae .next
    shl r10, 4
    add r10, [rbp - 24]
    mov rax, [r10 + CAT_DATA + 8]
    shl rax, CybouDB_PAGE_SHIFT
    mov r10, [rbp - 8]
    add rax, [r10 + DB_BASE]
    lea ARG2, [rax + CAT_TABLE_NAME]
    mov rax, [rbp - 56]
    lea ARG1, [rax + CAT_TABLE_NAME]
    mov ARG3, 32
    call equal_name
    test eax, eax
    jnz .bad
    inc qword [rbp - 64]
    jmp .duplicate
.next:
    inc qword [rbp - 40]
    mov rax, [rbp - 40]
    cmp rax, [rbp - 32]
    jb .leaf
.valid:
    mov eax, 1
    FRAME_END
    ret
.bad:
    xor eax, eax
    FRAME_END
    ret

; Validate the descriptor's current (possibly staged) catalog graph.
current_valid:
    FRAME_BEGIN CybouDB_SB_SIZE, 0
    mov r10, ARG1
    mov rax, [r10 + DB_GENERATION]
    cmp rax, -1
    je .generation
    inc rax
.generation:
    mov [rbp - CybouDB_SB_SIZE + SB_GENERATION], rax
    mov rax, [r10 + DB_ALLOC]
    mov [rbp - CybouDB_SB_SIZE + SB_ALLOC_PAGES], rax
    mov rax, [r10 + DB_BITMAP]
    mov [rbp - CybouDB_SB_SIZE + SB_BITMAP_ROOT], rax
    mov rax, [r10 + DB_ROOT]
    mov [rbp - CybouDB_SB_SIZE + SB_ROOT_PAGE], rax
    mov dword [rbp - CybouDB_SB_SIZE + SB_STAGED], 1
    lea ARG2, [rbp - CybouDB_SB_SIZE]
    call db_catalog_validate
    FRAME_END
    ret

; stamp(page, ctx): id is derived from its mapping address; body is preserved.
stamp:
    mov r10, ARG1
    mov r11, ARG2
    mov dword [r10 + CAT_MAGIC], CAT_MAGIC_VALUE
    mov dword [r10 + CAT_VERSION], CAT_VERSION_VALUE
    mov rax, r10
    sub rax, [r11 + DB_BASE]
    shr rax, CybouDB_PAGE_SHIFT
    mov [r10 + CAT_PAGE_ID], rax
    mov rax, [r11 + DB_GENERATION]
    inc rax
    mov [r10 + CAT_GENERATION], rax
    mov qword [r10 + CAT_RESERVED], 0
    mov qword [r10 + CAT_RESERVED + 8], 0
    mov qword [r10 + CAT_RESERVED + 16], 0
    ret

seal_page:
    FRAME_BEGIN 16, 0
    mov [rbp - 8], ARG1
    mov ARG2, CAT_CRC
    call crc32c
    mov r10, [rbp - 8]
    mov [r10 + CAT_CRC], eax
    FRAME_END
    ret

; db_catalog_get(ctx, table_id, out_schema_page): returns a page id, not an
; editable alias. The output remains unchanged on failure.
db_catalog_get:
    FRAME_BEGIN 32, 0
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
    mov [rbp - 24], ARG3
    mov r10, ARG1
    cmp qword [r10 + DB_BASE], 0
    je .state
    cmp qword [r10 + DB_MODE], -1
    je .state
    test qword [r10 + DB_FEATURES], CybouDB_FEATURE_CATALOG
    jz .state
    call current_valid
    test eax, eax
    jz .corrupt
    mov r10, [rbp - 8]
    mov rax, [r10 + DB_ROOT]
    test rax, rax
    jz .missing
    shl rax, CybouDB_PAGE_SHIFT
    add rax, [r10 + DB_BASE]
    mov ecx, [rax + CAT_COUNT]
    lea r10, [rax + CAT_DATA]
    mov r11, [rbp - 16]
.find:
    cmp r11, [r10]
    je .found
    add r10, 16
    dec ecx
    jnz .find
.missing:
    mov eax, CybouDB_E_NOTFOUND
    jmp .done
.found:
    mov rax, [r10 + 8]
    mov r11, [rbp - 24]
    mov [r11], rax
    xor eax, eax
    jmp .done
.state:
    mov eax, CybouDB_E_STATE
    jmp .done
.corrupt:
    mov eax, CybouDB_E_CATALOG
.done:
    FRAME_END
    ret

; db_catalog_put(ctx, nonzero_table_id, schema_image): insert/replace schema.
; Input needs count at +36, table name at +64, column records at +96 and zero
; tail. The core stamps the remaining header. Existing id means replacement.
; Validate and reserve capacity before allocating; root changes only at end.
db_catalog_put:
    FRAME_BEGIN 96, 0
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
    mov [rbp - 24], ARG3
    mov r10, ARG1
    cmp qword [r10 + DB_WRITABLE], 0
    je .readonly
    cmp qword [r10 + DB_MODE], 1
    jne .state
    test qword [r10 + DB_FEATURES], CybouDB_FEATURE_CATALOG
    jz .state
    cmp qword [r10 + DB_GENERATION], -1
    je .generation
    test ARG2, ARG2
    jz .schema
    mov ARG1, [rbp - 24]
    mov ARG2, [rbp - 8]
    call schema_valid
    test eax, eax
    jz .schema
    mov ARG1, [rbp - 8]
    call current_valid
    test eax, eax
    jz .corrupt
    mov qword [rbp - 32], 0           ; old root address
    mov qword [rbp - 40], 0           ; old count
    mov qword [rbp - 48], 0           ; insertion index
    mov qword [rbp - 56], 0           ; replacing existing id
    mov r10, [rbp - 8]
    mov rax, [r10 + DB_ROOT]
    test rax, rax
    jz .capacity
    shl rax, CybouDB_PAGE_SHIFT
    add rax, [r10 + DB_BASE]
    mov [rbp - 32], rax
    mov eax, [rax + CAT_COUNT]
    mov [rbp - 40], rax
    mov [rbp - 48], rax
    mov qword [rbp - 64], 0
.scan:
    mov r10, [rbp - 64]
    shl r10, 4
    add r10, [rbp - 32]
    mov rax, [r10 + CAT_DATA]
    cmp rax, [rbp - 16]
    jb .name
    mov rax, [rbp - 64]
    cmp rax, [rbp - 48]
    jae .check_equal
    mov [rbp - 48], rax
.check_equal:
    mov rax, [r10 + CAT_DATA]
    cmp rax, [rbp - 16]
    jne .name
    mov rax, [r10 + CAT_DATA + 8]
    shl rax, CybouDB_PAGE_SHIFT
    mov r11, [rbp - 8]
    add rax, [r11 + DB_BASE]
    cmp qword [rax + CAT_DATA_ROOT], 0
    jne .state                      ; no schema replacement over existing rows
    mov qword [rbp - 56], 1
    jmp .next
.name:
    mov rax, [r10 + CAT_DATA + 8]
    shl rax, CybouDB_PAGE_SHIFT
    mov r11, [rbp - 8]
    add rax, [r11 + DB_BASE]
    lea ARG2, [rax + CAT_TABLE_NAME]
    mov rax, [rbp - 24]
    lea ARG1, [rax + CAT_TABLE_NAME]
    mov ARG3, 32
    call equal_name
    test eax, eax
    jnz .schema
.next:
    inc qword [rbp - 64]
    mov rax, [rbp - 64]
    cmp rax, [rbp - 40]
    jb .scan
.capacity:
    cmp qword [rbp - 56], 0
    jne .space
    cmp qword [rbp - 40], CAT_MAX_TABLES
    jae .catalog_full
.space:
    mov ARG1, [rbp - 8]
    call db_bitmap_headroom
    cmp rax, 2                      ; new schema and new directory
    jb .full
    mov r10, [rbp - 8]
    mov ARG1, r10
    lea ARG2, [rbp - 72]             ; new schema page id
    call db_cow_alloc_page
    test eax, eax
    jnz .done
    mov r10, [rbp - 8]
    mov rax, [rbp - 72]
    shl rax, CybouDB_PAGE_SHIFT
    add rax, [r10 + DB_BASE]
    mov [rbp - 88], rax
    mov r11, [rbp - 24]
    mov ecx, CybouDB_PAGE_SIZE / 8
.copy_schema:
    mov rdx, [r11]
    mov [rax], rdx
    add r11, 8
    add rax, 8
    dec ecx
    jnz .copy_schema
    mov ARG1, [rbp - 88]
    mov ARG2, [rbp - 8]
    call stamp
    mov r10, [rbp - 88]
    mov rax, [rbp - 16]
    mov [r10 + CAT_OWNER], rax
    mov dword [r10 + CAT_TYPE], CAT_SCHEMA
    mov ARG1, r10
    call seal_page
    mov r10, [rbp - 8]
    mov ARG1, r10
    cmp qword [rbp - 32], 0
    je .new_root
    mov ARG2, [r10 + DB_ROOT]
    lea ARG3, [rbp - 80]
    call db_cow_copy_page
    jmp .root_ready
.new_root:
    lea ARG2, [rbp - 80]
    call db_cow_alloc_page
.root_ready:
    test eax, eax
    jnz .done
    mov r10, [rbp - 8]
    mov rax, [rbp - 80]
    shl rax, CybouDB_PAGE_SHIFT
    add rax, [r10 + DB_BASE]
    mov [rbp - 88], rax
    mov ARG1, rax
    mov ARG2, r10
    call stamp
    mov r10, [rbp - 88]
    mov qword [r10 + CAT_OWNER], 0
    mov dword [r10 + CAT_TYPE], CAT_DIRECTORY
    mov r8, [rbp - 40]
    cmp qword [rbp - 56], 0
    jne .entry
    mov r9, r8
    inc r8
.shift:
    cmp r9, [rbp - 48]
    jbe .entry
    mov r11, r9
    shl r11, 4
    mov rax, [r10 + CAT_DATA + r11 - 16]
    mov [r10 + CAT_DATA + r11], rax
    mov rax, [r10 + CAT_DATA + r11 - 8]
    mov [r10 + CAT_DATA + r11 + 8], rax
    dec r9
    jmp .shift
.entry:
    mov [r10 + CAT_COUNT], r8d
    mov r11, [rbp - 48]
    shl r11, 4
    mov rax, [rbp - 16]
    mov [r10 + CAT_DATA + r11], rax
    mov rax, [rbp - 72]
    mov [r10 + CAT_DATA + r11 + 8], rax
    mov ARG1, r10
    call seal_page
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 80]
    call db_cow_set_root
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
.schema:
    mov eax, CybouDB_E_SCHEMA
    jmp .done
.corrupt:
    mov eax, CybouDB_E_CATALOG
    jmp .done
.full:
    mov eax, CybouDB_E_FULL
    jmp .done
.catalog_full:
    mov eax, CybouDB_E_CATALOG_FULL
.done:
    FRAME_END
    ret

; Internal append publication: validate a fresh PAX data root, copy the schema and
; directory, then stage their root. db_pax_insert preflights the entire path.
; db_catalog_set_data(ctx, table_id, new_data_root)
; db_catalog_set_data(ctx, owner, data_root): publish a data root and keep
; whatever statistics root the schema page already carried.
db_catalog_set_data:
    FRAME_BEGIN 0, 1
    mov ARG4, -1
    call db_catalog_set_data_stats
    FRAME_END
    ret

; db_catalog_set_data_stats(ctx, owner, data_root, stats_root): the same, with
; the statistics that describe those rows. A stats_root of -1 keeps what the
; schema page holds, which is what a caller that wrote no statistics wants.
; Both roots land in one copied schema page, so a generation can never hold
; data and statistics that disagree.
db_catalog_set_data_stats:
    FRAME_BEGIN 96, 0
    mov [rbp - 80], ARG4
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
    mov ARG2, ARG3                  ; the root must be a page this txn allocated
    call db_bitmap_is_fresh
    test eax, eax
    jz .page
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    lea ARG3, [rbp - 32]
    call db_catalog_get
    test eax, eax
    jnz .done
    mov r10, [rbp - 8]
    mov rax, [rbp - 32]
    shl rax, CybouDB_PAGE_SHIFT
    add rax, [r10 + DB_BASE]
    mov [rbp - 72], rax
    mov ARG1, r10
    mov ARG2, rax
    mov ARG3, [rbp - 24]
    call db_pax_check_new
    test rax, rax
    jz .page
    mov eax, [rax + PAX_ROWS]
    mov [rbp - 40], rax
    mov r11, [rbp - 72]
    cmp rax, [r11 + CAT_TABLE_ROWS]
    jbe .rows
    mov r10, [rbp - 8]
    mov ARG1, [rbp - 8]
    call db_bitmap_headroom
    cmp rax, 2                      ; new schema and new catalog root
    jb .full
    mov r10, [rbp - 8]
    mov rax, [r10 + DB_ROOT]
    mov [rbp - 48], rax
    mov ARG1, r10
    mov ARG2, [rbp - 32]
    lea ARG3, [rbp - 56]
    call db_cow_copy_page
    test eax, eax
    jnz .done
    mov r10, [rbp - 8]
    mov rax, [rbp - 56]
    shl rax, CybouDB_PAGE_SHIFT
    add rax, [r10 + DB_BASE]
    mov [rbp - 72], rax
    mov ARG1, rax
    mov ARG2, r10
    call stamp
    mov r10, [rbp - 72]
    mov rax, [rbp - 24]
    mov [r10 + CAT_DATA_ROOT], rax
    mov rax, [rbp - 40]
    mov [r10 + CAT_TABLE_ROWS], rax
    mov rax, [rbp - 80]
    cmp rax, -1
    je .stats_kept
    mov [r10 + CAT_STATS_ROOT], rax
.stats_kept:
    mov ARG1, r10
    call seal_page
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 48]
    lea ARG3, [rbp - 64]
    call db_cow_copy_page
    test eax, eax
    jnz .done
    mov r10, [rbp - 8]
    mov rax, [rbp - 64]
    shl rax, CybouDB_PAGE_SHIFT
    add rax, [r10 + DB_BASE]
    mov [rbp - 72], rax
    mov ARG1, rax
    mov ARG2, r10
    call stamp
    mov r10, [rbp - 72]
    mov ecx, [r10 + CAT_COUNT]
    mov r11, [rbp - 16]
    add r10, CAT_DATA
.entry:
    cmp [r10], r11
    je .found
    add r10, 16
    dec ecx
    jnz .entry
    mov eax, CybouDB_E_CATALOG
    jmp .done
.found:
    mov rax, [rbp - 56]
    mov [r10 + 8], rax
    mov ARG1, [rbp - 72]
    call seal_page
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 64]
    call db_cow_set_root
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
.page:
    mov eax, CybouDB_E_PAX
    jmp .done
.rows:
    mov eax, CybouDB_E_ROWS
    jmp .done
.full:
    mov eax, CybouDB_E_FULL
.done:
    FRAME_END
    ret
