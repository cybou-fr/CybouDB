; Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
; SPDX-License-Identifier: Apache-2.0
; Exact streaming top-K for normalized cosine and squared L2.
; Results are sorted deterministically:
; Cosine: score descending, then vector id ascending.
; L2: squared distance ascending, then vector id ascending.
%include "cyboudb.inc"
%include "vector.inc"
BITS 64
default rel

extern vector_cosine_normalized_f32_resolve
extern vector_l2sq_f32_resolve
global vector_topk_init, cyboudb_vector_topk_init
global vector_topk_cosine_begin, cyboudb_vector_topk_cosine_begin
global vector_topk_cosine_feed, cyboudb_vector_topk_cosine_feed
global vector_topk_cosine_finish, cyboudb_vector_topk_cosine_finish
global vector_topk_l2sq_begin, cyboudb_vector_topk_l2sq_begin
global vector_topk_l2sq_feed, cyboudb_vector_topk_l2sq_feed
global vector_topk_l2sq_finish, cyboudb_vector_topk_l2sq_finish
global vector_topk_cosine_f32, vector_topk_l2sq_f32
global cyboudb_vector_topk_cosine_f32, cyboudb_vector_topk_l2sq_f32

; r12 = state, rbx = bytes per vector. Validate every derived address before
; dispatch. This proves arithmetic does not wrap; readable/writable capacity
; remains the C caller's responsibility, as with any pointer-based API.
%macro VTOPK_VALIDATE_RANGES 1
    cmp dword [r12 + VTOPK_STRUCT_SIZE], VTOPK_STATE_SIZE
    jne %1
    cmp dword [r12 + VTOPK_ABI_VERSION], CybouDB_VECTOR_ABI_VERSION
    jne %1
    mov rax, [r12 + VTOPK_QUERY]
    add rax, rbx
    jc %1
    mov r9, [r12 + VTOPK_COUNT]
    test r9, r9
    jz %%done

    mov rcx, r9
    dec rcx
    mov rax, [r12 + VTOPK_STRIDE]
    mul rcx
    test rdx, rdx
    jnz %1
    add rax, rbx
    jc %1
    add rax, [r12 + VTOPK_VECTORS]
    jc %1

    mov rax, [r12 + VTOPK_CANDIDATES]
    test rax, rax
    jz %%outputs
    mov rcx, r9
    dec rcx
    shr rcx, 3
    add rax, rcx
    jc %1
    inc rax
    jz %1

%%outputs:
    mov rcx, [r12 + VTOPK_K]
    cmp rcx, r9
    cmova rcx, r9
    dec rcx
    mov rax, rcx
    mov r8d, 8
    mul r8
    test rdx, rdx
    jnz %1
    add rax, 8
    jc %1
    add rax, [r12 + VTOPK_OUT_IDS]
    jc %1
    mov rax, rcx
    mov r8d, 4
    mul r8
    test rdx, rdx
    jnz %1
    add rax, 4
    jc %1
    add rax, [r12 + VTOPK_OUT_SCORES]
    jc %1
%%done:
%endmacro

section .text

; cyboudb_vector_topk_init(search) -> status
cyboudb_vector_topk_init:
vector_topk_init:
    test ARG1, ARG1
    jz .init_invalid
    mov r10, ARG1
    xor eax, eax
    mov edx, VTOPK_STATE_SIZE / 8
.init_zero:
    mov qword [r10], 0
    add r10, 8
    dec edx
    jnz .init_zero
    mov dword [ARG1 + VTOPK_STRUCT_SIZE], VTOPK_STATE_SIZE
    mov dword [ARG1 + VTOPK_ABI_VERSION], CybouDB_VECTOR_ABI_VERSION
    xor eax, eax
    ret
.init_invalid:
    mov eax, VECTOR_INVALID
    ret

