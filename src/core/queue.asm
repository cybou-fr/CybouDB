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
extern catalog_entry_in
global db_queue_push, db_queue_pop, db_queue_peek, db_queue_depth
global db_queue_retire_all
global db_queue_scan_claimable
global db_queue_claim, db_queue_ack, db_queue_nack, db_queue_renew
global lease_find_slot
global db_stream_append
global queue_slot_at, queue_slot_copy, queue_retire_chain
global db_stream_retire_all

section .data
; Segment pages this process looked at while validating. A queue that is
; drained as fast as it is filled holds one segment however many messages it
; has carried, and a test can say so rather than assuming it.
global queue_segments_walked
queue_segments_walked: dq 0

; What a search for a claimable message looked at. Counters rather than a
; timing, for the reason preview.2 established: a counter says whether the cost
; follows the work or the backlog, and a timing says what the machine was doing
; that afternoon. See docs/QUEUE.md, "The open problem: finding a claimable
; message".
global lease_slots_inspected, lease_segments_inspected
lease_slots_inspected: dq 0
lease_segments_inspected: dq 0

; Reserved and never incremented. If the per-segment summary needs a level
; above it, that level will want counting too, and naming it now is what keeps
; a later measurement comparable with the ones taken before it.
global lease_summary_nodes_inspected
lease_summary_nodes_inspected: dq 0

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
    ; An entry the published generation already named, at the same absolute
    ; position and with the same page, is inherited: copy-on-write means the
    ; engine cannot have rewritten that page since the commit that proved it.
    ; Not visited, so not counted - queue_segments_walked measures the work
    ; actually done, which is the whole point of the counter.
    mov rcx, [r11 + QSV_BASE_ENTRIES]
    test rcx, rcx
    jz .visit
    add rax, [r11 + QSV_FIRST_SEG]
    sub rax, [r11 + QSV_BASE_FIRST_SEG]
    jb .visit                       ; a position it did not hold yet
    cmp rax, [r11 + QSV_BASE_SEGMENTS]
    jae .visit                      ; a position past what it held
    mov rdx, [rcx + rax * 8]        ; the page it named there
    mov rcx, [r11 + QSV_ENTRIES]
    mov rax, [rbp - 16]
    cmp rdx, [rcx + rax * 8]
    jne .visit
    inc qword [rbp - 16]
    jmp .entry
.visit:
    mov rax, [rbp - 16]
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
    ; The segment's claimable summary. Without leases nothing writes it and it
    ; must be zero; with them it is a timestamp, and what makes it trustworthy
    ; is not a value but an inequality - lease_summaries_valid requires it to
    ; be no later than what the slots say, because a summary that is too low
    ; costs a wasted look and one that is too high hides a claimable message.
    ;
    ; Conditional rather than deleted, which is what the commit that named the
    ; field said would happen here.
    mov r9, [r11 + QSV_CTX]         ; r11 is the validator's own struct
    test qword [r9 + DB_FEATURES], CybouDB_FEATURE_QUEUE_LEASES
    jnz .ready_at_checked
    cmp qword [r10 + QSEG_READY_AT], 0
    jne .bad
.ready_at_checked:
    cmp qword [r10 + QSEG_RESERVED], 0
    jne .bad
    cmp qword [r10 + QSEG_RESERVED + 8], 0
    jne .bad
    mov rax, [rbp - 16]
    add rax, [r11 + QSV_FIRST_SEG]
    imul rax, QUEUE_SEG_SLOTS
    cmp [r10 + QSEG_FIRST], rax
    jne .bad
    ; Every segment's checksum, every commit, including ones an older
    ; generation sealed.
    ;
    ; Gating this on db_bitmap_deep - fresh generation or DB_VERIFY, the rule
    ; the catalog, index, PAX, varlen and zone map code all follow - was tried
    ; and reverted. It bought nothing: 746, 848 and 1092 us a message at depths
    ; of 500, 1,000 and 2,000, against 764, 830 and 1092 before. The counters
    ; said why - segments visited per commit were 4.5, 8.6 and 16.6 while the
    ; catalog stayed at 2.0, so the cost is the visit and not the sum. And it
    ; had a price: `queue_page_test` damages a byte of a slot in a segment an
    ; earlier generation wrote and requires the commit to refuse, which a
    ; skipped checksum does not. Paying a real weakening of what a commit
    ; catches for no measured speed is not a trade.
    ;
    ; The depth is a directory the commit re-proves entry by entry. Making that
    ; incremental is the fix, and it is in ROADMAP.md for after the preview.
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
    ; Reserved with leases and without: it is where a failure count would go,
    ; and there is no rule to write against it yet.
    cmp dword [r10 + QMSG_RESERVED32], 0
    jne .bad

    mov r11, [rbp - 8]
    mov r11, [r11 + QSV_CTX]
    test qword [r11 + DB_FEATURES], CybouDB_FEATURE_QUEUE_LEASES
    jnz .lease_state

    ; Without the capability nothing has a lease, and a record that claims one
    ; was not written by this build.
    cmp dword [r10 + QMSG_STATE], QMSG_STATE_HELD
    jne .bad
    cmp qword [r10 + QMSG_LEASE_UNTIL], 0
    jne .bad
    cmp qword [r10 + QMSG_LEASE_TOKEN], 0
    jne .bad
    jmp .state_ok

.lease_state:
    ; docs/QUEUE.md, "What a valid file looks like, with leases and without".
    ; The token is the slot's fencing history rather than a property of being
    ; claimed, so HELD accepts any token: NACK raises it and leaves the message
    ; HELD, and requiring zero there would forbid the state NACK is defined to
    ; produce.
    mov ecx, [r10 + QMSG_STATE]
    cmp ecx, QMSG_STATE_HELD
    je .state_held
    cmp ecx, QMSG_STATE_CLAIMED
    je .state_claimed
    cmp ecx, QMSG_STATE_ACKED
    jne .bad                        ; a fourth state nothing defines

    ; ACKED: finished, and it keeps the token that finished it. A zero there
    ; would mean never claimed, which is the one value a forged ticket could
    ; guess, so the finished state is the last one that should accept it.
    cmp qword [r10 + QMSG_LEASE_UNTIL], 0
    jne .bad
    cmp qword [r10 + QMSG_LEASE_TOKEN], 0
    je .bad
    jmp .state_ok

.state_held:
    cmp qword [r10 + QMSG_LEASE_UNTIL], 0
    jne .bad                        ; nobody holds it, so nothing expires
    jmp .state_ok

.state_claimed:
    cmp qword [r10 + QMSG_LEASE_UNTIL], 0
    je .bad                         ; a claim without a deadline never lapses
    cmp qword [r10 + QMSG_LEASE_TOKEN], 0
    je .bad                         ; and a claim raised the token

