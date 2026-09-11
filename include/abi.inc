; Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
; SPDX-License-Identifier: Apache-2.0
; =============================================================================
;  abi.inc - Transparent layer over two ABIs: Windows x64 and System V AMD64
; =============================================================================
;  Differences hidden by this file:
;
;    Windows x64            System V AMD64 (Linux)
;    -----------            ----------------------
;    RCX RDX R8 R9          RDI RSI RDX RCX R8 R9   - integer arguments
;    32-byte shadow space   no shadow space         - spill area for the
;                                                     first four arguments
;    RBX RBP RSI RDI R12-15 RBX RBP R12-15          - callee-saved registers
;
;  Shared rule: RSP must be a multiple of 16 at every CALL instruction.
;  Inside a function (after CALL pushed the return address) RSP = 8 (mod 16).
; =============================================================================

%ifndef CybouDB_ABI_INC
%define CybouDB_ABI_INC

; --- Detect the target platform from the object file format ------------------
%ifidn __OUTPUT_FORMAT__, win64
    %define CybouDB_WINDOWS 1
%elifidn __OUTPUT_FORMAT__, elf64
    %define CybouDB_LINUX 1
%else
    %error "CybouDB: unsupported output format (use -f win64 or -f elf64)"
%endif

; --- Argument registers ------------------------------------------------------
%ifdef CybouDB_WINDOWS
    %define ARG1  rcx
    %define ARG2  rdx
    %define ARG3  r8
    %define ARG4  r9
    %define ARG1d ecx
    %define ARG2d edx
    %define ARG3d r8d
    %define ARG4d r9d
    ; The caller must reserve 32 bytes of "shadow space" where the callee may
    ; spill its four register arguments.
    %define SHADOW_SPACE 32
%else
    %define ARG1  rdi
    %define ARG2  rsi
    %define ARG3  rdx
    %define ARG4  rcx
    %define ARG5  r8
    %define ARG6  r9
    %define ARG1d edi
    %define ARG2d esi
    %define ARG3d edx
    %define ARG4d ecx
    %define SHADOW_SPACE 0
%endif

; -----------------------------------------------------------------------------
;  FRAME_BEGIN <local bytes>, <number of stack-passed arguments>
; -----------------------------------------------------------------------------
;  Builds a stack frame that at the same time:
;    * provides locals addressed as [rbp-8], [rbp-16], ...
;    * holds the outgoing argument area (shadow space + stack arguments),
;      addressed through STKARG(n), where n=0 is the 5th argument on Windows.
;    * keeps RSP 16-byte aligned at every CALL.
;
;  Layout (addresses grow upwards):
;     rsp+0 .............. shadow space (32 bytes on Windows, 0 on Linux)
;     rsp+SHADOW_SPACE ... STKARG(0), STKARG(1), ...
;     ...................  padding
;     rbp-N .............. locals
;     rbp+0 .............. saved RBP
;
;  NOTE: save callee-saved registers (RBX, R12-R15) into local slots, not with
;  PUSH - a PUSH here would break the 16-byte alignment of the frame.
; -----------------------------------------------------------------------------
%macro FRAME_BEGIN 0-2 0, 0
    push    rbp
    mov     rbp, rsp
    %assign _fr_loc  ((%1) + 15) & ~15
    %assign _fr_out  ((SHADOW_SPACE + ((%2) * 8)) + 15) & ~15
    %if (_fr_loc + _fr_out) > 0
    ; Touch every page when growing a large frame (Windows guard pages).
    %rep (_fr_loc + _fr_out) / 4096
    sub     rsp, 4096
    test    byte [rsp], 0
    %endrep
    %if (_fr_loc + _fr_out) % 4096
    sub     rsp, (_fr_loc + _fr_out) % 4096
    %endif
    %endif
%endmacro

%macro FRAME_END 0
    mov     rsp, rbp
    pop     rbp
%endmacro

; Outgoing stack argument slot: STKARG(0) is the fifth argument on Windows.
%define STKARG(i) [rsp + SHADOW_SPACE + (i) * 8]

; Cross-platform passing and receiving of 5th and 6th integer/pointer arguments.
; Callers use PASS_ARG5 / PASS_ARG6 before CALL.
; Callees read IN_ARG5 / IN_ARG6 into a register (e.g. mov rax, IN_ARG5) after FRAME_BEGIN.
%ifdef CybouDB_WINDOWS
    %macro PASS_ARG5 1
        mov     qword STKARG(0), %1
    %endmacro
    %macro PASS_ARG6 1
        mov     qword STKARG(1), %1
    %endmacro
    %define IN_ARG5 [rbp + 48]
    %define IN_ARG6 [rbp + 56]
%else
    %macro PASS_ARG5 1
        mov     ARG5, %1
    %endmacro
    %macro PASS_ARG6 1
        mov     ARG6, %1
    %endmacro
    %define IN_ARG5 ARG5
    %define IN_ARG6 ARG6
%endif

; -----------------------------------------------------------------------------
;  Call an external function without a frame of our own (for short wrappers).
;  Reserves shadow space, calls, releases it. RSP must already be aligned.
; -----------------------------------------------------------------------------
%macro CALL_ABI 1
    %if SHADOW_SPACE > 0
    sub     rsp, SHADOW_SPACE
    %endif
    call    %1
    %if SHADOW_SPACE > 0
    add     rsp, SHADOW_SPACE
    %endif
%endmacro

%endif ; CybouDB_ABI_INC