; Common begin logic for cosine and l2sq
%macro VTOPK_BEGIN_IMPL 0
    test ARG1, ARG1
    jz %%begin_invalid
    cmp dword [ARG1 + VTOPK_STRUCT_SIZE], VTOPK_STATE_SIZE
    jne %%begin_invalid
    cmp dword [ARG1 + VTOPK_ABI_VERSION], CybouDB_VECTOR_ABI_VERSION
    jne %%begin_invalid
    cmp qword [ARG1 + VTOPK_DIM], 0
    je %%begin_invalid
    cmp qword [ARG1 + VTOPK_K], 0
    je %%begin_invalid
    cmp qword [ARG1 + VTOPK_QUERY], 0
    je %%begin_invalid
    cmp qword [ARG1 + VTOPK_OUT_IDS], 0
    je %%begin_invalid
    cmp qword [ARG1 + VTOPK_OUT_SCORES], 0
    je %%begin_invalid
    cmp qword [ARG1 + VTOPK_REVERSE], 1
    ja %%begin_invalid
    mov rax, [ARG1 + VTOPK_DIM]
    mov rdx, 0x3fffffffffffffff
    cmp rax, rdx
    ja %%begin_invalid
    shl rax, 2
    cmp [ARG1 + VTOPK_STRIDE], rax
    jb %%begin_invalid
    ; query address range wrap check
    mov rdx, [ARG1 + VTOPK_QUERY]
    add rdx, rax
    jc %%begin_invalid
    ; out_ids range wrap check
    mov rax, [ARG1 + VTOPK_K]
    dec rax
    mov r8d, 8
    mul r8
    test rdx, rdx
    jnz %%begin_invalid
    add rax, 8
    jc %%begin_invalid
    add rax, [ARG1 + VTOPK_OUT_IDS]
    jc %%begin_invalid
    ; out_scores range wrap check
    mov rax, [ARG1 + VTOPK_K]
    dec rax
    mov r8d, 4
    mul r8
    test rdx, rdx
    jnz %%begin_invalid
    add rax, 4
    jc %%begin_invalid
    add rax, [ARG1 + VTOPK_OUT_SCORES]
    jc %%begin_invalid
    mov qword [ARG1 + VTOPK_OUT_COUNT], 0
    mov qword [ARG1 + VTOPK_EVAL_COUNT], 0
    xor eax, eax
    ret
%%begin_invalid:
    mov eax, VECTOR_INVALID
    ret
%endmacro

cyboudb_vector_topk_cosine_begin:
vector_topk_cosine_begin:
    VTOPK_BEGIN_IMPL

cyboudb_vector_topk_l2sq_begin:
vector_topk_l2sq_begin:
    VTOPK_BEGIN_IMPL

cyboudb_vector_topk_cosine_finish:
vector_topk_cosine_finish:
cyboudb_vector_topk_l2sq_finish:
vector_topk_l2sq_finish:
    test ARG1, ARG1
    jz .finish_invalid
    cmp dword [ARG1 + VTOPK_STRUCT_SIZE], VTOPK_STATE_SIZE
    jne .finish_invalid
    cmp dword [ARG1 + VTOPK_ABI_VERSION], CybouDB_VECTOR_ABI_VERSION
    jne .finish_invalid
    xor eax, eax
    ret
.finish_invalid:
    mov eax, VECTOR_INVALID
    ret

; cyboudb_vector_topk_cosine_feed(search, base_id, vectors, count, candidate_mask)
cyboudb_vector_topk_cosine_feed:
vector_topk_cosine_feed:
    FRAME_BEGIN 64, 0
    mov [rbp - 8], rbx
    mov [rbp - 16], r12
    mov [rbp - 24], r13
    mov [rbp - 32], r14
    mov [rbp - 40], r15
    mov r12, ARG1                   ; search
    mov r13, ARG2                   ; base_id
    mov rbx, ARG3                   ; vectors
    mov r14, ARG4                   ; count
    mov r15, IN_ARG5                ; candidate_mask
    test r12, r12
    jz .cfeed_invalid
    cmp dword [r12 + VTOPK_STRUCT_SIZE], VTOPK_STATE_SIZE
    jne .cfeed_invalid
    cmp dword [r12 + VTOPK_ABI_VERSION], CybouDB_VECTOR_ABI_VERSION
    jne .cfeed_invalid
    test r14, r14
    jz .cfeed_success
    cmp r14, 64
    ja .cfeed_invalid
    test rbx, rbx
    jz .cfeed_invalid
    mov rax, r13
    add rax, r14
    jc .cfeed_invalid
    ; Validate vectors buffer range
    mov rcx, r14
    dec rcx
    mov rax, [r12 + VTOPK_STRIDE]
    mul rcx
    test rdx, rdx
    jnz .cfeed_invalid
    mov rcx, [r12 + VTOPK_DIM]
    shl rcx, 2
    add rax, rcx
    jc .cfeed_invalid
    add rax, rbx
    jc .cfeed_invalid
    test r15, r15
    jz .cfeed_success

    call vector_cosine_normalized_f32_resolve
    mov [rbp - 56], rax             ; kernel ptr
    xor r10d, r10d                  ; lane index (0..count-1)
