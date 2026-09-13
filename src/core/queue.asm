; Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
; SPDX-License-Identifier: Apache-2.0
; Durable FIFO queues: the catalog page that defines one, its segments, and
; what a commit proves about both. The decisions behind the layout are in
; docs/QUEUE.md; where the bytes are is in include/queue.inc.
;
; A segment is an ordinary copy-on-write payload page, so nothing here has a
; crash protocol of its own: a new segment reaches the superblock through the
; queue page and the catalog directory, in the same publication as everything
; else the transaction wrote.
%include "cyboudb.inc"
BITS 64
default rel
extern crc32c
extern db_bitmap_candidate_payload
extern db_var_validate_chain
global queue_page_valid, db_queue_seg_addr, queue_seg_seal

section .data
; Segment pages this process looked at while validating. A queue that is
; drained as fast as it is filled holds one segment however many messages it
; has carried, and a test can say so rather than assuming it.
global queue_segments_walked
queue_segments_walked: dq 0

section .text

; db_queue_seg_addr(ARG1 = ctx, ARG2 = page id) -> RAX: where it is mapped.
db_queue_seg_addr:
    mov rax, ARG2
    shl rax, CybouDB_PAGE_SHIFT
    mov r10, ARG1
    add rax, [r10 + DB_BASE]
    ret

; queue_seg_seal(ARG1 = segment address, ARG2 = ctx): stamp the page id and
; generation this transaction gives it, then checksum the whole page.
queue_seg_seal:
    FRAME_BEGIN 32, 0
    mov [rbp - 8], ARG1
    mov r10, ARG1
    mov r11, ARG2
    mov rax, r10
    sub rax, [r11 + DB_BASE]
    shr rax, CybouDB_PAGE_SHIFT
    mov [r10 + QSEG_PAGE_ID], rax
    mov rax, [r11 + DB_GENERATION]
    inc rax
    mov [r10 + QSEG_GENERATION], rax
    mov ARG1, r10
    mov ARG2, QSEG_CRC
    call crc32c
    mov r10, [rbp - 8]
    mov [r10 + QSEG_CRC], eax
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  queue_page_valid(ARG1 = ctx, ARG2 = candidate superblock, ARG3 = queue page)
;      -> RAX: 1 when the queue that page defines is coherent.
;
;  Called where every other directory-reachable page is proved: at every commit
;  and at every open, refusing the generation rather than the statement.
;
;  What it costs is the segments the queue is holding, not the messages it has
;  carried. A drained queue is one page. The per-message walk - the shape of a
;  slot and the extent chain a long payload names - runs under DB_VERIFY, which
;  `cyboudb check` sets, for the same reason the index recomputes subtree sizes
;  only there: a segment's own checksum already covers its slots, and what a
;  checksum cannot say is whether a page id inside one leads anywhere.
;
;  Local slots: [rbp-8]=ctx, [rbp-16]=sb, [rbp-24]=queue page, [rbp-32]=head,
;               [rbp-40]=tail, [rbp-48]=segments, [rbp-56]=first segment,
;               [rbp-64]=entry index, [rbp-72]=segment address,
;               [rbp-80]=position, [rbp-88]=slot address
; -----------------------------------------------------------------------------
queue_page_valid:
    FRAME_BEGIN 128, 2
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
    mov [rbp - 24], ARG3
    mov r10, ARG1
    test qword [r10 + DB_FEATURES], CybouDB_FEATURE_QUEUE
    jz .bad

    mov r11, ARG3
    cmp byte [r11 + Q_NAME], 0
    je .bad                         ; a queue nothing can name
    cmp qword [r11 + Q_RESERVED2], 0
    jne .bad
    cmp qword [r11 + Q_RESERVED2 + 8], 0
    jne .bad

    mov rax, [r11 + Q_HEAD]
    mov [rbp - 32], rax
    mov rdx, [r11 + Q_TAIL]
    mov [rbp - 40], rdx
    cmp rax, rdx
    ja .bad                         ; the head cannot pass the tail
    ; A version 1 DEQUEUE hands out and acknowledges in one step, so the claim
    ; cursor is the head. The field is where a lease would keep it; until there
    ; is a capability bit saying a build writes leases, a file whose claim has
    ; run ahead was written by something this build does not understand.
    mov rcx, [r11 + Q_CLAIM]
    cmp rcx, rax
    jne .bad
    mov ecx, [r11 + Q_SEGMENTS]
    mov [rbp - 48], rcx
    cmp rcx, Q_MAX_SEGMENTS
    ja .bad
    mov rax, [r11 + Q_FIRST_SEG]
    mov [rbp - 56], rax

    ; The directory names exactly the segments spanning [head, tail). Both
    ; ends follow from the positions, so a queue cannot carry a segment it has
    ; drained or be missing one it is using.
    mov rax, [rbp - 32]
    xor edx, edx
    mov rcx, QUEUE_SEG_SLOTS
    div rcx                         ; rax = the segment the head is in
    cmp rax, [rbp - 56]
    jne .bad
    mov rdx, [rbp - 32]
    cmp rdx, [rbp - 40]
    jne .not_empty
    cmp qword [rbp - 48], 0
    jne .bad                        ; an empty queue names no segment
    jmp .entries_done
