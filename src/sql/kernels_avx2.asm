; Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
; SPDX-License-Identifier: Apache-2.0
; =============================================================================
;  src/sql/kernels_avx2.asm - AVX2 Vector Predicate Kernels & CPUID Detection
; =============================================================================
;  AVX2 vector predicate kernel ABI v1 matching kernels_scalar.asm:
;    kernel(values, null_mask, active_mask, literal_bits) -> RAX=true, RDX=unknown
;  - Unknown = active & null
;  - True is disjoint from unknown and a subset of active
;  - Evaluates up to 64 rows using 256-bit YMM vector instructions
;  - Preserves callee-saved registers and executes vzeroupper before return
; =============================================================================

%include "sql.inc"

BITS 64
default rel

global cpu_has_avx2
global avx2_kernel_table

; Export individual AVX2 kernel symbols
global avx2_i32_eq,  avx2_i32_neq, avx2_i32_lt,  avx2_i32_lte, avx2_i32_gt,  avx2_i32_gte
global avx2_i64_eq,  avx2_i64_neq, avx2_i64_lt,  avx2_i64_lte, avx2_i64_gt,  avx2_i64_gte
global avx2_f32_eq,  avx2_f32_neq, avx2_f32_lt,  avx2_f32_lte, avx2_f32_gt,  avx2_f32_gte
global avx2_bool_eq, avx2_bool_neq

section .rodata
align 32
f32_abs_mask: times 8 dd 0x7fffffff
f32_inf_mask: times 8 dd 0x7f800000
lane_bits32: dd 1, 2, 4, 8, 16, 32, 64, 128
lane_bits64: dq 1, 2, 4, 8

section .bss
align 4
avx2_cached: resd 1                     ; 0 = uninit, 1 = present, -1 = absent

section .text

; =============================================================================
;  cpu_has_avx2() -> EAX: 1 if AVX2 supported by CPU & OS, 0 otherwise
; =============================================================================
cpu_has_avx2:
    mov     eax, [avx2_cached]
    test    eax, eax
    jnz     .cached

    FRAME_BEGIN 16, 0
    mov     [rbp - 8], rbx              ; RBX is callee-saved, preserve across CPUID

    ; 1. Check max CPUID basic leaf support (need at least leaf 7)
    xor     eax, eax
    cpuid
    cmp     eax, 7
    jb      .no_avx2

    ; 2. Check OSXSAVE (ECX bit 27) and AVX (ECX bit 28) in leaf 1
    mov     eax, 1
    cpuid
    and     ecx, 0x18000000             ; bits 27 and 28
    cmp     ecx, 0x18000000
    jne     .no_avx2

    ; 3. Query XCR0 via XGETBV to verify OS saves SSE (bit 1) and AVX (bit 2) state
    xor     ecx, ecx
    xgetbv                              ; returns EAX:EDX
    and     eax, 6
    cmp     eax, 6
    jne     .no_avx2

    ; 4. Check AVX2 (EBX bit 5) in leaf 7, sub-leaf 0
    mov     eax, 7
    xor     ecx, ecx
    cpuid
    test    ebx, 0x20                   ; bit 5
    jz      .no_avx2

    mov     rbx, [rbp - 8]
    FRAME_END
    mov     dword [avx2_cached], 1
    mov     eax, 1
    ret

.no_avx2:
    mov     rbx, [rbp - 8]
    FRAME_END
    mov     dword [avx2_cached], -1
    xor     eax, eax
    ret

.cached:
    cmp     eax, 1
    sete    al
    movzx   eax, al
    ret


; =============================================================================
;  INT32 AVX2 Kernels (8 lanes per YMM, 8 chunks for 64 rows)
; =============================================================================
; Full chunks retain the ordinary load. Sparse/tail chunks use fault-suppressing
; integer masked loads, so inactive and NULL lane addresses are never read.
%macro LOAD_VALID32 1
    cmp r8b, 0xff
    je %%full
    vmovd xmm1, r8d
    vpbroadcastd ymm1, xmm1
    vpand ymm1, ymm1, [lane_bits32]
    vpcmpeqd ymm1, ymm1, [lane_bits32]
    vpmaskmovd ymm1, ymm1, [%1]
    jmp %%loaded
