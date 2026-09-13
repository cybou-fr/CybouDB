; Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
; SPDX-License-Identifier: Apache-2.0
; Append-only streams: the catalog page that defines one, the cursors reading
; it, and what a commit proves about both. The decisions behind the layout are
; in docs/STREAM.md; where the bytes are is in include/stream.inc.
;
; A stream's records live in segment pages of the queue's format, so there is
; no storage here - only the page that names those segments and the readers
; standing in them. The walk over the segments is db_queue_segments_valid, and
; it is one routine because a stream and a queue are two promises over one
; storage shape.
%include "cyboudb.inc"
BITS 64
default rel
extern db_queue_segments_valid
extern db_catalog_page, db_catalog_edit, db_catalog_seal
extern queue_slot_at, queue_slot_copy, queue_retire_chain
extern db_bitmap_retire
global stream_page_valid
global db_stream_cursor_add, db_stream_cursor_drop, db_stream_cursor_find
global db_stream_peek, db_stream_read, db_stream_trim

section .text

; -----------------------------------------------------------------------------
;  stream_page_valid(ARG1 = ctx, ARG2 = candidate superblock, ARG3 = page)
;      -> RAX: 1 when the stream that page defines is coherent.
;
;  What is here is what makes a stream a stream: its cursors. A cursor names a
;  durable reader and says where it has read to, and the two things that can be
;  wrong with one are that it is standing outside the stream and that two of
;  them are the same reader.
;
;  A cursor at `end` has read everything, which is why the range it must be in
;  is closed at the top and the empty stream has every cursor at the same place.
;
;  Local slots: [rbp-8]=ctx, [rbp-16]=sb, [rbp-24]=page, [rbp-32]=first,
;               [rbp-40]=end, [rbp-48]=cursors, [rbp-56]=cursor index,
;               [rbp-64]=cursor address, [rbp-72]=the one compared against,
;               [rbp-160]=the segment walk's descriptor
; -----------------------------------------------------------------------------
stream_page_valid:
    FRAME_BEGIN 192, 0
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
    mov [rbp - 24], ARG3
    mov r10, ARG1
    test qword [r10 + DB_FEATURES], CybouDB_FEATURE_STREAM
    jz .bad

    mov r11, ARG3
    cmp byte [r11 + S_NAME], 0
    je .bad                         ; a stream nothing can name
    cmp qword [r11 + S_RESERVED], 0
    jne .bad
    cmp qword [r11 + S_RESERVED2], 0
    jne .bad
    cmp qword [r11 + S_RESERVED2 + 8], 0
    jne .bad

    mov rax, [r11 + S_FIRST]
    mov [rbp - 32], rax
    mov rdx, [r11 + S_END]
    mov [rbp - 40], rdx
    mov rcx, [r11 + S_CURSORS]
    mov [rbp - 48], rcx
    cmp rcx, S_MAX_CURSORS
    ja .bad

    ; Every cursor in use stands somewhere inside the stream and is a reader
    ; nothing else is.
    mov qword [rbp - 56], 0
.cursor:
    mov rax, [rbp - 56]
    cmp rax, [rbp - 48]
    jae .cursors_done
    imul rax, SCUR_SIZE
    mov r11, [rbp - 24]
    lea rax, [r11 + S_CURSOR_TABLE + rax]
    mov [rbp - 64], rax
    cmp byte [rax + SCUR_NAME], 0
    je .bad                         ; a reader nothing can name
    mov rdx, [rax + SCUR_POSITION]
    cmp rdx, [rbp - 32]
    jb .bad                         ; standing behind what the stream still has
    cmp rdx, [rbp - 40]
    ja .bad                         ; or past what it has ever held

    ; And no two of them are the same reader. Eight is the ceiling, so this
    ; costs at most twenty-eight comparisons and needs no cleverness.
    mov qword [rbp - 72], 0
.against:
    mov rax, [rbp - 72]
    cmp rax, [rbp - 56]
    jae .cursor_next
    imul rax, SCUR_SIZE
    mov r11, [rbp - 24]
    lea r9, [r11 + S_CURSOR_TABLE + rax]
    mov r10, [rbp - 64]
    xor ecx, ecx