.state_ok:
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
    FRAME_BEGIN 160, 0
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

    test qword [r10 + DB_FEATURES], CybouDB_FEATURE_QUEUE_LEASES
    jnz .q_leases

    ; Without leases the clock has no high-water, and a DEQUEUE hands out and
    ; acknowledges in one step, so the claim cursor is the head. A file that
    ; disagrees was written by something this build does not understand - which
    ; is what the capability bit exists to say before this check is reached.
    cmp qword [r11 + Q_TIME_FLOOR], 0
    jne .q_bad
    mov rax, [r11 + Q_HEAD]
    cmp rax, [r11 + Q_CLAIM]
    jne .q_bad
    jmp .q_cursor_ok

.q_leases:
    ; With them, acknowledgement can arrive out of order, so the oldest
    ; unacknowledged position and the next one to hand out stop being the same
    ; number - but neither may pass the other or the tail.
    mov rax, [r11 + Q_HEAD]
    cmp rax, [r11 + Q_CLAIM]
    ja .q_bad
    mov rax, [r11 + Q_CLAIM]
    cmp rax, [r11 + Q_TAIL]
    ja .q_bad

    ; Q_TIME_FLOOR is deliberately not required to be a timestamp. Having
    ; leases and having used them are different facts: the bit is set when the
    ; file is created, and a queue in that file may never see a CLAIM. Zero is
    ; what "no time has been used yet" looks like, and demanding more would be
    ; demanding evidence of use from a file that claimed only the ability.

.q_cursor_ok:

    mov [rbp - 160 + QSV_CTX], ARG1
    mov rax, [rbp - 16]
    mov [rbp - 160 + QSV_SB], rax
    mov r11, [rbp - 24]
    mov rax, [r11 + CAT_OWNER]
    mov [rbp - 160 + QSV_OWNER], rax
    lea rax, [r11 + Q_ENTRIES]
    mov [rbp - 160 + QSV_ENTRIES], rax
    lea rax, [r11 + Q_CRC]
    mov [rbp - 160 + QSV_TAIL_END], rax
    mov ecx, [r11 + Q_SEGMENTS]
    mov [rbp - 160 + QSV_SEGMENTS], rcx
    mov rax, [r11 + Q_FIRST_SEG]
    mov [rbp - 160 + QSV_FIRST_SEG], rax
    mov rax, [r11 + Q_HEAD]
    mov [rbp - 160 + QSV_LOW], rax
    mov rax, [r11 + Q_TAIL]
    mov [rbp - 160 + QSV_HIGH], rax
    mov qword [rbp - 160 + QSV_MAX_SEG], Q_MAX_SEGMENTS
    ; What the published generation held for this object. An entry naming the
    ; same page at the same position has not been rewritten - copy-on-write
    ; forbids it - so the commit that published it proved it, and this one
    ; inherits that instead of repeating it. docs/COMMIT_VALIDATION.md.
    ;
    ; The published page cannot have been reused underneath us: span_reuse only
    ; takes a page that is RETIRED in the published map as well as the staged
    ; one, and a page this transaction retired is still PAYLOAD in the
    ; published map.
    xor eax, eax
    mov [rbp - 160 + QSV_BASE_ENTRIES], rax
    mov [rbp - 160 + QSV_BASE_SEGMENTS], rax
    mov [rbp - 160 + QSV_BASE_FIRST_SEG], rax
    mov r10, [rbp - 8]
    cmp qword [r10 + DB_VERIFY], 0
    jne .no_base                    ; `cyboudb check` inherits nothing
    cmp qword [r10 + DB_CS_OVERFLOW], 0
    jne .no_base                    ; an incomplete change-set proves nothing
    mov r11, [r10 + DB_SB_PTR]
    test r11, r11
    jz .no_base                     ; nothing published yet to inherit from
    mov ARG2, [r11 + SB_ROOT_PAGE]
    mov ARG3, [rbp - 160 + QSV_OWNER]
    mov ARG4, CAT_QUEUE
    mov ARG1, r10
    call catalog_entry_in
    test rax, rax
    jz .no_base
    mov ecx, [rax + Q_SEGMENTS]
    mov [rbp - 160 + QSV_BASE_SEGMENTS], rcx
    mov r11, [rax + Q_FIRST_SEG]
    mov [rbp - 160 + QSV_BASE_FIRST_SEG], r11
    lea r11, [rax + Q_ENTRIES]
    mov [rbp - 160 + QSV_BASE_ENTRIES], r11
.no_base:
    lea ARG1, [rbp - 160]
    call db_queue_segments_valid
    test eax, eax
    jz .q_bad

    ; And the per-segment summaries, which the search trusts to skip whole
    ; segments unread. A summary that is too high hides a claimable message.
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 24]
    call lease_summaries_valid
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

; -----------------------------------------------------------------------------
;  queue_slot_at(ARG1 = ctx, ARG2 = object page, ARG3 = where that object's
;                directory starts, ARG4 = position) -> RAX: the slot, or 0
;
;  Where a position lives is arithmetic and a directory lookup, and it is the
;  same arithmetic for a queue and for a stream: the fields it reads sit at
;  one offset in both, and the one that does not is the argument.
;
;  Zero when the directory does not reach the position, which is a page that
;  disagrees with itself rather than an empty object - callers check emptiness
;  before they ask.
; -----------------------------------------------------------------------------
queue_slot_at:
    FRAME_BEGIN 48, 0
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
    mov [rbp - 24], ARG3
    mov rax, ARG4
    xor edx, edx
    mov rcx, QUEUE_SEG_SLOTS
    div rcx
    mov [rbp - 32], rdx             ; the slot inside the segment
    mov r10, [rbp - 16]
    sub rax, [r10 + Q_FIRST_SEG]    ; S_FIRST_SEG is the same offset
    jb .s_none
    mov ecx, [r10 + Q_SEGMENTS]     ; as is S_SEGMENTS
    cmp rax, rcx
    jae .s_none
    add r10, [rbp - 24]
    mov r11, [r10 + rax * 8]
    mov ARG1, [rbp - 8]
    mov ARG2, r11
    call db_queue_seg_addr
    mov rdx, [rbp - 32]
    shl rdx, 6                      ; QUEUE_SLOT_SIZE
    lea rax, [rax + QSEG_SLOTS + rdx]
    FRAME_END
    ret
.s_none:
    xor eax, eax
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  queue_slot_copy(ARG1 = ctx, ARG2 = owner id, ARG3 = slot, ARG4 = buffer,
;                  ARG5 = where to write the length, ARG6 = buffer capacity)
;      -> RAX: result code
;
;  The payload out of a slot, from the slot itself or from the extent chain it
;  names. The owner id is what the chain is checked against, so a message can
;  only ever read pages its own object owns.
;
;  Local slots: [rbp-8]=ctx, [rbp-16]=owner, [rbp-24]=slot, [rbp-32]=buffer,
;               [rbp-40]=length out, [rbp-48]=capacity, [rbp-56]=length,
;               [rbp-80]=extent descriptor
; -----------------------------------------------------------------------------
queue_slot_copy:
    FRAME_BEGIN 96, 2
    ; The stack-passed pair first, before anything can touch what carries them.
    mov r10, IN_ARG5
    mov r11, IN_ARG6
    mov [rbp - 40], r10
    mov [rbp - 48], r11
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
    mov [rbp - 24], ARG3
    mov [rbp - 32], ARG4

    mov r8, [rbp - 24]
    mov ecx, [r8 + QMSG_LENGTH]
    mov [rbp - 56], rcx
    mov ecx, [r8 + QMSG_FLAGS]
    test ecx, QMSG_FLAG_EXTENT
    jnz .c_extent
    mov rcx, [rbp - 56]
    cmp rcx, QMSG_INLINE_MAX
    ja .c_state                     ; a slot cannot hold that, so this is not one
    mov r9, [rbp - 32]
    xor edx, edx
