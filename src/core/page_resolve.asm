; Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
; SPDX-License-Identifier: Apache-2.0
; =============================================================================
;  core/page_resolve.asm - a page of an encrypted database, as an address
; =============================================================================
;  docs/ENCRYPTED_ENGINE.md, step 3. The engine asks for a page address 128
;  times; when DB_CACHE is set, this is what answers.
;
;      cached already        the frame it is in
;      not cached            read it, open it, and the frame it went into
;      it does not verify    zero, and DB_ENC_ERROR says what happened
;
;  Zero rather than a refusal in a register, because the sites that call this
;  are 128 pieces of code written around an address that could not fail. They
;  will each have to learn to see a null - that is the work step 3 is made of -
;  and until they do, a null is at least a fault at the point of use rather
;  than a plaintext page that was never verified.
;
;  The seal directory leaf is read on every miss. That is one extra read per
;  miss and it is deliberate for now: the leaf is a page like any other, and
;  caching it properly means deciding whether metadata and payload share a
;  cache - which is a measurement, not a preference, and step 19 is where it
;  belongs.
; =============================================================================

%include "cyboudb.inc"
%include "crypto.inc"

BITS 64
default rel

global db_page_resolve

extern cyboudb_pcache_lookup
extern cyboudb_pcache_admit
extern cyboudb_pcache_invalidate
extern cyboudb_page_open
extern vfs_read_at

; Frame:
;   [rbp - 8..32]  saved rbx, r12, r13
;   [rbp - 40] ctx    [rbp - 48] page    [rbp - 56] frame
;   [rbp - 64] the evicted page the cache reported
;   [rbp - 128] the page seal arguments, CybouDB_PSEAL_ARGS_SIZE
;   [rbp - 4224] the seal directory leaf, read on every miss
%define PR_ARGS   128
%define PR_LEAF   4224
%define PR_FRAME  4288

section .text

; =============================================================================
;  db_page_resolve(ctx, page) -> uint8_t *plaintext, or 0
; =============================================================================
db_page_resolve:
    FRAME_BEGIN PR_FRAME, 0
    mov     [rbp - 8], rbx
    mov     [rbp - 16], r12
    mov     [rbp - 24], r13

    mov     rbx, ARG1                   ; ctx
    mov     r12, ARG2                   ; the page wanted
    mov     [rbp - 40], rbx
    mov     [rbp - 48], r12

    ; --- already decrypted? ---------------------------------------------------
    mov     ARG1, [rbx + DB_CACHE]
    mov     ARG2, r12
    call    cyboudb_pcache_lookup
    test    rax, rax
    jz      .miss

    ; A hit clears the error as a miss does. Leaving the last failure in place
    ; would let a caller read a stale reason after a resolve that succeeded -
    ; and the first test written against this did exactly that, and believed
    ; it.
    mov     rbx, [rbp - 40]
    mov     qword [rbx + DB_ENC_ERROR], 0
    jmp     .done
.miss:

    ; --- which leaf covers this page, and where the entry is -----------------
    ;  One leaf holds CybouDB_SEAL_ENTRIES_PER_LEAF pages, and the directory
    ;  starts at the page the crypto root named.
    mov     rax, r12
    xor     rdx, rdx
    mov     rcx, CybouDB_SEAL_ENTRIES_PER_LEAF
    div     rcx                         ; rax = which leaf, rdx = which entry
    mov     r13, rdx                    ; the entry index, wanted later

    add     rax, [rbx + DB_SEAL_DIR]
    shl     rax, CybouDB_PAGE_SHIFT     ; the leaf's byte offset in the file

    mov     ARG1, [rbx + DB_HANDLE]
    lea     ARG2, [rbp - PR_LEAF]
    mov     ARG3, CybouDB_PAGE_SIZE
    mov     ARG4, rax
    call    vfs_read_at
    cmp     rax, CybouDB_PAGE_SIZE
    jne     .no_entry

    ; --- a frame to read the page into ---------------------------------------
    mov     rbx, [rbp - 40]
    mov     ARG1, [rbx + DB_CACHE]
    mov     ARG2, [rbp - 48]
    lea     ARG3, [rbp - 64]
    call    cyboudb_pcache_admit
    test    rax, rax
    jz      .no_entry
    mov     [rbp - 56], rax

    ; The evicted page is reported and, for now, must not have been dirty:
    ; writing back belongs to step 4 with the commit order, and a dirty page
    ; quietly dropped would be a lost write rather than a slow one.
    ;
    ; "Nothing was evicted" is all ones, and all ones has bit 63 set - which is
    ; also how the cache says "this one was dirty". So the sentinel is checked
    ; first, and the order is not optional: testing the bit first makes every
    ; admission into an empty set look like a dirty eviction, which is exactly
    ; what the first version of this did.
    mov     rax, [rbp - 64]
    cmp     rax, -1
    je      .nothing_evicted
    bt      rax, 63
    jc      .dirty_victim