.name_byte:
    mov al, [r9 + SCUR_NAME + rcx]
    cmp al, [r10 + SCUR_NAME + rcx]
    jne .names_differ
    test al, al
    jz .bad                         ; ran to the end of both: one reader twice
    inc rcx
    cmp rcx, SCUR_NAME_MAX
    jb .name_byte
    jmp .bad                        ; the full width matched
.names_differ:
    inc qword [rbp - 72]
    jmp .against
.cursor_next:
    inc qword [rbp - 56]
    jmp .cursor

.cursors_done:
    ; A slot no cursor is using holds nothing, as every tail in this format
    ; does. Without this a name and a position could sit past the count, read
    ; by nothing and refused by nothing.
    mov rax, [rbp - 48]
    imul rax, SCUR_SIZE
    mov r11, [rbp - 24]
    lea r9, [r11 + S_CURSOR_TABLE + rax]
    lea rcx, [r11 + S_ENTRIES]
.slot_tail:
    cmp r9, rcx
    jae .slots_clean
    cmp dword [r9], 0
    jne .bad
    add r9, 4
    jmp .slot_tail
.slots_clean:

    ; The segments are the queue's, and so is the walk over them.
    mov rax, [rbp - 8]
    mov [rbp - 160 + QSV_CTX], rax
    mov rax, [rbp - 16]
    mov [rbp - 160 + QSV_SB], rax
    mov r11, [rbp - 24]
    mov rax, [r11 + CAT_OWNER]
    mov [rbp - 160 + QSV_OWNER], rax
    lea rax, [r11 + S_ENTRIES]
    mov [rbp - 160 + QSV_ENTRIES], rax
    lea rax, [r11 + S_CRC]
    mov [rbp - 160 + QSV_TAIL_END], rax
    mov ecx, [r11 + S_SEGMENTS]
    mov [rbp - 160 + QSV_SEGMENTS], rcx
    mov rax, [r11 + S_FIRST_SEG]
    mov [rbp - 160 + QSV_FIRST_SEG], rax
    mov rax, [rbp - 32]
    mov [rbp - 160 + QSV_LOW], rax
    mov rax, [rbp - 40]
    mov [rbp - 160 + QSV_HIGH], rax
    mov qword [rbp - 160 + QSV_MAX_SEG], S_MAX_SEGMENTS
    lea ARG1, [rbp - 160]
    call db_queue_segments_valid
    FRAME_END
    ret
.bad:
    xor eax, eax
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  stream_cursor_slot(ARG1 = stream page, ARG2 = index) -> RAX: the cursor
; -----------------------------------------------------------------------------
stream_cursor_slot:
    mov rax, ARG2
    shl rax, 5                      ; SCUR_SIZE
    add rax, ARG1
    add rax, S_CURSOR_TABLE
    ret

; -----------------------------------------------------------------------------
;  db_stream_cursor_find(ARG1 = stream page, ARG2 = name, ARG3 = length)
;      -> RAX: the cursor's index, or -1
;
;  A name matches when its bytes match and the stored name ends there: the
;  table holds NUL-padded names, so "read" must not find "reader".
; -----------------------------------------------------------------------------
db_stream_cursor_find:
    FRAME_BEGIN 64, 0
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
    mov [rbp - 24], ARG3
    mov qword [rbp - 32], 0
.each:
    mov r10, [rbp - 8]
    mov rax, [rbp - 32]
    cmp rax, [r10 + S_CURSORS]
    jae .missing
    shl rax, 5
    lea r11, [r10 + S_CURSOR_TABLE + rax]   ; the cursor
    mov r10, [rbp - 16]                     ; the name looked for
    mov rcx, [rbp - 24]
    xor edx, edx
.byte:
    cmp rdx, rcx
    jae .ended
    mov al, [r10 + rdx]
    cmp al, [r11 + SCUR_NAME + rdx]
    jne .next
    inc rdx
    jmp .byte
.ended:
    ; Every byte matched; it is the same name only if the stored one stops.
    cmp rdx, SCUR_NAME_MAX
    jae .found                      ; the full width, so nothing follows
    cmp byte [r11 + SCUR_NAME + rdx], 0
    jne .next