.cfeed_loop:
    cmp r10, r14
    jae .cfeed_success
    mov [rbp - 64], r10
    bt r15, r10
    jnc .cfeed_next
    mov rax, r10
    imul rax, [r12 + VTOPK_STRIDE]
    add rax, rbx
    mov ARG1, [r12 + VTOPK_QUERY]
    mov ARG2, rax
    mov ARG3, [r12 + VTOPK_DIM]
    call qword [rbp - 56]
    inc qword [r12 + VTOPK_EVAL_COUNT]
    ucomiss xmm0, xmm0
    jp .cfeed_nonfinite
    movd eax, xmm0
    and eax, 0x7f800000
    cmp eax, 0x7f800000
    je .cfeed_nonfinite
    movss [rbp - 48], xmm0
    mov r10, [rbp - 64]
    mov r8, r13
    add r8, r10                     ; candidate id = base_id + lane

    ; Insert candidate (r8, xmm0) into top-K
    mov r9, [r12 + VTOPK_OUT_COUNT]
    xor r11d, r11d
.cfeed_find:
    cmp r11, r9
    jae .cfeed_pos_ready
    mov rax, [r12 + VTOPK_OUT_SCORES]
    cmp qword [r12 + VTOPK_REVERSE], 0
    jne .cfeed_find_rev
    ucomiss xmm0, [rax + r11 * 4]
    ja .cfeed_pos_ready
    jmp .cfeed_find_next
.cfeed_find_rev:
    ucomiss xmm0, [rax + r11 * 4]
    jb .cfeed_pos_ready
.cfeed_find_next:
    inc r11
    jmp .cfeed_find
.cfeed_pos_ready:
    cmp r11, [r12 + VTOPK_K]
    jae .cfeed_next
    mov rcx, r9
    cmp rcx, [r12 + VTOPK_K]
    jb .cfeed_grow
    dec rcx
    jmp .cfeed_shift
.cfeed_grow:
    inc qword [r12 + VTOPK_OUT_COUNT]
.cfeed_shift:
    cmp rcx, r11
    jbe .cfeed_store
    mov rax, [r12 + VTOPK_OUT_IDS]
    mov rdx, [rax + rcx * 8 - 8]
    mov [rax + rcx * 8], rdx
    mov rax, [r12 + VTOPK_OUT_SCORES]
    mov edx, [rax + rcx * 4 - 4]
    mov [rax + rcx * 4], edx
    dec rcx
    jmp .cfeed_shift
.cfeed_store:
    mov rax, [r12 + VTOPK_OUT_IDS]
    mov [rax + r11 * 8], r8
    mov rax, [r12 + VTOPK_OUT_SCORES]
    mov edx, [rbp - 48]
    mov [rax + r11 * 4], edx
.cfeed_next:
    mov r10, [rbp - 64]
    inc r10
    jmp .cfeed_loop

.cfeed_success:
    xor eax, eax
    jmp .cfeed_done
.cfeed_invalid:
    mov eax, VECTOR_INVALID
    jmp .cfeed_done
.cfeed_nonfinite:
    mov eax, VECTOR_NONFINITE
.cfeed_done:
    mov rbx, [rbp - 8]
    mov r12, [rbp - 16]
    mov r13, [rbp - 24]
    mov r14, [rbp - 32]
    mov r15, [rbp - 40]
    FRAME_END
    ret

