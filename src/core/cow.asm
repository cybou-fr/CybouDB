; Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
; SPDX-License-Identifier: Apache-2.0
; Append-only COW for format v1 with CybouDB_FEATURE_COW, single writer only.
; A copy retires its source; whether that page comes back depends on the map
; layout. No catalog graph validation or concurrent access yet.
; Callers must not store through DB_BASE or retain writable aliases after commit.
%include "cyboudb.inc"
BITS 64
default rel

extern db_open, db_close
extern db_bitmap_alloc, db_bitmap_alloc_run, db_bitmap_is_payload
extern db_bitmap_retire, db_bitmap_is_fresh
global db_open_cow, db_cow_alloc_page, db_cow_copy_page
global db_cow_alloc_run, db_cow_copy_run
global db_cow_write_page, db_cow_set_root

section .text

; db_open_cow(path, ctx): writable open with no legacy free list. A separate
; entry point prevents switching a handle after legacy in-place mutations.
db_open_cow:
    FRAME_BEGIN 16, 0
    mov     [rbp - 8], ARG2
    mov     ARG3, 1
    xor     ARG4, ARG4
    call    db_open
    test    eax, eax
    jnz     .done
    mov     r10, [rbp - 8]
    test    qword [r10 + DB_FEATURES], CybouDB_FEATURE_COW
    jz      .unsupported
    cmp     qword [r10 + DB_FREELIST], 0
    jne     .unsupported
    mov     rax, [r10 + DB_COW_FLOOR]
    cmp     rax, [r10 + DB_PAGES]
    ja      .geometry
    mov     qword [r10 + DB_MODE], 1
    xor     eax, eax
    jmp     .done
.unsupported:
    mov     qword [rbp - 16], CybouDB_E_STATE
    jmp     .close
.geometry:
    mov     qword [rbp - 16], CybouDB_E_GEOMETRY
.close:
    mov     ARG1, r10
    call    db_close
    mov     rax, [rbp - 16]
.done:
    FRAME_END
    ret

; Internal: r10=ctx. All mutators fail before touching the mapping.
check_writer:
    cmp     qword [r10 + DB_WRITABLE], 0
    je      readonly_error
    cmp     qword [r10 + DB_MODE], 1
    jne     state_error
    cmp     qword [r10 + DB_GENERATION], -1
    je      generation_error
    xor     eax, eax
    ret

; db_cow_alloc_page(ctx, out_id). Zero an unpublished page beyond BOTH valid
; superblocks' high-water marks. Never pop or modify a legacy free-list node.
db_cow_alloc_page:
    FRAME_BEGIN 16, 0
    mov     [rbp - 8], ARG1
    mov     [rbp - 16], ARG2
    mov     r10, ARG1
    call    check_writer
    test    eax, eax
    jnz     .done
    mov     ARG1, [rbp - 8]
    mov     ARG2, [rbp - 16]
    call    db_bitmap_alloc
.done:
    FRAME_END
    ret

; db_cow_copy_page(ctx, source_id, out_id). Source remains byte-identical, and
; is retired: this generation replaces it with the copy, so the only reference
; left to it belongs to the generation this transaction is about to overwrite.
db_cow_copy_page:
    FRAME_BEGIN 32, 0
    mov     [rbp - 8], ARG1
    mov     [rbp - 16], ARG2
    mov     [rbp - 24], ARG3
    mov     r10, ARG1
    call    check_writer
    test    eax, eax
    jnz     .done
    mov     rax, [rbp - 16]
    cmp     rax, CybouDB_MIN_PAGES
    jb      .page
    cmp     rax, [r10 + DB_ALLOC]
    jae     .page
    mov     ARG1, r10
    mov     ARG2, rax
    call    db_bitmap_is_payload
    test    eax, eax
    jz      .page
    mov     r10, [rbp - 8]
    mov     ARG1, r10
    lea     ARG2, [rbp - 32]
    call    db_cow_alloc_page
    test    eax, eax
    jnz     .done
    mov     r10, [rbp - 8]
    mov     r11, [rbp - 16]
    DB_PAGE_HERE r11, r10
    mov     rax, [rbp - 32]
    DB_PAGE_HERE rax, r10
    mov     ecx, CybouDB_PAGE_SIZE / 8
.copy:
    mov     rdx, [r11]
    mov     [rax], rdx
    add     r11, 8
    add     rax, 8
    dec     ecx
    jnz     .copy
    mov     ARG1, [rbp - 8]
    mov     ARG2, [rbp - 16]
    call    db_bitmap_retire
    mov     r11, [rbp - 24]
    mov     rax, [rbp - 32]
    mov     [r11], rax
    xor     eax, eax
    jmp     .done
.page:
    mov     eax, CybouDB_E_PAGE
.done:
    FRAME_END
    ret

; db_cow_alloc_run(ctx, pages, out_first). A PAX leaf wider than one page is
; a run of consecutive pages, addressed by its first id alone, so it has to be
; allocated as a unit rather than a page at a time.
db_cow_alloc_run:
    FRAME_BEGIN 32, 0
    mov     [rbp - 8], ARG1
    mov     [rbp - 16], ARG2
    mov     [rbp - 24], ARG3
    mov     r10, ARG1
    call    check_writer
    test    eax, eax
    jnz     .done
    mov     ARG1, [rbp - 8]
    mov     ARG2, [rbp - 16]
    mov     ARG3, [rbp - 24]
    call    db_bitmap_alloc_run
.done:
    FRAME_END
    ret