.found:
    mov rax, [rbp - 32]
    FRAME_END
    ret
.next:
    inc qword [rbp - 32]
    jmp .each
.missing:
    mov rax, -1
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  db_stream_cursor_add(ctx, stream id, name, length) -> RAX: result code
;
;  A new reader, standing where the stream begins: the oldest record still
;  kept is the first one it has not seen, which is the only starting point
;  that promises it every record the stream still has.
;
;  Local slots: [rbp-8]=ctx, [rbp-16]=id, [rbp-24]=name, [rbp-32]=length,
;               [rbp-40]=page, [rbp-48]=first, [rbp-56]=end, [rbp-64]=cursor
; -----------------------------------------------------------------------------
db_stream_cursor_add:
    FRAME_BEGIN 96, 0
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
    mov [rbp - 24], ARG3
    mov [rbp - 32], ARG4
    mov r10, ARG1
    test qword [r10 + DB_FEATURES], CybouDB_FEATURE_STREAM
    jz .a_state
    mov rax, [rbp - 32]
    test rax, rax
    jz .a_value                     ; a reader nothing can name
    cmp rax, SCUR_NAME_MAX
    ja .a_value

    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    call db_catalog_page
    test rax, rax
    jz .a_state
    cmp dword [rax + CAT_TYPE], CAT_STREAM
    jne .a_state
    mov rdx, [rax + S_FIRST]
    mov [rbp - 48], rdx
    mov rdx, [rax + S_END]
    mov [rbp - 56], rdx
    mov [rbp - 72], rax

    ; One reader, one name - asked before the ceiling, because a name that is
    ; already there is the truer answer when both are true, and before
    ; anything is copied, so a refusal costs no page.
    mov ARG1, rax
    mov ARG2, [rbp - 24]
    mov ARG3, [rbp - 32]
    call db_stream_cursor_find
    cmp rax, -1
    jne .a_exists
    mov r10, [rbp - 72]
    cmp qword [r10 + S_CURSORS], S_MAX_CURSORS
    jae .a_full

    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    lea ARG3, [rbp - 40]
    call db_catalog_edit
    test eax, eax
    jnz .a_done

    ; stamp cleared the span the positions live in, so they go back first.
    mov r10, [rbp - 40]
    mov rax, [rbp - 48]
    mov [r10 + S_FIRST], rax
    mov rax, [rbp - 56]
    mov [r10 + S_END], rax

    mov ARG1, r10
    mov ARG2, [r10 + S_CURSORS]
    call stream_cursor_slot
    mov [rbp - 64], rax

    ; The name, into a slot that is zero the whole way: the validator requires
    ; the padding, and a slot freed by a drop was zeroed then.
    mov r8, [rbp - 64]
    mov r9, [rbp - 24]
    mov rcx, [rbp - 32]
    xor edx, edx
.a_byte:
    cmp rdx, rcx
    jae .a_padded
    mov al, [r9 + rdx]
    mov [r8 + SCUR_NAME + rdx], al
    inc rdx
    jmp .a_byte
.a_padded:
    cmp rdx, SCUR_NAME_MAX
    jae .a_named
    mov byte [r8 + SCUR_NAME + rdx], 0
    inc rdx
    jmp .a_padded
.a_named:
    mov byte [r8 + SCUR_NAME + SCUR_NAME_MAX], 0
    mov rax, [rbp - 48]
    mov [r8 + SCUR_POSITION], rax
    mov r10, [rbp - 40]
    inc qword [r10 + S_CURSORS]
    mov ARG1, r10
    call db_catalog_seal
    xor eax, eax
    jmp .a_done
.a_state:
    mov eax, CybouDB_E_STATE
    jmp .a_done
.a_value:
    mov eax, CybouDB_E_VALUE
    jmp .a_done
.a_full:
    mov eax, CybouDB_E_FULL
    jmp .a_done
.a_exists:
    mov eax, CybouDB_E_SCHEMA
