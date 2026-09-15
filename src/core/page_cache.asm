; Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
; SPDX-License-Identifier: Apache-2.0
; =============================================================================
;  core/page_cache.asm - the plaintext pages an encrypted database works on
; =============================================================================
;  docs/ENCRYPTED_FORMAT.md Decision 7 is why this exists: an encrypted
;  database cannot use the shared mapping, because plaintext in a shared
;  mapping is plaintext on the disk. The engine needs somewhere to keep pages
;  it has decrypted, and that somewhere is here.
;
;  Every parameter below was measured rather than chosen -
;  benchmarks/results/2026-09-15-cache-shape.md:
;
;    eight ways      four is where associativity stops paying and eight is
;                    where the index function stops mattering, which is the
;                    better reason for it;
;    low-bit index   consecutive page numbers land in consecutive sets, which
;                    is conflict-free. The mixing hash that looked obviously
;                    better lost by fifty-seven points at one way;
;    second touch    a page is probationary until it is asked for twice. Four
;                    points over clock on a hot working set, six under a scan,
;                    and no hint required - which matters more than the points,
;                    because a scan and a range read are the same sequence of
;                    page numbers and a cache that trusts a flag is wrong
;                    whenever the flag is.
;
;  Nothing here does I/O or crypto. A miss hands the caller a frame and says
;  what was evicted; filling the frame is the caller's business, and so is
;  writing back anything dirty. That keeps the cache testable without a file
;  and keeps the decision about durability where it belongs.
; =============================================================================

%include "cyboudb.inc"

BITS 64
default rel

global cyboudb_pcache_bytes
global cyboudb_pcache_init
global cyboudb_pcache_lookup
global cyboudb_pcache_admit
global cyboudb_pcache_mark_dirty
global cyboudb_pcache_frame
global cyboudb_pcache_invalidate
global cyboudb_pcache_stats
global cyboudb_pcache_frames
global cyboudb_pcache_dirty_at
global cyboudb_pcache_clean_at
global cyboudb_pcache_set_type
global cyboudb_pcache_type_at

; --- the control block -------------------------------------------------------
%define PC_MAGIC        0
%define PC_FRAMES       8               ; how many pages fit
%define PC_SETS         16
%define PC_CLOCK        24              ; a counter, for recency
%define PC_HITS         32
%define PC_MISSES       40
%define PC_EVICTIONS    48
%define PC_SLOTS        56              ; byte offset of the slot array
%define PC_FRAME_BASE   64              ; byte offset of the first frame
%define PC_HEADER       128

; --- one slot ----------------------------------------------------------------
%define SLOT_PAGE       0
%define SLOT_STAMP      8
%define SLOT_FLAGS      16
%define SLOT_SIZE       32

%define SLOT_VALID      1
%define SLOT_DIRTY      2
%define SLOT_RESIDENT   4               ; asked for twice, so not probationary
; Bits 8 to 15 hold the page's type. It lives here because the only code that
; knows a page's type is the code that wrote it, and the only code that needs
; it at seal time is the commit, which runs much later and sees nothing but a
; frame. Somewhere had to remember, and the slot already exists.
%define SLOT_TYPE_SHIFT 8
%define SLOT_TYPE_MASK  0xFF00

%define PCACHE_WAYS     8
%define PCACHE_MAGIC    0x43505351      ; 'QSPC'

section .text

; =============================================================================
;  cyboudb_pcache_bytes(frames) -> uint64
;
;  How much memory a cache of this many pages needs, frames included. Returns
;  zero if the count is not eight times a power of two, which is the shape the
;  index requires: the set count is masked, so it has to be a power of two.
; =============================================================================
cyboudb_pcache_bytes:
    mov     r10, ARG1
    test    r10, r10
    jz      .bad

    ; frames must be PCACHE_WAYS * 2^k
    xor     rdx, rdx
    mov     rax, r10
    mov     rcx, PCACHE_WAYS
    div     rcx
    test    rdx, rdx
    jnz     .bad                        ; not a multiple of the ways
    mov     r11, rax                    ; the set count
    test    r11, r11
    jz      .bad
    mov     rax, r11
    dec     rax
    test    rax, r11
    jnz     .bad                        ; not a power of two

    ; header and slots, rounded up to a page, then the frames
    mov     rax, r10
    imul    rax, rax, SLOT_SIZE
    add     rax, PC_HEADER
    add     rax, CybouDB_PAGE_SIZE - 1
    and     rax, ~(CybouDB_PAGE_SIZE - 1)
    mov     rcx, r10
    shl     rcx, CybouDB_PAGE_SHIFT
    add     rax, rcx
    ret
