; Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
; SPDX-License-Identifier: Apache-2.0
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
extern index_page_valid
extern queue_page_valid
extern stream_page_valid
extern db_zone_validate
global db_catalog_validate, db_catalog_put, db_catalog_get, db_catalog_drop
global db_catalog_put_index, db_catalog_set_index_root, db_catalog_page
global db_catalog_put_queue, db_catalog_put_stream
global db_catalog_edit, db_catalog_seal
global db_catalog_set_data, db_catalog_set_data_stats, db_catalog_replace_data
global db_catalog_replace_data_stats
global db_catalog_truncate_data
section .data
; Catalog pages this process validated. A statement proportional to the
; table shows up here before it shows up in a stopwatch.
global catalog_pages_validated
global catalog_entry_in
catalog_pages_validated: dq 0

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
    jbe .check_varlen
    cmp eax, CAT_VECTOR
    je .check_vector
    jmp .bad
.check_varlen:
    mov r11, [rbp - 48]
    test qword [r11 + DB_FEATURES], CybouDB_FEATURE_VARLEN
    jz .bad
    jmp .type_ok
.check_vector:
    mov r11, [rbp - 48]
    test qword [r11 + DB_FEATURES], CybouDB_FEATURE_VECTOR
    jz .bad
    mov eax, [r10 + 4]
    test ax, ~CAT_NULLABLE
    jnz .bad
    shr eax, 16
    test eax, eax
    jz .bad
    cmp eax, 4096
    ja .bad
    jmp .name_check
.type_ok:
    test dword [r10 + 4], ~CAT_NULLABLE
    jnz .bad
.name_check:
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
    inc qword [rel catalog_pages_validated]
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
    ; A queue page keeps its head and its tail in the reserved span, and
    ; answers for them where its segments are validated. It is checked before
    ; the PAX gate below because a queue needs no row storage to be a queue.
    cmp dword [r8 + CAT_TYPE], CAT_QUEUE
    jne .not_queue
    test qword [r10 + DB_FEATURES], CybouDB_FEATURE_QUEUE
    jz .bad
    jmp .reserved_done
.not_queue:
    ; A stream page keeps its two positions in the same span, and answers for
    ; them where its cursors and segments are validated.
    cmp dword [r8 + CAT_TYPE], CAT_STREAM
    jne .not_stream
    test qword [r10 + DB_FEATURES], CybouDB_FEATURE_STREAM
    jz .bad
    jmp .reserved_done
.not_stream:
    test qword [r10 + DB_FEATURES], CybouDB_FEATURE_PAX
    jz .reserved_all
    ; An index page keeps its root, column, flags and entry count in the same
    ; span, and answers for them where its tree is validated.
    cmp dword [r8 + CAT_TYPE], CAT_INDEX
    jne .not_index
    test qword [r10 + DB_FEATURES], CybouDB_FEATURE_INDEX
    jz .bad
    jmp .reserved_done
.not_index:
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
    mov r10, [rbp - 48]
    cmp [rax + CAT_OWNER], r10
    jne .bad                        ; a page answers to the id that names it
    mov r10, [rbp - 24]
    mov r11, [rax + CAT_GENERATION]
    cmp r11, [r10 + CAT_GENERATION]
    ja .bad

    ; Did the published directory name this same id at this same page? Then
    ; the object under it is the object the commit that published it proved,
    ; because copy-on-write forbids rewriting a page in place. The whole
    ; subtree is inherited: not walked, not counted, not read.
    ;
    ; The object's own page is still checked just above - that is one page and
    ; does not grow with anything. What is skipped is the walk beneath it,
    ; which is where the cost proportional to retained data lives.
    ;
    ; docs/COMMIT_VALIDATION.md says what this narrows and why it is only
    ; honest now that `cyboudb check` reports damage a commit no longer looks
    ; for.
    mov r10, [rbp - 56]
    mov eax, [r10 + CAT_TYPE]
    mov [rbp - 72], rax
    mov r10, [rbp - 8]
    cmp qword [r10 + DB_VERIFY], 0
    jne .walk_object                ; `cyboudb check` inherits nothing
    mov r11, [r10 + DB_SB_PTR]
    test r11, r11
    jz .walk_object                 ; nothing published yet to inherit from
    mov ARG2, [r11 + SB_ROOT_PAGE]
    mov ARG3, [rbp - 48]
    mov ARG4, [rbp - 72]
    mov ARG1, r10
    call catalog_entry_in
    test rax, rax
    jz .walk_object                 ; new object, or one it did not hold
    cmp rax, [rbp - 56]
    je .named                       ; the same page: nothing to prove again