.a_done:
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  db_stream_cursor_drop(ctx, stream id, name, length) -> RAX: result code
;
;  The reader goes, and with it whatever retention it was holding up: this is
;  the escape hatch a trim refused by an abandoned cursor has.
;
;  The table is kept dense, because the validator requires the slots past the
;  count to be zero and a reader is found by walking the first N. So the last
;  cursor moves into the hole and the slot it left is zeroed - a cursor's
;  index means nothing to anyone, only its name does.
;
;  Local slots: [rbp-8]=ctx, [rbp-16]=id, [rbp-24]=name, [rbp-32]=length,
;               [rbp-40]=page, [rbp-48]=first, [rbp-56]=end, [rbp-64]=index
; -----------------------------------------------------------------------------
db_stream_cursor_drop:
    FRAME_BEGIN 96, 0
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
    mov [rbp - 24], ARG3
    mov [rbp - 32], ARG4
    mov r10, ARG1
    test qword [r10 + DB_FEATURES], CybouDB_FEATURE_STREAM
    jz .d_state

    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    call db_catalog_page
    test rax, rax
    jz .d_state
    cmp dword [rax + CAT_TYPE], CAT_STREAM
    jne .d_state
    mov rdx, [rax + S_FIRST]
    mov [rbp - 48], rdx
    mov rdx, [rax + S_END]
    mov [rbp - 56], rdx
    mov ARG1, rax
    mov ARG2, [rbp - 24]
    mov ARG3, [rbp - 32]
    call db_stream_cursor_find
    cmp rax, -1
    je .d_missing
    mov [rbp - 64], rax

    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    lea ARG3, [rbp - 40]
    call db_catalog_edit
    test eax, eax
    jnz .d_done
    mov r10, [rbp - 40]
    mov rax, [rbp - 48]
    mov [r10 + S_FIRST], rax
    mov rax, [rbp - 56]
    mov [r10 + S_END], rax

    ; The last one into the hole, unless it is the hole.
    mov r10, [rbp - 40]
    mov rax, [r10 + S_CURSORS]
    dec rax
    mov [r10 + S_CURSORS], rax
    cmp rax, [rbp - 64]
    je .d_zero
    mov ARG1, r10
    mov ARG2, rax
    call stream_cursor_slot
    mov r11, rax                    ; the last cursor
    mov ARG1, [rbp - 40]
    mov ARG2, [rbp - 64]
    call stream_cursor_slot
    xor edx, edx
.d_move:
    mov cl, [r11 + rdx]
    mov [rax + rdx], cl
    inc rdx
    cmp rdx, SCUR_SIZE
    jb .d_move

.d_zero:
    ; And the slot past the count holds nothing, which the validator requires
    ; and a later add relies on for its padding.
    mov ARG1, [rbp - 40]
    mov r10, [rbp - 40]
    mov ARG2, [r10 + S_CURSORS]
    call stream_cursor_slot
    xor edx, edx
.d_zero_byte:
    mov byte [rax + rdx], 0
    inc rdx
    cmp rdx, SCUR_SIZE
    jb .d_zero_byte

    mov ARG1, [rbp - 40]
    call db_catalog_seal
    xor eax, eax
    jmp .d_done
.d_state:
    mov eax, CybouDB_E_STATE
    jmp .d_done
.d_missing:
    mov eax, CybouDB_E_CURSOR
