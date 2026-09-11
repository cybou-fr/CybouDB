; Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
; SPDX-License-Identifier: Apache-2.0
; =============================================================================
;  page.inc - CybouDB page model
; =============================================================================
;  A database file is an array of fixed-size pages. Page 0 is reserved: its
;  first 128 bytes hold the database header (see format.inc).
;
;  4096 bytes is the LOGICAL page size of the database - a property of the
;  file format, not of the machine. It is chosen because it matches the most
;  common OS page size, so in the common case a database page boundary also
;  falls on an OS page boundary.
;
;  It must never be assumed to equal the OS page size:
;    * AArch64 Linux supports 4 KiB, 16 KiB and 64 KiB base page granules,
;      and macOS on Apple silicon uses 16 KiB;
;    * on Windows the offset of a mapped view must be a multiple of the
;      system allocation granularity (64 KiB), which is unrelated to this.
;
;  Today nothing depends on the difference, because the VFS maps whole files
;  from offset 0. Once windowed mapping of a large database arrives, the VFS
;  will have to query the real os_page_size and mapping_granularity and align
;  its windows to those - while this constant stays 4096.
; =============================================================================

%ifndef CybouDB_PAGE_INC
%define CybouDB_PAGE_INC

%define CybouDB_PAGE_SIZE    4096
%define CybouDB_PAGE_SHIFT   12            ; 1 << 12 == 4096
%define CybouDB_HEADER_PAGE  0             ; index of the reserved page

; Upper bound on the page count: anything larger would overflow the 64-bit
; file size in the pages * PAGE_SIZE product.
%define CybouDB_MAX_PAGES    ((1 << (64 - CybouDB_PAGE_SHIFT)) - 1)

; -----------------------------------------------------------------------------
;  PAGES_TO_BYTES <register> - convert a page count into a byte size.
;  A shift rather than a multiply: the page size is a power of two.
; -----------------------------------------------------------------------------
%macro PAGES_TO_BYTES 1
    shl     %1, CybouDB_PAGE_SHIFT
%endmacro

; -----------------------------------------------------------------------------
;  PAGE_ADDR <destination>, <mapping base>, <page index>
;  Address of the start of a page inside the mapped file.
; -----------------------------------------------------------------------------
%macro PAGE_ADDR 3
    mov     %1, %3
    PAGES_TO_BYTES %1
    add     %1, %2
%endmacro

%endif ; CybouDB_PAGE_INC
