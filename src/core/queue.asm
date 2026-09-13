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
extern db_bitmap_candidate_payload, db_bitmap_is_fresh, db_bitmap_retire
extern db_cow_alloc_page, db_cow_copy_page
extern db_catalog_page, db_catalog_edit, db_catalog_seal
extern db_var_validate_chain, db_var_write_chain, db_var_read_chain
global queue_page_valid, db_queue_seg_addr, queue_seg_seal, db_queue_segments_valid
global db_queue_push, db_queue_pop, db_queue_peek, db_queue_depth
global db_queue_retire_all

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
;  db_queue_segments_valid(ARG1 = descriptor) -> RAX: 1 when the segments an
;  object names are coherent.
;
;  A queue and a stream are different promises over the same storage, so this
;  is the walk both of them get. What the caller has already proved is the page
;  that names the segments; what this proves is the segments.
;
;  What it costs is the segments the object is holding, not the records it has
;  carried. A drained queue, or a fully trimmed stream, is one page. The
;  per-record walk - the shape of a slot and the extent chain a long payload
;  names - runs under DB_VERIFY, which `cyboudb check` sets, for the reason the
;  index recomputes subtree sizes only there: a segment's own checksum already
;  covers its slots, and what a checksum cannot say is whether a page id inside
;  one leads anywhere.
;
;  Local slots: [rbp-8]=descriptor, [rbp-16]=entry index, [rbp-24]=segment
;               address, [rbp-32]=position, [rbp-40]=slot address
; -----------------------------------------------------------------------------
db_queue_segments_valid:
    FRAME_BEGIN 96, 2
    mov [rbp - 8], ARG1
    mov r11, ARG1
    mov rax, [r11 + QSV_LOW]
    cmp rax, [r11 + QSV_HIGH]
    ja .bad                         ; the low end cannot pass the high one
    mov rcx, [r11 + QSV_SEGMENTS]
    cmp rcx, [r11 + QSV_MAX_SEG]
    ja .bad

    ; The directory names exactly the segments spanning [low, high). Both ends
    ; follow from the positions, so an object cannot carry a segment it has
    ; let go of or be missing one it is using.
    xor edx, edx
    mov rcx, QUEUE_SEG_SLOTS
    div rcx                         ; rax = the segment the low end is in
    mov r11, [rbp - 8]
    cmp rax, [r11 + QSV_FIRST_SEG]
    jne .bad
    mov rax, [r11 + QSV_LOW]
    cmp rax, [r11 + QSV_HIGH]
    jne .not_empty
    cmp qword [r11 + QSV_SEGMENTS], 0
    jne .bad                        ; holding nothing names no segment
    jmp .entries_done
.not_empty:
    mov rax, [r11 + QSV_HIGH]
    dec rax
    xor edx, edx
    mov rcx, QUEUE_SEG_SLOTS
    div rcx                         ; the segment the last record is in
    mov r11, [rbp - 8]
    sub rax, [r11 + QSV_FIRST_SEG]
    inc rax
    cmp rax, [r11 + QSV_SEGMENTS]
    jne .bad

    ; And every one of them is a page this generation reaches, carrying the
    ; owner's id and the position the arithmetic says it starts at. Two entries
    ; naming one page would need one page to start at two positions, so the
    ; entries are distinct without being compared.
    mov qword [rbp - 16], 0
