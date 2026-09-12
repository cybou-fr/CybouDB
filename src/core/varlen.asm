; Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
; SPDX-License-Identifier: Apache-2.0
; Validation for persistent TEXT/BLOB extent chains.
%include "cyboudb.inc"
BITS 64
default rel
extern db_bitmap_alloc, db_bitmap_candidate_payload, db_bitmap_deep, db_bitmap_headroom
extern crc32c
global db_var_validate_chain, db_var_write_chain, db_var_materialize_batch
global db_var_read_chain
section .text

; db_var_read_chain(ctx, candidate_sb, descriptor, owner, out, capacity) -> error
; Validates the complete descriptor chain before copying any bytes. The output
; buffer is therefore unchanged on corruption or insufficient capacity.
db_var_read_chain:
    FRAME_BEGIN 80, 1
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
    mov [rbp - 24], ARG3
    mov [rbp - 32], ARG4
    mov rax, IN_ARG5
    mov [rbp - 40], rax
    mov rax, IN_ARG6
    mov [rbp - 48], rax
    cmp qword [rbp - 24], 0
    je .read_value
    mov r10, [rbp - 24]
    mov rax, [r10 + VAR_CELL_ROOT]
    mov [rbp - 56], rax
    mov rax, [r10 + VAR_CELL_LENGTH]
    mov [rbp - 64], rax
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    mov ARG3, [rbp - 56]
    mov ARG4, [rbp - 64]
    mov rax, [rbp - 32]
    PASS_ARG5 rax
    call db_var_validate_chain
    test eax, eax
    jz .read_corrupt
    mov rax, [rbp - 64]
    cmp [rbp - 48], rax
    jb .read_value
    test rax, rax
    jz .read_ok
    cmp qword [rbp - 40], 0
    je .read_value
    mov [rbp - 72], rax             ; remaining bytes
.read_page:
    mov r10, [rbp - 56]
    shl r10, CybouDB_PAGE_SHIFT
    mov r11, [rbp - 8]
    add r10, [r11 + DB_BASE]
    mov ecx, [r10 + VAR_USED]
    lea r11, [r10 + VAR_DATA]
    mov rdx, [rbp - 40]
.read_copy_byte:
    test rcx, rcx
    jz .read_advance
    mov al, [r11]
    mov [rdx], al
    inc r11
    inc rdx
    dec rcx
    jmp .read_copy_byte
.read_advance:
    mov [rbp - 40], rdx
    mov rax, [r10 + VAR_USED]
    sub [rbp - 72], rax
    jz .read_ok
    mov rax, [r10 + VAR_NEXT]
    mov [rbp - 56], rax
    jmp .read_page
.read_ok:
    xor eax, eax
    FRAME_END
    ret
.read_corrupt:
    mov eax, CybouDB_E_PAX
    FRAME_END
    ret
.read_value:
    mov eax, CybouDB_E_VALUE
    FRAME_END
    ret

; db_var_materialize_batch(ctx, schema, batch, owner, reserve_pages) -> error
; Preflights all extent pages plus the structural pages the caller still needs,
; then replaces each non-NULL varlen pointer slot with its persistent root.
db_var_materialize_batch:
    FRAME_BEGIN 144, 1
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
    mov [rbp - 24], ARG3
    mov [rbp - 32], ARG4
    mov rax, IN_ARG5
    mov [rbp - 40], rax
    mov qword [rbp - 104], 0
.mat_find_varlen:
    mov r10, [rbp - 104]
    mov r11, [rbp - 16]
    cmp r10d, [r11 + CAT_COUNT]
    jae .mat_noop
    shl r10, 5
    mov eax, [r11 + CAT_COLUMNS + r10]
    cmp eax, CAT_TEXT
    je .mat_has_varlen
    cmp eax, CAT_BLOB
    je .mat_has_varlen
    cmp eax, CAT_VECTOR
    je .mat_has_varlen
    inc qword [rbp - 104]
    jmp .mat_find_varlen
.mat_noop:
    xor eax, eax
    FRAME_END
    ret
