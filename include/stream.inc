; Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
; SPDX-License-Identifier: Apache-2.0
; Append-only streams, enabled only with CybouDB_FEATURE_STREAM. See
; docs/STREAM.md for why a stream is not a queue with extra readers, and why
; it is nonetheless stored in a queue's segments.
%ifndef CybouDB_STREAM_INC
%define CybouDB_STREAM_INC

; --- The catalog page that defines one stream, CAT_TYPE = CAT_STREAM ---------
; A fifth page type in the directory, in the same id space and namespace as
; tables, indexes and queues. The header is the queue's header with the two
; positions renamed: a reader of one file format should not have to learn two
; names for the same arithmetic.
%define CAT_STREAM 5

%define S_SEGMENTS 36                    ; aliases CAT_COUNT: directory entries
%define S_FIRST 40                       ; the oldest position still kept
%define S_END 48                         ; the position the next record takes
%define S_RESERVED 56                    ; 8 bytes, zero
%define S_NAME 64                        ; aliases CAT_TABLE_NAME: one namespace
%define S_FIRST_SEG 96                   ; the segment index entry zero names
%define S_CURSORS 104                    ; cursors in use, 0..S_MAX_CURSORS
; 16 bytes, zero. Room for what a retention policy would need - a count, a
; limit, the bits saying which applies - when there is one to defend.
%define S_RESERVED2 112
%define S_CURSOR_TABLE 128
%define S_ENTRIES 384                    ; u64 segment page ids, in order
%define S_CRC 4092
%define S_MAX_CURSORS 8
%define S_MAX_SEGMENTS 463               ; (4092 - 384) / 8

; --- A cursor ----------------------------------------------------------------
; A durable, named reader - not a connection. A process that wants to read
; without leaving anything behind reads by position and keeps its own place.
%define SCUR_NAME 0                      ; 24 bytes, NUL-padded
%define SCUR_POSITION 24                 ; the next position it will read
%define SCUR_SIZE 32
%define SCUR_NAME_MAX 23

; A record lives in a queue segment page, in a queue message slot, and reaches
; a varlen extent when it does not fit one. See include/queue.inc: one storage
; shape, two objects, and one validator for both.

%endif