; cyboudb_vector_topk_l2sq_feed(search, base_id, vectors, count, candidate_mask)
cyboudb_vector_topk_l2sq_feed:
vector_topk_l2sq_feed:
    FRAME_BEGIN 64, 0
    mov [rbp - 8], rbx
    mov [rbp - 16], r12
    mov [rbp - 24], r13
    mov [rbp - 32], r14
    mov [rbp - 40], r15
    mov r12, ARG1                   ; search
    mov r13, ARG2                   ; base_id
    mov rbx, ARG3                   ; vectors
    mov r14, ARG4                   ; count
    mov r15, IN_ARG5                ; candidate_mask
    test r12, r12
    jz .lfeed_invalid
    cmp dword [r12 + VTOPK_STRUCT_SIZE], VTOPK_STATE_SIZE
    jne .lfeed_invalid
    cmp dword [r12 + VTOPK_ABI_VERSION], CybouDB_VECTOR_ABI_VERSION
    jne .lfeed_invalid
    test r14, r14
    jz .lfeed_success
    cmp r14, 64
    ja .lfeed_invalid
    test rbx, rbx
    jz .lfeed_invalid
    mov rax, r13
    add rax, r14
    jc .lfeed_invalid
    ; Validate vectors buffer range
    mov rcx, r14
    dec rcx
    mov rax, [r12 + VTOPK_STRIDE]
    mul rcx
    test rdx, rdx
    jnz .lfeed_invalid
    mov rcx, [r12 + VTOPK_DIM]
    shl rcx, 2
    add rax, rcx
    jc .lfeed_invalid
    add rax, rbx
    jc .lfeed_invalid
    test r15, r15
    jz .lfeed_success

    call vector_l2sq_f32_resolve
    mov [rbp - 56], rax
    xor r10d, r10d
.lfeed_loop:
    cmp r10, r14
    jae .lfeed_success
    mov [rbp - 64], r10
    bt r15, r10
    jnc .lfeed_next
    mov rax, r10
    imul rax, [r12 + VTOPK_STRIDE]
    add rax, rbx
    mov ARG1, [r12 + VTOPK_QUERY]
    mov ARG2, rax
    mov ARG3, [r12 + VTOPK_DIM]
    call qword [rbp - 56]
    inc qword [r12 + VTOPK_EVAL_COUNT]
    ucomiss xmm0, xmm0
    jp .lfeed_nonfinite
    movd eax, xmm0
    and eax, 0x7f800000
    cmp eax, 0x7f800000
    je .lfeed_nonfinite
    movss [rbp - 48], xmm0
    mov r10, [rbp - 64]
    mov r8, r13
    add r8, r10

    ; Insert candidate (r8, xmm0) into top-K (lower distance is better)
    mov r9, [r12 + VTOPK_OUT_COUNT]
    xor r11d, r11d
.lfeed_find:
    cmp r11, r9
    jae .lfeed_pos_ready
    mov rax, [r12 + VTOPK_OUT_SCORES]
    cmp qword [r12 + VTOPK_REVERSE], 0
    jne .lfeed_find_rev
    ucomiss xmm0, [rax + r11 * 4]
    jb .lfeed_pos_ready
    jmp .lfeed_find_next
.lfeed_find_rev:
    ucomiss xmm0, [rax + r11 * 4]
    ja .lfeed_pos_ready
.lfeed_find_next:
    inc r11
    jmp .lfeed_find
.lfeed_pos_ready:
    cmp r11, [r12 + VTOPK_K]
    jae .lfeed_next
    mov rcx, r9
    cmp rcx, [r12 + VTOPK_K]
    jb .lfeed_grow
    dec rcx
    jmp .lfeed_shift
.lfeed_grow:
    inc qword [r12 + VTOPK_OUT_COUNT]