.walk_object:
    mov r10, [rbp - 56]
    cmp dword [r10 + CAT_TYPE], CAT_INDEX
    je .index_entry
    cmp dword [r10 + CAT_TYPE], CAT_QUEUE
    je .queue_entry
    cmp dword [r10 + CAT_TYPE], CAT_STREAM
    je .stream_entry
    cmp dword [r10 + CAT_TYPE], CAT_SCHEMA
    jne .bad
    mov ARG1, r10
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
    jmp .named
.index_entry:
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    mov ARG3, [rbp - 56]
    call index_page_valid
    test eax, eax
    jz .bad
    jmp .named
.queue_entry:
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    mov ARG3, [rbp - 56]
    call queue_page_valid
    test eax, eax
    jz .bad
    jmp .named
.stream_entry:
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    mov ARG3, [rbp - 56]
    call stream_page_valid
    test eax, eax
    jz .bad
.named:
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
; current_valid(ctx): the typed graph as this transaction has staged it.
;
; The walk deep-verifies every page whose generation matches the candidate
; superblock, and the candidate stands at the staged generation, so it checks
; exactly the pages this transaction wrote. Repeating that per append is
; quadratic - the Nth append re-checksums what the first N-1 staged - so the
; result is remembered for the length of the transaction. What the flag is
; allowed to skip is only work this writer would be doing on its own staged
; pages: the single-writer lock means nothing else can have touched them, and
; db_commit validates the graph again before any of it becomes durable.
current_valid:
    FRAME_BEGIN CybouDB_SB_SIZE + 16, 0
    mov [rbp - CybouDB_SB_SIZE - 8], ARG1
    mov r10, ARG1
    cmp qword [r10 + DB_WRITABLE], 0
    je .walk                        ; a reader has staged nothing to trust
    cmp qword [r10 + DB_VALIDATED], 0
    je .walk
    mov eax, 1
    FRAME_END
    ret
.walk:
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
    test eax, eax
    jz .done
    mov r10, [rbp - CybouDB_SB_SIZE - 8]
    cmp qword [r10 + DB_WRITABLE], 0
    je .done                        ; nothing to remember on a read-only open
    mov qword [r10 + DB_VALIDATED], 1
    mov eax, 1
.done:
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

; -----------------------------------------------------------------------------
;  catalog_entry_in(ARG1 = ctx, ARG2 = directory page, ARG3 = object id,
;                   ARG4 = expected type) -> RAX: the object page's address,
;                   or 0.
;
;  db_catalog_get answers from the live root. This answers from whichever
;  directory it is handed, which is what lets a commit ask what the *published*
;  generation held for an object while the staged one is being proved.
;
;  It returns 0 rather than refusing whenever anything is not as expected:
;  every caller uses the answer only to decide whether a proof may be
;  inherited, so "I do not know" has to mean "prove it the long way".
;
;  Local slots: [rbp-8]=ctx, [rbp-16]=id, [rbp-24]=type
; -----------------------------------------------------------------------------
catalog_entry_in:
    FRAME_BEGIN 32, 0
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG3
    mov [rbp - 24], ARG4
    mov r10, ARG1
    mov rax, ARG2
    cmp rax, CybouDB_MIN_PAGES
    jb .none                            ; 0, and the header, are not directories
    cmp rax, [r10 + DB_PAGES]
    jae .none                           ; past the end of the file
    cmp qword [r10 + DB_BASE], 0
    je .none
    shl rax, CybouDB_PAGE_SHIFT
    add rax, [r10 + DB_BASE]
    cmp dword [rax + CAT_TYPE], CAT_DIRECTORY
    jne .none
    mov ecx, [rax + CAT_COUNT]
    test ecx, ecx
    jz .none
    cmp ecx, CAT_MAX_TABLES
    ja .none
    lea r10, [rax + CAT_DATA]
    mov r11, [rbp - 16]