.d_done:
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  db_stream_peek(ctx, stream id, name, length, out_length, out_cursor)
;      -> RAX: result code
;
;  How much room the next record for this reader needs, and which cursor it
;  is - so that a caller can size a buffer before anything moves, and the
;  read that follows does not resolve the name a second time.
;
;  E_CURSOR when the stream has no reader of that name; E_NOTFOUND when it has
;  one and that reader has seen everything, which is the queue's answer for an
;  empty queue and means the same thing to a caller: nothing to hand back.
;
;  Local slots: [rbp-8]=ctx, [rbp-16]=id, [rbp-24]=name, [rbp-32]=length,
;               [rbp-40]=out length, [rbp-48]=out cursor, [rbp-56]=page,
;               [rbp-64]=cursor address
; -----------------------------------------------------------------------------
db_stream_peek:
    FRAME_BEGIN 96, 2
    mov r10, IN_ARG5
    mov r11, IN_ARG6
    mov [rbp - 40], r10
    mov [rbp - 48], r11
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
    mov [rbp - 24], ARG3
    mov [rbp - 32], ARG4
    mov r10, ARG1
    test qword [r10 + DB_FEATURES], CybouDB_FEATURE_STREAM
    jz .p_state

    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    call db_catalog_page
    test rax, rax
    jz .p_state
    cmp dword [rax + CAT_TYPE], CAT_STREAM
    jne .p_state
    mov [rbp - 56], rax
    mov ARG1, rax
    mov ARG2, [rbp - 24]
    mov ARG3, [rbp - 32]
    call db_stream_cursor_find
    cmp rax, -1
    je .p_no_cursor
    mov r11, [rbp - 48]
    mov [r11], rax
    mov ARG1, [rbp - 56]
    mov ARG2, rax
    call stream_cursor_slot
    mov [rbp - 64], rax

    mov r10, [rbp - 56]
    mov r11, [rax + SCUR_POSITION]  ; in a register no argument aliases
    cmp r11, [r10 + S_END]
    jae .p_caught_up

    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 56]
    mov ARG3, S_ENTRIES
    mov ARG4, r11
    call queue_slot_at
    test rax, rax
    jz .p_state                     ; a page that does not reach its own reader
    mov ecx, [rax + QMSG_LENGTH]
    mov r11, [rbp - 40]
    mov [r11], rcx
    xor eax, eax
    FRAME_END
    ret
.p_caught_up:
    mov eax, CybouDB_E_NOTFOUND
    FRAME_END
    ret
.p_no_cursor:
    mov eax, CybouDB_E_CURSOR
    FRAME_END
    ret
.p_state:
    mov eax, CybouDB_E_STATE
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  db_stream_read(ctx, stream id, cursor index, buffer, out_length, capacity)
;      -> RAX: result code
;
;  The record this reader has not seen, and then the reader has seen it. The
;  bytes are copied before the position moves, so a copy that fails leaves a
;  reader that will be given the same record again - which is the only failure
;  a reader can survive.
;
;  Nothing is removed. Another cursor still sees the record, and what stops it
;  being kept is a trim.
;
;  Local slots: [rbp-8]=ctx, [rbp-16]=id, [rbp-24]=index, [rbp-32]=buffer,
;               [rbp-40]=out length, [rbp-48]=capacity, [rbp-56]=page,
;               [rbp-64]=position
; -----------------------------------------------------------------------------
db_stream_read:
    FRAME_BEGIN 96, 2
    mov r10, IN_ARG5
    mov r11, IN_ARG6
    mov [rbp - 40], r10
    mov [rbp - 48], r11
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
    mov [rbp - 24], ARG3
    mov [rbp - 32], ARG4
    mov r10, ARG1
    test qword [r10 + DB_FEATURES], CybouDB_FEATURE_STREAM
    jz .r_state

    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    call db_catalog_page
    test rax, rax
    jz .r_state
    cmp dword [rax + CAT_TYPE], CAT_STREAM
    jne .r_state
    mov [rbp - 56], rax
    mov r11, [rbp - 24]             ; likewise: ARG1 is RCX on one of the two
    cmp r11, [rax + S_CURSORS]
    jae .r_state
    mov ARG1, rax
    mov ARG2, r11
    call stream_cursor_slot
    mov r11, [rax + SCUR_POSITION]
    mov [rbp - 64], r11
    mov r10, [rbp - 56]
    cmp r11, [r10 + S_END]
    jae .r_caught_up
    ; Both positions, before the edit: stamp clears the span they live in, and
    ; a stream that comes back saying it holds nothing while naming segments is
    ; one the commit refuses - which is how this was found.
    mov r11, [r10 + S_FIRST]
    mov [rbp - 72], r11
    mov r11, [r10 + S_END]
    mov [rbp - 80], r11

    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 56]
    mov ARG3, S_ENTRIES
    mov ARG4, [rbp - 64]            ; the position, out of its slot: the save
    call queue_slot_at              ; above needed the register it was in
    test rax, rax
    jz .r_state
    mov r10, [rbp - 48]
    PASS_ARG6 r10
    mov r10, [rbp - 40]
    PASS_ARG5 r10
    mov ARG4, [rbp - 32]
    mov ARG3, rax
    mov ARG2, [rbp - 16]
    mov ARG1, [rbp - 8]
    call queue_slot_copy
    test eax, eax
    jnz .r_done

    ; And now the reader has seen it. The page is copied for this, because a
    ; position is state and a commit is what makes state true.
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    lea ARG3, [rbp - 56]
    call db_catalog_edit
    test eax, eax
    jnz .r_done
    mov r10, [rbp - 56]
    mov r11, [rbp - 72]
    mov [r10 + S_FIRST], r11
    mov r11, [rbp - 80]
    mov [r10 + S_END], r11
    mov ARG1, r10
    mov ARG2, [rbp - 24]
    call stream_cursor_slot
    mov rdx, [rbp - 64]
    inc rdx
    mov [rax + SCUR_POSITION], rdx
    mov ARG1, [rbp - 56]
    call db_catalog_seal
    xor eax, eax
    jmp .r_done
