; =============================================================================
;  src/sql/bmi2.asm - BMI2 Bit Manipulation Primitives & CPUID Detection
; =============================================================================
;  Implements parallel bit extract (PEXT), parallel bit deposit (PDEP),
;  and zero high bits (BZHI) for fast NULL mask compaction and active lane
;  bit-vector operations, with runtime CPUID detection and scalar fallbacks.
; =============================================================================

%include "sql.inc"

BITS 64
default rel

global cpu_has_bmi2
global bmi2_pext64
global bmi2_pdep64
global bmi2_bzhi64
global bmi2_compact_nulls
global bmi2_force_scalar

section .data
align 4
bmi2_force_scalar: dd 0

section .bss
align 4
bmi2_cached: resd 1                     ; 0 = uninit, 1 = present, -1 = absent

section .text

; -----------------------------------------------------------------------------
;  cpu_has_bmi2() -> EAX: 1 if BMI2 supported by CPU, 0 otherwise
; -----------------------------------------------------------------------------
cpu_has_bmi2:
    mov     eax, [bmi2_cached]
    test    eax, eax
    jnz     .cached

    FRAME_BEGIN 16, 0
    mov     [rbp - 8], rbx              ; callee-saved RBX

    ; 1. Check max CPUID basic leaf support (need at least leaf 7)
    xor     eax, eax
    cpuid
    cmp     eax, 7
    jb      .no_bmi2

    ; 2. Query leaf 7, subleaf 0: EBX bit 8 = BMI2, bit 3 = BMI1
    mov     eax, 7
    xor     ecx, ecx
    cpuid
    bt      ebx, 8                      ; bit 8 is BMI2
    jnc     .no_bmi2

    mov     rbx, [rbp - 8]
    FRAME_END
    mov     dword [bmi2_cached], 1
    mov     eax, 1
    ret

.no_bmi2:
    mov     rbx, [rbp - 8]
    FRAME_END
    mov     dword [bmi2_cached], -1
    xor     eax, eax
    ret

.cached:
    cmp     eax, 1
    sete    al
    movzx   eax, al
    ret

; -----------------------------------------------------------------------------
;  bmi2_pext64(ARG1 = val, ARG2 = mask) -> RAX: extracted bits
; -----------------------------------------------------------------------------
bmi2_pext64:
    mov     r10, ARG1
    mov     r11, ARG2

    cmp     dword [bmi2_force_scalar], 0
    jne     .scalar_pext

    mov     eax, [bmi2_cached]
    cmp     eax, 1
    je      .hw_pext
    test    eax, eax
    jnz     .scalar_pext

    ; Check CPUID on first call
    FRAME_BEGIN 32, 0
    mov     [rbp - 8], r10
    mov     [rbp - 16], r11
    call    cpu_has_bmi2
    mov     r10, [rbp - 8]
    mov     r11, [rbp - 16]
    FRAME_END
    test    eax, eax
    jz      .scalar_pext

.hw_pext:
    pext    rax, r10, r11
    ret

.scalar_pext:
    xor     eax, eax
    xor     ecx, ecx
.pext_loop:
    test    r11, r11
    jz      .pext_done
    bsf     rdx, r11
    btr     r11, rdx
    bt      r10, rdx
    jnc     .pext_next
    bts     rax, rcx
.pext_next:
    inc     ecx
    jmp     .pext_loop
.pext_done:
    ret

; -----------------------------------------------------------------------------
;  bmi2_pdep64(ARG1 = val, ARG2 = mask) -> RAX: deposited bits
; -----------------------------------------------------------------------------
bmi2_pdep64:
    mov     r10, ARG1
    mov     r11, ARG2

    cmp     dword [bmi2_force_scalar], 0
    jne     .scalar_pdep

    mov     eax, [bmi2_cached]
    cmp     eax, 1
    je      .hw_pdep
    test    eax, eax
    jnz     .scalar_pdep

    ; Check CPUID on first call
    FRAME_BEGIN 32, 0
    mov     [rbp - 8], r10
    mov     [rbp - 16], r11
    call    cpu_has_bmi2
    mov     r10, [rbp - 8]
    mov     r11, [rbp - 16]
    FRAME_END
    test    eax, eax
    jz      .scalar_pdep

.hw_pdep:
    pdep    rax, r10, r11
    ret

.scalar_pdep:
    xor     eax, eax
    xor     ecx, ecx
.pdep_loop:
    test    r11, r11
    jz      .pdep_done
    bsf     rdx, r11
    btr     r11, rdx
    bt      r10, rcx
    jnc     .pdep_next
    bts     rax, rdx
.pdep_next:
    inc     ecx
    jmp     .pdep_loop
.pdep_done:
    ret

; -----------------------------------------------------------------------------
;  bmi2_bzhi64(ARG1 = val, ARG2 = index) -> RAX: masked value
; -----------------------------------------------------------------------------
bmi2_bzhi64:
    mov     r10, ARG1
    mov     r11, ARG2

    cmp     dword [bmi2_force_scalar], 0
    jne     .scalar_bzhi

    mov     eax, [bmi2_cached]
    cmp     eax, 1
    je      .hw_bzhi
    test    eax, eax
    jnz     .scalar_bzhi

    ; Check CPUID on first call
    FRAME_BEGIN 32, 0
    mov     [rbp - 8], r10
    mov     [rbp - 16], r11
    call    cpu_has_bmi2
    mov     r10, [rbp - 8]
    mov     r11, [rbp - 16]
    FRAME_END
    test    eax, eax
    jz      .scalar_bzhi

.hw_bzhi:
    bzhi    rax, r10, r11
    ret

.scalar_bzhi:
    cmp     r11, 64
    jae     .bzhi_all
    mov     ecx, r11d
    mov     rax, 1
    shl     rax, cl
    dec     rax
    and     rax, r10
    ret
.bzhi_all:
    mov     rax, r10
    ret

; -----------------------------------------------------------------------------
;  bmi2_compact_nulls(ARG1 = null_mask, ARG2 = selection_mask) -> RAX:
;  extracts and compacts null bits for selected active rows into contiguous bits.
; -----------------------------------------------------------------------------
bmi2_compact_nulls:
    jmp     bmi2_pext64

%ifdef CybouDB_LINUX
section .note.GNU-stack noalloc noexec nowrite progbits
%endif