.entry:
    mov r11, [rbp - 8]
    mov rax, [rbp - 16]
    cmp rax, [r11 + QSV_SEGMENTS]
    jae .entries_done
    inc qword [rel queue_segments_walked]
    ; The page goes in a register no argument aliases: ARG2 is RDX on one of
    ; the two ABIs, and loading the superblock would take the page with it.
    mov rcx, [r11 + QSV_ENTRIES]
    mov r9, [rcx + rax * 8]
    mov ARG1, [r11 + QSV_CTX]
    mov ARG2, [r11 + QSV_SB]
    mov ARG3, r9
    call db_bitmap_candidate_payload
    test eax, eax
    jz .bad
    mov r11, [rbp - 8]
    mov rcx, [r11 + QSV_ENTRIES]
    mov rax, [rbp - 16]
    mov r9, [rcx + rax * 8]
    mov ARG1, [r11 + QSV_CTX]
    mov ARG2, r9
    call db_queue_seg_addr
    mov [rbp - 24], rax
    mov r10, rax
    cmp dword [r10 + QSEG_MAGIC], QSEG_MAGIC_VALUE
    jne .bad
    cmp dword [r10 + QSEG_VERSION], QSEG_VERSION_VALUE
    jne .bad
    mov r11, [rbp - 8]
    mov rcx, [r11 + QSV_ENTRIES]
    mov rax, [rbp - 16]
    mov rdx, [rcx + rax * 8]
    cmp [r10 + QSEG_PAGE_ID], rdx
    jne .bad
    mov rdx, [r11 + QSV_OWNER]
    cmp [r10 + QSEG_OWNER], rdx
    jne .bad                        ; a segment answers to the object naming it
    cmp qword [r10 + QSEG_RESERVED], 0
    jne .bad
    cmp qword [r10 + QSEG_RESERVED + 8], 0
    jne .bad
    cmp qword [r10 + QSEG_RESERVED + 16], 0
    jne .bad
    mov rax, [rbp - 16]
    add rax, [r11 + QSV_FIRST_SEG]
    imul rax, QUEUE_SEG_SLOTS
    cmp [r10 + QSEG_FIRST], rax
    jne .bad
    mov ARG1, r10
    mov ARG2, QSEG_CRC
    call crc32c
    mov r10, [rbp - 24]
    cmp [r10 + QSEG_CRC], eax
    jne .bad
    inc qword [rbp - 16]
    jmp .entry

.entries_done:
    ; Everything past the entries the object claims is zero, as every tail in
    ; this format is. A commit re-checks a page's checksum only when this
    ; transaction wrote it, so without this a directory entry sitting past the
    ; count would be read by nothing and refused by nothing - which is how a
    ; page written by some other build gets believed.
    mov r11, [rbp - 8]
    mov rax, [r11 + QSV_SEGMENTS]
    mov r9, [r11 + QSV_ENTRIES]
    lea r9, [r9 + rax * 8]
    mov rcx, [r11 + QSV_TAIL_END]
.tail:
    cmp r9, rcx
    jae .tail_done
    cmp dword [r9], 0
    jne .bad
    add r9, 4
    jmp .tail
.tail_done:
    mov r11, [rbp - 8]
    mov r10, [r11 + QSV_CTX]
    cmp qword [r10 + DB_VERIFY], 0
    je .good

    ; The deep pass: every record the object is holding, in the slot the
    ; arithmetic puts it in.
    mov rax, [r11 + QSV_LOW]
    mov [rbp - 32], rax
.record:
    mov r11, [rbp - 8]
    mov rax, [rbp - 32]
    cmp rax, [r11 + QSV_HIGH]
    jae .good
    xor edx, edx
    mov rcx, QUEUE_SEG_SLOTS
    div rcx                         ; rax = segment, rdx = slot
    mov [rbp - 40], rdx             ; before an argument register takes it
    sub rax, [r11 + QSV_FIRST_SEG]
    mov rcx, [r11 + QSV_ENTRIES]
    mov r9, [rcx + rax * 8]
    mov ARG1, [r11 + QSV_CTX]
    mov ARG2, r9
    call db_queue_seg_addr
    mov rdx, [rbp - 40]
    shl rdx, 6                      ; QUEUE_SLOT_SIZE
    lea rax, [rax + QSEG_SLOTS + rdx]
    mov [rbp - 40], rax
    mov r10, rax
    ; Nothing has a lease yet, and a record that claims one was not written by
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
    jnz .record_extent
    cmp rdx, QMSG_INLINE_MAX
    ja .bad                         ; longer than a slot holds, and not an extent
    jmp .record_done
.record_extent:
    cmp rdx, QMSG_INLINE_MAX
    jbe .bad                        ; short enough to have stayed in the slot
    mov r11, [rbp - 8]
    mov rax, [r11 + QSV_OWNER]
    PASS_ARG5 rax
    mov ARG4, rdx
    mov ARG3, [r10 + QMSG_EXTENT]
    mov ARG1, [r11 + QSV_CTX]
    mov ARG2, [r11 + QSV_SB]
    call db_var_validate_chain
    test eax, eax
    jz .bad
.record_done:
    inc qword [rbp - 32]
    jmp .record

.good:
    mov eax, 1
    FRAME_END
    ret