.mat_has_varlen:
    mov r10, [rbp - 24]
    mov rax, [r10 + BATCH_VALUES]
    test rax, rax
    jz .mat_value
    mov [rbp - 48], rax
    mov rax, [r10 + BATCH_NULLS]
    mov [rbp - 56], rax
    mov rax, [r10 + BATCH_VAR_LENGTHS]
    mov [rbp - 64], rax
    mov rax, [r10 + BATCH_ROWS]
    mov [rbp - 72], rax
    mov qword [rbp - 80], 0             ; total extent pages
    mov qword [rbp - 88], 0             ; row
    mov qword [rbp - 96], 0             ; flat cell
.mat_pre_row:
    mov qword [rbp - 104], 0
.mat_pre_cell:
    mov r10, [rbp - 104]
    shl r10, 5
    add r10, [rbp - 16]
    mov ecx, [r10 + CAT_COLUMNS]
    cmp ecx, CAT_TEXT
    je .mat_pre_var
    cmp ecx, CAT_BLOB
    je .mat_pre_var
    cmp ecx, CAT_VECTOR
    jne .mat_pre_next
.mat_pre_var:
    cmp qword [rbp - 64], 0
    je .mat_value
    mov rax, [rbp - 96]
    mov r11, [rbp - 56]
    test r11, r11
    jz .mat_pre_nonnull
    cmp byte [r11 + rax], 0
    jne .mat_pre_zero
.mat_pre_nonnull:
    mov r11, [rbp - 64]
    mov rdx, [r11 + rax * 8]
    test rdx, rdx
    jz .mat_pre_next                  ; canonical empty value
    mov r11, [rbp - 48]
    cmp qword [r11 + rax * 8], 0
    je .mat_value
    mov rax, rdx
    xor edx, edx
    mov rcx, VAR_PAYLOAD_SIZE
    div rcx
    test rdx, rdx
    setnz dl
    movzx edx, dl
    add rax, rdx
    add [rbp - 80], rax
    jc .mat_full
    jmp .mat_pre_next
.mat_pre_zero:
    mov r11, [rbp - 64]
    cmp qword [r11 + rax * 8], 0
    jne .mat_value
.mat_pre_next:
    inc qword [rbp - 96]
    inc qword [rbp - 104]
    mov r10, [rbp - 16]
    mov eax, [r10 + CAT_COUNT]
    cmp [rbp - 104], rax
    jb .mat_pre_cell
    inc qword [rbp - 88]
    mov rax, [rbp - 88]
    cmp rax, [rbp - 72]
    jb .mat_pre_row
    mov rax, [rbp - 80]
    add rax, [rbp - 40]
    jc .mat_full
    mov [rbp - 120], rax
    mov ARG1, [rbp - 8]
    call db_bitmap_headroom
    cmp rax, [rbp - 120]
    jb .mat_full

    mov qword [rbp - 88], 0
    mov qword [rbp - 96], 0
.mat_write_row:
    mov qword [rbp - 104], 0
.mat_write_cell:
    mov r10, [rbp - 104]
    shl r10, 5
    add r10, [rbp - 16]
    mov ecx, [r10 + CAT_COLUMNS]
    cmp ecx, CAT_TEXT
    je .mat_write_var
    cmp ecx, CAT_BLOB
    je .mat_write_var
    cmp ecx, CAT_VECTOR
    jne .mat_write_next
.mat_write_var:
    mov rax, [rbp - 96]
    mov r11, [rbp - 56]
    test r11, r11
    jz .mat_write_nonnull
    cmp byte [r11 + rax], 0
    jne .mat_write_next
.mat_write_nonnull:
    mov r10, [rbp - 48]
    mov ARG2, [r10 + rax * 8]
    mov r11, [rbp - 64]
    mov ARG3, [r11 + rax * 8]
    mov ARG1, [rbp - 8]
    mov ARG4, [rbp - 32]
    lea r10, [rbp - 136]
    PASS_ARG5 r10
    call db_var_write_chain
    test eax, eax
    jnz .mat_done
    mov rax, [rbp - 96]
    mov r10, [rbp - 48]
    mov r11, [rbp - 136 + VAR_CELL_ROOT]
    mov [r10 + rax * 8], r11
.mat_write_next:
    inc qword [rbp - 96]
    inc qword [rbp - 104]
    mov r10, [rbp - 16]
    mov eax, [r10 + CAT_COUNT]
    cmp [rbp - 104], rax
    jb .mat_write_cell
    inc qword [rbp - 88]
    mov rax, [rbp - 88]
    cmp rax, [rbp - 72]
    jb .mat_write_row
    xor eax, eax