.r_caught_up:
    mov eax, CybouDB_E_NOTFOUND
    jmp .r_done
.r_state:
    mov eax, CybouDB_E_STATE
.r_done:
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  db_stream_trim(ctx, stream id, position) -> RAX: result code
;
;  Everything before that position stops being kept: the extent chain of each
;  record dropped, and then every segment that is now entirely behind the new
;  beginning.
;
;  A trim may not pass the slowest cursor. A reader whose position is behind it
;  would be asked, on its next read, for a record that is no longer there, and
;  there is no good answer to that - skipping loses data a reader was promised,
;  failing leaves it stuck forever. Refusing is the only answer that keeps both
;  promises, and the escape hatch is DROP CURSOR, which is explicit.
;
;  Trimming to a position already behind the beginning is nothing to do rather
;  than an error: the records are gone, which is what was asked for.
;
;  Local slots: [rbp-8]=ctx, [rbp-16]=id, [rbp-24]=position, [rbp-32]=page,
;               [rbp-40]=first, [rbp-48]=end, [rbp-56]=segments,
;               [rbp-64]=first segment, [rbp-72]=walk, [rbp-80]=dropped,
;               [rbp-88]=kept, [rbp-96]=the new first segment
; -----------------------------------------------------------------------------
db_stream_trim:
    FRAME_BEGIN 128, 0
    mov [rbp - 8], ARG1
    mov [rbp - 16], ARG2
    mov [rbp - 24], ARG3
    mov r10, ARG1
    test qword [r10 + DB_FEATURES], CybouDB_FEATURE_STREAM
    jz .t_state

    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    call db_catalog_page
    test rax, rax
    jz .t_state
    cmp dword [rax + CAT_TYPE], CAT_STREAM
    jne .t_state
    mov [rbp - 32], rax
    mov rdx, [rax + S_FIRST]
    mov [rbp - 40], rdx
    mov rcx, [rax + S_END]
    mov [rbp - 48], rcx
    mov r11, [rbp - 24]
    cmp r11, rcx
    ja .t_value                     ; past what the stream has ever held
    cmp r11, rdx
    jbe .t_nothing                  ; already behind the beginning

    ; No reader left behind. Asked before anything is copied.
    mov qword [rbp - 72], 0
.t_reader:
    mov r10, [rbp - 32]
    mov rax, [rbp - 72]
    cmp rax, [r10 + S_CURSORS]
    jae .t_readers_ok
    shl rax, 5                      ; SCUR_SIZE
    mov r11, [r10 + S_CURSOR_TABLE + rax + SCUR_POSITION]
    cmp r11, [rbp - 24]
    jb .t_retained
    inc qword [rbp - 72]
    jmp .t_reader
.t_readers_ok:

    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 16]
    lea ARG3, [rbp - 32]
    call db_catalog_edit
    test eax, eax
    jnz .t_done
    ; stamp clears the span the positions live in; the segment fields and the
    ; cursor table are outside it and came across with the copy.
    mov r10, [rbp - 32]
    mov rax, [rbp - 40]
    mov [r10 + S_FIRST], rax
    mov rax, [rbp - 48]
    mov [r10 + S_END], rax
    mov ecx, [r10 + S_SEGMENTS]
    mov [rbp - 56], rcx
    mov rdx, [r10 + S_FIRST_SEG]
    mov [rbp - 64], rdx

    ; The chains of the records being dropped, while the directory that
    ; reaches them is still the old one.
    mov rax, [rbp - 40]
    mov [rbp - 72], rax