.find:
    cmp r11, [r10]
    je .found
    add r10, 16
    dec ecx
    jnz .find
.none:
    xor eax, eax
    FRAME_END
    ret
.found:
    mov rax, [r10 + 8]
    mov r10, [rbp - 8]
    cmp rax, CybouDB_MIN_PAGES
    jb .none
    cmp rax, [r10 + DB_PAGES]
    jae .none
    shl rax, CybouDB_PAGE_SHIFT
    add rax, [r10 + DB_BASE]
    ; It has to be the object that was asked about, of the type that was
    ; asked about, or the answer is not usable.
    mov ecx, [rbp - 24]
    cmp [rax + CAT_TYPE], ecx
    jne .none
    mov r11, [rbp - 16]
    cmp [rax + CAT_OWNER], r11
    jne .none
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
    mov r11d, CAT_SCHEMA
    jmp catalog_put_common
; db_catalog_put_index(ctx, index id, page image): the same insertion, for the
; other kind of page a directory entry can name. What differs is the shape the
; image has to have and the type stamped into it; finding the slot, copying the
; directory and publishing the new root is work worth having once.
db_catalog_put_index:
    mov r11d, CAT_INDEX
    jmp catalog_put_common
; db_catalog_put_queue(ctx, queue id, page image): and for the fourth kind. A
; queue arrives empty - head, tail, segments and the directory all zero - so
; what the shape check is really saying is that nothing has been written into
; the page a caller is asking the catalog to publish.
db_catalog_put_queue:
    mov r11d, CAT_QUEUE
    jmp catalog_put_common
; db_catalog_put_stream(ctx, stream id, page image): and for the fifth kind. A
; stream arrives empty too - no records, no segments, no cursors - so the shape
; check says the same thing about a page a caller is asking to have published.
db_catalog_put_stream:
    mov r11d, CAT_STREAM
catalog_put_common:
    FRAME_BEGIN 96, 0
    mov [rbp - 96], r11
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
    cmp qword [rbp - 96], CAT_STREAM
    je .shape_stream
    cmp qword [rbp - 96], CAT_QUEUE
    je .shape_queue
    cmp qword [rbp - 96], CAT_INDEX
    je .shape_index
    mov ARG1, [rbp - 24]
    mov ARG2, [rbp - 8]
    call schema_valid
    test eax, eax
    jz .schema
    jmp .shape_ok
.shape_index:
    mov r10, [rbp - 8]
    test qword [r10 + DB_FEATURES], CybouDB_FEATURE_INDEX
    jz .state
    mov r11, [rbp - 24]
    mov eax, [r11 + IDX_COLUMN]
    cmp eax, CAT_MAX_COLUMNS
    jae .schema
    mov eax, [r11 + IDX_FLAGS]
    cmp eax, IDX_UNIQUE
    ja .schema
    cmp qword [r11 + IDX_TABLE], 0
    je .schema
    cmp qword [r11 + IDX_ROOT], 0
    jne .schema                     ; a new index starts empty
    cmp qword [r11 + IDX_ROWS], 0
    jne .schema
    cmp byte [r11 + IDX_NAME], 0
    je .schema
    jmp .shape_ok
.shape_queue:
    mov r10, [rbp - 8]
    test qword [r10 + DB_FEATURES], CybouDB_FEATURE_QUEUE
    jz .state
    mov r11, [rbp - 24]
    cmp byte [r11 + Q_NAME], 0
    je .schema
    cmp dword [r11 + Q_SEGMENTS], 0
    jne .schema
    cmp qword [r11 + Q_HEAD], 0
    jne .schema
    cmp qword [r11 + Q_TAIL], 0
    jne .schema
    cmp qword [r11 + Q_FIRST_SEG], 0
    jne .schema
    jmp .shape_ok