.c_byte:
    cmp rdx, rcx
    jae .c_copied
    mov al, [r8 + QMSG_PAYLOAD + rdx]
    mov [r9 + rdx], al
    inc rdx
    jmp .c_byte

.c_extent:
    ; The chain, validated before a byte of it is copied - which is what
    ; db_var_read_chain is for, and why this does not read pages itself.
    mov rax, [r8 + QMSG_EXTENT]
    mov [rbp - 80 + VAR_CELL_ROOT], rax
    mov rax, [rbp - 56]
    mov [rbp - 80 + VAR_CELL_LENGTH], rax
    mov r10, [rbp - 8]
    mov rax, [rbp - 48]
    PASS_ARG6 rax
    mov rax, [rbp - 32]
    PASS_ARG5 rax
    mov ARG4, [rbp - 16]
    lea ARG3, [rbp - 80]
    mov ARG2, [r10 + DB_SB_PTR]
    mov ARG1, r10
    call db_var_read_chain
    test eax, eax
    jnz .c_done

.c_copied:
    mov r11, [rbp - 40]
    mov rax, [rbp - 56]
    mov [r11], rax
    xor eax, eax
    jmp .c_done
.c_state:
    mov eax, CybouDB_E_STATE
.c_done:
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
    mov r10d, CAT_QUEUE
    jmp queue_push_common
; A record at the end of a stream is the same write: the position decides the
; segment and the slot, the payload goes in or into a chain, and nothing that
; is already there is touched. What differs is which page type it will accept,
; where that type's directory starts, how many entries it has room for, and
; that a stream has no claim cursor to carry forward - four numbers, against a
; second copy of every boundary case above.
db_stream_append:
    mov r10d, CAT_STREAM
queue_push_common:
    FRAME_BEGIN 192, 1
    ; Only the type is carried in, and in R10, because every other register
    ; that could carry it is one of the four arguments under one of the two
    ; conventions. The two numbers that follow from it are derived here, after
    ; the arguments are somewhere safe.
    mov [rbp - 144], r10            ; the page type this one writes
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
    mov [rbp - 24], ARG3
    mov [rbp - 32], ARG4
    mov qword [rbp - 152], Q_ENTRIES
    mov qword [rbp - 160], Q_MAX_SEGMENTS
    cmp qword [rbp - 144], CAT_STREAM
    jne .p_shaped
    mov qword [rbp - 152], S_ENTRIES
    mov qword [rbp - 160], S_MAX_SEGMENTS
.p_shaped:
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
    mov ecx, [rax + CAT_TYPE]
    cmp rcx, [rbp - 144]
    jne .p_state
    mov rdx, [rax + Q_HEAD]         ; S_FIRST is the same offset
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
    cmp rax, [rbp - 160]
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
    add r11, [rbp - 152]
    mov rax, [rbp - 88]
    mov rdx, [rbp - 96]
    mov [r11 + rax * 8], rdx
    inc qword [rbp - 56]
    jmp .p_slot

.p_have_segment:
    mov r11, [rbp - 72]
    add r11, [rbp - 152]
    mov rax, [rbp - 88]
    mov ARG2, [r11 + rax * 8]
    mov ARG1, [rbp - 8]
    lea ARG3, [rbp - 96]
    call queue_copy_seg
    test eax, eax
    jnz .p_done
    mov r11, [rbp - 72]
    add r11, [rbp - 152]
    mov rax, [rbp - 88]
    mov rdx, [rbp - 96]
    mov [r11 + rax * 8], rdx
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

    ; And the object says what it now holds. stamp cleared the reserved span,
    ; which is where head, tail and the claim cursor live.
    mov r10, [rbp - 72]
    mov rax, [rbp - 40]
    mov [r10 + Q_HEAD], rax
    ; The claim cursor follows the head, and only a queue has one: at that
    ; offset a stream keeps a reserved field that must stay zero, which stamp
    ; has just made it.
    cmp qword [rbp - 144], CAT_QUEUE
    jne .p_positioned
    mov [r10 + Q_CLAIM], rax
.p_positioned:
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
    mov [rbp - 136], r8

    mov r10, [rbp - 152]
    PASS_ARG6 r10                   ; capacity: what the caller said it has
    mov r10, [rbp - 32]
    PASS_ARG5 r10
    mov ARG4, [rbp - 24]
    mov ARG3, [rbp - 136]
    mov ARG2, [rbp - 16]
    mov ARG1, [rbp - 8]
    call queue_slot_copy
    test eax, eax
    jnz .o_done
    mov r8, [rbp - 136]
    mov ecx, [r8 + QMSG_LENGTH]
    mov [rbp - 104], rcx

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
    je .o_chain                     ; nothing moved, so nothing to shift

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
    jae .o_chain
    mov qword [r11 + Q_ENTRIES + rax * 8], 0
    inc rax
    jmp .o_clear

.o_chain:
    ; The chain the message named is nobody's now. Retiring it here rather
    ; than leaving it to the segment's retirement is the difference between a
    ; queue that reclaims what it read and one that grows forever: a segment
    ; is retired once, and it carried sixty-two messages.
    ;
    ; This block had no label and sat after a loop that could only leave by
    ; jumping past it, so for as long as it has existed it has never run. A
    ; hundred round trips through a three-hundred-page file did not notice;
    ; four hundred do.
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
; -----------------------------------------------------------------------------
;  db_queue_scan_claimable(ctx, queue id, now in ms, out position)
;      -> RAX: 1 when a claimable message was found, 0 when none was
;
;  The naive answer, on purpose. Walk forward from the head and take the first
;  slot that is HELD or whose lease has lapsed, skipping what is ACKED and what
;  is still held by somebody. It writes nothing - no state, no cursor, no
;  clock - because its job is to make the cost of this strategy a number before
;  a better strategy is chosen, and a measurement that also mutated would be
;  measuring something else by its second run.
;
;  What it counts is what a real claim would have to read: a slot per position
;  considered, and a segment page per segment the walk enters. The segment
;  counter only moves when the walk crosses into a new one, which is what makes
;  it mean "pages touched" rather than "positions divided by 62".
;
;  docs/QUEUE.md says why this is the hard part of leases and why a cursor
;  alone does not fix it.
; -----------------------------------------------------------------------------
db_queue_scan_claimable:
    FRAME_BEGIN 80, 0
    mov [rbp - 8], ARG1             ; ctx
    mov [rbp - 16], ARG2            ; queue id
    mov [rbp - 24], ARG3            ; now, in milliseconds
    mov [rbp - 32], ARG4            ; where the position goes, or zero
    mov r10, ARG1
    test qword [r10 + DB_FEATURES], CybouDB_FEATURE_QUEUE_LEASES
    jz .sc_none                     ; without the capability nothing is claimed
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    call db_catalog_page
    test rax, rax
    jz .sc_none
    cmp dword [rax + CAT_TYPE], CAT_QUEUE
    jne .sc_none
    mov [rbp - 40], rax
    mov rdx, [rax + Q_HEAD]
    mov [rbp - 48], rdx             ; the position being looked at
    mov rdx, [rax + Q_TAIL]
    mov [rbp - 56], rdx
    mov qword [rbp - 64], -1        ; the segment whose page is in hand
    mov qword [rbp - 72], 0         ; and its address

