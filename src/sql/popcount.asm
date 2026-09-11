; Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
; SPDX-License-Identifier: Apache-2.0
; Generic x86-64 population count with optional CPUID-selected POPCNT.
%include "sql.inc"
BITS 64
default rel
global cyboudb_popcount64, cpu_has_popcnt, popcount_force_scalar

section .data
align 4
popcount_force_scalar: dd 0
popcnt_cached: dd 0                    ; 0=unknown, 1=present, -1=absent

section .text
cpu_has_popcnt:
    mov eax, [popcnt_cached]
    test eax, eax
    jnz .cached
    push rbx
    mov eax, 1                        ; basic leaf 1 is available on x86-64
    cpuid
    bt ecx, 23
    pop rbx
    mov eax, -1
    jnc .save
    mov eax, 1
.save:
    mov [popcnt_cached], eax
.cached:
    cmp eax, 1
    sete al
    movzx eax, al
    ret

; cyboudb_popcount64(ARG1=value) -> RAX in [0,64]. Platform volatile registers
; may be clobbered, as for other hardware primitives. No POPCNT on fallback.
cyboudb_popcount64:
    mov r10, ARG1
    cmp dword [popcount_force_scalar], 0
    jne .scalar
    mov eax, [popcnt_cached]
    cmp eax, 1
    je .hardware
    test eax, eax
    jnz .scalar
    FRAME_BEGIN 16, 0
    mov [rbp - 8], r10
    call cpu_has_popcnt
    mov r10, [rbp - 8]
    FRAME_END
    test eax, eax
    jz .scalar
.hardware:
    popcnt rax, r10
    ret
.scalar:
    mov rax, r10
    shr rax, 1
    mov r11, 0x5555555555555555
    and rax, r11
    sub r10, rax
    mov r11, 0x3333333333333333
    mov rax, r10
    and rax, r11
    shr r10, 2
    and r10, r11
    add rax, r10
    mov r10, rax
    shr r10, 4
    add rax, r10
    mov r11, 0x0f0f0f0f0f0f0f0f
    and rax, r11
    mov r11, 0x0101010101010101
    imul rax, r11
    shr rax, 56
    ret

%ifdef CybouDB_LINUX
section .note.GNU-stack noalloc noexec nowrite progbits
%endif