.lfeed_shift:
    cmp rcx, r11
    jbe .lfeed_store
    mov rax, [r12 + VTOPK_OUT_IDS]
    mov rdx, [rax + rcx * 8 - 8]
    mov [rax + rcx * 8], rdx
    mov rax, [r12 + VTOPK_OUT_SCORES]
    mov edx, [rax + rcx * 4 - 4]
    mov [rax + rcx * 4], edx
    dec rcx
    jmp .lfeed_shift
.lfeed_store:
    mov rax, [r12 + VTOPK_OUT_IDS]
    mov [rax + r11 * 8], r8
    mov rax, [r12 + VTOPK_OUT_SCORES]
    mov edx, [rbp - 48]
    mov [rax + r11 * 4], edx
.lfeed_next:
    mov r10, [rbp - 64]
    inc r10
    jmp .lfeed_loop

.lfeed_success:
    xor eax, eax
    jmp .lfeed_done
.lfeed_invalid:
    mov eax, VECTOR_INVALID
    jmp .lfeed_done
.lfeed_nonfinite:
    mov eax, VECTOR_NONFINITE
.lfeed_done:
    mov rbx, [rbp - 8]
    mov r12, [rbp - 16]
    mov r13, [rbp - 24]
    mov r14, [rbp - 32]
    mov r15, [rbp - 40]
    FRAME_END
    ret

; Exact streaming top-K for normalized cosine (monolithic candidate scan)
cyboudb_vector_topk_cosine_f32:
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
    cmp dword [r12 + VTOPK_STRUCT_SIZE], VTOPK_STATE_SIZE
    jne .invalid
    cmp dword [r12 + VTOPK_ABI_VERSION], CybouDB_VECTOR_ABI_VERSION
    jne .invalid
    mov qword [r12 + VTOPK_OUT_COUNT], 0
    mov qword [r12 + VTOPK_EVAL_COUNT], 0
    cmp qword [r12 + VTOPK_DIM], 0
    je .invalid
    cmp qword [r12 + VTOPK_K], 0
    je .invalid
    cmp qword [r12 + VTOPK_REVERSE], 1
    ja .invalid
    cmp qword [r12 + VTOPK_QUERY], 0
    je .invalid
    cmp qword [r12 + VTOPK_VECTORS], 0
    je .invalid
    cmp qword [r12 + VTOPK_OUT_IDS], 0
    je .invalid
    cmp qword [r12 + VTOPK_OUT_SCORES], 0
    je .invalid
    mov rax, [r12 + VTOPK_DIM]
    mov rdx, 0x3fffffffffffffff
    cmp rax, rdx
    ja .invalid
    shl rax, 2
    cmp [r12 + VTOPK_STRIDE], rax
    jb .invalid
    mov rbx, rax
    VTOPK_VALIDATE_RANGES .invalid
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
    movd eax, xmm0
    and eax, 0x7f800000
    cmp eax, 0x7f800000
    je .nonfinite
    movss [rbp - 48], xmm0
    xor r11d, r11d                  ; insertion position
.find_position:
    cmp r11, r15
    jae .position_ready
    mov rax, [r12 + VTOPK_OUT_SCORES]
    cmp qword [r12 + VTOPK_REVERSE], 0
    jne .find_position_rev
    ucomiss xmm0, [rax + r11 * 4]
    ja .position_ready
    jmp .find_position_next
    ; Equal scores stay behind earlier (therefore smaller) vector ids.
.find_position_rev:
    ucomiss xmm0, [rax + r11 * 4]
    jb .position_ready
.find_position_next:
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

