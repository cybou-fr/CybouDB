; Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
; SPDX-License-Identifier: Apache-2.0
; =============================================================================
;  tests/hardware_harness.asm - Hardware CRC-32C and BMI2 Test Driver
; =============================================================================
;  Drives hardware and scalar implementations against oracle test vectors.
;  Reads fixed records of 8224 bytes:
;    Header (32 bytes):
;      qword 0: cmd (1=crc32c, 2=pext, 3=pdep, 4=bzhi, 5=compact_nulls)
;      qword 1: arg1 (len / val / null_mask)
;      qword 2: arg2 (mask / sel_mask / offset)
;      qword 3: force_scalar (0=hardware, 1=scalar)
;    Payload (8192 bytes):
;      Data buffer for CRC32C test cases
;  Outputs 8-byte result per record to stdout.
; =============================================================================

%include "sql.inc"

BITS 64
default rel

extern os_argv, os_write, vfs_open_ro, vfs_size, vfs_map_ro, vfs_unmap, vfs_close
extern crc32c, crc32c_force_scalar
extern cyboudb_popcount64, popcount_force_scalar
extern bmi2_pext64, bmi2_pdep64, bmi2_bzhi64, bmi2_compact_nulls, bmi2_force_scalar

global cyboudb_main

%define RECORD_SIZE 8224

section .bss
align 8
file_handle: resq 1
file_size:   resq 1
mapped:      resq 1
current:     resq 1
out_buf:     resq 1

section .text

cyboudb_main:
    FRAME_BEGIN 32, 0
    mov     [rbp - 8], rbx
    mov     [rbp - 16], r12
    mov     [rbp - 24], r13

    ; argv[1] = fixture file
    mov     ARG1, 1
    call    os_argv
    test    rax, rax
    jz      .fail

    mov     ARG1, rax
    xor     ARG2, ARG2
    call    vfs_open_ro
    cmp     rax, -1
    je      .fail
    mov     [file_handle], rax

    mov     ARG1, rax
    call    vfs_size
    test    rax, rax
    jle     .fail
    mov     [file_size], rax

    ; Check multiple of RECORD_SIZE
    xor     edx, edx
    mov     ecx, RECORD_SIZE
    div     rcx
    test    rdx, rdx
    jnz     .fail

    mov     ARG1, [file_handle]
    mov     ARG2, [file_size]
    call    vfs_map_ro
    test    rax, rax
    jz      .fail
    mov     [mapped], rax
    mov     [current], rax

    ; Loop over records
    mov     r12, [mapped]
    add     r12, [file_size]            ; end pointer
    mov     r13, [current]

.record_loop:
    cmp     r13, r12
    jae     .success

    mov     rax, [r13 + 0]              ; cmd
    mov     rbx, [r13 + 24]             ; force_scalar

    cmp     rax, 1
    je      .run_crc
    cmp     rax, 2
    je      .run_pext
    cmp     rax, 3
    je      .run_pdep
    cmp     rax, 4
    je      .run_bzhi
    cmp     rax, 5
    je      .run_compact
    cmp     rax, 6
    je      .run_popcount
    jmp     .fail

.run_popcount:
    mov     dword [popcount_force_scalar], ebx
    mov     ARG1, [r13 + 8]
    call    cyboudb_popcount64
    mov     [out_buf], rax
    jmp     .emit

.run_crc:
    mov     dword [crc32c_force_scalar], ebx
    lea     ARG1, [r13 + 32]
    ; Check if offset adjustment in arg2
    add     ARG1, [r13 + 16]
    mov     ARG2, [r13 + 8]             ; length
    call    crc32c
    mov     [out_buf], rax
    jmp     .emit

.run_pext:
    mov     dword [bmi2_force_scalar], ebx
    mov     ARG1, [r13 + 8]             ; val
    mov     ARG2, [r13 + 16]            ; mask
    call    bmi2_pext64
    mov     [out_buf], rax
    jmp     .emit

.run_pdep:
    mov     dword [bmi2_force_scalar], ebx
    mov     ARG1, [r13 + 8]             ; val
    mov     ARG2, [r13 + 16]            ; mask
    call    bmi2_pdep64
    mov     [out_buf], rax
    jmp     .emit

.run_bzhi:
    mov     dword [bmi2_force_scalar], ebx
    mov     ARG1, [r13 + 8]             ; val
    mov     ARG2, [r13 + 16]            ; index
    call    bmi2_bzhi64
    mov     [out_buf], rax
    jmp     .emit

.run_compact:
    mov     dword [bmi2_force_scalar], ebx
    mov     ARG1, [r13 + 8]             ; null_mask
    mov     ARG2, [r13 + 16]            ; sel_mask
    call    bmi2_compact_nulls
    mov     [out_buf], rax

.emit:
    lea     ARG1, [out_buf]
    mov     ARG2, 8
    call    os_write

    add     r13, RECORD_SIZE
    jmp     .record_loop

.success:
    mov     ARG1, [mapped]
    mov     ARG2, [file_size]
    call    vfs_unmap
    mov     ARG1, [file_handle]
    call    vfs_close
    mov     rbx, [rbp - 8]
    mov     r12, [rbp - 16]
    mov     r13, [rbp - 24]
    FRAME_END
    xor     eax, eax
    ret

.fail:
    mov     rbx, [rbp - 8]
    mov     r12, [rbp - 16]
    mov     r13, [rbp - 24]
    FRAME_END
    mov     eax, 1
    ret

%ifdef CybouDB_LINUX
section .note.GNU-stack noalloc noexec nowrite progbits
%endif