.sc_next:
    mov rax, [rbp - 48]
    cmp rax, [rbp - 56]
    jae .sc_none                    ; the walk reached the tail
    xor edx, edx
    mov r9, QUEUE_SEG_SLOTS
    div r9                          ; rax = segment, rdx = slot within it
    mov [rbp - 80], rdx
    cmp rax, [rbp - 64]
    je .sc_have_segment

    mov [rbp - 64], rax
    mov r11, [rbp - 40]
    sub rax, [r11 + Q_FIRST_SEG]
    mov r9, [r11 + Q_ENTRIES + rax * 8]
    mov ARG1, [rbp - 8]
    mov ARG2, r9
    call db_queue_seg_addr
    mov [rbp - 72], rax
    inc qword [rel lease_segments_inspected]

    ; One u64 answers for sixty-two slots. A deadline still ahead means
    ; nothing in this segment is free and nothing has lapsed, so the walk
    ; steps over the whole of it without reading a slot.
    mov r8, rax
    mov rax, [r8 + QSEG_READY_AT]
    cmp rax, [rbp - 24]
    jbe .sc_have_segment
    mov rax, [rbp - 48]
    xor edx, edx
    mov rcx, QUEUE_SEG_SLOTS
    div rcx
    inc rax
    imul rax, QUEUE_SEG_SLOTS
    mov [rbp - 48], rax
    jmp .sc_next

.sc_have_segment:
    inc qword [rel lease_slots_inspected]
    mov rdx, [rbp - 80]
    shl rdx, 6                      ; QUEUE_SLOT_SIZE
    mov r8, [rbp - 72]
    lea r8, [r8 + QSEG_SLOTS + rdx]
    mov ecx, [r8 + QMSG_STATE]
    cmp ecx, QMSG_STATE_HELD
    je .sc_found
    cmp ecx, QMSG_STATE_CLAIMED
    jne .sc_step                    ; ACKED, and the validator allows no other
    ; A lapsed lease is claimable; a deadline still ahead is somebody's.
    mov rax, [r8 + QMSG_LEASE_UNTIL]
    cmp rax, [rbp - 24]
    ja .sc_step

.sc_found:
    mov r11, [rbp - 32]
    test r11, r11
    jz .sc_found_done
    mov rax, [rbp - 48]
    mov [r11], rax
.sc_found_done:
    mov eax, 1
    FRAME_END
    ret

.sc_step:
    inc qword [rbp - 48]
    jmp .sc_next

.sc_none:
    xor eax, eax
    FRAME_END
    ret


; -----------------------------------------------------------------------------
;  The lease operations.
;
;  Each of the four is a short transaction: the queue page and the one segment
;  page the message lives in, copy-on-written like anything else, and nothing
;  else touched. What the deadline is measured on and why the token rather than
;  the deadline decides an acknowledgement is in docs/QUEUE.md; this is where
;  that becomes code.
;
;  `now` is an argument rather than a clock read here. The platform primitive
;  belongs at the edge where the caller is, and a core that takes the time it
;  is given is a core whose tests do not depend on what o'clock it is.
;
;  None of these moves the head. A run of acknowledged messages at the front is
;  a valid queue - the state table says so - and advancing over it is
;  retirement machinery rather than lease machinery. It is the next commit, and
;  until it lands a queue reclaims nothing it acknowledges.
; -----------------------------------------------------------------------------

; -----------------------------------------------------------------------------
;  lease_find_slot(ctx, id, position) -> RAX: the slot, read-only, or 0
;
;  Where a refusal is decided. Nothing is copied and nothing is stamped, which
;  is what makes a refused operation leave the file exactly as it found it -
;  the first version of these operations made the slot writable first and
;  discovered the refusal afterwards, which left a queue page stamped with a
;  new generation and never sealed, and the next commit refused the whole
;  transaction over an operation that had already said no.
; -----------------------------------------------------------------------------
lease_find_slot:
    FRAME_BEGIN 48, 0
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
    mov [rbp - 24], ARG3
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    call db_catalog_page
    test rax, rax
    jz .lf_no
    cmp dword [rax + CAT_TYPE], CAT_QUEUE
    jne .lf_no
    mov r11, rax
    mov rax, [rbp - 24]
    cmp rax, [r11 + Q_HEAD]
    jb .lf_no
    cmp rax, [r11 + Q_TAIL]
    jae .lf_no
    xor edx, edx
    mov rcx, QUEUE_SEG_SLOTS
    div rcx
    mov [rbp - 32], rdx
    sub rax, [r11 + Q_FIRST_SEG]
    mov ecx, [r11 + Q_SEGMENTS]
    cmp rax, rcx
    jae .lf_no
    mov ARG2, [r11 + Q_ENTRIES + rax * 8]
    mov ARG1, [rbp - 8]
    call db_queue_seg_addr
    test rax, rax
    jz .lf_no
    mov rdx, [rbp - 32]
    shl rdx, 6
    lea rax, [rax + QSEG_SLOTS + rdx]
    FRAME_END
    ret
.lf_no:
    xor eax, eax
    FRAME_END
    ret

%define LE_QPAGE 0
%define LE_SEG   8
%define LE_SLOT  16