.bad:
    xor eax, eax
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  queue_page_valid(ARG1 = ctx, ARG2 = candidate superblock, ARG3 = queue page)
;      -> RAX: 1 when the queue that page defines is coherent.
;
;  Called where every other directory-reachable page is proved: at every commit
;  and at every open, refusing the generation rather than the statement. What
;  is here is what makes a queue a queue; the segments are proved by the walk
;  a stream shares.
;
;  Local slots: [rbp-8]=ctx, [rbp-16]=sb, [rbp-24]=queue page,
;               [rbp-96]=the descriptor
; -----------------------------------------------------------------------------
queue_page_valid:
    FRAME_BEGIN 128, 0
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
    mov [rbp - 24], ARG3
    mov r10, ARG1
    test qword [r10 + DB_FEATURES], CybouDB_FEATURE_QUEUE
    jz .q_bad

    mov r11, ARG3
    cmp byte [r11 + Q_NAME], 0
    je .q_bad                       ; a queue nothing can name
    cmp qword [r11 + Q_RESERVED2], 0
    jne .q_bad
    cmp qword [r11 + Q_RESERVED2 + 8], 0
    jne .q_bad
    ; A version 1 DEQUEUE hands out and acknowledges in one step, so the claim
    ; cursor is the head. The field is where a lease would keep it; until there
    ; is a capability bit saying a build writes leases, a file whose claim has
    ; run ahead was written by something this build does not understand.
    mov rax, [r11 + Q_HEAD]
    cmp rax, [r11 + Q_CLAIM]
    jne .q_bad

    mov [rbp - 96 + QSV_CTX], ARG1
    mov rax, [rbp - 16]
    mov [rbp - 96 + QSV_SB], rax
    mov r11, [rbp - 24]
    mov rax, [r11 + CAT_OWNER]
    mov [rbp - 96 + QSV_OWNER], rax
    lea rax, [r11 + Q_ENTRIES]
    mov [rbp - 96 + QSV_ENTRIES], rax
    lea rax, [r11 + Q_CRC]
    mov [rbp - 96 + QSV_TAIL_END], rax
    mov ecx, [r11 + Q_SEGMENTS]
    mov [rbp - 96 + QSV_SEGMENTS], rcx
    mov rax, [r11 + Q_FIRST_SEG]
    mov [rbp - 96 + QSV_FIRST_SEG], rax
    mov rax, [r11 + Q_HEAD]
    mov [rbp - 96 + QSV_LOW], rax
    mov rax, [r11 + Q_TAIL]
    mov [rbp - 96 + QSV_HIGH], rax
    mov qword [rbp - 96 + QSV_MAX_SEG], Q_MAX_SEGMENTS
    lea ARG1, [rbp - 96]
    call db_queue_segments_valid
    FRAME_END
    ret
.q_bad:
    xor eax, eax
    FRAME_END
    ret
; queue_copy_seg(ARG1 = ctx, ARG2 = page id, ARG3 = out id) -> RAX: result
; A segment this transaction already allocated is already its own copy, for the
; reason an index node is: nothing published reaches it, and a segment has
; exactly one parent. Without this an ENQUEUE of many messages would spend a
; page each, which is what CREATE INDEX used to do a row at a time.
queue_copy_seg:
    FRAME_BEGIN 32, 0
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
    mov [rbp - 24], ARG3
    call db_bitmap_is_fresh
    test eax, eax
    jz .copy
    mov r10, [rbp - 24]
    mov rax, [rbp - 16]
    mov [r10], rax
    xor eax, eax
    FRAME_END
    ret
.copy:
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    mov ARG3, [rbp - 24]
    call db_cow_copy_page
    FRAME_END
    ret

; db_queue_depth(ARG1 = ctx, ARG2 = queue id) -> RAX: messages held, or -1
db_queue_depth:
    FRAME_BEGIN 16, 0
    call db_catalog_page
    test rax, rax
    jz .no_queue
    cmp dword [rax + CAT_TYPE], CAT_QUEUE
    jne .no_queue
    mov rdx, [rax + Q_TAIL]
    sub rdx, [rax + Q_HEAD]
    mov rax, rdx
    FRAME_END
    ret
