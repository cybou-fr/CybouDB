; Storage-independent contiguous arena for FLOAT32 vectors.
%include "cyboudb.inc"
%include "vector.inc"
BITS 64
default rel

extern vector_normalize_f32_resolve
global vector_arena_init, vector_arena_append, vector_arena_append_raw, vector_arena_append_normalized, vector_arena_get
global cyboudb_vector_arena_init, cyboudb_vector_arena_append, cyboudb_vector_arena_append_raw, cyboudb_vector_arena_append_normalized, cyboudb_vector_arena_get

section .text
; vector_arena_init(state, base, capacity_bytes, dimensions) -> status
cyboudb_vector_arena_init:
vector_arena_init:
    test ARG1, ARG1
    jz .init_invalid
    test ARG2, ARG2
    jz .init_invalid
    test ARG4, ARG4
    jz .init_invalid
    mov rax, ARG4
    mov r10, 0x3fffffffffffffff
    cmp rax, r10
    ja .init_invalid
    shl rax, 2
    cmp ARG3, rax
    jb .init_invalid
    mov r10, ARG2
    add r10, ARG3
    jc .init_invalid
    mov dword [ARG1 + VARENA_STRUCT_SIZE], VARENA_SIZE
    mov dword [ARG1 + VARENA_ABI_VERSION], CybouDB_VECTOR_ABI_VERSION
    mov [ARG1 + VARENA_BASE], ARG2
    mov [ARG1 + VARENA_CAPACITY], ARG3
    mov qword [ARG1 + VARENA_USED], 0
    mov [ARG1 + VARENA_DIM], ARG4
    mov [ARG1 + VARENA_STRIDE], rax
    mov qword [ARG1 + VARENA_COUNT], 0
    xor eax, eax
    ret
.init_invalid:
    mov eax, VECTOR_INVALID
    ret

; Common validation macro for append functions.
%macro VARENA_VALIDATE_APPEND 1
    test r12, r12
    jz %1
    cmp dword [r12 + VARENA_STRUCT_SIZE], VARENA_SIZE
    jne %1
    cmp dword [r12 + VARENA_ABI_VERSION], CybouDB_VECTOR_ABI_VERSION
    jne %1
    test r13, r13
    jz %1
    test r14, r14
    jz %1
    mov rax, r14
    add rax, 8
    jc %1
    mov rax, [r12 + VARENA_DIM]
    test rax, rax
    jz %1
    mov rcx, 0x3fffffffffffffff
    cmp rax, rcx
    ja %1
    shl rax, 2
    cmp rax, [r12 + VARENA_STRIDE]
    jne %1
    mov rcx, [r12 + VARENA_BASE]
    test rcx, rcx
    jz %1
    add rcx, [r12 + VARENA_CAPACITY]
    jc %1
    mov rcx, r13
    add rcx, rax
    jc %1
    mov rax, [r12 + VARENA_COUNT]
    mul qword [r12 + VARENA_STRIDE]
    test rdx, rdx
    jnz %1
    cmp rax, [r12 + VARENA_USED]
    jne %1
    mov rax, [r12 + VARENA_USED]
    cmp rax, [r12 + VARENA_CAPACITY]
    ja %1
%endmacro

; vector_arena_append_raw(state, input, out_id) -> status
cyboudb_vector_arena_append_raw:
vector_arena_append_raw:
    FRAME_BEGIN 32, 0
    mov [rbp - 8], r12
    mov [rbp - 16], r13
    mov [rbp - 24], r14
    mov r12, ARG1
    mov r13, ARG2
    mov r14, ARG3
    VARENA_VALIDATE_APPEND .raw_invalid
    mov rax, [r12 + VARENA_USED]
    add rax, [r12 + VARENA_STRIDE]
    jc .raw_full
    cmp rax, [r12 + VARENA_CAPACITY]
    ja .raw_full

    ; Validate finite floats (no NaN, no Inf)
    xor r9d, r9d
.raw_check_loop:
    cmp r9, [r12 + VARENA_DIM]
    jae .raw_copy
    movss xmm0, [r13 + r9 * 4]
    ucomiss xmm0, xmm0
    jp .raw_nonfinite
    movd eax, xmm0
    and eax, 0x7f800000
    cmp eax, 0x7f800000
    je .raw_nonfinite
    inc r9
    jmp .raw_check_loop

.raw_copy:
    mov r10, [r12 + VARENA_BASE]
    add r10, [r12 + VARENA_USED]
    xor r9d, r9d
