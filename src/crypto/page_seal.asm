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
global cyboudb_page_seal
global cyboudb_page_open

extern os_random
extern cyboudb_xchacha20poly1305_seal
extern cyboudb_xchacha20poly1305_open

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



; =============================================================================
;  cyboudb_page_seal(args) -> 0, or a CybouDB_E_* code
;  cyboudb_page_open(args) -> 0, or CybouDB_E_SEAL
;
;  ARG1  const uint8_t *args    CybouDB_PSEAL_ARGS_SIZE, laid out in crypto.inc
;
;  One page in, one page out, in place, with the nonce and the tag going to the
;  seal directory entry rather than into the page - a page is 4096 bytes before
;  and after, which is what let the format keep every existing page layout.
;
;  The nonce is drawn per seal and stored, never derived. docs/ENCRYPTED_FORMAT.md
;  Decision 4 has the argument: a nonce derived from (page, generation) is
;  correct for the pages a commit publishes and wrong for the ones it rewrites
;  after a crash, and a repeated nonce under one key is the end of the cipher.
;
;  Frame:
;    [rbp - 8..24]  saved rbx, r12, r13
;    [rbp - 32]  args
;    [rbp - 96]  aad, 48 bytes
;    [rbp - 160] aead args, 56 bytes
; =============================================================================
; -----------------------------------------------------------------------------
;  BUILD_PAGE_AAD - rbx = args; fills [rbp - PS_AAD] from the five fields.
;  Shared by seal and open so a page is bound and checked against one layout.
;
;  A macro and not a subroutine: PASS_ARG5 writes into the outgoing argument
;  area, which is addressed from rsp, and a call moves rsp.
; -----------------------------------------------------------------------------
%macro BUILD_PAGE_AAD 0
    mov     [rbp - 40], r10             ; the page type, from wherever it came
    mov     ARG1, rbp
    sub     ARG1, PS_AAD
    mov     ARG2, [rbx + PSEAL_UUID]
    mov     ARG3, [rbx + PSEAL_PAGE_NO]
    mov     ARG4, [rbx + PSEAL_GENERATION]
    mov     rax, [rbp - 40]
    PASS_ARG5 rax
    mov     rax, [rbx + PSEAL_EPOCH]
    PASS_ARG6 rax
    call    cyboudb_page_aad
%endmacro

; -----------------------------------------------------------------------------
;  BUILD_AEAD_ARGS - rbx = args; fills [rbp - PS_AEAD] for the AEAD.
;  The nonce and the tag point into the seal directory entry, which is where
;  they live afterwards: nothing copies them into the page.
; -----------------------------------------------------------------------------
%macro BUILD_AEAD_ARGS 0
    lea     r10, [rbp - PS_AEAD]
    mov     rax, [rbx + PSEAL_KEY]
    mov     [r10 + AEAD_KEY], rax
    mov     rax, [rbx + PSEAL_ENTRY]
    add     rax, SENTRY_NONCE
    mov     [r10 + AEAD_NONCE], rax
    lea     rax, [rbp - PS_AAD]
    mov     [r10 + AEAD_AAD], rax
    mov     qword [r10 + AEAD_AAD_LEN], CybouDB_PAGE_AAD_SIZE
    mov     rax, [rbx + PSEAL_PAGE]
    mov     [r10 + AEAD_BUF], rax
    mov     qword [r10 + AEAD_BUF_LEN], CybouDB_PAGE_SIZE
    mov     rax, [rbx + PSEAL_ENTRY]
    add     rax, SENTRY_TAG
    mov     [r10 + AEAD_TAG], rax
%endmacro

%define PS_AAD    96
%define PS_AEAD   160
%define PS_FRAME  192

cyboudb_page_seal:
    FRAME_BEGIN PS_FRAME, 2
    mov     [rbp - 8], rbx
    mov     [rbp - 16], r12
    mov     [rbp - 24], r13

    mov     rbx, ARG1
    mov     [rbp - 32], rbx

    ; A fresh nonce, into the entry where it will be stored - and its last
    ; byte is the page's type, which is Decision 5b: a reader has to build the
    ; associated data before it can verify anything, and the type is the one
    ; field it cannot know. Twenty-three bytes of randomness and one of type.
    mov     ARG1, [rbx + PSEAL_ENTRY]
    add     ARG1, SENTRY_NONCE
    mov     ARG2, CybouDB_XAEAD_NONCE_SIZE - 1
    call    os_random
    test    eax, eax
    jnz     .no_randomness

    mov     rbx, [rbp - 32]
    mov     r10, [rbx + PSEAL_PAGE_TYPE]
    mov     r11, [rbx + PSEAL_ENTRY]
    mov     [r11 + SENTRY_NONCE + CybouDB_XAEAD_NONCE_SIZE - 1], r10b
    ; r10 now carries the type into the associated data as well, so the byte
    ; in the nonce and the byte in the AAD are one value and not two.

    BUILD_PAGE_AAD

    mov     rbx, [rbp - 32]
    BUILD_AEAD_ARGS

    mov     ARG1, rbp
    sub     ARG1, PS_AEAD
    call    cyboudb_xchacha20poly1305_seal
    xor     eax, eax
    jmp     .done

.no_randomness:
    mov     eax, CybouDB_E_STATE
.done:
    mov     rbx, [rbp - 8]
    mov     r12, [rbp - 16]
    mov     r13, [rbp - 24]
    FRAME_END
    ret

cyboudb_page_open:
    FRAME_BEGIN PS_FRAME, 2
    mov     [rbp - 8], rbx
    mov     [rbp - 16], r12
    mov     [rbp - 24], r13

    mov     rbx, ARG1
    mov     [rbp - 32], rbx

    ; The type comes out of the nonce, not out of the arguments. The caller
    ; that needs to open a page is exactly the one that does not know what kind
    ; of page it is - and a caller that does know gains nothing by saying so,
    ; because the tag is what decides either way. Decision 5b.
    mov     r11, [rbx + PSEAL_ENTRY]
    movzx   r10d, byte [r11 + SENTRY_NONCE + CybouDB_XAEAD_NONCE_SIZE - 1]

    BUILD_PAGE_AAD

    mov     rbx, [rbp - 32]
    BUILD_AEAD_ARGS

    mov     ARG1, rbp
    sub     ARG1, PS_AEAD
    call    cyboudb_xchacha20poly1305_open
    test    eax, eax
    jnz     .refused
    xor     eax, eax
    jmp     .done

.refused:
    ; Everything this can mean - a wrong key, a wrong page number, a rewritten
    ; ciphertext, a bit that flipped on the disk - looks identical from here,
    ; and the sentence in main.asm names the two that matter.
    mov     eax, CybouDB_E_SEAL
.done:
    mov     rbx, [rbp - 8]
    mov     r12, [rbp - 16]
    mov     r13, [rbp - 24]
    FRAME_END
    ret



%ifdef CybouDB_LINUX
section .note.GNU-stack noalloc noexec nowrite progbits
%endif