.no_queue:
    mov rax, -1
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  db_queue_push(ctx, queue id, bytes, length) -> RAX: result code
;
;  One message at the tail. Where it goes is arithmetic on the position, so
;  what this touches is the queue page, the segment that position lands in, and
;  nothing else: no walk, no chain, no rewrite of what is already there.
;
;  A tail that crosses a segment boundary needs a new segment, and an empty
;  queue re-bases its directory on the segment the tail is in rather than
;  carrying entries for segments it has drained.
;
;  Local slots: [rbp-8]=ctx, [rbp-16]=id, [rbp-24]=bytes, [rbp-32]=length,
;               [rbp-40]=head, [rbp-48]=tail, [rbp-56]=segments,
;               [rbp-64]=first segment, [rbp-72]=queue page, [rbp-80]=slot,
;               [rbp-88]=entry index, [rbp-96]=segment page id,
;               [rbp-104]=segment address
; -----------------------------------------------------------------------------
db_queue_push:
    FRAME_BEGIN 192, 1
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
    mov [rbp - 24], ARG3
    mov [rbp - 32], ARG4
    mov r10, ARG1
    test qword [r10 + DB_FEATURES], CybouDB_FEATURE_QUEUE
    jz .p_state
    mov rax, [rbp - 32]
    shr rax, 32
    jnz .p_value                    ; a length the slot's field cannot hold

    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    call db_catalog_page
    test rax, rax
    jz .p_state
    cmp dword [rax + CAT_TYPE], CAT_QUEUE
    jne .p_state
    mov rdx, [rax + Q_HEAD]
    mov [rbp - 40], rdx
    mov rdx, [rax + Q_TAIL]
    mov [rbp - 48], rdx
    mov ecx, [rax + Q_SEGMENTS]
    mov [rbp - 56], rcx
    mov rdx, [rax + Q_FIRST_SEG]
    mov [rbp - 64], rdx

    ; The segment and the slot this position lands in.
    mov rax, [rbp - 48]
    xor edx, edx
    mov rcx, QUEUE_SEG_SLOTS
    div rcx
    mov [rbp - 80], rdx             ; the slot inside it
    cmp qword [rbp - 56], 0
    jne .p_based
    mov [rbp - 64], rax             ; an empty queue starts where the tail is
.p_based:
    sub rax, [rbp - 64]
    mov [rbp - 88], rax             ; the directory entry it wants
    cmp rax, [rbp - 56]
    jb .p_edit
    cmp rax, Q_MAX_SEGMENTS
    jae .p_full                     ; the backlog this format can hold

.p_edit:
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    lea ARG3, [rbp - 72]
    call db_catalog_edit
    test eax, eax
    jnz .p_done

    mov rax, [rbp - 88]
    cmp rax, [rbp - 56]
    jb .p_have_segment

    ; A segment of its own, stamped with the position it starts at - which is
    ; what makes two entries naming one page impossible.
    mov ARG1, [rbp - 8]
    lea ARG2, [rbp - 96]
    call db_cow_alloc_page
    test eax, eax
    jnz .p_done
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 96]
    call db_queue_seg_addr
    mov [rbp - 104], rax
    mov r10, rax
    mov dword [r10 + QSEG_MAGIC], QSEG_MAGIC_VALUE
    mov dword [r10 + QSEG_VERSION], QSEG_VERSION_VALUE
    mov rax, [rbp - 16]
    mov [r10 + QSEG_OWNER], rax
    mov rax, [rbp - 88]
    add rax, [rbp - 64]
    imul rax, QUEUE_SEG_SLOTS
    mov [r10 + QSEG_FIRST], rax
    mov r11, [rbp - 72]
    mov rax, [rbp - 88]
    mov rdx, [rbp - 96]
    mov [r11 + Q_ENTRIES + rax * 8], rdx
    inc qword [rbp - 56]
    jmp .p_slot

.p_have_segment:
    mov r11, [rbp - 72]
    mov rax, [rbp - 88]
    mov ARG2, [r11 + Q_ENTRIES + rax * 8]
    mov ARG1, [rbp - 8]
    lea ARG3, [rbp - 96]
    call queue_copy_seg
    test eax, eax
    jnz .p_done
    mov r11, [rbp - 72]
    mov rax, [rbp - 88]
    mov rdx, [rbp - 96]
    mov [r11 + Q_ENTRIES + rax * 8], rdx
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 96]
    call db_queue_seg_addr
    mov [rbp - 104], rax

.p_slot:
    ; The payload, into the slot the position names.
    mov rax, [rbp - 80]
    shl rax, 6                      ; QUEUE_SLOT_SIZE
    add rax, [rbp - 104]
    add rax, QSEG_SLOTS
    mov [rbp - 112], rax            ; the slot
    mov r8, rax
    mov rcx, [rbp - 32]
    mov [r8 + QMSG_LENGTH], ecx
    mov dword [r8 + QMSG_FLAGS], 0
    mov dword [r8 + QMSG_STATE], QMSG_STATE_HELD
    mov dword [r8 + QMSG_RESERVED32], 0
    mov qword [r8 + QMSG_LEASE_UNTIL], 0
    mov qword [r8 + QMSG_LEASE_TOKEN], 0
    cmp rcx, QMSG_INLINE_MAX
    ja .p_extent
    mov r9, [rbp - 24]
    xor edx, edx