.mat_done:
    FRAME_END
    ret
.mat_value:
    mov eax, CybouDB_E_VALUE
    FRAME_END
    ret
.mat_full:
    mov eax, CybouDB_E_FULL
    FRAME_END
    ret

; db_var_write_chain(ctx, bytes, length, owner, out_descriptor) -> error code
; Allocates individual COW pages, fills and seals every page, and publishes
; the descriptor to caller memory only after the complete chain exists.
db_var_write_chain:
    FRAME_BEGIN 144, 1
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
    mov [rbp - 24], ARG3
    mov [rbp - 32], ARG4
    mov rax, IN_ARG5
    mov [rbp - 40], rax
    test rax, rax
    jz .write_value_error
    test qword [rbp - 24], -1
    jnz .write_nonempty
    mov qword [rax + VAR_CELL_ROOT], 0
    mov qword [rax + VAR_CELL_LENGTH], 0
    xor eax, eax
    FRAME_END
    ret
.write_nonempty:
    cmp qword [rbp - 16], 0
    je .write_value_error
    cmp qword [rbp - 32], 0
    je .write_value_error
    mov rax, [rbp - 24]
    xor edx, edx
    mov rcx, VAR_PAYLOAD_SIZE
    div rcx
    test rdx, rdx
    setnz dl
    movzx edx, dl
    add rax, rdx
    mov [rbp - 48], rax             ; page count
    mov ARG1, [rbp - 8]
    call db_bitmap_headroom
    cmp rax, [rbp - 48]
    jb .write_full
    mov qword [rbp - 112], 0        ; previous extent address
    mov qword [rbp - 64], 0         ; page index
    mov rax, [rbp - 24]
    mov [rbp - 72], rax             ; remaining bytes
    mov rax, [rbp - 16]
    mov [rbp - 80], rax             ; source cursor
.write_page:
    mov ARG1, [rbp - 8]
    lea ARG2, [rbp - 88]
    call db_bitmap_alloc
    test eax, eax
    jnz .write_done
    mov rax, [rbp - 88]             ; current page id
    mov r10, [rbp - 112]
    test r10, r10
    jz .write_first
    mov [r10 + VAR_NEXT], rax
    mov ARG1, r10
    mov ARG2, VAR_CRC
    call crc32c
    mov r10, [rbp - 112]
    mov [r10 + VAR_CRC], eax
    jmp .write_linked
.write_first:
    mov [rbp - 56], rax             ; first page id
.write_linked:
    mov r10, [rbp - 88]
    shl r10, CybouDB_PAGE_SHIFT
    mov r11, [rbp - 8]
    add r10, [r11 + DB_BASE]
    mov [rbp - 96], r10
    mov rax, [rbp - 88]
    mov dword [r10 + VAR_MAGIC], VAR_MAGIC_VALUE
    mov dword [r10 + VAR_VERSION], VAR_VERSION_VALUE
    mov [r10 + VAR_PAGE_ID], rax
    mov rax, [r11 + DB_GENERATION]
    inc rax
    mov [r10 + VAR_GENERATION], rax
    mov rax, [rbp - 32]
    mov [r10 + VAR_OWNER], rax
    mov rax, [rbp - 72]
    cmp rax, VAR_PAYLOAD_SIZE
    jbe .write_used_ready
    mov eax, VAR_PAYLOAD_SIZE
.write_used_ready:
    mov [rbp - 104], rax
    mov [r10 + VAR_USED], eax
    mov qword [r10 + VAR_NEXT], 0
.write_copy:
    mov rcx, [rbp - 104]
    mov r10, [rbp - 80]
    mov r11, [rbp - 96]
    add r11, VAR_DATA
.write_copy_byte:
    test rcx, rcx
    jz .write_seal
    mov al, [r10]
    mov [r11], al
    inc r10
    inc r11
    dec rcx
    jmp .write_copy_byte
.write_seal:
    mov [rbp - 80], r10
    mov ARG1, [rbp - 96]
    mov ARG2, VAR_CRC
    call crc32c
    mov r10, [rbp - 96]
    mov [r10 + VAR_CRC], eax
    mov [rbp - 112], r10          ; last extent; linked when the next page arrives
    mov rax, [rbp - 104]
    sub [rbp - 72], rax
    inc qword [rbp - 64]
    mov rax, [rbp - 64]
    cmp rax, [rbp - 48]
    jb .write_page
    mov r10, [rbp - 40]
    mov rax, [rbp - 56]
    mov [r10 + VAR_CELL_ROOT], rax
    mov rax, [rbp - 24]
    mov [r10 + VAR_CELL_LENGTH], rax
    xor eax, eax