.shape_stream:
    mov r10, [rbp - 8]
    test qword [r10 + DB_FEATURES], CybouDB_FEATURE_STREAM
    jz .state
    mov r11, [rbp - 24]
    cmp byte [r11 + S_NAME], 0
    je .schema
    cmp dword [r11 + S_SEGMENTS], 0
    jne .schema
    cmp qword [r11 + S_FIRST], 0
    jne .schema
    cmp qword [r11 + S_END], 0
    jne .schema
    cmp qword [r11 + S_FIRST_SEG], 0
    jne .schema
    cmp qword [r11 + S_CURSORS], 0
    jne .schema
.shape_ok:
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
    cmp qword [rbp - 96], CAT_SCHEMA
    jne .state                      ; an index is never replaced in place
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
    mov rax, [rbp - 96]
    mov [r10 + CAT_TYPE], eax
    cmp rax, CAT_INDEX
    jne .typed
    ; stamp clears the reserved span, which is where an index keeps its column
    ; and its flags. A schema starts those fields at zero and does not care.
    mov r11, [rbp - 24]
    mov eax, [r11 + IDX_COLUMN]
    mov [r10 + IDX_COLUMN], eax
    mov eax, [r11 + IDX_FLAGS]
    mov [r10 + IDX_FLAGS], eax
.typed:
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

; db_catalog_drop(ctx, table_id): remove a table from the catalog directory.
; If it was the only table, stages a zero root (empty catalog).
; Otherwise, allocates a new directory page, copies the remaining entries,
; seals the page, and stages the new directory root.
; The dropped table's schema and data pages are retired and will be reclaimed
; when unreferenced by both active generations.
db_catalog_drop:
    FRAME_BEGIN 64, 0
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
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
    jz .notfound
    mov ARG1, [rbp - 8]
    call current_valid
    test eax, eax
    jz .corrupt

    mov r10, [rbp - 8]
    mov rax, [r10 + DB_ROOT]
    test rax, rax
    jz .notfound
    shl rax, CybouDB_PAGE_SHIFT
    add rax, [r10 + DB_BASE]
    mov [rbp - 24], rax
    mov eax, [rax + CAT_COUNT]
    test eax, eax
    jz .notfound
    mov [rbp - 32], rax

    mov qword [rbp - 40], 0
.scan:
    mov r10, [rbp - 40]
    shl r10, 4
    add r10, [rbp - 24]
    mov rax, [r10 + CAT_DATA]
    cmp rax, [rbp - 16]
    je .found
    inc qword [rbp - 40]
    mov rax, [rbp - 40]
    cmp rax, [rbp - 32]
    jb .scan
    jmp .notfound

.found:
    cmp qword [rbp - 32], 1
    jne .drop_multi
    mov ARG1, [rbp - 8]
    xor ARG2, ARG2
    call db_cow_set_root
    xor eax, eax
    jmp .done

.drop_multi:
    mov ARG1, [rbp - 8]
    call db_bitmap_headroom
    cmp rax, 1
    jb .full

    mov r10, [rbp - 8]
    mov ARG1, r10
    lea ARG2, [rbp - 48]
    call db_cow_alloc_page
    test eax, eax
    jnz .done

    mov r10, [rbp - 8]
    mov rax, [rbp - 48]
    shl rax, CybouDB_PAGE_SHIFT
    add rax, [r10 + DB_BASE]
    mov [rbp - 56], rax

    mov ARG1, rax
    mov ARG2, r10
    call stamp

    mov r10, [rbp - 56]
    mov qword [r10 + CAT_OWNER], 0
    mov dword [r10 + CAT_TYPE], CAT_DIRECTORY
    mov eax, [rbp - 32]
    dec eax
    mov [r10 + CAT_COUNT], eax

    mov r8, [rbp - 24]
    mov r9, [rbp - 56]
    xor ecx, ecx
.copy_before:
    cmp rcx, [rbp - 40]
    jae .copy_after_start
    mov r10, rcx
    shl r10, 4
    mov rax, [r8 + CAT_DATA + r10]
    mov [r9 + CAT_DATA + r10], rax
    mov rax, [r8 + CAT_DATA + r10 + 8]
    mov [r9 + CAT_DATA + r10 + 8], rax
    inc rcx
    jmp .copy_before

.copy_after_start:
    mov rdx, [rbp - 40]
    mov rcx, rdx
    inc rcx
