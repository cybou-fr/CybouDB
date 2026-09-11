; Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
; SPDX-License-Identifier: Apache-2.0
; Persistent variable-width TEXT/BLOB extent contract.
%ifndef CybouDB_VARLEN_INC
%define CybouDB_VARLEN_INC

%define VAR_MAGIC_VALUE 0x56515341      ; ASQV
%define VAR_VERSION_VALUE 1
%define VAR_MAGIC 0
%define VAR_VERSION 4
%define VAR_PAGE_ID 8
%define VAR_GENERATION 16
%define VAR_OWNER 24                    ; owning catalog table id
%define VAR_NEXT 32                     ; next extent page id, zero on final page
%define VAR_USED 40                     ; payload bytes used in this page
%define VAR_RESERVED 44
%define VAR_RESERVED_SIZE 20
%define VAR_DATA 64
%define VAR_CRC 4092
%define VAR_PAYLOAD_SIZE (VAR_CRC - VAR_DATA)

; Persistent PAX cell descriptor. Empty non-NULL values are {0, 0}; NULL is
; represented only by the existing PAX NULL mask.
%define VAR_CELL_ROOT 0                 ; first extent page id
%define VAR_CELL_LENGTH 8               ; logical byte length
%define VAR_CELL_SIZE 16

%endif