.write_done:
    FRAME_END
    ret
.write_value_error:
    mov eax, CybouDB_E_VALUE
    FRAME_END
    ret
.write_full:
    mov eax, CybouDB_E_FULL
    FRAME_END
    ret

; db_var_validate_chain(ctx, candidate_sb, root, length, owner) -> 1 / 0
db_var_validate_chain:
    FRAME_BEGIN 96, 0
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
    mov [rbp - 24], ARG3
    mov [rbp - 32], ARG4
    mov rax, IN_ARG5
    mov [rbp - 40], rax
    test ARG4, ARG4
    jnz .nonempty
    test ARG3, ARG3
    jnz .bad
    mov eax, 1
    FRAME_END
    ret
.nonempty:
    test ARG3, ARG3
    jz .bad
    cmp qword [rbp - 40], 0
    je .bad
    mov rax, [rbp - 32]
    xor edx, edx
    mov rcx, VAR_PAYLOAD_SIZE
    div rcx
    test rdx, rdx
    setnz dl
    movzx edx, dl
    add rax, rdx
    mov [rbp - 48], rax
    mov qword [rbp - 56], 0
.page:
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    mov ARG3, [rbp - 24]
    call db_bitmap_candidate_payload
    test eax, eax
    jz .bad
    mov r10, [rbp - 24]
    shl r10, CybouDB_PAGE_SHIFT
    mov r11, [rbp - 8]
    add r10, [r11 + DB_BASE]
    mov [rbp - 64], r10
    cmp dword [r10 + VAR_MAGIC], VAR_MAGIC_VALUE
    jne .bad
    cmp dword [r10 + VAR_VERSION], VAR_VERSION_VALUE
    jne .bad
    mov rax, [rbp - 24]
    cmp [r10 + VAR_PAGE_ID], rax
    jne .bad
    mov rax, [r10 + VAR_GENERATION]
    test rax, rax
    jz .bad
    mov r11, [rbp - 16]
    cmp rax, [r11 + SB_GENERATION]
    ja .bad
    mov rax, [rbp - 40]
    cmp [r10 + VAR_OWNER], rax
    jne .bad
    mov rax, [r10 + VAR_RESERVED]
    or rax, [r10 + VAR_RESERVED + 8]
    or eax, [r10 + VAR_RESERVED + 16]
    jnz .bad
    mov rax, [rbp - 32]
    cmp rax, VAR_PAYLOAD_SIZE
    jbe .used_ready
    mov eax, VAR_PAYLOAD_SIZE
.used_ready:
    mov [rbp - 72], rax
    cmp [r10 + VAR_USED], eax
    jne .bad
    inc qword [rbp - 56]
    mov rax, [rbp - 56]
    cmp rax, [rbp - 48]
    je .must_end
    cmp qword [r10 + VAR_NEXT], 0
    je .bad
    jmp .deep
.must_end:
    cmp qword [r10 + VAR_NEXT], 0
    jne .bad
.deep:
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    mov r10, [rbp - 64]
    mov ARG3, [r10 + VAR_GENERATION]
    call db_bitmap_deep
    test eax, eax
    jz .advance
    mov ARG1, [rbp - 64]
    mov ARG2, VAR_CRC
    call crc32c
    mov r10, [rbp - 64]
    cmp [r10 + VAR_CRC], eax
    jne .bad
    mov rcx, VAR_PAYLOAD_SIZE
    sub rcx, [rbp - 72]
    jz .advance
    lea r10, [r10 + VAR_DATA]
    add r10, [rbp - 72]
.zero_tail:
    cmp byte [r10], 0
    jne .bad
    inc r10
    dec rcx
    jnz .zero_tail
.advance:
    mov r10, [rbp - 64]
    mov rax, [r10 + VAR_NEXT]
    mov [rbp - 24], rax
    mov rax, [rbp - 72]
    sub [rbp - 32], rax
    mov rax, [rbp - 56]
    cmp rax, [rbp - 48]
    jb .page
    cmp qword [rbp - 32], 0
    jne .bad
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