%%full:
    vmovdqu ymm1, [%1]
%%loaded:
%endmacro

%macro LOAD_VALID64 1
    mov eax, r8d
    and eax, 15
    cmp eax, 15
    je %%full
    vmovq xmm1, r8
    vpbroadcastq ymm1, xmm1
    vpand ymm1, ymm1, [lane_bits64]
    vpcmpeqq ymm1, ymm1, [lane_bits64]
    vpmaskmovq ymm1, ymm1, [%1]
    jmp %%loaded
%%full:
    vmovdqu ymm1, [%1]
%%loaded:
%endmacro

%macro AVX2_I32_KERNEL 2
%1:
    FRAME_BEGIN 16, 0
    mov     rax, ARG2                   ; nulls
    mov     r8, ARG3                    ; active
    and     rax, r8
    mov     [rbp - 8], rax              ; unknown = active & nulls
    not     rax
    and     r8, rax                     ; valid = active & ~nulls
    jz      %%empty

    mov     r10, ARG1                   ; values
    vmovd   xmm0, ARG4d
    vpbroadcastd ymm0, xmm0             ; ymm0 = broadcast literal

    xor     r11, r11                    ; r11 = accumulated true_mask

    ; Unroll 8 chunks of 8 lanes (256 bits = 32 bytes each)
    %assign chunk 0
    %rep 8
        test    r8b, r8b
        jz      %%skip_%[chunk]
        LOAD_VALID32 r10 + chunk * 32
        %2      ymm2, ymm1, ymm0
        vmovmskps eax, ymm2
        and     al, r8b
        %if chunk > 0
        shl     rax, chunk * 8
        or      r11, rax
        %else
        mov     r11, rax
        %endif
    %%skip_%[chunk]:
        shr     r8, 8
        jz      %%done
    %assign chunk chunk+1
    %endrep

%%done:
    vzeroupper
    mov     rax, r11
    mov     rdx, [rbp - 8]
    FRAME_END
    ret

%%empty:
    xor     eax, eax
    mov     rdx, [rbp - 8]
    FRAME_END
    ret
%endmacro

; Operator macro helpers for INT32
%macro I32_OP_EQ 3
    vpcmpeqd %1, %2, %3
%endmacro

%macro I32_OP_NEQ 3
    vpcmpeqd %1, %2, %3
    vpxor    ymm4, ymm4, ymm4
    vpcmpeqd ymm4, ymm4, ymm4           ; ymm4 = all 1s
    vpxor    %1, %1, ymm4               ; invert
%endmacro

%macro I32_OP_GT 3
    vpcmpgtd %1, %2, %3
%endmacro

%macro I32_OP_LTE 3
    vpcmpgtd %1, %2, %3
    vpxor    ymm4, ymm4, ymm4
    vpcmpeqd ymm4, ymm4, ymm4           ; ymm4 = all 1s
    vpxor    %1, %1, ymm4               ; invert
%endmacro

%macro I32_OP_LT 3
    vpcmpgtd %1, %3, %2                 ; lit > val
%endmacro

%macro I32_OP_GTE 3
    vpcmpgtd %1, %3, %2                 ; lit > val
    vpxor    ymm4, ymm4, ymm4
    vpcmpeqd ymm4, ymm4, ymm4           ; ymm4 = all 1s
    vpxor    %1, %1, ymm4               ; invert
%endmacro

AVX2_I32_KERNEL avx2_i32_eq,  I32_OP_EQ
AVX2_I32_KERNEL avx2_i32_neq, I32_OP_NEQ
AVX2_I32_KERNEL avx2_i32_gt,  I32_OP_GT
AVX2_I32_KERNEL avx2_i32_lte, I32_OP_LTE
AVX2_I32_KERNEL avx2_i32_lt,  I32_OP_LT
AVX2_I32_KERNEL avx2_i32_gte, I32_OP_GTE


