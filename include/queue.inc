; Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
; SPDX-License-Identifier: Apache-2.0
; Durable FIFO queues, enabled only with CybouDB_FEATURE_QUEUE. See
; docs/QUEUE.md for why a queue here is addressed by position rather than
; threaded on pointers, and for what a commit proves about one.
%ifndef CybouDB_QUEUE_INC
%define CybouDB_QUEUE_INC

; --- The catalog page that defines one queue, CAT_TYPE = CAT_QUEUE ------------
; A fourth page type in the directory, in the same id space as tables and
; indexes and sharing their namespace. It reuses the catalog header, so the
; fields below either alias one of those or live in what a schema page spends
; on columns.
%define CAT_QUEUE 4


%define Q_SEGMENTS 36                    ; aliases CAT_COUNT: entries below
%define Q_HEAD 40                        ; the oldest position still held
%define Q_TAIL 48                        ; the position the next message takes
%define Q_RESERVED 56                    ; 8 bytes, zero
%define Q_NAME 64                        ; aliases CAT_TABLE_NAME: one namespace
%define Q_FIRST_SEG 96                   ; the segment index entry zero names
%define Q_RESERVED2 104                  ; 16 bytes, zero
%define Q_ENTRIES 128                    ; u64 segment page ids, in order
%define Q_CRC 4092
%define Q_MAX_SEGMENTS 495               ; (4092 - 128) / 8

; --- A segment page ----------------------------------------------------------
; An ordinary payload page holding a fixed run of message slots. Which segment
; a position belongs to, and which slot inside it, is arithmetic on the
; position - there is no pointer to follow and none to keep correct.
%define QSEG_MAGIC_VALUE 0x51515341      ; ASQQ
%define QSEG_VERSION_VALUE 1
%define QSEG_MAGIC 0
%define QSEG_VERSION 4
%define QSEG_PAGE_ID 8
%define QSEG_GENERATION 16
%define QSEG_OWNER 24                    ; the queue id
%define QSEG_FIRST 32                    ; the first position this segment holds
%define QSEG_RESERVED 40                 ; 24 bytes, zero
%define QSEG_SLOTS 64
%define QSEG_CRC 4092

%define QUEUE_SLOT_SIZE 64
%define QUEUE_SEG_SLOTS 62               ; (4092 - 64) / 64

; --- A message slot ----------------------------------------------------------
; A payload of QMSG_INLINE_MAX bytes or fewer sits in the slot. A longer one is
; a varlen extent chain owned by the queue id, which is the same machinery a
; TEXT cell uses and the reason the queue does not invent a second one.
%define QMSG_LENGTH 0                    ; u32 payload bytes
%define QMSG_FLAGS 4                     ; u32
%define QMSG_PAYLOAD 8                   ; QMSG_INLINE_MAX bytes
%define QMSG_EXTENT 8                    ; or the chain's first page id
%define QMSG_RESERVED 56                 ; 8 bytes, zero
%define QMSG_INLINE_MAX 48
%define QMSG_FLAG_EXTENT 1

%endif