.bad:
    xor     eax, eax
    ret

; =============================================================================
;  cyboudb_pcache_init(mem, bytes, frames) -> int
;
;  ARG1  uint8_t *mem      page-aligned
;  ARG2  uint64_t bytes    at least what cyboudb_pcache_bytes asked for
;  ARG3  uint64_t frames
; =============================================================================
cyboudb_pcache_init:
    FRAME_BEGIN 64, 0
    mov     [rbp - 8], rbx
    mov     [rbp - 16], r12

    mov     rbx, ARG1
    mov     [rbp - 24], ARG2
    mov     r12, ARG3

    test    rbx, rbx
    jz      .refuse
    test    rbx, CybouDB_PAGE_SIZE - 1
    jnz     .refuse                     ; a frame must be a page, on a page

    mov     ARG1, r12
    call    cyboudb_pcache_bytes
    test    rax, rax
    jz      .refuse
    cmp     rax, [rbp - 24]
    ja      .refuse                     ; the caller brought too little memory

    ; zero the header and the slots
    mov     rcx, r12
    imul    rcx, rcx, SLOT_SIZE
    add     rcx, PC_HEADER
    xor     rax, rax
    xor     rdx, rdx
.zero:
    mov     [rbx + rdx], rax
    add     rdx, 8
    cmp     rdx, rcx
    jb      .zero

    mov     dword [rbx + PC_MAGIC], PCACHE_MAGIC
    mov     [rbx + PC_FRAMES], r12
    mov     rax, r12
    shr     rax, 3                      ; frames / PCACHE_WAYS
    mov     [rbx + PC_SETS], rax
    mov     qword [rbx + PC_SLOTS], PC_HEADER

    mov     rax, r12
    imul    rax, rax, SLOT_SIZE
    add     rax, PC_HEADER
    add     rax, CybouDB_PAGE_SIZE - 1
    and     rax, ~(CybouDB_PAGE_SIZE - 1)
    mov     [rbx + PC_FRAME_BASE], rax

    xor     eax, eax
    jmp     .done
.refuse:
    mov     eax, CybouDB_E_STATE
.done:
    mov     rbx, [rbp - 8]
    mov     r12, [rbp - 16]
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  SET_BASE <dst>, <cache>, <page>  - address of the first slot of the set a
;  page belongs to. The index is the low bits: consecutive pages land in
;  consecutive sets, which is the whole reason a mixing hash is not here.
; -----------------------------------------------------------------------------
%macro SET_BASE 3
    mov     rax, %3
    mov     rcx, [%2 + PC_SETS]
    dec     rcx
    and     rax, rcx                    ; the set
    shl     rax, 3                      ; times PCACHE_WAYS
    imul    rax, rax, SLOT_SIZE
    add     rax, [%2 + PC_SLOTS]
    lea     %1, [%2 + rax]
%endmacro

; -----------------------------------------------------------------------------
;  FRAME_OF <dst>, <cache>, <slot index within the whole array>
; -----------------------------------------------------------------------------
%macro FRAME_OF 3
    mov     rax, %3
    shl     rax, CybouDB_PAGE_SHIFT
    add     rax, [%2 + PC_FRAME_BASE]
    lea     %1, [%2 + rax]
%endmacro

; =============================================================================
;  cyboudb_pcache_lookup(cache, page_no) -> uint8_t *frame, or NULL
;
;  A hit promotes: the second time a page is asked for it stops being
;  probationary, and that is the whole of the scan resistance.
; =============================================================================
cyboudb_pcache_lookup:
    FRAME_BEGIN 48, 0
    mov     [rbp - 8], rbx
    mov     rbx, ARG1
    mov     r11, ARG2

    SET_BASE r10, rbx, r11
    xor     r8, r8