; -----------------------------------------------------------------------------
;  lease_edit_slot(ctx, id, position, out[3]) -> EAX: 0, or an error
;
;  The writable queue page, the writable segment page the position lives in,
;  and the slot inside it. The directory is re-pointed at the copy here, so a
;  caller only has to seal what it wrote.
; -----------------------------------------------------------------------------
lease_edit_slot:
    FRAME_BEGIN 96, 0
    mov [rbp - 8], ARG1             ; ctx
    mov [rbp - 16], ARG2            ; queue id
    mov [rbp - 24], ARG3            ; position
    mov [rbp - 32], ARG4            ; out

    ; Head, tail and the claim cursor are read before the edit and written
    ; back after it, because db_catalog_edit stamps the page it hands over and
    ; stamping clears the reserved span - which is exactly where a queue keeps
    ; those three. db_queue_push restores them the same way, for the same
    ; reason; a caller that forgets gets a queue whose tail is zero and whose
    ; every position is therefore out of range.
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    call db_catalog_page
    test rax, rax
    jz .le_state
    cmp dword [rax + CAT_TYPE], CAT_QUEUE
    jne .le_state
    mov rdx, [rax + Q_HEAD]
    mov [rbp - 72], rdx
    mov rdx, [rax + Q_TAIL]
    mov [rbp - 80], rdx
    mov rdx, [rax + Q_CLAIM]
    mov [rbp - 88], rdx

    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    lea ARG3, [rbp - 40]
    call db_catalog_edit
    test eax, eax
    jnz .le_done
    mov r11, [rbp - 40]
    mov rdx, [rbp - 72]
    mov [r11 + Q_HEAD], rdx
    mov rdx, [rbp - 80]
    mov [r11 + Q_TAIL], rdx
    mov rdx, [rbp - 88]
    mov [r11 + Q_CLAIM], rdx
    mov r10, [rbp - 32]
    mov [r10 + LE_QPAGE], r11

    mov rax, [rbp - 24]
    cmp rax, [r11 + Q_HEAD]
    jb .le_range
    cmp rax, [r11 + Q_TAIL]
    jae .le_range

    xor edx, edx
    mov rcx, QUEUE_SEG_SLOTS
    div rcx                         ; rax = segment, rdx = slot within it
    mov [rbp - 48], rdx
    sub rax, [r11 + Q_FIRST_SEG]
    mov [rbp - 56], rax
    mov ecx, [r11 + Q_SEGMENTS]
    cmp rax, rcx
    jae .le_range                   ; a directory that does not reach its own

    mov ARG2, [r11 + Q_ENTRIES + rax * 8]
    mov ARG1, [rbp - 8]
    lea ARG3, [rbp - 64]
    call queue_copy_seg
    test eax, eax
    jnz .le_done

    mov r11, [rbp - 40]
    mov rax, [rbp - 56]
    mov rdx, [rbp - 64]
    mov [r11 + Q_ENTRIES + rax * 8], rdx

    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 64]
    call db_queue_seg_addr
    test rax, rax
    jz .le_state
    mov r10, [rbp - 32]
    mov [r10 + LE_SEG], rax
    mov rdx, [rbp - 48]
    shl rdx, 6                      ; QUEUE_SLOT_SIZE
    lea rdx, [rax + QSEG_SLOTS + rdx]
    mov [r10 + LE_SLOT], rdx
    xor eax, eax
.le_done:
    FRAME_END
    ret
.le_range:
    mov eax, CybouDB_E_VALUE
    FRAME_END
    ret
.le_state:
    mov eax, CybouDB_E_STATE
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  lease_now(ctx, id, now, out q_now) -> EAX: 0, or an error
;
;  The clock a queue uses never runs backwards, whatever the machine's does:
;  max(the time given, the largest this queue has used). docs/QUEUE.md, "The
;  clock a lease deadline is measured on".
; -----------------------------------------------------------------------------
lease_now:
    FRAME_BEGIN 48, 0
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
    mov [rbp - 24], ARG3
    mov [rbp - 32], ARG4
    mov r10, ARG1
    test qword [r10 + DB_FEATURES], CybouDB_FEATURE_QUEUE_LEASES
    jz .ln_state
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    call db_catalog_page
    test rax, rax
    jz .ln_state
    cmp dword [rax + CAT_TYPE], CAT_QUEUE
    jne .ln_state
    mov rdx, [rax + Q_TIME_FLOOR]
    mov rcx, [rbp - 24]
    cmp rcx, rdx
    jae .ln_ready
    mov rcx, rdx
.ln_ready:
    mov r10, [rbp - 32]
    mov [r10], rcx
    xor eax, eax
    FRAME_END
    ret
.ln_state:
    mov eax, CybouDB_E_STATE
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  db_queue_claim(ctx, id, now, duration, out position, out token) -> EAX
;
;  Takes the first claimable message and gives it a deadline and a token.
; -----------------------------------------------------------------------------
db_queue_claim:
    FRAME_BEGIN 128, 2
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
    mov [rbp - 24], ARG3            ; now
    mov [rbp - 32], ARG4            ; how long the lease runs
    mov rax, IN_ARG5
    mov [rbp - 40], rax             ; where the position goes
    mov rax, IN_ARG6
    mov [rbp - 48], rax             ; and the token

    cmp qword [rbp - 32], 0
    je .c_value                     ; a lease that has already expired

    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    mov ARG3, [rbp - 24]
    lea ARG4, [rbp - 56]
    call lease_now
    test eax, eax
    jnz .c_done

    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    mov ARG3, [rbp - 56]
    lea ARG4, [rbp - 64]
    call db_queue_scan_claimable
    test eax, eax
    jz .c_empty

    ; The token only goes up, and at the end it stops rather than wrapping: a
    ; wrapped token could equal a stale one, which is the single thing the
    ; token exists to prevent. Asked before anything is copied, so that the
    ; refusal leaves the file alone.
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    mov ARG3, [rbp - 64]
    call lease_find_slot
    test rax, rax
    jz .c_value
    cmp qword [rax + QMSG_LEASE_TOKEN], -1
    je .c_exhausted

    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    mov ARG3, [rbp - 64]
    lea ARG4, [rbp - 96]
    call lease_edit_slot
    test eax, eax
    jnz .c_done

    mov r8, [rbp - 80]              ; the slot
    mov rax, [r8 + QMSG_LEASE_TOKEN]
    inc rax
    mov [r8 + QMSG_LEASE_TOKEN], rax
    mov [rbp - 72], rax

    mov rdx, [rbp - 56]
    add rdx, [rbp - 32]
    jc .c_value                     ; a deadline past the end of the clock
    mov [r8 + QMSG_LEASE_UNTIL], rdx
    mov dword [r8 + QMSG_STATE], QMSG_STATE_CLAIMED

    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 96]
    mov ARG3, [rbp - 88]
    mov ARG4, [rbp - 64]
    call lease_seg_refresh
    mov ARG1, [rbp - 88]
    mov ARG2, [rbp - 8]
    call queue_seg_seal

    ; The cursor is one past the highest position ever handed out, so it moves
    ; only when this claim is the highest - a reclaimed message is behind it.
    mov r11, [rbp - 96]
    mov rax, [rbp - 64]
    inc rax
    cmp rax, [r11 + Q_CLAIM]
    jbe .c_cursor_ok
    mov [r11 + Q_CLAIM], rax
.c_cursor_ok:
    mov rax, [rbp - 56]
    mov [r11 + Q_TIME_FLOOR], rax
    mov ARG1, r11
    call db_catalog_seal

    mov r10, [rbp - 40]
    test r10, r10
    jz .c_no_position
    mov rax, [rbp - 64]
    mov [r10], rax
