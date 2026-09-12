; Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
; SPDX-License-Identifier: Apache-2.0
; =============================================================================
;  tests/abi_probe.asm - does a library call give back the registers it borrowed
; =============================================================================
;  A callee-saved register that a library fails to restore is invisible to a
;  test written in C: the harness only notices when the compiler happens to
;  have kept something live in that register across the call, which depends on
;  optimisation settings and on the surrounding code. The engine shipped such
;  a bug - a tokenizer slot that held saved RBX and a pending literal token
;  type at the same time - and every existing test passed with it in place.
;
;  cyboudb_abi_probe fills every callee-saved general register with a distinct
;  marker, calls a two-argument library entry point, and reports which markers
;  came back changed. That turns an ABI violation into an ordinary failing
;  assertion rather than a corrupted caller somewhere downstream.
;
;  cyboudb_abi_probe(fn, a1, a2, out_mask) -> the value fn returned
;
;  Bits written to out_mask, on both ABIs:
;     0 RBX   1 R12   2 R13   3 R14   4 R15
;  and, where the ABI makes them callee-saved (Windows only):
;     5 RSI   6 RDI
; =============================================================================
%include "abi.inc"
BITS 64
default rel
global cyboudb_abi_probe
section .text

; Local slots: [rbp-8]=fn, [rbp-16]=a1, [rbp-24]=a2, [rbp-32]=out_mask,
;              [rbp-40]=return value, [rbp-48]=mask under construction,
;              [rbp-56..-104]=the caller's callee-saved registers
cyboudb_abi_probe:
    FRAME_BEGIN 112, 0
    mov     [rbp - 8], ARG1
    mov     [rbp - 16], ARG2
    mov     [rbp - 24], ARG3
    mov     [rbp - 32], ARG4

    ; This function is itself bound by the contract it is testing.
    mov     [rbp - 56], rbx
    mov     [rbp - 64], r12
    mov     [rbp - 72], r13
    mov     [rbp - 80], r14
    mov     [rbp - 88], r15
    mov     [rbp - 96], rsi
    mov     [rbp - 104], rdi

    mov     rbx, 0x1111111111111111
    mov     r12, 0x2222222222222222
    mov     r13, 0x3333333333333333
    mov     r14, 0x4444444444444444
    mov     r15, 0x5555555555555555
    mov     rsi, 0x6666666666666666
    mov     rdi, 0x7777777777777777

    mov     rax, [rbp - 8]
    mov     ARG1, [rbp - 16]
    mov     ARG2, [rbp - 24]
    call    rax
    mov     [rbp - 40], rax

    mov     qword [rbp - 48], 0
    mov     r10, 0x1111111111111111
    cmp     rbx, r10
    je      .check_r12
    or      qword [rbp - 48], 1
.check_r12:
    mov     r10, 0x2222222222222222
    cmp     r12, r10
    je      .check_r13
    or      qword [rbp - 48], 2
.check_r13:
    mov     r10, 0x3333333333333333
    cmp     r13, r10
    je      .check_r14
    or      qword [rbp - 48], 4
.check_r14:
    mov     r10, 0x4444444444444444
    cmp     r14, r10
    je      .check_r15
    or      qword [rbp - 48], 8
.check_r15:
    mov     r10, 0x5555555555555555
    cmp     r15, r10
    je      .check_rsi
    or      qword [rbp - 48], 16
.check_rsi:
%ifdef CybouDB_WINDOWS
    mov     r10, 0x6666666666666666
    cmp     rsi, r10
    je      .check_rdi
    or      qword [rbp - 48], 32
.check_rdi:
    mov     r10, 0x7777777777777777
    cmp     rdi, r10
    je      .report
    or      qword [rbp - 48], 64
%endif
.report:
    mov     rbx, [rbp - 56]
    mov     r12, [rbp - 64]
    mov     r13, [rbp - 72]
    mov     r14, [rbp - 80]
    mov     r15, [rbp - 88]
    mov     rsi, [rbp - 96]
    mov     rdi, [rbp - 104]

    mov     r10, [rbp - 32]
    test    r10, r10
    jz      .done
    mov     rax, [rbp - 48]
    mov     [r10], eax
.done:
    mov     rax, [rbp - 40]
    FRAME_END
    ret
