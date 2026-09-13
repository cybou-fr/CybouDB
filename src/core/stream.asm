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
global stream_page_valid

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
