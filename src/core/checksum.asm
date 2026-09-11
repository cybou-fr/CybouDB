; Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
; SPDX-License-Identifier: Apache-2.0
; =============================================================================
;  core/checksum.asm - CRC-32C used by the on-disk format
; =============================================================================
;  CRC-32C (Castagnoli): reflected algorithm, reversed polynomial 0x82F63B78,
;  initial value 0xFFFFFFFF, final value inverted.
;
;  Uses hardware SSE4.2 CRC32 instructions (4x unrolled 64-bit chunks) when
;  supported by the CPU, falling back to the portable bit-by-bit reference loop.
;
;  Test vector: crc32c("123456789") = 0xE3069283.
; =============================================================================

%include "cyboudb.inc"

BITS 64
default rel

global crc32c
global cpu_has_sse42
global crc32c_force_scalar

%define CRC32C_POLY_REFLECTED  0x82F63B78

section .data
align 4
crc32c_force_scalar: dd 0

section .bss
align 4
sse42_cached: resd 1                    ; 0 = uninit, 1 = present, -1 = absent

section .text

; -----------------------------------------------------------------------------
;  cpu_has_sse42() -> EAX: 1 if SSE4.2 supported by CPU, 0 otherwise
; -----------------------------------------------------------------------------
cpu_has_sse42:
    mov     eax, [sse42_cached]
    test    eax, eax
    jnz     .cached

    FRAME_BEGIN 16, 0
    mov     [rbp - 8], rbx              ; callee-saved RBX

    ; Check max CPUID basic leaf support (need at least leaf 1)
    xor     eax, eax
    cpuid
    test    eax, eax
    jz      .no_sse42

    ; Query leaf 1, ECX bit 20 = SSE4.2
    mov     eax, 1
    cpuid
    bt      ecx, 20
    jnc     .no_sse42

    mov     rbx, [rbp - 8]
    FRAME_END
    mov     dword [sse42_cached], 1
    mov     eax, 1
    ret

.no_sse42:
    mov     rbx, [rbp - 8]
    FRAME_END
    mov     dword [sse42_cached], -1
    xor     eax, eax
    ret

.cached:
    cmp     eax, 1
    sete    al
    movzx   eax, al
    ret

; -----------------------------------------------------------------------------
;  crc32c(ARG1 = buffer, ARG2 = length in bytes) -> EAX: checksum
;
;  Clobbers only volatile registers on both ABIs; a zero length yields the
;  checksum of the empty message (0x00000000).
; -----------------------------------------------------------------------------
crc32c:
    mov     r10, ARG1                   ; cursor over the buffer
    mov     r11, ARG2                   ; bytes remaining
    mov     eax, 0xFFFFFFFF             ; running CRC value
    test    r11, r11
    jz      .done

    cmp     dword [crc32c_force_scalar], 0
    jne     .byte_loop

    ; Check cached CPUID status
    mov     edx, [sse42_cached]
    cmp     edx, 1
    je      .hardware
    test    edx, edx
    jnz     .byte_loop                  ; -1: absent

    ; Uninitialized: query CPUID
    FRAME_BEGIN 32, 0
    mov     [rbp - 8], r10
    mov     [rbp - 16], r11
    call    cpu_has_sse42
    mov     r10, [rbp - 8]
    mov     r11, [rbp - 16]
    FRAME_END
    test    eax, eax
    mov     eax, 0xFFFFFFFF             ; reset running CRC value
    jz      .byte_loop

.hardware:
    ; 4x unrolled 8-byte loop (32 bytes per iteration)
.hw_loop32:
    cmp     r11, 32
    jb      .hw_qword
    crc32   rax, qword [r10]
    crc32   rax, qword [r10 + 8]
    crc32   rax, qword [r10 + 16]
    crc32   rax, qword [r10 + 24]
    add     r10, 32
    sub     r11, 32
    jmp     .hw_loop32

.hw_qword:
    cmp     r11, 8
    jb      .hw_tail
    crc32   rax, qword [r10]
    add     r10, 8
    sub     r11, 8
    jmp     .hw_qword

.hw_tail:
    test    r11b, 4
    jz      .hw_word
    crc32   eax, dword [r10]
    add     r10, 4

.hw_word:
    test    r11b, 2
    jz      .hw_byte
    crc32   eax, word [r10]
    add     r10, 2

.hw_byte:
    test    r11b, 1
    jz      .done
    crc32   eax, byte [r10]

.done:
    not     eax                         ; final inversion
    ret

; Scalar fallback bit loop
.byte_loop:
    movzx   edx, byte [r10]
    xor     eax, edx                    ; fold the byte into the low 8 bits
    mov     ecx, 8                      ; eight bit steps per byte
.bit_loop:
    shr     eax, 1
    jnc     .next_bit                   ; the shifted-out bit decides
    xor     eax, CRC32C_POLY_REFLECTED
.next_bit:
    dec     ecx
    jnz     .bit_loop

    inc     r10
    dec     r11
    jnz     .byte_loop

    not     eax                         ; final inversion
    ret

%ifdef CybouDB_LINUX
section .note.GNU-stack noalloc noexec nowrite progbits
%endif