.raw_copy_loop:
    cmp r9, [r12 + VARENA_DIM]
    jae .raw_success
    mov eax, [r13 + r9 * 4]
    mov [r10 + r9 * 4], eax
    inc r9
    jmp .raw_copy_loop

.raw_success:
    mov rax, [r12 + VARENA_COUNT]
    mov [r14], rax
    inc qword [r12 + VARENA_COUNT]
    mov rax, [r12 + VARENA_STRIDE]
    add [r12 + VARENA_USED], rax
    xor eax, eax
    jmp .raw_done
.raw_invalid:
    mov eax, VECTOR_INVALID
    jmp .raw_done
.raw_nonfinite:
    mov eax, VECTOR_NONFINITE
    jmp .raw_done
.raw_full:
    mov eax, VECTOR_FULL
.raw_done:
    mov r12, [rbp - 8]
    mov r13, [rbp - 16]
    mov r14, [rbp - 24]
    FRAME_END
    ret

; Default append aliases append_raw
cyboudb_vector_arena_append:
vector_arena_append:
    jmp vector_arena_append_raw

; vector_arena_append_normalized(state, input, out_id) -> status
cyboudb_vector_arena_append_normalized:
vector_arena_append_normalized:
    FRAME_BEGIN 32, 0
    mov [rbp - 8], r12
    mov [rbp - 16], r13
    mov [rbp - 24], r14
    mov r12, ARG1
    mov r13, ARG2
    mov r14, ARG3
    VARENA_VALIDATE_APPEND .norm_invalid
    mov rax, [r12 + VARENA_USED]
    mov rcx, rax
    add rax, [r12 + VARENA_STRIDE]
    jc .norm_full
    cmp rax, [r12 + VARENA_CAPACITY]
    ja .norm_full
    mov [rbp - 32], rcx
    call vector_normalize_f32_resolve
    mov r10, rax
    mov ARG2, [r12 + VARENA_BASE]
    add ARG2, [rbp - 32]
    mov ARG1, r13
    mov ARG3, [r12 + VARENA_DIM]
    call r10
    test eax, eax
    jnz .norm_done
    mov rax, [r12 + VARENA_COUNT]
    mov [r14], rax
    inc qword [r12 + VARENA_COUNT]
    mov rax, [r12 + VARENA_STRIDE]
    add [r12 + VARENA_USED], rax
    xor eax, eax
    jmp .norm_done
.norm_invalid:
    mov eax, VECTOR_INVALID
    jmp .norm_done
.norm_full:
    mov eax, VECTOR_FULL
.norm_done:
    mov r12, [rbp - 8]
    mov r13, [rbp - 16]
    mov r14, [rbp - 24]
    FRAME_END
    ret

; vector_arena_get(state, vector_id) -> pointer or NULL
cyboudb_vector_arena_get:
vector_arena_get:
    test ARG1, ARG1
    jz .get_missing
    mov r10, ARG1
    mov r11, ARG2
    cmp dword [r10 + VARENA_STRUCT_SIZE], VARENA_SIZE
    jne .get_missing
    cmp dword [r10 + VARENA_ABI_VERSION], CybouDB_VECTOR_ABI_VERSION
    jne .get_missing
    mov rax, [r10 + VARENA_COUNT]
    mul qword [r10 + VARENA_STRIDE]
    test rdx, rdx
    jnz .get_missing
    cmp rax, [r10 + VARENA_USED]
    jne .get_missing
    cmp rax, [r10 + VARENA_CAPACITY]
    ja .get_missing
    mov rcx, [r10 + VARENA_BASE]
    test rcx, rcx
    jz .get_missing
    add rcx, [r10 + VARENA_CAPACITY]
    jc .get_missing
    cmp r11, [r10 + VARENA_COUNT]
    jae .get_missing
    mov rax, r11
    mul qword [r10 + VARENA_STRIDE]
    test rdx, rdx
    jnz .get_missing
    mov rcx, rax
    add rcx, [r10 + VARENA_STRIDE]
    jc .get_missing
    cmp rcx, [r10 + VARENA_CAPACITY]
    ja .get_missing
    add rax, [r10 + VARENA_BASE]
    jc .get_missing
    ret
.get_missing:
    xor eax, eax
    ret

%ifndef CybouDB_WINDOWS
section .note.GNU-stack noalloc noexec nowrite progbits
%endif