.nothing_evicted:

    ; --- read the ciphertext into that frame ---------------------------------
    mov     rax, [rbp - 48]
    shl     rax, CybouDB_PAGE_SHIFT
    mov     ARG1, [rbx + DB_HANDLE]
    mov     ARG2, [rbp - 56]
    mov     ARG3, CybouDB_PAGE_SIZE
    mov     ARG4, rax
    call    vfs_read_at
    cmp     rax, CybouDB_PAGE_SIZE
    jne     .short_read

    ; --- open it -------------------------------------------------------------
    mov     rbx, [rbp - 40]
    lea     r10, [rbp - PR_ARGS]

    lea     rax, [rbx + DB_SEAL_KEY]
    mov     [r10 + PSEAL_KEY], rax
    mov     rax, [rbp - 56]
    mov     [r10 + PSEAL_PAGE], rax

    ; the entry inside the leaf this page belongs to
    mov     rax, r13
    imul    rax, rax, SENTRY_SIZE
    lea     rcx, [rbp - PR_LEAF]
    add     rax, rcx
    add     rax, SLEAF_ENTRIES
    mov     [r10 + PSEAL_ENTRY], rax

    lea     rax, [rbx + DB_UUID]
    mov     [r10 + PSEAL_UUID], rax
    mov     rax, [rbp - 48]
    mov     [r10 + PSEAL_PAGE_NO], rax
    mov     rax, [rbx + DB_GENERATION]
    mov     [r10 + PSEAL_GENERATION], rax
    mov     qword [r10 + PSEAL_PAGE_TYPE], 0    ; open reads it from the nonce
    mov     rax, [rbx + DB_SEAL_EPOCH]
    mov     [r10 + PSEAL_EPOCH], rax

    lea     ARG1, [rbp - PR_ARGS]
    call    cyboudb_page_open
    test    eax, eax
    jnz     .refused

    mov     qword [rbx + DB_ENC_ERROR], 0
    mov     rax, [rbp - 56]
    jmp     .done

.refused:
    ; The frame holds a page that did not verify. It must not stay in the
    ; cache looking like a page that did - a later lookup would hit it and
    ; hand out bytes nothing vouched for.
    mov     [rbx + DB_ENC_ERROR], rax
    mov     ARG1, [rbx + DB_CACHE]
    mov     ARG2, [rbp - 48]
    call    cyboudb_pcache_invalidate
    xor     eax, eax
    jmp     .done

.short_read:
    mov     rbx, [rbp - 40]
    mov     qword [rbx + DB_ENC_ERROR], CybouDB_E_SEAL
    mov     ARG1, [rbx + DB_CACHE]
    mov     ARG2, [rbp - 48]
    call    cyboudb_pcache_invalidate
    xor     eax, eax
    jmp     .done

.dirty_victim:
    mov     qword [rbx + DB_ENC_ERROR], CybouDB_E_STATE
    xor     eax, eax
    jmp     .done

.no_entry:
    mov     rbx, [rbp - 40]
    mov     qword [rbx + DB_ENC_ERROR], CybouDB_E_SEAL
    xor     eax, eax

.done:
    mov     rbx, [rbp - 8]
    mov     r12, [rbp - 16]
    mov     r13, [rbp - 24]
    FRAME_END
    ret

%ifdef CybouDB_LINUX
section .note.GNU-stack noalloc noexec nowrite progbits
%endif