.t_record:
    mov rax, [rbp - 72]
    cmp rax, [rbp - 24]
    jae .t_records_done
    mov ARG1, [rbp - 8]
    mov ARG2, [rbp - 32]
    mov ARG3, S_ENTRIES
    mov ARG4, [rbp - 72]
    call queue_slot_at
    test rax, rax
    jz .t_state
    mov ecx, [rax + QMSG_FLAGS]
    test ecx, QMSG_FLAG_EXTENT
    jz .t_record_next
    mov r11, [rax + QMSG_EXTENT]
    mov ARG1, [rbp - 8]
    mov ARG2, r11
    call queue_retire_chain
.t_record_next:
    inc qword [rbp - 72]
    jmp .t_record
.t_records_done:

    ; How much of the directory the new beginning leaves behind. A stream
    ; trimmed to its end names no segment at all, exactly as a drained queue
    ; does; otherwise it keeps whatever the new beginning is standing in.
    mov rax, [rbp - 24]
    xor edx, edx
    mov rcx, QUEUE_SEG_SLOTS
    div rcx
    mov [rbp - 96], rax             ; the segment the new beginning is in
    mov rdx, [rbp - 24]
    cmp rdx, [rbp - 48]
    jne .t_keeping
    mov rax, [rbp - 56]
    mov [rbp - 80], rax             ; emptied: every entry goes
    mov qword [rbp - 88], 0
    jmp .t_counted
.t_keeping:
    mov rax, [rbp - 96]
    sub rax, [rbp - 64]
    mov [rbp - 80], rax
    mov rdx, [rbp - 56]
    sub rdx, rax
    mov [rbp - 88], rdx
.t_counted:

    ; The segments behind it have nothing left to give.
    mov qword [rbp - 72], 0
.t_retire:
    mov rax, [rbp - 72]
    cmp rax, [rbp - 80]
    jae .t_retired
    mov r11, [rbp - 32]
    add r11, S_ENTRIES
    mov ARG2, [r11 + rax * 8]
    mov ARG1, [rbp - 8]
    call db_bitmap_retire
    inc qword [rbp - 72]
    jmp .t_retire
.t_retired:
    cmp qword [rbp - 80], 0
    je .t_publish                   ; nothing moved, so nothing to shift

    ; What is left moves down to entry zero.
    mov r11, [rbp - 32]
    add r11, S_ENTRIES
    mov rcx, [rbp - 80]
    xor edx, edx
.t_move:
    cmp rdx, [rbp - 88]
    jae .t_moved
    mov r9, rdx
    add r9, rcx
    mov r8, [r11 + r9 * 8]
    mov [r11 + rdx * 8], r8
    inc rdx
    jmp .t_move
.t_moved:
    ; And what used to be beyond them is zero, as every tail here is.
    mov rax, [rbp - 88]
.t_clear:
    cmp rax, [rbp - 56]
    jae .t_publish
    mov qword [r11 + rax * 8], 0
    inc rax
    jmp .t_clear

.t_publish:
    mov r10, [rbp - 32]
    mov rax, [rbp - 24]
    mov [r10 + S_FIRST], rax
    mov rax, [rbp - 48]
    mov [r10 + S_END], rax
    mov rax, [rbp - 88]
    mov [r10 + S_SEGMENTS], eax
    mov rax, [rbp - 96]
    mov [r10 + S_FIRST_SEG], rax
    mov ARG1, r10
    call db_catalog_seal
    xor eax, eax
    jmp .t_done
.t_nothing:
    xor eax, eax
    jmp .t_done
.t_value:
    mov eax, CybouDB_E_VALUE
    jmp .t_done
.t_retained:
    mov eax, CybouDB_E_RETAINED
    jmp .t_done
.t_state:
    mov eax, CybouDB_E_STATE
.t_done:
    FRAME_END
    ret
