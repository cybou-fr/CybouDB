; Regression driver for non-contiguous variable-width extent allocation.
%include "cyboudb.inc"
BITS 64
default rel
extern os_argv, os_exit
extern db_open_cow, db_close, db_commit, db_bitmap_retire, db_cow_alloc_page
extern db_var_write_chain

global cyboudb_main

%define TEST_LENGTH (VAR_PAYLOAD_SIZE + 37)
%define TEST_OWNER 77
%define FILL_PAGES 123

section .bss
align 8
ctx:        resb CybouDB_DB_SIZE
ids:        resq FILL_PAGES
descriptor: resb VAR_CELL_SIZE
source:     resb TEST_LENGTH

section .text
cyboudb_main:
    FRAME_BEGIN 16, 0
    mov ARG1, 1
    call os_argv
    test rax, rax
    jz failure
    mov ARG1, rax
    lea ARG2, [ctx]
    call db_open_cow
    test eax, eax
    jnz failure

    ; Fill a 128-page span-map file from its initial high-water mark.
    mov qword [rbp - 8], 0
.fill:
    lea ARG1, [ctx]
    lea r10, [ids]
    mov rax, [rbp - 8]
    lea ARG2, [r10 + rax * 8]
    call db_cow_alloc_page
    test eax, eax
    jnz failure_close
    inc qword [rbp - 8]
    cmp qword [rbp - 8], FILL_PAGES
    jb .fill

    lea ARG1, [ctx]
    call db_commit
    test eax, eax
    jnz failure_close

    ; Retire alternating pages and publish the holes.
    mov qword [rbp - 8], 0
.retire:
    test byte [rbp - 8], 1
    jnz .retire_next
    lea ARG1, [ctx]
    lea r10, [ids]
    mov rax, [rbp - 8]
    mov ARG2, [r10 + rax * 8]
    call db_bitmap_retire
.retire_next:
    inc qword [rbp - 8]
    cmp qword [rbp - 8], FILL_PAGES
    jb .retire

    lea ARG1, [ctx]
    call db_commit
    test eax, eax
    jnz failure_close

    ; A two-page value must reuse two holes even though no contiguous run exists.
    lea ARG1, [ctx]
    lea ARG2, [source]
    mov ARG3, TEST_LENGTH
    mov ARG4, TEST_OWNER
    lea rax, [descriptor]
    PASS_ARG5 rax
    call db_var_write_chain
    test eax, eax
    jnz failure_close

    mov rax, [descriptor + VAR_CELL_ROOT]
    mov r10, rax
    shl r10, CybouDB_PAGE_SHIFT
    add r10, [ctx + DB_BASE]
    mov rax, [r10 + VAR_NEXT]
    mov rdx, [descriptor + VAR_CELL_ROOT]
    inc rdx
    cmp rax, rdx
    je failure_close

    lea ARG1, [ctx]
    call db_close
    xor eax, eax
    FRAME_END
    ret

failure_close:
    lea ARG1, [ctx]
    call db_close
failure:
    mov ARG1, 99
    call os_exit
