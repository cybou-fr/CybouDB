; Exact streaming top-K for normalized cosine. Results are sorted by score
; descending, then vector id ascending. No allocation and no full score array.
%include "cyboudb.inc"
%include "vector.inc"
BITS 64
default rel

extern vector_cosine_normalized_f32_resolve
global vector_topk_cosine_f32

section .text
vector_topk_cosine_f32:
    FRAME_BEGIN 64, 0
    mov [rbp - 8], rbx
    mov [rbp - 16], r12
    mov [rbp - 24], r13
    mov [rbp - 32], r14
    mov [rbp - 40], r15
    mov r12, ARG1
    test r12, r12
    jz .invalid
    mov qword [r12 + VTOPK_OUT_COUNT], 0
    mov qword [r12 + VTOPK_EVAL_COUNT], 0
    cmp qword [r12 + VTOPK_DIM], 0
    je .invalid
    cmp qword [r12 + VTOPK_K], 0
    je .invalid
    cmp qword [r12 + VTOPK_QUERY], 0
    je .invalid
    cmp qword [r12 + VTOPK_VECTORS], 0
    je .invalid
    cmp qword [r12 + VTOPK_OUT_IDS], 0
    je .invalid
    cmp qword [r12 + VTOPK_OUT_SCORES], 0
    je .invalid
    mov rax, [r12 + VTOPK_DIM]
    shl rax, 2
    cmp [r12 + VTOPK_STRIDE], rax
    jb .invalid
    call vector_cosine_normalized_f32_resolve
    mov r13, rax                    ; resolved once per search
    xor r14d, r14d                  ; candidate id
    xor r15d, r15d                  ; retained count
.candidate:
    cmp r14, [r12 + VTOPK_COUNT]
    jae .success
    mov rax, [r12 + VTOPK_CANDIDATES]
    test rax, rax
    jz .evaluate
    bt [rax], r14
    jnc .next_candidate
.evaluate:
    mov rbx, r14
    imul rbx, [r12 + VTOPK_STRIDE]
    add rbx, [r12 + VTOPK_VECTORS]
    mov ARG1, [r12 + VTOPK_QUERY]
    mov ARG2, rbx
    mov ARG3, [r12 + VTOPK_DIM]
    call r13
    inc qword [r12 + VTOPK_EVAL_COUNT]
    ucomiss xmm0, xmm0
    jp .nonfinite
    movss [rbp - 48], xmm0
    xor r11d, r11d                  ; insertion position
.find_position:
    cmp r11, r15
    jae .position_ready
    mov rax, [r12 + VTOPK_OUT_SCORES]
    ucomiss xmm0, [rax + r11 * 4]
    ja .position_ready
    ; Equal scores stay behind earlier (therefore smaller) vector ids.
    inc r11
    jmp .find_position
.position_ready:
    cmp r11, [r12 + VTOPK_K]
    jae .next_candidate
    mov r10, r15                    ; destination slot while shifting
    cmp r10, [r12 + VTOPK_K]
    jb .grow
    dec r10                         ; full: overwrite the previous worst
    jmp .shift
.grow:
    inc r15
.shift:
    cmp r10, r11
    jbe .store
    mov rcx, [r12 + VTOPK_OUT_IDS]
    mov rax, [rcx + r10 * 8 - 8]
    mov [rcx + r10 * 8], rax
    mov rcx, [r12 + VTOPK_OUT_SCORES]
    mov eax, [rcx + r10 * 4 - 4]
    mov [rcx + r10 * 4], eax
    dec r10
    jmp .shift
.store:
    mov rax, [r12 + VTOPK_OUT_IDS]
    mov [rax + r11 * 8], r14
    mov rax, [r12 + VTOPK_OUT_SCORES]
    mov ecx, [rbp - 48]
    mov [rax + r11 * 4], ecx
.next_candidate:
    inc r14
    jmp .candidate
.success:
    mov [r12 + VTOPK_OUT_COUNT], r15
    xor eax, eax
    jmp .done
.invalid:
    mov eax, VECTOR_INVALID
    jmp .done
.nonfinite:
    mov eax, VECTOR_NONFINITE
.done:
    mov rbx, [rbp - 8]
    mov r12, [rbp - 16]
    mov r13, [rbp - 24]
    mov r14, [rbp - 32]
    mov r15, [rbp - 40]
    FRAME_END
    ret

%ifndef CybouDB_WINDOWS
section .note.GNU-stack noalloc noexec nowrite progbits
%endif