.c_no_position:
    mov r10, [rbp - 48]
    test r10, r10
    jz .c_ok
    mov rax, [rbp - 72]
    mov [r10], rax
.c_ok:
    xor eax, eax
.c_done:
    FRAME_END
    ret
.c_empty:
    mov eax, CybouDB_E_NOTFOUND
    FRAME_END
    ret
.c_exhausted:
    mov eax, CybouDB_E_VALUE        ; claimed 2^64 times, and saying so
    FRAME_END
    ret
.c_value:
    mov eax, CybouDB_E_VALUE
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  lease_hold(ctx, id, position, token, out[3]) -> EAX
;
;  What ACK, NACK and RENEW all need first: the slot, writable, and the proof
;  that this caller still holds it. **The deadline is never consulted.** A
;  lapsed lease means somebody else may take the message; the token is what
;  says somebody else did, and only that refuses anything.
; -----------------------------------------------------------------------------
lease_hold:
    FRAME_BEGIN 64, 1
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
    mov [rbp - 24], ARG3
    mov [rbp - 32], ARG4            ; the token the caller was given
    mov rax, IN_ARG5
    mov [rbp - 40], rax             ; out

    mov r10, ARG1
    test qword [r10 + DB_FEATURES], CybouDB_FEATURE_QUEUE_LEASES
    jz .lh_state

    ; Decided first, on the page as it stands. A refusal copies nothing.
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    mov ARG3, [rbp - 24]
    call lease_find_slot
    test rax, rax
    jz .lh_lease                    ; finished, or never in this queue at all
    mov r8, rax
    cmp dword [r8 + QMSG_STATE], QMSG_STATE_CLAIMED
    jne .lh_lease                   ; nobody holds it, or it is already done
    mov rax, [rbp - 32]
    cmp [r8 + QMSG_LEASE_TOKEN], rax
    jne .lh_lease                   ; the lease was reclaimed and handed on

    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    mov ARG3, [rbp - 24]
    mov ARG4, [rbp - 40]
    call lease_edit_slot
    test eax, eax
    jnz .lh_done
    xor eax, eax
.lh_done:
    FRAME_END
    ret
.lh_lease:
    mov eax, CybouDB_E_LEASE
    FRAME_END
    ret
.lh_value:
    mov eax, CybouDB_E_VALUE
    FRAME_END
    ret
.lh_state:
    mov eax, CybouDB_E_STATE
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  lease_summaries_valid(ctx, queue page) -> RAX: 1 when every segment's
;  QSEG_READY_AT is one the search may trust
;
;  The rule is an inequality and not an equality, which is the whole of what
;  the summary has to promise:
;
;      stored <= what the slots actually say
;
;  A summary that is too low costs a look into a segment with nothing in it. A
;  summary that is too high **hides a claimable message**, which is a queue
;  that has silently lost work. Only the second is damage, so only the second
;  is refused.
;
;  That also makes the field safe for any writer that is merely conservative -
;  a path that leaves a zero where it could have raised it is correct and
;  slower, which is the direction this format prefers everywhere else.
; -----------------------------------------------------------------------------
lease_summaries_valid:
    FRAME_BEGIN 96, 0
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
    mov r10, ARG1
    test qword [r10 + DB_FEATURES], CybouDB_FEATURE_QUEUE_LEASES
    jz .sv_yes                      ; without them the field is checked as zero

    mov r11, ARG2
    mov rax, [r11 + Q_HEAD]
    mov [rbp - 24], rax
    mov rax, [r11 + Q_TAIL]
    mov [rbp - 32], rax
    mov rax, [r11 + Q_FIRST_SEG]
    mov [rbp - 40], rax
    mov ecx, [r11 + Q_SEGMENTS]
    mov [rbp - 48], rcx
    mov qword [rbp - 56], 0         ; the directory entry being looked at

.sv_entry:
    mov rax, [rbp - 56]
    cmp rax, [rbp - 48]
    jae .sv_yes
    mov r11, [rbp - 16]
    mov ARG2, [r11 + Q_ENTRIES + rax * 8]
    mov ARG1, [rbp - 8]
    call db_queue_seg_addr
    test rax, rax
    jz .sv_no
    mov [rbp - 64], rax             ; the segment page

    ; The live range this segment holds.
    mov rax, [rbp - 56]
    add rax, [rbp - 40]
    imul rax, QUEUE_SEG_SLOTS
    mov [rbp - 72], rax
    mov rdx, rax
    add rdx, QUEUE_SEG_SLOTS
    mov [rbp - 80], rdx
    mov rax, [rbp - 24]
    cmp rax, [rbp - 72]
    jbe .sv_low_ready
    mov [rbp - 72], rax
.sv_low_ready:
    mov rax, [rbp - 32]
    cmp rax, [rbp - 80]
    jae .sv_high_ready
    mov [rbp - 80], rax
.sv_high_ready:

    mov rax, -1
    mov [rbp - 88], rax
.sv_slot:
    mov rax, [rbp - 72]
    cmp rax, [rbp - 80]
    jae .sv_compare
    xor edx, edx
    mov rcx, QUEUE_SEG_SLOTS
    div rcx
    shl rdx, 6
    mov r8, [rbp - 64]
    lea r8, [r8 + QSEG_SLOTS + rdx]
    mov ecx, [r8 + QMSG_STATE]
    cmp ecx, QMSG_STATE_HELD
    je .sv_floor
    cmp ecx, QMSG_STATE_CLAIMED
    jne .sv_slot_next
    mov rax, [r8 + QMSG_LEASE_UNTIL]
    cmp rax, [rbp - 88]
    jae .sv_slot_next
    mov [rbp - 88], rax
.sv_slot_next:
    inc qword [rbp - 72]
    jmp .sv_slot
.sv_floor:
    mov qword [rbp - 88], 0
.sv_compare:
    mov r8, [rbp - 64]
    mov rax, [r8 + QSEG_READY_AT]
    cmp rax, [rbp - 88]
    ja .sv_no                       ; it would hide a claimable message
    inc qword [rbp - 56]
    jmp .sv_entry

.sv_yes:
    mov eax, 1
    FRAME_END
    ret