.p_byte:
    cmp rdx, rcx
    jae .p_padded
    mov al, [r9 + rdx]
    mov [r8 + QMSG_PAYLOAD + rdx], al
    inc rdx
    jmp .p_byte
.p_padded:
    ; The rest of the slot is zero. A reused page arrives zeroed and a slot is
    ; never written twice, because a position is never reused - but a segment
    ; copied from an older generation carries whatever it had.
    cmp rdx, QMSG_INLINE_MAX
    jae .p_sealed
    mov byte [r8 + QMSG_PAYLOAD + rdx], 0
    inc rdx
    jmp .p_padded

.p_extent:
    ; Longer than a slot holds, so the bytes go where a TEXT cell's go: a
    ; chain of extent pages owned by the queue's id. The slot keeps the length
    ; and the first page, which is the same descriptor a PAX cell keeps.
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 24]
    mov ARG3, [rbp - 32]
    mov ARG4, [rbp - 16]
    lea rax, [rbp - 128]
    PASS_ARG5 rax
    call db_var_write_chain
    test eax, eax
    jnz .p_done
    mov r8, [rbp - 112]
    mov dword [r8 + QMSG_FLAGS], QMSG_FLAG_EXTENT
    mov rax, [rbp - 128 + VAR_CELL_ROOT]
    mov [r8 + QMSG_EXTENT], rax
    ; And the rest of the payload area is zero, as every tail here is: a slot
    ; naming an extent keeps no bytes of its own.
    mov edx, 8
.p_extent_pad:
    cmp rdx, QMSG_INLINE_MAX
    jae .p_sealed
    mov byte [r8 + QMSG_PAYLOAD + rdx], 0
    inc rdx
    jmp .p_extent_pad

.p_sealed:
    mov ARG1, [rbp - 104]
    mov ARG2, [rbp - 8]
    call queue_seg_seal

    ; And the queue says what it now holds. stamp cleared the reserved span,
    ; which is where head, tail and the claim cursor live.
    mov r10, [rbp - 72]
    mov rax, [rbp - 40]
    mov [r10 + Q_HEAD], rax
    mov [r10 + Q_CLAIM], rax
    mov rax, [rbp - 48]
    inc rax
    mov [r10 + Q_TAIL], rax
    mov rax, [rbp - 56]
    mov [r10 + Q_SEGMENTS], eax
    mov rax, [rbp - 64]
    mov [r10 + Q_FIRST_SEG], rax
    mov ARG1, r10
    call db_catalog_seal
    xor eax, eax
    jmp .p_done
.p_state:
    mov eax, CybouDB_E_STATE
    jmp .p_done
.p_value:
    mov eax, CybouDB_E_VALUE
    jmp .p_done
.p_full:
    mov eax, CybouDB_E_FULL
