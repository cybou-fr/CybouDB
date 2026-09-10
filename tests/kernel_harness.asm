; Direct kernel ABI driver. Fixed records: 6 qwords + 520 bytes (568 bytes).
; Header: type, op, nulls, active, literal, flags. Data starts at 48 (+1 if flag4).
; flag1 uses NULL values pointer; flag2 sets unmasked MXCSR, otherwise FTZ/DAZ.
; Outputs true/unknown qwords per record; unsupported pairs output two -1s.
%include "sql.inc"
BITS 64
default rel
extern os_argv, os_write, vfs_open_ro, vfs_size, vfs_map_ro, vfs_unmap, vfs_close
extern sql_kernel_resolve, sql_kernel_force_scalar
extern for8_eq, for8_ne, for8_lt, for8_le, for8_gt, for8_ge
extern for16_eq, for16_ne, for16_lt, for16_le, for16_gt, for16_ge
extern vector_dot_f32_scalar, vector_l2sq_f32_scalar
extern vector_dot_f32_resolve
extern vector_cosine_normalized_f32_resolve
extern os_mem_alloc, os_mem_free
%ifdef CybouDB_WINDOWS
extern VirtualProtect
%endif
global cyboudb_main
section .bss
align 8
file_handle: resq 1
mapped: resq 1
file_size: resq 1
current: resq 1
kernel_fn: resq 1
guard_base: resq 1
result: resq 2
mxcsr_before: resd 1
mxcsr_after: resd 1
mxcsr_original: resd 1
section .text
cyboudb_main:
    FRAME_BEGIN 64, 0
    mov [rbp - 8], rbx
    mov [rbp - 16], r12
    mov [rbp - 24], r13
    mov [rbp - 32], r14
    mov [rbp - 40], r15
    mov [rbp - 48], rsi
    mov [rbp - 56], rdi
    stmxcsr [mxcsr_original]
    call guard_init
    test eax, eax
    jnz .fail
    mov ARG1, 2
    call os_argv
    test rax, rax
    jz .default_kernels
    mov dword [sql_kernel_force_scalar], 1
.default_kernels:
    mov ARG1, 1
    call os_argv
    mov ARG1, rax
    xor ARG2, ARG2
    call vfs_open_ro
    cmp rax, -1
    je .fail
    mov [file_handle], rax
    mov ARG1, rax
    call vfs_size
    test rax, rax
    jle .fail
    mov [file_size], rax
    xor edx, edx
    mov ecx, 568
    div rcx
    test rdx, rdx
    jnz .fail
    mov ARG1, [file_handle]
    mov ARG2, [file_size]
    call vfs_map_ro
    test rax, rax
    jz .fail
    mov [mapped], rax
    mov [current], rax
.loop:
    mov r10, [current]
    cmp qword [r10], 32
    je .vector_dot
    cmp qword [r10], 33
    je .vector_l2
    cmp qword [r10], 34
    je .vector_dot_auto
    cmp qword [r10], 35
    je .vector_cosine_auto
    cmp qword [r10], 8
    je .resolve_for8
    cmp qword [r10], 16
    je .resolve_for16
    mov ARG1, [r10]
    mov ARG2, [r10 + 8]
    call sql_kernel_resolve
    jmp .resolved
.resolve_for8:
    lea rax, [rel for8_table]
    jmp .resolve_for
.resolve_for16:
    lea rax, [rel for16_table]
.resolve_for:
    mov rcx, [r10 + 8]
    dec rcx
    cmp rcx, 5
    ja .unsupported
    mov rax, [rax + rcx * 8]
.resolved:
    test rax, rax
    jz .unsupported
    mov [kernel_fn], rax
    mov r10, [current]
    lea ARG1, [r10 + 48]
    test qword [r10 + 40], 4
    jz .aligned
    inc ARG1
.aligned:
    test qword [r10 + 40], 24          ; guard-page fixture (flags 8 or 16)
    jz .check_null_pointer
    mov ARG1, r10
    call guard_values
    mov ARG1, rax
    mov r10, [current]
.check_null_pointer:
    test qword [r10 + 40], 1
    jz .with_values
    xor ARG1, ARG1
.with_values:
    mov ARG2, [r10 + 16]
    mov ARG3, [r10 + 24]
    mov ARG4, [r10 + 32]
    mov dword [mxcsr_before], 0xffc0
    test qword [r10 + 40], 2
    jz .set_mxcsr
    mov dword [mxcsr_before], 0        ; all exceptions unmasked
.set_mxcsr:
    ldmxcsr [mxcsr_before]
    mov rbx, 0x123456789abcdef0
    mov r12, rbx
    mov r13, rbx
    mov r14, rbx
    mov r15, rbx
%ifdef CybouDB_WINDOWS
    mov rsi, rbx
    mov rdi, rbx
%endif
    call [kernel_fn]
    mov [result], rax
    mov [result + 8], rdx
    mov r10, 0x123456789abcdef0
    cmp rbx, r10
    jne .fail
    cmp r12, r10
    jne .fail
    cmp r13, r10
    jne .fail
    cmp r14, r10
    jne .fail
    cmp r15, r10
    jne .fail