.sv_no:
    xor eax, eax
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  lease_seg_refresh(ctx, queue page, segment address, position)
;
;  Recompute one segment's QSEG_READY_AT from the slots it holds:
;
;      0            a free message is in it, and zero is the floor
;      the least deadline among its claims
;      UINT64_MAX   it holds neither
;
;  Called where the segment page is already being rewritten, which is what
;  makes it free - see benchmarks/results/2026-09-14-lease-ready-at-tree.md.
;  The walk stops at the first free message it finds, because nothing below
;  zero exists.
;
;  The live range is [head, tail) clipped to this segment: positions outside it
;  are not read by anything and must not be summarised, or a segment that had
;  been half consumed would claim a deadline nobody holds.
; -----------------------------------------------------------------------------
lease_seg_refresh:
    FRAME_BEGIN 64, 0
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2            ; the queue page
    mov [rbp - 24], ARG3            ; the segment, writable
    mov [rbp - 32], ARG4            ; a position inside it

    mov r10, ARG1
    test qword [r10 + DB_FEATURES], CybouDB_FEATURE_QUEUE_LEASES
    jz .sr_done                     ; the field stays zero without them

    mov rax, [rbp - 32]
    xor edx, edx
    mov rcx, QUEUE_SEG_SLOTS
    div rcx
    imul rax, QUEUE_SEG_SLOTS
    mov [rbp - 40], rax             ; the first position this segment holds
    mov rdx, rax
    add rdx, QUEUE_SEG_SLOTS
    mov [rbp - 48], rdx             ; one past the last

    mov r11, [rbp - 16]
    mov rax, [r11 + Q_HEAD]
    cmp rax, [rbp - 40]
    jbe .sr_low_ready
    mov [rbp - 40], rax
.sr_low_ready:
    mov rax, [r11 + Q_TAIL]
    cmp rax, [rbp - 48]
    jae .sr_high_ready
    mov [rbp - 48], rax
.sr_high_ready:

    mov rax, -1
    mov [rbp - 56], rax             ; the least deadline so far
.sr_slot:
    mov rax, [rbp - 40]
    cmp rax, [rbp - 48]
    jae .sr_store
    xor edx, edx
    mov rcx, QUEUE_SEG_SLOTS
    div rcx
    shl rdx, 6                      ; QUEUE_SLOT_SIZE
    mov r8, [rbp - 24]
    lea r8, [r8 + QSEG_SLOTS + rdx]
    mov ecx, [r8 + QMSG_STATE]
    cmp ecx, QMSG_STATE_HELD
    je .sr_floor
    cmp ecx, QMSG_STATE_CLAIMED
    jne .sr_next                    ; ACKED gives nothing
    mov rax, [r8 + QMSG_LEASE_UNTIL]
    cmp rax, [rbp - 56]
    jae .sr_next
    mov [rbp - 56], rax
.sr_next:
    inc qword [rbp - 40]
    jmp .sr_slot
.sr_floor:
    mov qword [rbp - 56], 0
.sr_store:
    mov r8, [rbp - 24]
    mov rax, [rbp - 56]
    mov [r8 + QSEG_READY_AT], rax
.sr_done:
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  lease_advance_head(ctx, the writable queue page) -> EAX: 0
;
;  The head is the oldest position not acknowledged, and acknowledgement can
;  arrive out of order - so it moves over a *run* of ACKED messages rather than
;  one at a time. Message 5 finishing before 3 leaves the head at 3 with 5
;  already done, and both move when 3 is acknowledged.
;
;  This is retirement machinery rather than lease machinery, and it is the same
;  machinery db_queue_pop has: the bytes each message owned are given back as
;  the head passes it, the segments left entirely behind are retired, and what
;  is left of the directory moves down to entry zero.
;
;  The extents are retired here and not at the acknowledgement, which is the
;  part worth knowing. An ACKED message still inside [head, tail) is one the
;  validator walks, and it would walk the chain the slot names - so a chain
;  retired at ACK would be a chain the next commit reads as damage. The head
;  passing the message is the moment nothing reads it again.
; -----------------------------------------------------------------------------
lease_advance_head:
    FRAME_BEGIN 96, 0
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
    mov r11, ARG2
    mov rax, [r11 + Q_HEAD]
    mov [rbp - 24], rax             ; where the head started
    mov [rbp - 32], rax             ; and where it is getting to
    mov rax, [r11 + Q_TAIL]
    mov [rbp - 40], rax

.ah_step:
    mov rax, [rbp - 32]
    cmp rax, [rbp - 40]
    jae .ah_moved
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    mov ARG3, Q_ENTRIES
    mov ARG4, [rbp - 32]
    call queue_slot_at
    test rax, rax
    jz .ah_moved
    cmp dword [rax + QMSG_STATE], QMSG_STATE_ACKED
    jne .ah_moved                   ; the run ends at the first unfinished one

    mov ecx, [rax + QMSG_FLAGS]
    test ecx, QMSG_FLAG_EXTENT
    jz .ah_no_chain
    mov ARG2, [rax + QMSG_EXTENT]
    mov ARG1, [rbp - 8]
    call queue_retire_chain
.ah_no_chain:
    inc qword [rbp - 32]
    jmp .ah_step

.ah_moved:
    mov rax, [rbp - 32]
    cmp rax, [rbp - 24]
    je .ah_done                     ; nothing at the front was finished

    mov r11, [rbp - 16]
    mov [r11 + Q_HEAD], rax
    xor edx, edx
    mov rcx, QUEUE_SEG_SLOTS
    div rcx
    mov [rbp - 48], rax             ; the segment the new head is in

    mov rdx, [rbp - 32]
    cmp rdx, [rbp - 40]
    jne .ah_keeping
    mov ecx, [r11 + Q_SEGMENTS]
    mov [rbp - 56], rcx             ; drained: every entry goes
    mov qword [rbp - 64], 0
    jmp .ah_counted
.ah_keeping:
    mov rax, [rbp - 48]
    sub rax, [r11 + Q_FIRST_SEG]
    mov [rbp - 56], rax             ; entries the head has left behind
    mov ecx, [r11 + Q_SEGMENTS]
    sub rcx, rax
    mov [rbp - 64], rcx
.ah_counted:

    mov qword [rbp - 72], 0
.ah_retire:
    mov rax, [rbp - 72]
    cmp rax, [rbp - 56]
    jae .ah_retired
    mov r11, [rbp - 16]
    mov ARG2, [r11 + Q_ENTRIES + rax * 8]
    mov ARG1, [rbp - 8]
    call db_bitmap_retire
    inc qword [rbp - 72]
    jmp .ah_retire
.ah_retired:
    cmp qword [rbp - 56], 0
    je .ah_fields                   ; nothing moved, so nothing to shift

    mov r11, [rbp - 16]
    mov rcx, [rbp - 56]
    xor edx, edx
.ah_move:
    cmp rdx, [rbp - 64]
    jae .ah_cleared
    mov r9, rdx
    add r9, rcx
    mov r8, [r11 + Q_ENTRIES + r9 * 8]
    mov [r11 + Q_ENTRIES + rdx * 8], r8
    inc rdx
    jmp .ah_move
.ah_cleared:
    ; And what used to be beyond them is zero, as every tail here is.
    mov rax, [rbp - 64]
    mov ecx, [r11 + Q_SEGMENTS]
.ah_clear:
    cmp rax, rcx
    jae .ah_fields
    mov qword [r11 + Q_ENTRIES + rax * 8], 0
    inc rax
    jmp .ah_clear

.ah_fields:
    mov r11, [rbp - 16]
    mov rax, [rbp - 64]
    mov [r11 + Q_SEGMENTS], eax
    mov rax, [rbp - 48]
    mov [r11 + Q_FIRST_SEG], rax
