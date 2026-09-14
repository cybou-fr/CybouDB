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
%define Q_HEAD 40                        ; the oldest position not acknowledged
%define Q_TAIL 48                        ; the position the next message takes
; The position the next claim would take. Reserved: a version 1 DEQUEUE hands
; out and acknowledges a message in one step, so this always equals Q_HEAD and
; validation says so. It exists because the operation a work queue needs is not
; DEQUEUE but a claim with an expiry, and a claim cursor that can run ahead of
; the oldest unacknowledged message is the one field that cannot be added
; later without moving bytes. See docs/QUEUE.md.
%define Q_CLAIM 56
%define Q_NAME 64                        ; aliases CAT_TABLE_NAME: one namespace
%define Q_FIRST_SEG 96                   ; the segment index entry zero names
; The page holding the internal nodes of the lease index, or zero for a queue
; that has none - which is legal, and means a claim searches by walking. A few
; segments need no tree; the threshold at which one is built is a tuning
; decision and is not in the file, which is what keeps it changeable.
;
; Zero and unused until an engine builds one.
%define Q_AUX_ROOT 104                   ; u64, zero
; What a second level of segment directory would need when 495 segments stops
; being enough, which is the road PAX already took. Leases took the first half
; of what used to be sixteen reserved bytes and deliberately left this: the
; queue that outgrows 495 segments is the one that most needs a bounded claim
; search, so a format letting either eat the other's bytes would have made that
; combination the one it could not express.
%define Q_DIR_ROOT 112                   ; u64, zero
%define Q_RESERVED2 Q_AUX_ROOT           ; the pair, for the checks that span it
; The largest time this queue has ever used, in milliseconds since the Unix
; epoch. Reserved and zero until leases exist. A lease deadline is wall-clock
; time, because it is the only clock that still means anything after the crash
; it exists to survive - and a wall clock jumps. Every operation would take
; max(now, this) and write it back, so the clock a queue uses never runs
; backwards whatever the machine's does. See docs/QUEUE.md, "The clock a lease
; deadline is measured on", for what each direction of jump costs and why the
; lease token rather than the deadline is what keeps an ACK honest.
;
; These eight bytes were unnamed and unchecked through preview.1 and
; preview.2. Every file either of them wrote has them zero - a queue page is
; allocated zeroed and nothing ever wrote here - but validation did not say so,
; and eight bytes nothing requires to be zero are eight bytes a later release
; cannot use.
%define Q_TIME_FLOOR 120
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
; When this segment next has something claimable: zero if it holds a free
; message, the least deadline among its claims if it holds only claims, and
; UINT64_MAX if it holds neither. One u64 that answers the only question a
; search asks, and one a lapse changes without anything writing to it.
;
; It lives here rather than in a central index because every operation that
; changes a slot is already rewriting this page - see docs/QUEUE.md, "Where the
; summary lives", and the measurement it cites.
;
; Zero and unused until an engine builds the index. The check that it is zero
; becomes conditional at that point, the way Q_TIME_FLOOR's did, and is not
; deleted.
%define QSEG_READY_AT 40                 ; u64, zero
%define QSEG_RESERVED 48                 ; 16 bytes, zero
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
; What a message is doing, until when, and under whose claim. Zero throughout
; unless the database carries CybouDB_FEATURE_QUEUE_LEASES, which is decided
; when the file is created.
;
; The token is the slot's fencing history and not a property of being claimed:
; zero means never claimed, and it only ever goes up. So a HELD message may
; carry any token - NACK raises it and leaves the message HELD - and an ACKED
; one keeps the token that finished it, which is what makes a stale ticket
; visibly stale. See docs/QUEUE.md, "What a valid file looks like".
;
; QMSG_RESERVED32 stays reserved with leases and without: it is where a failure
; count would go when there is a dead-letter rule to write against it.
%define QMSG_STATE 8                     ; u32
%define QMSG_RESERVED32 12               ; u32, zero
%define QMSG_LEASE_UNTIL 16              ; u64, zero
%define QMSG_LEASE_TOKEN 24              ; u64, zero
%define QMSG_PAYLOAD 32                  ; QMSG_INLINE_MAX bytes
%define QMSG_EXTENT 32                   ; or the chain's first page id
%define QMSG_INLINE_MAX 32
%define QMSG_FLAG_EXTENT 1
; What a message is doing. HELD is the only one a queue without
; CybouDB_FEATURE_QUEUE_LEASES may carry; the other two are what a lease adds,
; and ACKED is what lets acknowledgement arrive out of order.
%define QMSG_STATE_HELD 0
%define QMSG_STATE_CLAIMED 1
%define QMSG_STATE_ACKED 2

; --- What db_queue_segments_valid is asked to prove ---------------------------
; A stream keeps its records in these same segments, so the walk over them is
; one routine and not two. What differs between a queue and a stream is the
; page that names the segments, which is what the caller has already checked
; by the time it fills this in.
%define QSV_CTX 0
%define QSV_SB 8
%define QSV_OWNER 16                     ; the id a segment must answer to
%define QSV_ENTRIES 24                   ; where entry zero is
%define QSV_TAIL_END 32                  ; where the entries must have stopped
%define QSV_SEGMENTS 40
%define QSV_FIRST_SEG 48
%define QSV_LOW 56                       ; the first position held
%define QSV_HIGH 64                      ; one past the last
%define QSV_MAX_SEG 72
; What the published generation held, so an entry that has not moved can be
; inherited rather than re-proved. Zero in QSV_BASE_ENTRIES means there is no
; published version of this object to compare against - it is new, or this is
; an exhaustive walk - and every entry is validated. See
; docs/COMMIT_VALIDATION.md.
%define QSV_BASE_ENTRIES 80              ; entry zero of the published page, or 0
%define QSV_BASE_SEGMENTS 88
%define QSV_BASE_FIRST_SEG 96
%define QSV_SIZE 104

%endif