.copy_after:
    cmp rcx, [rbp - 32]
    jae .zero_tail_start
    mov r10, rcx
    shl r10, 4
    mov r11, rdx
    shl r11, 4
    mov rax, [r8 + CAT_DATA + r10]
    mov [r9 + CAT_DATA + r11], rax
    mov rax, [r8 + CAT_DATA + r10 + 8]
    mov [r9 + CAT_DATA + r11 + 8], rax
    inc rcx
    inc rdx
    jmp .copy_after

.zero_tail_start:
    mov rax, [rbp - 32]
    dec rax
    shl rax, 4
    add rax, CAT_DATA
    mov r10, [rbp - 56]
    xor edx, edx
.zero_loop:
    cmp rax, CAT_CRC
    jae .seal
    mov byte [r10 + rax], dl
    inc rax
    jmp .zero_loop

.seal:
    mov ARG1, [rbp - 56]
    call seal_page

    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 48]
    call db_cow_set_root
    xor eax, eax
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
.notfound:
    mov eax, CybouDB_E_NOTFOUND
    jmp .done
.corrupt:
    mov eax, CybouDB_E_CATALOG
    jmp .done
.full:
    mov eax, CybouDB_E_FULL
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
    FRAME_BEGIN 0, 1
    xor rax, rax                    ; append publication requires row growth
    PASS_ARG5 rax
    call catalog_publish_data
    FRAME_END
    ret

; db_catalog_replace_data(ctx, owner, data_root): UPDATE publication. Unlike
; append, replacement must preserve the exact row count. Statistics are reset
; atomically with the new schema page: retaining stats for the old values would
; make deep validation reject the generation (and could mis-prune predicates).
db_catalog_replace_data:
    FRAME_BEGIN 0, 1
    xor ARG4, ARG4                  ; no zone-map describes the rewritten leaf
    mov rax, 1
    PASS_ARG5 rax
    call catalog_publish_data
    FRAME_END
    ret

; db_catalog_replace_data_stats(ctx, owner, data_root, stats_root): publish an
; exact-row replacement together with freshly recomputed zone metadata.
db_catalog_replace_data_stats:
    FRAME_BEGIN 0, 1
    mov rax, 1
    PASS_ARG5 rax
    call catalog_publish_data
    FRAME_END
    ret

; db_catalog_truncate_data(ctx, owner): DELETE-V1 publication. The table keeps
; its schema and loses every row: data root, statistics root and row count all
; return to the state CREATE TABLE left them in, which is the one state the
; validator, the scan cursor and the append path are already written for. No
; page is freed here; the retired graph is reclaimed once neither recoverable
; superblock still references it.
db_catalog_truncate_data:
    FRAME_BEGIN 0, 1
    xor ARG3, ARG3                  ; data root returns to zero
    xor ARG4, ARG4                  ; and so does the statistics root
    mov rax, 2
    PASS_ARG5 rax
    call catalog_publish_data
    FRAME_END
    ret

; catalog_publish_data(ctx, owner, data_root, stats_root, replace_mode)
;   replace_mode 0 = append (row count must grow)
;   replace_mode 1 = replace (row count must be preserved exactly)
;   replace_mode 2 = truncate (roots zeroed, row count returns to zero)
catalog_publish_data:
    FRAME_BEGIN 96, 0
    mov rax, IN_ARG5
    mov [rbp - 88], rax
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
    cmp qword [rbp - 88], 2
    je .truncate_schema
    mov ARG2, ARG3                  ; the root must be a page this txn allocated
    call db_bitmap_is_fresh
    test eax, eax
    jz .page
.truncate_schema:
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
    cmp qword [rbp - 88], 2
    je .truncate_rows
    mov ARG1, r10
    mov ARG2, rax
    mov ARG3, [rbp - 24]
    call db_pax_check_new
    test rax, rax
    jz .page
    mov eax, [rax + PAX_ROWS]
    mov [rbp - 40], rax
    mov r11, [rbp - 72]
    cmp qword [rbp - 88], 0
    jne .replacement_rows
    cmp rax, [r11 + CAT_TABLE_ROWS]
    jbe .rows
    jmp .rows_ok
.replacement_rows:
    cmp rax, [r11 + CAT_TABLE_ROWS]
    jne .rows
    jmp .rows_ok