.ah_done:
    xor eax, eax
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  db_queue_ack(ctx, id, position, token) -> EAX
;
;  Done. The slot keeps the token that finished it, which is what makes a
;  ticket presented against it visibly stale.
; -----------------------------------------------------------------------------
db_queue_ack:
    FRAME_BEGIN 64, 1
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
    mov [rbp - 24], ARG3            ; the summary below is recomputed for it
    lea rax, [rbp - 64]
    PASS_ARG5 rax
    call lease_hold
    test eax, eax
    jnz .a_done
    mov r8, [rbp - 64 + LE_SLOT]
    mov dword [r8 + QMSG_STATE], QMSG_STATE_ACKED
    mov qword [r8 + QMSG_LEASE_UNTIL], 0
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 64 + LE_QPAGE]
    mov ARG3, [rbp - 64 + LE_SEG]
    mov ARG4, [rbp - 24]
    call lease_seg_refresh
    mov ARG1, [rbp - 64 + LE_SEG]
    mov ARG2, [rbp - 8]
    call queue_seg_seal

    ; The head moves over whatever is finished at the front, which may be this
    ; message, may be a run of them that were waiting for it, and may be
    ; nothing at all.
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 64 + LE_QPAGE]
    call lease_advance_head

    mov ARG1, [rbp - 64 + LE_QPAGE]
    call db_catalog_seal
    xor eax, eax
.a_done:
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  db_queue_nack(ctx, id, position, token) -> EAX
;
;  Handed back. The token goes up, because otherwise a worker could give a
;  message back, watch another take it, and then acknowledge it.
; -----------------------------------------------------------------------------
db_queue_nack:
    FRAME_BEGIN 64, 1
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
    mov [rbp - 24], ARG3
    mov [rbp - 32], ARG4
    ; A nack raises the token, so it has the same end as a claim does, and the
    ; same reason for stopping there rather than wrapping. Asked on the page as
    ; it stands, because a refusal copies nothing.
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    mov ARG3, [rbp - 24]
    call lease_find_slot
    test rax, rax
    jz .n_value
    cmp qword [rax + QMSG_LEASE_TOKEN], -1
    je .n_value
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    mov ARG3, [rbp - 24]
    mov ARG4, [rbp - 32]
    lea rax, [rbp - 64]
    PASS_ARG5 rax
    call lease_hold
    test eax, eax
    jnz .n_done
    mov r8, [rbp - 64 + LE_SLOT]
    mov rax, [r8 + QMSG_LEASE_TOKEN]
    inc rax
    mov [r8 + QMSG_LEASE_TOKEN], rax
    mov dword [r8 + QMSG_STATE], QMSG_STATE_HELD
    mov qword [r8 + QMSG_LEASE_UNTIL], 0
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 64 + LE_QPAGE]
    mov ARG3, [rbp - 64 + LE_SEG]
    mov ARG4, [rbp - 24]
    call lease_seg_refresh
    mov ARG1, [rbp - 64 + LE_SEG]
    mov ARG2, [rbp - 8]
    call queue_seg_seal
    mov ARG1, [rbp - 64 + LE_QPAGE]
    call db_catalog_seal
    xor eax, eax
.n_done:
    FRAME_END
    ret
.n_value:
    mov eax, CybouDB_E_VALUE
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  db_queue_renew(ctx, id, position, token, now, duration) -> EAX
;
;  A longer lease on the same token. A lapsed deadline is not a refusal: if
;  another worker had taken the message the token would say so.
; -----------------------------------------------------------------------------
db_queue_renew:
    FRAME_BEGIN 128, 2
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
    mov [rbp - 24], ARG3
    mov [rbp - 32], ARG4
    mov rax, IN_ARG5
    mov [rbp - 40], rax             ; now
    mov rax, IN_ARG6
    mov [rbp - 48], rax             ; how much longer

    cmp qword [rbp - 48], 0
    je .r_value

    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    mov ARG3, [rbp - 40]
    lea ARG4, [rbp - 56]
    call lease_now
    test eax, eax
    jnz .r_done

    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    mov ARG3, [rbp - 24]
    mov ARG4, [rbp - 32]
    lea rax, [rbp - 128]
    PASS_ARG5 rax
    call lease_hold
    test eax, eax
    jnz .r_done

    mov rdx, [rbp - 56]
    add rdx, [rbp - 48]
    jc .r_value
    mov r8, [rbp - 128 + LE_SLOT]
    mov [r8 + QMSG_LEASE_UNTIL], rdx
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 128 + LE_QPAGE]
    mov ARG3, [rbp - 128 + LE_SEG]
    mov ARG4, [rbp - 24]
    call lease_seg_refresh
    mov ARG1, [rbp - 128 + LE_SEG]
    mov ARG2, [rbp - 8]
    call queue_seg_seal
    mov r11, [rbp - 128 + LE_QPAGE]
    mov rax, [rbp - 56]
    mov [r11 + Q_TIME_FLOOR], rax
    mov ARG1, r11
    call db_catalog_seal
    xor eax, eax
.r_done:
    FRAME_END
    ret
.r_value:
    mov eax, CybouDB_E_VALUE
    FRAME_END
    ret

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
    mov r10d, CAT_QUEUE
    mov r11d, Q_ENTRIES
    jmp queue_retire_common
; A stream's records sit in the same segments, named by a directory at a
; different offset, so what differs between retiring one and retiring a queue
; is two numbers. The walk is one walk for the reason the validation is.
db_stream_retire_all:
    mov r10d, CAT_STREAM
    mov r11d, S_ENTRIES
queue_retire_common:
    FRAME_BEGIN 112, 0
    mov [rbp - 88], r11             ; where this object's directory starts
    mov [rbp - 96], r10             ; and what kind of page it must be
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
    mov r10, ARG1
    ; The queue bit, for a stream too: a stream's records live in a queue's
    ; segments, and the bit that defines them is the one that must be set.
    test qword [r10 + DB_FEATURES], CybouDB_FEATURE_QUEUE
    jz .a_ok
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    call db_catalog_page
    test rax, rax
    jz .a_ok
    mov ecx, [rax + CAT_TYPE]
    cmp rcx, [rbp - 96]
    jne .a_ok
    mov [rbp - 24], rax
    mov rdx, [rax + Q_HEAD]         ; S_FIRST is the same offset
    mov [rbp - 32], rdx
    mov rdx, [rax + Q_TAIL]         ; as is S_END
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
    add r11, [rbp - 88]
    mov r9, [r11 + rax * 8]
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
    add r11, [rbp - 88]
    mov r9, [r11 + rax * 8]
    mov ARG1, [rbp - 8]
    mov ARG2, r9
    call db_bitmap_retire
    inc qword [rbp - 72]
    jmp .a_segment
.a_ok:
    xor eax, eax
    FRAME_END
    ret

%ifdef CybouDB_LINUX
section .note.GNU-stack noalloc noexec nowrite progbits
%endif
