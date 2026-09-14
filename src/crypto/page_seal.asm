; Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
; SPDX-License-Identifier: Apache-2.0
; =============================================================================
;  crypto/page_seal.asm - the associated data a sealed page is bound to
; =============================================================================
;  docs/ENCRYPTED_FORMAT.md, Decision 5. Encrypting a page proves nobody can
;  read it; the associated data is what proves nobody can move it. Each of the
;  five fields is here because leaving it out enables one specific attack:
;
;    database uuid   a page from another database of the same shape is spliced
;                    in. The header's reserved_uuid, zero since v1 was frozen,
;                    is what makes this field possible;
;    page number     a valid page is presented at a different page number - a
;                    queue segment read as a catalog page;
;    generation      a page from an earlier generation of this file is replayed
;                    into the current one: a balance from before a transfer,
;                    authenticating perfectly;
;    page type       type confusion inside one generation;
;    seal epoch      a page under a rotated-away key is accepted after rotation.
;
;  It is built here rather than by each caller because every caller must lay it
;  out identically down to the byte. Two callers that disagree do not produce a
;  warning: they produce a database whose pages cannot be opened, at some later
;  date, by a build that is not wrong.
;
;  Little-endian throughout, matching every other integer in the format.
; =============================================================================

%include "cyboudb.inc"
%include "crypto.inc"

BITS 64
default rel

global cyboudb_page_aad

section .text

; =============================================================================
;  cyboudb_page_aad(out, uuid, page_number, generation, page_type, seal_epoch)
;
;  ARG1  uint8_t        out[48]
;  ARG2  const uint8_t  uuid[16]
;  ARG3  uint64_t       page_number
;  ARG4  uint64_t       generation
;  ARG5  uint64_t       page_type
;  ARG6  uint64_t       seal_epoch
; =============================================================================
cyboudb_page_aad:
    FRAME_BEGIN 64, 2

    ; Arguments last to first: ARG5 and ARG6 come off the stack under Win64 and
    ; out of r8 and r9 under System V, where they alias ARG3 and ARG4.
%ifdef CybouDB_WINDOWS
    mov     rax, IN_ARG6
    mov     [rbp - 8], rax
    mov     rax, IN_ARG5
    mov     [rbp - 16], rax
%else
    mov     [rbp - 8], ARG6
    mov     [rbp - 16], ARG5
%endif
    mov     [rbp - 24], ARG4            ; generation
    mov     [rbp - 32], ARG3            ; page number
    mov     r11, ARG2                   ; uuid
    mov     r10, ARG1                   ; out

    mov     rax, [r11]                  ; the uuid, both halves
    mov     [r10 + AAD_UUID], rax
    mov     rax, [r11 + 8]
    mov     [r10 + AAD_UUID + 8], rax

    mov     rax, [rbp - 32]
    mov     [r10 + AAD_PAGE_NO], rax
    mov     rax, [rbp - 24]
    mov     [r10 + AAD_GENERATION], rax
    mov     rax, [rbp - 16]
    mov     [r10 + AAD_PAGE_TYPE], rax
    mov     rax, [rbp - 8]
    mov     [r10 + AAD_SEAL_EPOCH], rax

    FRAME_END
    ret

%ifdef CybouDB_LINUX
section .note.GNU-stack noalloc noexec nowrite progbits
%endif