; =============================================================================
;  INT64 AVX2 Kernels (4 lanes per YMM, 16 chunks for 64 rows)
; =============================================================================
%macro AVX2_I64_KERNEL 2
%1:
    FRAME_BEGIN 16, 0
    mov     rax, ARG2                   ; nulls
    mov     r8, ARG3                    ; active
    and     rax, r8
    mov     [rbp - 8], rax              ; unknown = active & nulls
    not     rax
    and     r8, rax                     ; valid = active & ~nulls
    jz      %%empty

    mov     r10, ARG1                   ; values
    vmovq   xmm0, ARG4
    vpbroadcastq ymm0, xmm0             ; ymm0 = broadcast literal

    xor     r11, r11                    ; r11 = accumulated true_mask

    ; Unroll 16 chunks of 4 lanes (256 bits = 32 bytes each)
    %assign chunk 0
    %rep 16
        test    r8b, 0x0F
        jz      %%skip_%[chunk]
        LOAD_VALID64 r10 + chunk * 32
        %2      ymm2, ymm1, ymm0
        vmovmskpd eax, ymm2
        and     al, 0x0F
        and     al, r8b
        %if chunk > 0
        shl     rax, chunk * 4
        or      r11, rax
        %else
        mov     r11, rax
        %endif
    %%skip_%[chunk]:
        shr     r8, 4
        jz      %%done
    %assign chunk chunk+1
    %endrep

%%done:
    vzeroupper
    mov     rax, r11
    mov     rdx, [rbp - 8]
    FRAME_END
    ret

%%empty:
    xor     eax, eax
    mov     rdx, [rbp - 8]
    FRAME_END
    ret
%endmacro

; Operator macro helpers for INT64
%macro I64_OP_EQ 3
    vpcmpeqq %1, %2, %3
%endmacro

%macro I64_OP_NEQ 3
    vpcmpeqq %1, %2, %3
    vpxor    ymm4, ymm4, ymm4
    vpcmpeqd ymm4, ymm4, ymm4           ; ymm4 = all 1s
    vpxor    %1, %1, ymm4               ; invert
%endmacro

%macro I64_OP_GT 3
    vpcmpgtq %1, %2, %3
%endmacro

%macro I64_OP_LTE 3
    vpcmpgtq %1, %2, %3
    vpxor    ymm4, ymm4, ymm4
    vpcmpeqd ymm4, ymm4, ymm4           ; ymm4 = all 1s
    vpxor    %1, %1, ymm4               ; invert
%endmacro

%macro I64_OP_LT 3
    vpcmpgtq %1, %3, %2                 ; lit > val
%endmacro

%macro I64_OP_GTE 3
    vpcmpgtq %1, %3, %2                 ; lit > val
    vpxor    ymm4, ymm4, ymm4
    vpcmpeqd ymm4, ymm4, ymm4           ; ymm4 = all 1s
    vpxor    %1, %1, ymm4               ; invert
%endmacro

AVX2_I64_KERNEL avx2_i64_eq,  I64_OP_EQ
AVX2_I64_KERNEL avx2_i64_neq, I64_OP_NEQ
AVX2_I64_KERNEL avx2_i64_gt,  I64_OP_GT
AVX2_I64_KERNEL avx2_i64_lte, I64_OP_LTE
AVX2_I64_KERNEL avx2_i64_lt,  I64_OP_LT
AVX2_I64_KERNEL avx2_i64_gte, I64_OP_GTE


; =============================================================================
;  FLOAT32 AVX2 Kernels (8 lanes per YMM, 8 chunks for 64 rows)
;  Uses signed integer key transformation:
;    - NaNs are always FALSE for all operators
;    - Signed zeros (+0.0 and -0.0) compare EQUAL
;    - Operates entirely in integer units, avoiding sNaN exceptions and DAZ/FTZ
; =============================================================================
%macro AVX2_F32_KERNEL 2
%1:
    FRAME_BEGIN 16, 0
    mov     rax, ARG2                   ; nulls
    mov     r8, ARG3                    ; active
    and     rax, r8
    mov     [rbp - 8], rax              ; unknown = active & nulls
    not     rax
    and     r8, rax                     ; valid = active & ~nulls
    jz      %%empty

    ; Literal integer key transformation
    mov     eax, ARG4d
    mov     edx, eax
    and     edx, 0x7fffffff             ; abs(lit)
    cmp     edx, 0x7f800000             ; > inf?
    ja      %%empty                     ; NaN literal is FALSE for all comparisons

    test    edx, edx
    jnz     %%lit_nonzero
    xor     eax, eax                    ; canonicalize -0.0 to +0.0