%ifdef CybouDB_WINDOWS
    cmp rsi, r10
    jne .fail
    cmp rdi, r10
    jne .fail
%endif
    stmxcsr [mxcsr_after]
    mov eax, [mxcsr_before]
    cmp eax, [mxcsr_after]
    jne .fail
    ldmxcsr [mxcsr_original]
    jmp .output
.vector_dot:
    lea ARG1, [r10 + 48]
    lea ARG2, [r10 + 304]
    mov ARG3, [r10 + 24]
    call vector_dot_f32_scalar
    jmp .vector_result
.vector_l2:
    lea ARG1, [r10 + 48]
    lea ARG2, [r10 + 304]
    mov ARG3, [r10 + 24]
    call vector_l2sq_f32_scalar
    jmp .vector_result
.vector_dot_auto:
    call vector_dot_f32_resolve
    jmp .vector_auto_ready
.vector_cosine_auto:
    call vector_cosine_normalized_f32_resolve
.vector_auto_ready:
    mov [kernel_fn], rax
    mov r10, [current]
    lea ARG1, [r10 + 48]
    lea ARG2, [r10 + 304]
    mov ARG3, [r10 + 24]
    call [kernel_fn]
.vector_result:
    movd eax, xmm0
    mov [result], rax
    mov qword [result + 8], 0
    jmp .output
.unsupported:
    mov qword [result], -1
    mov qword [result + 8], -1
.output:
    lea ARG1, [result]
    mov ARG2, 16
    call os_write
    add qword [current], 568
    mov rax, [mapped]
    add rax, [file_size]
    cmp [current], rax
    jb .loop
    mov ARG1, [mapped]
    mov ARG2, [file_size]
    call vfs_unmap
    mov ARG1, [file_handle]
    call vfs_close
    mov ARG1, [guard_base]
    mov ARG2, 12288
    call os_mem_free
    xor eax, eax
    jmp .done
.fail:
    mov eax, 99
.done:
    ldmxcsr [mxcsr_original]
    mov rbx, [rbp - 8]
    mov r12, [rbp - 16]
    mov r13, [rbp - 24]
    mov r14, [rbp - 32]
    mov r15, [rbp - 40]
    mov rsi, [rbp - 48]
    mov rdi, [rbp - 56]
    FRAME_END
    ret

section .rodata
align 8
for8_table:  dq for8_eq, for8_ne, for8_lt, for8_le, for8_gt, for8_ge
for16_table: dq for16_eq, for16_ne, for16_lt, for16_le, for16_gt, for16_ge

section .text
; Three pages: inaccessible / writable / inaccessible. Setup failures fail
; the suite rather than silently skipping memory-safety checks.
guard_init:
    FRAME_BEGIN 16, 0
    mov ARG1, 12288
    call os_mem_alloc
    test rax, rax
    jz .failed
    mov [guard_base], rax
%ifdef CybouDB_WINDOWS
    mov ARG1, rax
    mov ARG2, 4096
    mov ARG3, 1                       ; PAGE_NOACCESS
    lea ARG4, [rbp - 8]
    call VirtualProtect
    test eax, eax
    jz .failed
    mov ARG1, [guard_base]
    add ARG1, 8192
    mov ARG2, 4096
    mov ARG3, 1
    lea ARG4, [rbp - 8]
    call VirtualProtect
    test eax, eax
    jz .failed
%else
    mov rdi, rax
    mov esi, 4096
    xor edx, edx                     ; PROT_NONE
    mov eax, 10                      ; mprotect
    syscall
    test rax, rax
    jnz .failed
    mov rdi, [guard_base]
    add rdi, 8192
    mov esi, 4096
    xor edx, edx
    mov eax, 10
    syscall
    test rax, rax
    jnz .failed
%endif
    xor eax, eax
    FRAME_END
    ret
.failed:
    mov eax, 1
    FRAME_END
    ret

; ARG1=record. flags>>8 gives accessible prefix length (flag8) or inaccessible
; prefix length (flag16). Return a base pointer placing the exact lane boundary
; against a guard page, copying only the addressable portion of fixture data.
guard_values:
    mov r10, ARG1
    mov r11d, 4
    cmp qword [r10], 2
    jne .not_i64
    mov r11d, 8
.not_i64:
    cmp qword [r10], 4
    jne .width_ready
    mov r11d, 1
.width_ready:
    mov rcx, [r10 + 40]
    shr rcx, 8
    imul rcx, r11                    ; prefix byte count
    lea rdx, [r10 + 48]
    mov r9, [guard_base]
    test qword [r10 + 40], 16
    jnz .head
    add r9, 8192
    sub r9, rcx
    mov r10, r9                      ; destination
    jmp .copy
.head:
    add r9, 4096
    mov r10, r9
    sub r9, rcx                      ; values base includes unreadable prefix
    add rdx, rcx
    shl r11, 6                       ; 64 lanes
    sub r11, rcx
    mov rcx, r11
.copy:
    xor r8d, r8d
.loop:
    cmp r8, rcx
    jae .done
    mov al, [rdx + r8]
    mov [r10 + r8], al
    inc r8
    jmp .loop
.done:
    mov rax, r9
    ret

%ifdef CybouDB_LINUX
section .note.GNU-stack noalloc noexec nowrite progbits
%endif