.scan:
    mov     rax, r8
    imul    rax, rax, SLOT_SIZE
    lea     r9, [r10 + rax]
    test    dword [r9 + SLOT_FLAGS], SLOT_VALID
    jz      .next
    cmp     [r9 + SLOT_PAGE], r11
    jne     .next

    ; a hit
    inc     qword [rbx + PC_CLOCK]
    mov     rax, [rbx + PC_CLOCK]
    mov     [r9 + SLOT_STAMP], rax
    or      dword [r9 + SLOT_FLAGS], SLOT_RESIDENT
    inc     qword [rbx + PC_HITS]

    ; which slot is this, counting from the start of the array
    mov     rax, r9
    sub     rax, rbx
    sub     rax, [rbx + PC_SLOTS]
    xor     rdx, rdx
    mov     rcx, SLOT_SIZE
    div     rcx
    FRAME_OF rax, rbx, rax
    jmp     .done

.next:
    inc     r8
    cmp     r8, PCACHE_WAYS
    jb      .scan

    inc     qword [rbx + PC_MISSES]
    xor     eax, eax
.done:
    mov     rbx, [rbp - 8]
    FRAME_END
    ret

; =============================================================================
;  cyboudb_pcache_admit(cache, page_no, out_evicted) -> uint8_t *frame
;
;  ARG3  uint64_t *out_evicted   may be NULL; receives the page number that
;                                was thrown out, with bit 63 set if that page
;                                was dirty - or all ones when nothing was
;                                evicted.
;
;  All ones and not zero, because page zero is the file header and a cache may
;  legitimately hold it.
;
;  A caller must test for all ones BEFORE testing bit 63, because all ones has
;  bit 63 set: "nothing was evicted" and "what was evicted was dirty" are not
;  distinguishable by that bit alone. The first caller written against this got
;  it the other way round and saw a dirty eviction on every admission into an
;  empty set. A sentinel that collides with a real value is a bug
;  waiting for the one caller who evicts page zero, and this one was found by
;  a test that filled a set starting at page zero.
;
;  The caller fills the frame. Saying what was evicted rather than calling back
;  into the caller keeps this file free of I/O and keeps the write-back
;  decision where the durability rules are.
; =============================================================================
cyboudb_pcache_admit:
    FRAME_BEGIN 64, 0
    mov     [rbp - 8], rbx
    mov     [rbp - 16], r12
    mov     [rbp - 24], r13

    mov     rbx, ARG1
    mov     r12, ARG2
    mov     r13, ARG3

    SET_BASE r10, rbx, r12
    mov     [rbp - 32], r10

    ; an empty slot first, whatever the policy
    xor     r8, r8
.empty:
    mov     rax, r8
    imul    rax, rax, SLOT_SIZE
    lea     r9, [r10 + rax]
    test    dword [r9 + SLOT_FLAGS], SLOT_VALID
    jz      .place
    inc     r8
    cmp     r8, PCACHE_WAYS
    jb      .empty

    ; the oldest probationary page, and only then the oldest page
    mov     r11, -1                     ; best index
    mov     rcx, -1                     ; best stamp, unsigned max
    xor     r8, r8
.probation:
    mov     rax, r8
    imul    rax, rax, SLOT_SIZE
    lea     r9, [r10 + rax]
    test    dword [r9 + SLOT_FLAGS], SLOT_RESIDENT
    jnz     .probation_next
    mov     rax, [r9 + SLOT_STAMP]
    cmp     rax, rcx
    jae     .probation_next
    mov     rcx, rax
    mov     r11, r8
.probation_next:
    inc     r8
    cmp     r8, PCACHE_WAYS
    jb      .probation

    cmp     r11, -1
    jne     .chosen

    ; every page in the set has been asked for twice; take the oldest
    mov     rcx, -1
    xor     r8, r8
.oldest:
    mov     rax, r8
    imul    rax, rax, SLOT_SIZE
    lea     r9, [r10 + rax]
    mov     rax, [r9 + SLOT_STAMP]
    cmp     rax, rcx
    jae     .oldest_next
    mov     rcx, rax
    mov     r11, r8
.oldest_next:
    inc     r8
    cmp     r8, PCACHE_WAYS
    jb      .oldest

.chosen:
    mov     r8, r11
    mov     rax, r8
    imul    rax, rax, SLOT_SIZE
    mov     r10, [rbp - 32]
    lea     r9, [r10 + rax]

    inc     qword [rbx + PC_EVICTIONS]
    test    r13, r13
    jz      .place
    mov     rax, [r9 + SLOT_PAGE]
    test    dword [r9 + SLOT_FLAGS], SLOT_DIRTY
    jz      .report
    bts     rax, 63                     ; the caller has to write this one back
