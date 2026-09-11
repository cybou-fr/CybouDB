; Focused integration driver for variable-width extent read/write primitives.
%include "cyboudb.inc"
BITS 64
default rel
extern os_argv, os_exit
extern db_open_cow, db_close
extern db_var_validate_chain, db_var_write_chain, db_var_read_chain
extern crc32c
global cyboudb_main

%define TEST_LENGTH (VAR_PAYLOAD_SIZE + 37)
%define TEST_OWNER 77

section .bss
align 8
ctx:       resb CybouDB_DB_SIZE
candidate: resb CybouDB_SB_SIZE
descriptor: resb VAR_CELL_SIZE
empty_descriptor: resb VAR_CELL_SIZE
source:    resb TEST_LENGTH
output:    resb TEST_LENGTH

section .text
cyboudb_main:
    FRAME_BEGIN 16, 2
    mov ARG1, 1
    call os_argv
    test rax, rax
    jz failure
    mov ARG1, rax
    lea ARG2, [ctx]
    call db_open_cow
    test eax, eax
    jnz failure

    ; Deterministic bytes crossing one extent boundary.
    lea r10, [source]
    xor ecx, ecx
.fill:
    mov eax, ecx
    imul eax, 131
    add eax, 17
    mov [r10 + rcx], al
    inc ecx
    cmp ecx, TEST_LENGTH
    jb .fill

    lea ARG1, [ctx]
    lea ARG2, [source]
    mov ARG3, TEST_LENGTH
    mov ARG4, TEST_OWNER
    lea rax, [descriptor]
    PASS_ARG5 rax
    call db_var_write_chain
    test eax, eax
    jnz failure_close
    call make_candidate

    ; A short destination is rejected before its sentinel can change.
    mov byte [output], 0xA5
    lea ARG1, [ctx]
    lea ARG2, [candidate]
    lea ARG3, [descriptor]
    mov ARG4, TEST_OWNER
    lea rax, [output]
    PASS_ARG5 rax
    mov rax, TEST_LENGTH - 1
    PASS_ARG6 rax
    call db_var_read_chain
    cmp eax, CybouDB_E_VALUE
    jne failure_close
    cmp byte [output], 0xA5
    jne failure_close

    ; The complete multi-extent value round-trips byte for byte.
    lea ARG1, [ctx]
    lea ARG2, [candidate]
    lea ARG3, [descriptor]
    mov ARG4, TEST_OWNER
    lea rax, [output]
    PASS_ARG5 rax
    mov rax, TEST_LENGTH
    PASS_ARG6 rax
    call db_var_read_chain
    test eax, eax
    jnz failure_close
    lea r10, [source]
    lea r11, [output]
    mov ecx, TEST_LENGTH