%%lit_nonzero:
    test    eax, eax
    jns     %%lit_key_ready
    xor     eax, 0x7fffffff             ; flip negative keys
%%lit_key_ready:
    vmovd   xmm0, eax
    vpbroadcastd ymm0, xmm0             ; ymm0 = broadcast literal key

    mov     r10, ARG1                   ; values
    vmovdqa ymm5, [f32_abs_mask]        ; 0x7fffffff in all dwords

    xor     r11, r11                    ; r11 = accumulated true_mask

    ; Unroll 8 chunks of 8 lanes
    %assign chunk 0
    %rep 8
        test    r8b, r8b
        jz      %%skip_%[chunk]
        LOAD_VALID32 r10 + chunk * 32

        ; 1. Identify NaNs: abs(x) > 0x7f800000
        vpand   ymm2, ymm1, ymm5        ; ymm2 = abs(val)
        vpcmpgtd ymm3, ymm2, [f32_inf_mask] ; ymm3 = nan_mask (all 1s if NaN)

        ; 2. Canonicalize -0.0 to +0.0: if abs(x) == 0, val = 0
        vpxor   ymm4, ymm4, ymm4
        vpcmpeqd ymm4, ymm2, ymm4       ; ymm4 = is_zero mask
        vpandn  ymm1, ymm4, ymm1        ; clear -0.0 sign

        ; 3. Flip negative values: if val < 0, val = val ^ 0x7fffffff
        vpsrad  ymm4, ymm1, 31          ; all 1s if negative, 0 if positive
        vpand   ymm4, ymm4, ymm5        ; 0x7fffffff if negative, 0 if positive
        vpxor   ymm1, ymm1, ymm4        ; ymm1 = transformed integer key

        ; 4. Compare transformed keys against literal key
        %2      ymm2, ymm1, ymm0

        ; 5. Mask out NaNs (NaNs are always FALSE)
        vpandn  ymm2, ymm3, ymm2

        ; 6. Extract 8-bit comparison result
        vmovmskps eax, ymm2
        and     al, r8b
        %if chunk > 0
        shl     rax, chunk * 8
        or      r11, rax
        %else
        mov     r11, rax
        %endif
    %%skip_%[chunk]:
        shr     r8, 8
        jz      %%done
    %assign chunk chunk+1
    %endrep

%%done:
    vzeroupper
    mov     rax, r11
    mov     rdx, [rbp - 8]
    FRAME_END
    ret

%%empty:
    vzeroupper
    xor     eax, eax
    mov     rdx, [rbp - 8]
    FRAME_END
    ret
%endmacro

AVX2_F32_KERNEL avx2_f32_eq,  I32_OP_EQ
AVX2_F32_KERNEL avx2_f32_neq, I32_OP_NEQ
AVX2_F32_KERNEL avx2_f32_gt,  I32_OP_GT
AVX2_F32_KERNEL avx2_f32_lte, I32_OP_LTE
AVX2_F32_KERNEL avx2_f32_lt,  I32_OP_LT
AVX2_F32_KERNEL avx2_f32_gte, I32_OP_GTE


; =============================================================================
;  BOOL AVX2 Kernels (32 lanes per YMM, 2 chunks for 64 rows)
; =============================================================================
extern scalar_bool_eq, scalar_bool_neq
; AVX2 has no byte-granularity masked load. Keep vectorization only when
; each 32-byte chunk is entirely valid or empty; otherwise tail-call scalar.
; This runs before modifying any argument registers on either platform.
%macro BOOL_SPARSE_FALLBACK 1
    mov rax, ARG2
    not rax
    and rax, ARG3
    test eax, eax
    jz %%upper
    cmp eax, -1
    jne %1
%%upper:
    shr rax, 32
    test eax, eax
    jz %%ok
    cmp eax, -1
    jne %1