.p_done:
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  db_queue_pop(ctx, queue id, out_buffer, out_length) -> RAX: result code,
;  CybouDB_E_NOTFOUND when the queue holds nothing.
;
;  The message at the head, copied out before anything moves - the segment it
;  came from may be retired by the same call, and handing back a pointer into a
;  page that is about to leave the generation is how a zero-copy read stops
;  being a read.
;
;  Taking a message does not clear its slot. The slot is unreachable the moment
;  the head passes it, and clearing it would mean writing a page the take did
;  not otherwise have to touch. A segment every one of whose positions is now
;  behind the head is retired and its entry dropped, so a queue drained as fast
;  as it is filled holds the segments it is using and not the ones it has used.
;
;  The first segment the directory names is always the one the head is in -
;  validation says so, and deriving it here rather than tracking it is what
;  keeps the two from ever disagreeing.
;
;  Local slots: [rbp-8]=ctx, [rbp-16]=id, [rbp-24]=out buffer, [rbp-32]=out len,
;               [rbp-40]=head, [rbp-48]=tail, [rbp-56]=segments,
;               [rbp-64]=first segment, [rbp-72]=queue page, [rbp-80]=slot,
;               [rbp-88]=entry index, [rbp-96]=segment address,
;               [rbp-104]=length, [rbp-112]=entries retired,
;               [rbp-120]=entries kept, [rbp-128]=the loop index,
;               [rbp-136]=the slot, [rbp-144]=extent descriptor,
;               [rbp-152]=what the caller buffer holds
; -----------------------------------------------------------------------------
db_queue_pop:
    FRAME_BEGIN 224, 2
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
    mov [rbp - 24], ARG3
    mov [rbp - 32], ARG4
    mov rax, IN_ARG5
    mov [rbp - 152], rax            ; what the caller's buffer holds
    mov r10, ARG1
    test qword [r10 + DB_FEATURES], CybouDB_FEATURE_QUEUE
    jz .o_state

    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    call db_catalog_page
    test rax, rax
    jz .o_state
    cmp dword [rax + CAT_TYPE], CAT_QUEUE
    jne .o_state
    mov rdx, [rax + Q_HEAD]
    mov [rbp - 40], rdx
    mov rcx, [rax + Q_TAIL]
    mov [rbp - 48], rcx
    cmp rdx, rcx
    je .o_empty
    mov ecx, [rax + Q_SEGMENTS]
    mov [rbp - 56], rcx
    mov rdx, [rax + Q_FIRST_SEG]
    mov [rbp - 64], rdx

    ; Which segment the head is in, and where inside it.
    mov rax, [rbp - 40]
    xor edx, edx
    mov rcx, QUEUE_SEG_SLOTS
    div rcx
    mov [rbp - 80], rdx
    sub rax, [rbp - 64]
    mov [rbp - 88], rax
    cmp rax, [rbp - 56]
    jae .o_state                    ; the directory does not reach its own head

    ; The bytes, out of the page and into the caller before anything moves.
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    call db_catalog_page
    mov r11, rax
    mov rax, [rbp - 88]
    mov ARG2, [r11 + Q_ENTRIES + rax * 8]
    mov ARG1, [rbp - 8]
    call db_queue_seg_addr
    mov [rbp - 96], rax
    mov rdx, [rbp - 80]
    shl rdx, 6
    lea r8, [rax + QSEG_SLOTS + rdx]
    mov ecx, [r8 + QMSG_LENGTH]
    mov [rbp - 104], rcx
    mov [rbp - 136], r8             ; the slot, for the flags below
    mov ecx, [r8 + QMSG_FLAGS]
    test ecx, QMSG_FLAG_EXTENT
    jnz .o_extent
    mov rcx, [rbp - 104]
    cmp rcx, QMSG_INLINE_MAX
    ja .o_state                     ; a slot cannot hold that, so this is not one
    mov r9, [rbp - 24]
    xor edx, edx
.o_byte:
    cmp rdx, rcx
    jae .o_copied
    mov al, [r8 + QMSG_PAYLOAD + rdx]
    mov [r9 + rdx], al
    inc rdx
    jmp .o_byte

.o_extent:
    ; The chain, validated before a byte of it is copied - which is what
    ; db_var_read_chain is for, and why the queue does not read pages itself.
    mov r8, [rbp - 136]
    mov rax, [r8 + QMSG_EXTENT]
    mov [rbp - 144 + VAR_CELL_ROOT], rax
    mov rax, [rbp - 104]
    mov [rbp - 144 + VAR_CELL_LENGTH], rax
    mov r10, [rbp - 8]
    mov rax, [rbp - 152]
    PASS_ARG6 rax                   ; capacity: what the caller said it has
    mov rax, [rbp - 24]
    PASS_ARG5 rax
    mov ARG4, [rbp - 16]
    lea ARG3, [rbp - 144]
    mov ARG2, [r10 + DB_SB_PTR]
    mov ARG1, r10
    call db_var_read_chain
    test eax, eax
    jnz .o_done

.o_copied:
    mov r11, [rbp - 32]
    mov rax, [rbp - 104]
    mov [r11], rax

    ; How much of the directory the move leaves behind. A queue that has just
    ; run dry names no segment at all; otherwise the head keeps whatever it is
    ; still standing in.
    mov rax, [rbp - 40]
    inc rax
    mov [rbp - 40], rax             ; the new head
    xor edx, edx
    mov rcx, QUEUE_SEG_SLOTS
    div rcx
    mov [rbp - 128], rax            ; the segment the new head is in
    mov rdx, [rbp - 40]
    cmp rdx, [rbp - 48]
    jne .o_keeping
    mov rax, [rbp - 56]
    mov [rbp - 112], rax            ; drained: every entry goes
    mov qword [rbp - 120], 0
    jmp .o_counted
.o_keeping:
    mov rax, [rbp - 128]
    sub rax, [rbp - 64]
    mov [rbp - 112], rax            ; entries the head has left behind
    mov rdx, [rbp - 56]
    sub rdx, rax
    mov [rbp - 120], rdx