.compare:
    mov al, [r10]
    cmp al, [r11]
    jne failure_close
    inc r10
    inc r11
    dec ecx
    jnz .compare

    ; Canonical empty values need neither storage nor an output pointer.
    lea ARG1, [ctx]
    lea ARG2, [candidate]
    lea ARG3, [empty_descriptor]
    mov ARG4, TEST_OWNER
    xor eax, eax
    PASS_ARG5 rax
    PASS_ARG6 rax
    call db_var_read_chain
    test eax, eax
    jnz failure_close

    ; Header corruption is detected before modifying the destination.
    mov rax, [descriptor + VAR_CELL_ROOT]
    shl rax, CybouDB_PAGE_SHIFT
    add rax, [ctx + DB_BASE]
    xor byte [rax + VAR_MAGIC], 1
    mov byte [output], 0x5A
    lea ARG1, [ctx]
    lea ARG2, [candidate]
    lea ARG3, [descriptor]
    mov ARG4, TEST_OWNER
    lea rax, [output]
    PASS_ARG5 rax
    mov rax, TEST_LENGTH
    PASS_ARG6 rax
    call db_var_read_chain
    cmp eax, CybouDB_E_PAX
    jne failure_close
    cmp byte [output], 0x5A
    jne failure_close

    ; Restore the header, then verify payload CRC corruption is rejected.
    mov rax, [descriptor + VAR_CELL_ROOT]
    shl rax, CybouDB_PAGE_SHIFT
    add rax, [ctx + DB_BASE]
    mov dword [rax + VAR_MAGIC], VAR_MAGIC_VALUE
    mov ARG1, rax
    mov ARG2, VAR_CRC
    call crc32c
    mov r10, [descriptor + VAR_CELL_ROOT]
    shl r10, CybouDB_PAGE_SHIFT
    add r10, [ctx + DB_BASE]
    mov [r10 + VAR_CRC], eax
    xor byte [r10 + VAR_DATA], 1
    mov byte [output], 0x5A
    lea ARG1, [ctx]
    lea ARG2, [candidate]
    lea ARG3, [descriptor]
    mov ARG4, TEST_OWNER
    lea rax, [output]
    PASS_ARG5 rax
    mov rax, TEST_LENGTH
    PASS_ARG6 rax
    call db_var_read_chain
    cmp eax, CybouDB_E_PAX
    jne failure_close
    cmp byte [output], 0x5A
    jne failure_close
    xor byte [r10 + VAR_DATA], 1
    mov ARG1, r10
    mov ARG2, VAR_CRC
    call crc32c
    mov r10, [descriptor + VAR_CELL_ROOT]
    shl r10, CybouDB_PAGE_SHIFT
    add r10, [ctx + DB_BASE]
    mov [r10 + VAR_CRC], eax

    ; Early termination and cycles must fail before copying any bytes.
    mov rax, [r10 + VAR_NEXT]
    mov [rbp - 8], rax
    mov qword [r10 + VAR_NEXT], 0
    mov ARG1, r10
    mov ARG2, VAR_CRC
    call crc32c
    mov r10, [descriptor + VAR_CELL_ROOT]
    shl r10, CybouDB_PAGE_SHIFT
    add r10, [ctx + DB_BASE]
    mov [r10 + VAR_CRC], eax
    mov byte [output], 0x5A
    lea ARG1, [ctx]
    lea ARG2, [candidate]
    lea ARG3, [descriptor]
    mov ARG4, TEST_OWNER
    lea rax, [output]
    PASS_ARG5 rax
    mov rax, TEST_LENGTH
    PASS_ARG6 rax
    call db_var_read_chain
    cmp eax, CybouDB_E_PAX
    jne failure_close
    cmp byte [output], 0x5A
    jne failure_close
    mov rax, [rbp - 8]
    mov [r10 + VAR_NEXT], rax
    mov ARG1, r10
    mov ARG2, VAR_CRC
    call crc32c
    mov [r10 + VAR_CRC], eax

    mov rax, [r10 + VAR_NEXT]
    shl rax, CybouDB_PAGE_SHIFT
    add rax, [ctx + DB_BASE]
    mov [rbp - 8], rax
    mov rdx, [descriptor + VAR_CELL_ROOT]
    mov [rax + VAR_NEXT], rdx
    mov ARG1, rax
    mov ARG2, VAR_CRC
    call crc32c
    mov r10, [rbp - 8]
    mov [r10 + VAR_CRC], eax
    mov byte [output], 0x5A
    lea ARG1, [ctx]
    lea ARG2, [candidate]
    lea ARG3, [descriptor]
    mov ARG4, TEST_OWNER
    lea rax, [output]
    PASS_ARG5 rax
    mov rax, TEST_LENGTH
    PASS_ARG6 rax
    call db_var_read_chain
    cmp eax, CybouDB_E_PAX
    jne failure_close
    cmp byte [output], 0x5A
    jne failure_close
    mov qword [r10 + VAR_NEXT], 0
    mov ARG1, r10
    mov ARG2, VAR_CRC
    call crc32c
    mov [r10 + VAR_CRC], eax

    ; Header identity, ownership and reserved bytes are part of validation.
    mov rax, [descriptor + VAR_CELL_ROOT]
    shl rax, CybouDB_PAGE_SHIFT
    add rax, [ctx + DB_BASE]
    xor qword [rax + VAR_PAGE_ID], 1
    xor qword [rax + VAR_OWNER], 1
    mov qword [rax + VAR_RESERVED], 1
    mov ARG1, rax
    mov ARG2, VAR_CRC
    call crc32c
    mov r10, [descriptor + VAR_CELL_ROOT]
    shl r10, CybouDB_PAGE_SHIFT
    add r10, [ctx + DB_BASE]
    mov [r10 + VAR_CRC], eax
    lea ARG1, [ctx]
    lea ARG2, [candidate]
    mov ARG3, [descriptor + VAR_CELL_ROOT]
    mov ARG4, TEST_LENGTH
    mov rax, TEST_OWNER
    PASS_ARG5 rax
    call db_var_validate_chain
    test eax, eax
    jnz failure_close
    mov rax, [descriptor + VAR_CELL_ROOT]
    mov [r10 + VAR_PAGE_ID], rax
    mov qword [r10 + VAR_OWNER], TEST_OWNER
    mov qword [r10 + VAR_RESERVED], 0
    mov ARG1, r10
    mov ARG2, VAR_CRC
    call crc32c
    mov [r10 + VAR_CRC], eax

    ; Generation ordering and canonical used length are also mandatory.
    mov qword [r10 + VAR_GENERATION], 0
    mov qword [r10 + VAR_USED], 0
    mov ARG1, r10
    mov ARG2, VAR_CRC
    call crc32c
    mov [r10 + VAR_CRC], eax
    lea ARG1, [ctx]
    lea ARG2, [candidate]
    mov ARG3, [descriptor + VAR_CELL_ROOT]
    mov ARG4, TEST_LENGTH
    mov rax, TEST_OWNER
    PASS_ARG5 rax
    call db_var_validate_chain
    test eax, eax
    jnz failure_close
    mov r10, [descriptor + VAR_CELL_ROOT]
    shl r10, CybouDB_PAGE_SHIFT
    add r10, [ctx + DB_BASE]
    mov rax, [candidate + SB_GENERATION]
    mov [r10 + VAR_GENERATION], rax
    mov dword [r10 + VAR_USED], VAR_PAYLOAD_SIZE
    mov ARG1, r10
    mov ARG2, VAR_CRC
    call crc32c
    mov [r10 + VAR_CRC], eax

    lea ARG1, [ctx]
    call db_close
    xor eax, eax
    FRAME_END
    ret

; Construct the same minimal staged candidate used by PAX publication checks.
make_candidate:
    mov rax, [ctx + DB_GENERATION]
    inc rax
    mov [candidate + SB_GENERATION], rax
    mov rax, [ctx + DB_ALLOC]
    mov [candidate + SB_ALLOC_PAGES], rax
    mov rax, [ctx + DB_BITMAP]
    mov [candidate + SB_BITMAP_ROOT], rax
    mov dword [candidate + SB_STAGED], 1
    ret

failure_close:
    lea ARG1, [ctx]
    call db_close
failure:
    mov ARG1, 99
    call os_exit