; db_cow_copy_run(ctx, source_first, pages, out_first). The run equivalent of
; db_cow_copy_page: every page of the source stays byte-identical and is
; retired, because this generation replaces the whole leaf with the copy.
;
; Local slots: [rbp-8]=ctx, [rbp-16]=source first, [rbp-24]=pages,
;              [rbp-32]=out, [rbp-40]=destination first, [rbp-48]=index
db_cow_copy_run:
    FRAME_BEGIN 64, 0
    mov     [rbp - 8], ARG1
    mov     [rbp - 16], ARG2
    mov     [rbp - 24], ARG3
    mov     [rbp - 32], ARG4
    cmp     qword [rbp - 24], 2
    jb      .one_page

    ; Every page of the source must be a payload page of this generation,
    ; checked before anything is allocated so a rejected leaf costs nothing.
    mov     qword [rbp - 48], 0
.verify:
    mov     r10, [rbp - 8]
    mov     rax, [rbp - 16]
    add     rax, [rbp - 48]
    cmp     rax, CybouDB_MIN_PAGES
    jb      .page
    cmp     rax, [r10 + DB_ALLOC]
    jae     .page
    mov     ARG1, r10
    mov     ARG2, rax
    call    db_bitmap_is_payload
    test    eax, eax
    jz      .page
    inc     qword [rbp - 48]
    mov     rax, [rbp - 48]
    cmp     rax, [rbp - 24]
    jb      .verify

    mov     ARG1, [rbp - 8]
    mov     ARG2, [rbp - 24]
    lea     ARG3, [rbp - 40]
    call    db_cow_alloc_run
    test    eax, eax
    jnz     .done

    mov     r10, [rbp - 8]
    mov     r11, [rbp - 16]
    DB_PAGE_HERE r11, r10
    mov     rax, [rbp - 40]
    DB_PAGE_HERE rax, r10
    mov     rcx, [rbp - 24]
    shl     rcx, CybouDB_PAGE_SHIFT - 3    ; qwords in the whole run
.copy_run:
    mov     rdx, [r11]
    mov     [rax], rdx
    add     r11, 8
    add     rax, 8
    dec     rcx
    jnz     .copy_run

    mov     qword [rbp - 48], 0
.retire:
    mov     ARG1, [rbp - 8]
    mov     ARG2, [rbp - 16]
    add     ARG2, [rbp - 48]
    call    db_bitmap_retire
    inc     qword [rbp - 48]
    mov     rax, [rbp - 48]
    cmp     rax, [rbp - 24]
    jb      .retire

    mov     r11, [rbp - 32]
    mov     rax, [rbp - 40]
    mov     [r11], rax
    xor     eax, eax
    jmp     .done
.one_page:
    mov     ARG1, [rbp - 8]
    mov     ARG2, [rbp - 16]
    mov     ARG3, [rbp - 32]
    call    db_cow_copy_page
    jmp     .done
.page:
    mov     eax, CybouDB_E_PAGE
.done:
    FRAME_END
    ret

; db_cow_write_page(ctx, destination_id, readable_4096_byte_buffer).
; Only pages allocated since open/the last successful commit are writable.
; Source must be disjoint from destination or exactly equal to it.
db_cow_write_page:
    FRAME_BEGIN 32, 0
    mov     [rbp - 24], ARG1
    mov     [rbp - 8], ARG2
    mov     [rbp - 16], ARG3
    mov     r10, ARG1
    call    check_writer
    test    eax, eax
    jnz     .done
    mov     rax, [rbp - 8]
    cmp     rax, [r10 + DB_ALLOC]
    jae     .page
    mov     ARG1, r10
    mov     ARG2, rax
    call    db_bitmap_is_fresh
    test    eax, eax
    jz      .page
    mov     r10, [rbp - 24]
    mov     rax, [rbp - 8]
    DB_PAGE_HERE rax, r10
    mov     r11, [rbp - 16]
    mov     ecx, CybouDB_PAGE_SIZE / 8
.copy:
    mov     rdx, [r11]
    mov     [rax], rdx
    add     r11, 8
    add     rax, 8
    dec     ecx
    jnz     .copy
    xor     eax, eax
    jmp     .done
.page:
    mov     eax, CybouDB_E_PAGE
.done:
    FRAME_END
    ret

; db_cow_set_root(ctx, page_id): 0 clears the root. No graph/type validation yet.
db_cow_set_root:
    FRAME_BEGIN 16, 0
    mov     [rbp - 16], ARG1
    mov     [rbp - 8], ARG2
    mov     r10, ARG1
    call    check_writer
    test    eax, eax
    jnz     .done
    mov     rax, [rbp - 8]
    test    rax, rax
    jz      .set
    cmp     rax, CybouDB_MIN_PAGES
    jb      .page
    cmp     rax, [r10 + DB_ALLOC]
    jae     .page
    mov     ARG1, r10
    mov     ARG2, rax
    call    db_bitmap_is_payload
    test    eax, eax
    jz      .page
    mov     r10, [rbp - 16]
    mov     rax, [rbp - 8]
.set:
    mov     [r10 + DB_ROOT], rax
    xor     eax, eax
    jmp     .done
.page:
    mov     eax, CybouDB_E_PAGE
.done:
    FRAME_END
    ret

readonly_error:
    mov     eax, CybouDB_E_READONLY
    ret
state_error:
    mov     eax, CybouDB_E_STATE
    ret
generation_error:
    mov     eax, CybouDB_E_GENERATION
    ret

%ifdef CybouDB_LINUX
section .note.GNU-stack noalloc noexec nowrite progbits
%endif