.truncate_rows:
    mov qword [rbp - 40], 0
.rows_ok:
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

; -----------------------------------------------------------------------------
;  db_catalog_set_index_root(ctx, index id, tree root, entries)
;      -> RAX: result code
;
;  Publishes a tree the caller has just built or edited: the index page is
;  copied, given the new root and count, and the directory is copied to name
;  the copy. Nothing here knows what changed inside the tree - that is the
;  point of the root being one page id.
;
;  The root must be a page this transaction allocated, which is what stops a
;  published generation from being made to point at a tree it never wrote.
;
;  Local slots: [rbp-8]=ctx, [rbp-16]=index id, [rbp-24]=root, [rbp-32]=entries,
;               [rbp-40]=index page id, [rbp-48]=old directory,
;               [rbp-56]=new index page, [rbp-64]=new directory, [rbp-72]=address
; -----------------------------------------------------------------------------
;  db_catalog_edit(ctx, id, out_address) -> RAX: result
;
;  Copy the page a directory entry names, publish the copy in that entry, and
;  hand back somewhere to write. What a caller does with it is the caller's;
;  what the catalog owns is that the new page is the one the generation will
;  reach, and db_catalog_seal is how the caller says it is finished.
;
;  The directory is repointed before the contents are final, which is safe
;  because nothing reads a staged graph until the commit validates it, and the
;  seal happens first. A statement that fails in between is rolled back whole.
;
;  stamp clears the reserved span, so a caller keeping anything there - a
;  queue keeps its head and its tail - writes it back afterwards. It was going
;  to anyway; that is what it asked to edit the page for.
;
;  Local slots: [rbp-8]=ctx, [rbp-16]=id, [rbp-24]=out, [rbp-32]=old page id,
;               [rbp-40]=old root, [rbp-48]=new page id, [rbp-56]=new root id,
;               [rbp-64]=address
; -----------------------------------------------------------------------------
db_catalog_edit:
    FRAME_BEGIN 96, 0
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
    mov [rbp - 24], ARG3
    mov r10, ARG1
    cmp qword [r10 + DB_WRITABLE], 0
    je .e_readonly
    cmp qword [r10 + DB_MODE], 1
    jne .e_state
    test qword [r10 + DB_FEATURES], CybouDB_FEATURE_CATALOG
    jz .e_state
    cmp qword [r10 + DB_GENERATION], -1
    je .e_generation
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    call db_catalog_page
    test rax, rax
    jz .e_state
    mov r10, [rbp - 8]
    mov rcx, rax
    sub rcx, [r10 + DB_BASE]
    shr rcx, CybouDB_PAGE_SHIFT
    mov [rbp - 32], rcx
    mov rax, [r10 + DB_ROOT]
    mov [rbp - 40], rax
    mov ARG1, [rbp - 8]
    call db_bitmap_headroom
    cmp rax, 2                      ; the page and the directory
    jb .e_full

    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 32]
    lea ARG3, [rbp - 48]
    call db_cow_copy_page
    test eax, eax
    jnz .e_done
    mov r10, [rbp - 8]
    mov rax, [rbp - 48]
    shl rax, CybouDB_PAGE_SHIFT
    add rax, [r10 + DB_BASE]
    mov [rbp - 64], rax
    mov ARG1, rax
    mov ARG2, r10
    call stamp

    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 40]
    lea ARG3, [rbp - 56]
    call db_cow_copy_page
    test eax, eax
    jnz .e_done
    mov r10, [rbp - 8]
    mov rax, [rbp - 56]
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
.e_entry:
    cmp [r10], r11
    je .e_found
    add r10, 16
    dec ecx
    jnz .e_entry
    mov eax, CybouDB_E_CATALOG
    jmp .e_done
.e_found:
    mov rax, [rbp - 48]
    mov [r10 + 8], rax
    mov ARG1, [rbp - 72]
    call seal_page
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 56]
    call db_cow_set_root
    test eax, eax
    jnz .e_done
    mov r11, [rbp - 24]
    mov rax, [rbp - 64]
    mov [r11], rax
    xor eax, eax
    jmp .e_done