.not_empty:
    mov rax, [rbp - 40]
    dec rax
    xor edx, edx
    mov rcx, QUEUE_SEG_SLOTS
    div rcx                         ; rax = the segment the last message is in
    sub rax, [rbp - 56]
    inc rax
    cmp rax, [rbp - 48]
    jne .bad

    ; And every one of them is a page this generation reaches, carrying this
    ; queue's id and the position the arithmetic says it starts at. Two entries
    ; naming one page would need one page to start at two positions, so the
    ; entries are distinct without being compared.
    mov qword [rbp - 64], 0
.entry:
    mov rax, [rbp - 64]
    cmp rax, [rbp - 48]
    jae .entries_done
    inc qword [rel queue_segments_walked]
    mov r11, [rbp - 24]
    mov rdx, [r11 + Q_ENTRIES + rax * 8]
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    mov ARG3, rdx
    call db_bitmap_candidate_payload
    test eax, eax
    jz .bad
    mov r11, [rbp - 24]
    mov rax, [rbp - 64]
    mov ARG2, [r11 + Q_ENTRIES + rax * 8]
    mov ARG1, [rbp - 8]
    call db_queue_seg_addr
    mov [rbp - 72], rax
    mov r10, rax
    cmp dword [r10 + QSEG_MAGIC], QSEG_MAGIC_VALUE
    jne .bad
    cmp dword [r10 + QSEG_VERSION], QSEG_VERSION_VALUE
    jne .bad
    mov r11, [rbp - 24]
    mov rax, [rbp - 64]
    mov rdx, [r11 + Q_ENTRIES + rax * 8]
    cmp [r10 + QSEG_PAGE_ID], rdx
    jne .bad
    mov rdx, [r11 + CAT_OWNER]
    cmp [r10 + QSEG_OWNER], rdx
    jne .bad                        ; a segment answers to the queue that names it
    cmp qword [r10 + QSEG_RESERVED], 0
    jne .bad
    cmp qword [r10 + QSEG_RESERVED + 8], 0
    jne .bad
    cmp qword [r10 + QSEG_RESERVED + 16], 0
    jne .bad
    mov rax, [rbp - 64]
    add rax, [rbp - 56]
    imul rax, QUEUE_SEG_SLOTS
    cmp [r10 + QSEG_FIRST], rax
    jne .bad
    mov ARG1, r10
    mov ARG2, QSEG_CRC
    call crc32c
    mov r10, [rbp - 72]
    cmp [r10 + QSEG_CRC], eax
    jne .bad
    inc qword [rbp - 64]
    jmp .entry

.entries_done:
    ; Everything past the entries this queue claims is zero, as every tail in
    ; this format is. A commit re-checks a page's checksum only when this
    ; transaction wrote it, so without this a directory entry sitting past the
    ; count would be read by nothing and refused by nothing - which is how a
    ; page written by some other build gets believed.
    mov r8, [rbp - 24]
    mov rax, [rbp - 48]
    lea r9, [r8 + Q_ENTRIES + rax * 8]
    lea r11, [r8 + Q_CRC]
.tail:
    cmp r9, r11
    jae .tail_done
    cmp dword [r9], 0
    jne .bad
    add r9, 4
    jmp .tail
.tail_done:

    mov r10, [rbp - 8]
    cmp qword [r10 + DB_VERIFY], 0
    je .good

    ; The deep pass: every message the queue is holding, in the slot the
    ; arithmetic puts it in.
    mov rax, [rbp - 32]
    mov [rbp - 80], rax
.message:
    mov rax, [rbp - 80]
    cmp rax, [rbp - 40]
    jae .good
    xor edx, edx
    mov rcx, QUEUE_SEG_SLOTS
    div rcx                         ; rax = segment, rdx = slot
    sub rax, [rbp - 56]
    mov r11, [rbp - 24]
    mov ARG2, [r11 + Q_ENTRIES + rax * 8]
    mov [rbp - 88], rdx
    mov ARG1, [rbp - 8]
    call db_queue_seg_addr
    mov rdx, [rbp - 88]
    shl rdx, 6                      ; QUEUE_SLOT_SIZE
    lea rax, [rax + QSEG_SLOTS + rdx]
    mov [rbp - 88], rax
    mov r10, rax
    ; Nothing has a lease yet, and a message that claims one was not written by
    ; this build.
    cmp dword [r10 + QMSG_STATE], QMSG_STATE_HELD
    jne .bad
    cmp dword [r10 + QMSG_RESERVED32], 0
    jne .bad
    cmp qword [r10 + QMSG_LEASE_UNTIL], 0
    jne .bad
    cmp qword [r10 + QMSG_LEASE_TOKEN], 0
    jne .bad
    mov ecx, [r10 + QMSG_FLAGS]
    test ecx, ~QMSG_FLAG_EXTENT
    jnz .bad
    mov edx, [r10 + QMSG_LENGTH]
    test ecx, QMSG_FLAG_EXTENT
    jnz .message_extent
    cmp rdx, QMSG_INLINE_MAX
    ja .bad                         ; longer than a slot holds and not an extent
    jmp .message_done
.message_extent:
    cmp rdx, QMSG_INLINE_MAX
    jbe .bad                        ; short enough to have stayed in the slot
    mov r11, [rbp - 24]
    mov rax, [r11 + CAT_OWNER]
    PASS_ARG5 rax
    mov ARG4, rdx
    mov ARG3, [r10 + QMSG_EXTENT]
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    call db_var_validate_chain
    test eax, eax
    jz .bad
.message_done:
    inc qword [rbp - 80]
    jmp .message

.good:
    mov eax, 1
    FRAME_END
    ret
.bad:
    xor eax, eax
    FRAME_END
    ret