%%ok:
%endmacro

global avx2_bool_eq
avx2_bool_eq:
    BOOL_SPARSE_FALLBACK scalar_bool_eq
    FRAME_BEGIN 16, 0
    mov     rax, ARG2                   ; nulls
    mov     r8, ARG3                    ; active
    and     rax, r8
    mov     [rbp - 8], rax              ; unknown = active & nulls
    not     rax
    and     r8, rax                     ; valid = active & ~nulls
    jz      .bool_empty

    mov     r10, ARG1                   ; values
    vmovd   xmm0, ARG4d
    vpbroadcastb ymm0, xmm0             ; ymm0 = broadcast literal byte

    xor     r11, r11

    ; Chunk 0: rows 0..31
    test    r8d, r8d
    jz      .bool_chunk1
    vmovdqu ymm1, [r10]
    vpcmpeqb ymm2, ymm1, ymm0
    vpmovmskb eax, ymm2
    and     eax, r8d
    mov     r11d, eax

.bool_chunk1:
    shr     r8, 32
    jz      .bool_done
    test    r8d, r8d
    jz      .bool_done
    vmovdqu ymm1, [r10 + 32]
    vpcmpeqb ymm2, ymm1, ymm0
    vpmovmskb eax, ymm2
    and     eax, r8d
    shl     rax, 32
    or      r11, rax

.bool_done:
    vzeroupper
    mov     rax, r11
    mov     rdx, [rbp - 8]
    FRAME_END
    ret

.bool_empty:
    xor     eax, eax
    mov     rdx, [rbp - 8]
    FRAME_END
    ret

global avx2_bool_neq
avx2_bool_neq:
    BOOL_SPARSE_FALLBACK scalar_bool_neq
    FRAME_BEGIN 16, 0
    mov     rax, ARG2                   ; nulls
    mov     r8, ARG3                    ; active
    and     rax, r8
    mov     [rbp - 8], rax              ; unknown = active & nulls
    not     rax
    and     r8, rax                     ; valid = active & ~nulls
    jz      .bool_neq_empty

    mov     r10, ARG1                   ; values
    vmovd   xmm0, ARG4d
    vpbroadcastb ymm0, xmm0             ; ymm0 = broadcast literal byte

    xor     r11, r11

    ; Chunk 0: rows 0..31
    test    r8d, r8d
    jz      .bool_neq_chunk1
    vmovdqu ymm1, [r10]
    vpcmpeqb ymm2, ymm1, ymm0
    vpmovmskb eax, ymm2
    not     eax
    and     eax, r8d
    mov     r11d, eax

.bool_neq_chunk1:
    shr     r8, 32
    jz      .bool_neq_done
    test    r8d, r8d
    jz      .bool_neq_done
    vmovdqu ymm1, [r10 + 32]
    vpcmpeqb ymm2, ymm1, ymm0
    vpmovmskb eax, ymm2
    not     eax
    and     eax, r8d
    shl     rax, 32
    or      r11, rax

.bool_neq_done:
    vzeroupper
    mov     rax, r11
    mov     rdx, [rbp - 8]
    FRAME_END
    ret

.bool_neq_empty:
    xor     eax, eax
    mov     rdx, [rbp - 8]
    FRAME_END
    ret


; =============================================================================
;  AVX2 Kernel Table
; =============================================================================
section .rodata
align 8
avx2_kernel_table:
    dq avx2_i32_eq,  avx2_i32_neq, avx2_i32_lt,  avx2_i32_lte, avx2_i32_gt,  avx2_i32_gte
    dq avx2_i64_eq,  avx2_i64_neq, avx2_i64_lt,  avx2_i64_lte, avx2_i64_gt,  avx2_i64_gte
    dq avx2_f32_eq,  avx2_f32_neq, avx2_f32_lt,  avx2_f32_lte, avx2_f32_gt,  avx2_f32_gte
    dq avx2_bool_eq, avx2_bool_neq, 0, 0, 0, 0

%ifdef CybouDB_LINUX
section .note.GNU-stack noalloc noexec nowrite progbits
%endif
