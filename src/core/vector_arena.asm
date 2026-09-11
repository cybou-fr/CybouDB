; Storage-independent contiguous arena for normalized FLOAT32 vectors.
%include "cyboudb.inc"
%include "vector.inc"
BITS 64
default rel

extern vector_normalize_f32_resolve
global vector_arena_init, vector_arena_append, vector_arena_get
global cyboudb_vector_arena_init, cyboudb_vector_arena_append, cyboudb_vector_arena_get

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

; vector_arena_append(state, input, out_id) -> status
cyboudb_vector_arena_append:
vector_arena_append:
    FRAME_BEGIN 32, 0
    mov [rbp - 8], r12
    mov [rbp - 16], r13
    mov [rbp - 24], r14
    mov r12, ARG1
    mov r13, ARG2
    mov r14, ARG3
    test r12, r12
    jz .append_invalid
    test r13, r13
    jz .append_invalid
    test r14, r14
    jz .append_invalid
    mov rax, [r12 + VARENA_USED]
    mov rcx, rax
    add rax, [r12 + VARENA_STRIDE]
    jc .append_full
    cmp rax, [r12 + VARENA_CAPACITY]
    ja .append_full
    mov [rbp - 32], rcx
    call vector_normalize_f32_resolve
    mov r10, rax
    mov ARG2, [r12 + VARENA_BASE]
    add ARG2, [rbp - 32]
    mov ARG1, r13
    mov ARG3, [r12 + VARENA_DIM]
    call r10
    test eax, eax
    jnz .append_done
    mov rax, [r12 + VARENA_COUNT]
    mov [r14], rax
    inc qword [r12 + VARENA_COUNT]
    mov rax, [r12 + VARENA_STRIDE]
    add [r12 + VARENA_USED], rax
    xor eax, eax
    jmp .append_done
.append_invalid:
    mov eax, VECTOR_INVALID
    jmp .append_done
.append_full:
    mov eax, VECTOR_FULL
.append_done:
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
    cmp ARG2, [ARG1 + VARENA_COUNT]
    jae .get_missing
    mov rax, ARG2
    imul rax, [ARG1 + VARENA_STRIDE]
    add rax, [ARG1 + VARENA_BASE]
    ret
.get_missing:
    xor eax, eax
    ret

%ifndef CybouDB_WINDOWS
section .note.GNU-stack noalloc noexec nowrite progbits
%endif