.report:
    mov     [r13], rax
    jmp     .placed_report

.place:
    test    r13, r13
    jz      .placed_report
    mov     qword [r13], -1             ; nothing was evicted

.placed_report:
    mov     r10, [rbp - 32]
    mov     rax, r8
    imul    rax, rax, SLOT_SIZE
    lea     r9, [r10 + rax]

    mov     [r9 + SLOT_PAGE], r12
    inc     qword [rbx + PC_CLOCK]
    mov     rax, [rbx + PC_CLOCK]
    mov     [r9 + SLOT_STAMP], rax
    mov     dword [r9 + SLOT_FLAGS], SLOT_VALID   ; probationary, and clean

    ; the frame that belongs to this slot
    mov     rax, r9
    sub     rax, rbx
    sub     rax, [rbx + PC_SLOTS]
    xor     rdx, rdx
    mov     rcx, SLOT_SIZE
    div     rcx
    FRAME_OF rax, rbx, rax

    mov     rbx, [rbp - 8]
    mov     r12, [rbp - 16]
    mov     r13, [rbp - 24]
    FRAME_END
    ret

; =============================================================================
;  cyboudb_pcache_mark_dirty(cache, page_no) -> int
;  cyboudb_pcache_invalidate(cache, page_no) -> int
;
;  Both return 0 when the page was there and CybouDB_E_STATE when it was not -
;  marking a page dirty that the cache does not hold is a caller's bug, not a
;  no-op to be swallowed.
; =============================================================================
cyboudb_pcache_mark_dirty:
    mov     r10, ARG1
    mov     r11, ARG2
    SET_BASE r10, r10, r11
    mov     rdx, ARG1
    xor     r8, r8
.scan:
    mov     rax, r8
    imul    rax, rax, SLOT_SIZE
    lea     r9, [r10 + rax]
    test    dword [r9 + SLOT_FLAGS], SLOT_VALID
    jz      .next
    cmp     [r9 + SLOT_PAGE], r11
    jne     .next
    or      dword [r9 + SLOT_FLAGS], SLOT_DIRTY
    xor     eax, eax
    ret
.next:
    inc     r8
    cmp     r8, PCACHE_WAYS
    jb      .scan
    mov     eax, CybouDB_E_STATE
    ret

cyboudb_pcache_invalidate:
    mov     r10, ARG1
    mov     r11, ARG2
    SET_BASE r10, r10, r11
    xor     r8, r8
.scan:
    mov     rax, r8
    imul    rax, rax, SLOT_SIZE
    lea     r9, [r10 + rax]
    test    dword [r9 + SLOT_FLAGS], SLOT_VALID
    jz      .next
    cmp     [r9 + SLOT_PAGE], r11
    jne     .next
    mov     dword [r9 + SLOT_FLAGS], 0
    mov     qword [r9 + SLOT_PAGE], 0
    xor     eax, eax
    ret
.next:
    inc     r8
    cmp     r8, PCACHE_WAYS
    jb      .scan
    mov     eax, CybouDB_E_STATE
    ret

; =============================================================================
;  cyboudb_pcache_frame(cache, page_no) -> uint8_t *, or NULL
;
;  The frame a page occupies, without counting a hit or touching recency. For
;  a caller that already looked the page up and wants the address again - and
;  for tests, which should not have to disturb the statistics they measure.
; =============================================================================
cyboudb_pcache_frame:
    mov     r10, ARG1
    mov     r11, ARG2
    mov     rdx, r10
    SET_BASE r10, r10, r11
    xor     r8, r8
.scan:
    mov     rax, r8
    imul    rax, rax, SLOT_SIZE
    lea     r9, [r10 + rax]
    test    dword [r9 + SLOT_FLAGS], SLOT_VALID
    jz      .next
    cmp     [r9 + SLOT_PAGE], r11
    jne     .next
    mov     rax, r9
    sub     rax, rdx
    sub     rax, [rdx + PC_SLOTS]
    push    rdx
    xor     rdx, rdx
    mov     rcx, SLOT_SIZE
    div     rcx
    pop     rdx
    FRAME_OF rax, rdx, rax
    ret
.next:
    inc     r8
    cmp     r8, PCACHE_WAYS
    jb      .scan
    xor     eax, eax
    ret