; Exact streaming Top-K squared L2 (monolithic candidate scan).
cyboudb_vector_topk_l2sq_f32:
vector_topk_l2sq_f32:
    FRAME_BEGIN 64, 0
    mov [rbp - 8], rbx
    mov [rbp - 16], r12
    mov [rbp - 24], r13
    mov [rbp - 32], r14
    mov [rbp - 40], r15
    mov r12, ARG1
    test r12, r12
    jz .l2_invalid
    cmp dword [r12 + VTOPK_STRUCT_SIZE], VTOPK_STATE_SIZE
    jne .l2_invalid
    cmp dword [r12 + VTOPK_ABI_VERSION], CybouDB_VECTOR_ABI_VERSION
    jne .l2_invalid
    mov qword [r12 + VTOPK_OUT_COUNT], 0
    mov qword [r12 + VTOPK_EVAL_COUNT], 0
    cmp qword [r12 + VTOPK_DIM], 0
    je .l2_invalid
    cmp qword [r12 + VTOPK_K], 0
    je .l2_invalid
    cmp qword [r12 + VTOPK_REVERSE], 1
    ja .l2_invalid
    cmp qword [r12 + VTOPK_QUERY], 0
    je .l2_invalid
    cmp qword [r12 + VTOPK_VECTORS], 0
    je .l2_invalid
    cmp qword [r12 + VTOPK_OUT_IDS], 0
    je .l2_invalid
    cmp qword [r12 + VTOPK_OUT_SCORES], 0
    je .l2_invalid
    mov rax, [r12 + VTOPK_DIM]
    mov rdx, 0x3fffffffffffffff
    cmp rax, rdx
    ja .l2_invalid
    shl rax, 2
    cmp [r12 + VTOPK_STRIDE], rax
    jb .l2_invalid
    mov rbx, rax
    VTOPK_VALIDATE_RANGES .l2_invalid
    call vector_l2sq_f32_resolve
    mov r13, rax
    xor r14d, r14d
    xor r15d, r15d
.l2_candidate:
    cmp r14, [r12 + VTOPK_COUNT]
    jae .l2_success
    mov rax, [r12 + VTOPK_CANDIDATES]
    test rax, rax
    jz .l2_evaluate
    bt [rax], r14
    jnc .l2_next
.l2_evaluate:
    mov rbx, r14
    imul rbx, [r12 + VTOPK_STRIDE]
    add rbx, [r12 + VTOPK_VECTORS]
    mov ARG1, [r12 + VTOPK_QUERY]
    mov ARG2, rbx
    mov ARG3, [r12 + VTOPK_DIM]
    call r13
    inc qword [r12 + VTOPK_EVAL_COUNT]
    ucomiss xmm0, xmm0
    jp .l2_nonfinite
    movd eax, xmm0
    and eax, 0x7f800000
    cmp eax, 0x7f800000
    je .l2_nonfinite
    movss [rbp - 48], xmm0
    xor r11d, r11d
.l2_find:
    cmp r11, r15
    jae .l2_position
    mov rax, [r12 + VTOPK_OUT_SCORES]
    cmp qword [r12 + VTOPK_REVERSE], 0
    jne .l2_find_rev
    ucomiss xmm0, [rax + r11 * 4]
    jb .l2_position
    jmp .l2_find_next
.l2_find_rev:
    ucomiss xmm0, [rax + r11 * 4]
    ja .l2_position
.l2_find_next:
    inc r11
    jmp .l2_find
.l2_position:
    cmp r11, [r12 + VTOPK_K]
    jae .l2_next
    mov r10, r15
    cmp r10, [r12 + VTOPK_K]
    jb .l2_grow
    dec r10
    jmp .l2_shift
.l2_grow:
    inc r15
.l2_shift:
    cmp r10, r11
    jbe .l2_store
    mov rcx, [r12 + VTOPK_OUT_IDS]
    mov rax, [rcx + r10 * 8 - 8]
    mov [rcx + r10 * 8], rax
    mov rcx, [r12 + VTOPK_OUT_SCORES]
    mov eax, [rcx + r10 * 4 - 4]
    mov [rcx + r10 * 4], eax
    dec r10
    jmp .l2_shift
.l2_store:
    mov rax, [r12 + VTOPK_OUT_IDS]
    mov [rax + r11 * 8], r14
    mov rax, [r12 + VTOPK_OUT_SCORES]
    mov ecx, [rbp - 48]
    mov [rax + r11 * 4], ecx
.l2_next:
    inc r14
    jmp .l2_candidate
.l2_success:
    mov [r12 + VTOPK_OUT_COUNT], r15
    xor eax, eax
    jmp .l2_done
.l2_invalid:
    mov eax, VECTOR_INVALID
    jmp .l2_done
.l2_nonfinite:
    mov eax, VECTOR_NONFINITE
.l2_done:
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