.o_counted:

    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    lea ARG3, [rbp - 72]
    call db_catalog_edit
    test eax, eax
    jnz .o_done

    ; The ones behind the head have nothing left to give.
    mov qword [rbp - 88], 0
.o_retire:
    mov rax, [rbp - 88]
    cmp rax, [rbp - 112]
    jae .o_retired
    mov r11, [rbp - 72]
    mov ARG2, [r11 + Q_ENTRIES + rax * 8]
    mov ARG1, [rbp - 8]
    call db_bitmap_retire
    inc qword [rbp - 88]
    jmp .o_retire
.o_retired:
    cmp qword [rbp - 112], 0
    je .o_publish                   ; nothing moved, so nothing to shift

    ; What is left moves down to entry zero.
    mov r11, [rbp - 72]
    mov rcx, [rbp - 112]
    xor edx, edx
.o_move:
    cmp rdx, [rbp - 120]
    jae .o_moved
    mov r9, rdx
    add r9, rcx
    mov r8, [r11 + Q_ENTRIES + r9 * 8]
    mov [r11 + Q_ENTRIES + rdx * 8], r8
    inc rdx
    jmp .o_move
.o_moved:
    ; And what used to be beyond them is zero, as every tail here is.
    mov rax, [rbp - 120]
.o_clear:
    cmp rax, [rbp - 56]
    jae .o_publish
    mov qword [r11 + Q_ENTRIES + rax * 8], 0
    inc rax
    jmp .o_clear

    ; The chain the message named is nobody's now. Retiring it here rather
    ; than leaving it to the segment's retirement is the difference between a
    ; queue that reclaims what it read and one that grows forever: a segment
    ; is retired once, and it carried sixty-two messages.
    mov r8, [rbp - 136]
    mov ecx, [r8 + QMSG_FLAGS]
    test ecx, QMSG_FLAG_EXTENT
    jz .o_publish
    mov ARG1, [rbp - 8]
    mov ARG2, [r8 + QMSG_EXTENT]
    call queue_retire_chain

.o_publish:
    mov r10, [rbp - 72]
    mov rax, [rbp - 40]
    mov [r10 + Q_HEAD], rax
    mov [r10 + Q_CLAIM], rax
    mov rax, [rbp - 48]
    mov [r10 + Q_TAIL], rax
    mov rax, [rbp - 120]
    mov [r10 + Q_SEGMENTS], eax
    mov rax, [rbp - 128]
    mov [r10 + Q_FIRST_SEG], rax
    mov ARG1, r10
    call db_catalog_seal
    xor eax, eax
    jmp .o_done
.o_empty:
    mov eax, CybouDB_E_NOTFOUND
    jmp .o_done
.o_state:
    mov eax, CybouDB_E_STATE
.o_done:
    FRAME_END
    ret

; queue_retire_chain(ARG1 = ctx, ARG2 = first extent page): hand the pages
; back. The walk is bounded by the chain it is given and stops at a page that
; is not one, because a chain that has already been damaged is not a reason to
; follow it further.
;
;  Local slots: [rbp-8]=ctx, [rbp-16]=page, [rbp-24]=address
queue_retire_chain:
    FRAME_BEGIN 32, 0
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
.r_page:
    cmp qword [rbp - 16], 0
    je .r_done
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    call db_queue_seg_addr
    mov [rbp - 24], rax
    cmp dword [rax + VAR_MAGIC], VAR_MAGIC_VALUE
    jne .r_done
    mov r9, [rax + VAR_NEXT]
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    mov [rbp - 16], r9
    call db_bitmap_retire
    jmp .r_page
.r_done:
    xor eax, eax
    FRAME_END
    ret