; =============================================================================
;  cyboudb_pcache_stats(cache, out) - hits, misses, evictions, in that order
; =============================================================================
cyboudb_pcache_stats:
    mov     r10, ARG1
    mov     r11, ARG2
    mov     rax, [r10 + PC_HITS]
    mov     [r11], rax
    mov     rax, [r10 + PC_MISSES]
    mov     [r11 + 8], rax
    mov     rax, [r10 + PC_EVICTIONS]
    mov     [r11 + 16], rax
    ret



; =============================================================================
;  cyboudb_pcache_frames(cache) -> how many frames it holds
;  cyboudb_pcache_dirty_at(cache, slot) -> the page in that slot if it is
;                                          dirty, or all ones
;  cyboudb_pcache_clean_at(cache, slot) -> marks that slot clean
;
;  A commit has to find every page it has changed, and a cache that cannot be
;  walked would mean keeping a second list of the same thing somewhere else -
;  two structures that must agree, which is the shape most lost-write bugs
;  have. Walking slots is not elegant and it is exact.
;
;  All ones for "not a dirty page" for the same reason the eviction report uses
;  it: page zero is a real page.
; =============================================================================
cyboudb_pcache_frames:
    mov     r10, ARG1
    mov     rax, [r10 + PC_FRAMES]
    ret

cyboudb_pcache_dirty_at:
    mov     r10, ARG1
    mov     r11, ARG2
    cmp     r11, [r10 + PC_FRAMES]
    jae     .none
    mov     rax, r11
    imul    rax, rax, SLOT_SIZE
    add     rax, [r10 + PC_SLOTS]
    add     rax, r10
    mov     ecx, [rax + SLOT_FLAGS]
    and     ecx, SLOT_VALID | SLOT_DIRTY
    cmp     ecx, SLOT_VALID | SLOT_DIRTY
    jne     .none
    mov     rax, [rax + SLOT_PAGE]
    ret
.none:
    mov     rax, -1
    ret

cyboudb_pcache_clean_at:
    mov     r10, ARG1
    mov     r11, ARG2
    cmp     r11, [r10 + PC_FRAMES]
    jae     .done
    mov     rax, r11
    imul    rax, rax, SLOT_SIZE
    add     rax, [r10 + PC_SLOTS]
    add     rax, r10
    and     dword [rax + SLOT_FLAGS], ~SLOT_DIRTY
.done:
    xor     eax, eax
    ret


; =============================================================================
;  cyboudb_pcache_set_type(cache, page, type) -> int
;  cyboudb_pcache_type_at(cache, slot) -> the type, or all ones
; =============================================================================
cyboudb_pcache_set_type:
    mov     r10, ARG1
    mov     r11, ARG2
    mov     rdx, ARG3
    SET_BASE r10, r10, r11
    xor     r8, r8
.scan:
    mov     rax, r8
    imul    rax, rax, SLOT_SIZE
    lea     r9, [r10 + rax]
    test    dword [r9 + SLOT_FLAGS], SLOT_VALID
    jz      .next
    cmp     [r9 + SLOT_PAGE], r11
    jne     .next
    mov     eax, [r9 + SLOT_FLAGS]
    and     eax, ~SLOT_TYPE_MASK
    mov     ecx, edx
    shl     ecx, SLOT_TYPE_SHIFT
    and     ecx, SLOT_TYPE_MASK
    or      eax, ecx
    mov     [r9 + SLOT_FLAGS], eax
    xor     eax, eax
    ret
.next:
    inc     r8
    cmp     r8, PCACHE_WAYS
    jb      .scan
    mov     eax, CybouDB_E_STATE
    ret

cyboudb_pcache_type_at:
    mov     r10, ARG1
    mov     r11, ARG2
    cmp     r11, [r10 + PC_FRAMES]
    jae     .none
    mov     rax, r11
    imul    rax, rax, SLOT_SIZE
    add     rax, [r10 + PC_SLOTS]
    add     rax, r10
    test    dword [rax + SLOT_FLAGS], SLOT_VALID
    jz      .none
    mov     eax, [rax + SLOT_FLAGS]
    and     eax, SLOT_TYPE_MASK
    shr     eax, SLOT_TYPE_SHIFT
    ret
.none:
    mov     rax, -1
    ret

%ifdef CybouDB_LINUX
section .note.GNU-stack noalloc noexec nowrite progbits
%endif