.e_readonly:
    mov eax, CybouDB_E_READONLY
    jmp .e_done
.e_state:
    mov eax, CybouDB_E_STATE
    jmp .e_done
.e_generation:
    mov eax, CybouDB_E_GENERATION
    jmp .e_done
.e_full:
    mov eax, CybouDB_E_FULL
.e_done:
    FRAME_END
    ret

; db_catalog_seal(ARG1 = a page db_catalog_edit handed back): checksum it.
db_catalog_seal:
    jmp seal_page

; -----------------------------------------------------------------------------
db_catalog_set_index_root:
    FRAME_BEGIN 96, 0
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
    mov [rbp - 24], ARG3
    mov [rbp - 32], ARG4
    mov r10, ARG1
    cmp qword [r10 + DB_WRITABLE], 0
    je .readonly
    cmp qword [r10 + DB_MODE], 1
    jne .state
    test qword [r10 + DB_FEATURES], CybouDB_FEATURE_INDEX
    jz .state
    cmp qword [r10 + DB_GENERATION], -1
    je .generation
    cmp qword [rbp - 24], 0
    je .located                     ; an emptied index has no root to check
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 24]
    call db_bitmap_is_fresh
    test eax, eax
    jz .page
.located:
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    call db_catalog_page
    test rax, rax
    jz .state
    mov r10, [rbp - 8]
    mov rcx, rax
    sub rcx, [r10 + DB_BASE]
    shr rcx, CybouDB_PAGE_SHIFT
    mov [rbp - 40], rcx
    cmp dword [rax + CAT_TYPE], CAT_INDEX
    jne .state
    ; stamp clears the reserved span on the copy, and the column and the
    ; flags live there. Carry them across rather than rediscovering them.
    mov ecx, [rax + IDX_COLUMN]
    mov [rbp - 80], rcx
    mov ecx, [rax + IDX_FLAGS]
    mov [rbp - 88], rcx
    mov rax, [r10 + DB_ROOT]
    mov [rbp - 48], rax
    mov ARG1, [rbp - 8]
    call db_bitmap_headroom
    cmp rax, 2                      ; the index page and the directory
    jb .full

    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 40]
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
    mov [r10 + IDX_ROOT], rax
    mov rax, [rbp - 32]
    mov [r10 + IDX_ROWS], rax
    mov eax, [rbp - 80]
    mov [r10 + IDX_COLUMN], eax
    mov eax, [rbp - 88]
    mov [r10 + IDX_FLAGS], eax
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
    mov eax, CybouDB_E_PAGE
    jmp .done
.full:
    mov eax, CybouDB_E_FULL
.done:
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  db_catalog_page(ctx, id) -> RAX: the page an entry names, mapped, or zero.
;
;  db_catalog_get answers the same question and validates the staged graph on
;  the way, which is right for a caller that has just been handed an id from
;  outside. It is wrong for a statement that is in the middle of its own
;  transaction: the walk is proportional to the table, and doing it again per
;  statement is what made appends cost the size of the database before
;  current_valid learned to remember. This is the lookup without the walk, for
;  callers whose work db_commit will prove anyway.
; -----------------------------------------------------------------------------
db_catalog_page:
    mov r10, ARG1
    mov rax, [r10 + DB_ROOT]
    test rax, rax
    jz .none
    shl rax, CybouDB_PAGE_SHIFT
    add rax, [r10 + DB_BASE]
    mov ecx, [rax + CAT_COUNT]
    test ecx, ecx
    jz .none
    lea r8, [rax + CAT_DATA]
    ; The counter goes in a register no argument aliases: ARG2 is RDX on
    ; one of the two ABIs, and the id being looked for would go with it.
    xor r9d, r9d
.scan_entry:
    cmp [r8], ARG2
    je .found
    add r8, 16
    inc r9d
    cmp r9d, ecx
    jb .scan_entry
.none:
    xor eax, eax
    ret
.found:
    mov rax, [r8 + 8]
    shl rax, CybouDB_PAGE_SHIFT
    add rax, [r10 + DB_BASE]
    ret

%ifdef CybouDB_LINUX
section .note.GNU-stack noalloc noexec nowrite progbits
%endif