; db_queue_peek(ARG1 = ctx, ARG2 = queue id, ARG3 = out length) -> RAX: 0 when
; a message is waiting, CybouDB_E_NOTFOUND when the queue is empty.
;
; How many bytes the next take needs, without taking it. A caller that has to
; provide the buffer has to be told how big, and asking is cheaper than
; guessing a maximum that a message longer than it would then be unable to
; leave the queue through.
;
;  Local slots: [rbp-8]=ctx, [rbp-16]=id, [rbp-24]=out
db_queue_peek:
    FRAME_BEGIN 48, 0
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
    mov [rbp - 24], ARG3
    mov r10, ARG1
    test qword [r10 + DB_FEATURES], CybouDB_FEATURE_QUEUE
    jz .k_state
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    call db_catalog_page
    test rax, rax
    jz .k_state
    cmp dword [rax + CAT_TYPE], CAT_QUEUE
    jne .k_state
    mov rdx, [rax + Q_HEAD]
    cmp rdx, [rax + Q_TAIL]
    je .k_empty
    mov rcx, [rax + Q_FIRST_SEG]
    mov r11, rax
    mov rax, rdx
    xor edx, edx
    mov r9, QUEUE_SEG_SLOTS
    div r9
    sub rax, rcx
    mov r9, [r11 + Q_ENTRIES + rax * 8]
    mov [rbp - 32], rdx             ; the slot inside the segment
    mov ARG1, [rbp - 8]
    mov ARG2, r9
    call db_queue_seg_addr
    mov rdx, [rbp - 32]
    shl rdx, 6
    lea r8, [rax + QSEG_SLOTS + rdx]
    mov ecx, [r8 + QMSG_LENGTH]
    mov r11, [rbp - 24]
    mov [r11], rcx
    xor eax, eax
    FRAME_END
    ret
.k_empty:
    mov eax, CybouDB_E_NOTFOUND
    FRAME_END
    ret
.k_state:
    mov eax, CybouDB_E_STATE
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  db_queue_retire_all(ctx, queue id) -> RAX: result code
;
;  Every page a queue is holding, handed back: the extent chain of each message
;  still in it, and then the segments themselves. What a DROP QUEUE does before
;  the catalog entry goes, for the reason DROP INDEX retires its tree - an
;  entry removed from the directory takes the last reference to those pages
;  with it, and a payload page nothing references is a page nothing will ever
;  hand out again.
;
;  Messages already taken are not walked. Their chains went at the take, and
;  their positions are below the head.
;
;  Local slots: [rbp-8]=ctx, [rbp-16]=id, [rbp-24]=queue page, [rbp-32]=head,
;               [rbp-40]=tail, [rbp-48]=segments, [rbp-56]=first segment,
;               [rbp-64]=position, [rbp-72]=entry index
; -----------------------------------------------------------------------------
db_queue_retire_all:
    FRAME_BEGIN 96, 0
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
    mov r10, ARG1
    test qword [r10 + DB_FEATURES], CybouDB_FEATURE_QUEUE
    jz .a_ok
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    call db_catalog_page
    test rax, rax
    jz .a_ok
    cmp dword [rax + CAT_TYPE], CAT_QUEUE
    jne .a_ok
    mov [rbp - 24], rax
    mov rdx, [rax + Q_HEAD]
    mov [rbp - 32], rdx
    mov rdx, [rax + Q_TAIL]
    mov [rbp - 40], rdx
    mov ecx, [rax + Q_SEGMENTS]
    mov [rbp - 48], rcx
    mov rdx, [rax + Q_FIRST_SEG]
    mov [rbp - 56], rdx

    ; The chains first, while the entries that name their segments are still
    ; there to find them through.
    mov rax, [rbp - 32]
    mov [rbp - 64], rax
.a_message:
    mov rax, [rbp - 64]
    cmp rax, [rbp - 40]
    jae .a_segments
    xor edx, edx
    mov rcx, QUEUE_SEG_SLOTS
    div rcx                         ; rax = segment, rdx = slot
    mov [rbp - 80], rdx             ; before an argument register takes it
    sub rax, [rbp - 56]
    mov r11, [rbp - 24]
    mov r9, [r11 + Q_ENTRIES + rax * 8]
    mov ARG1, [rbp - 8]
    mov ARG2, r9
    call db_queue_seg_addr
    mov rdx, [rbp - 80]
    shl rdx, 6                      ; QUEUE_SLOT_SIZE
    lea r8, [rax + QSEG_SLOTS + rdx]
    mov ecx, [r8 + QMSG_FLAGS]
    test ecx, QMSG_FLAG_EXTENT
    jz .a_next_message
    mov r9, [r8 + QMSG_EXTENT]
    mov ARG1, [rbp - 8]
    mov ARG2, r9
    call queue_retire_chain
.a_next_message:
    inc qword [rbp - 64]
    jmp .a_message

.a_segments:
    mov qword [rbp - 72], 0
.a_segment:
    mov rax, [rbp - 72]
    cmp rax, [rbp - 48]
    jae .a_ok
    mov r11, [rbp - 24]
    mov r9, [r11 + Q_ENTRIES + rax * 8]
    mov ARG1, [rbp - 8]
    mov ARG2, r9
    call db_bitmap_retire
    inc qword [rbp - 72]
    jmp .a_segment
.a_ok:
    xor eax, eax
    FRAME_END
    ret
