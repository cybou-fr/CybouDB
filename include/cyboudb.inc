; Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
; SPDX-License-Identifier: Apache-2.0
; =============================================================================
;  cyboudb.inc - Master header of the CybouDB engine
; =============================================================================
;  The only file a module needs to include: it pulls in the ABI layer, the
;  constants, the page model and the file format.
;
;  It also describes the open-database descriptor (CybouDB_DB) through which the
;  core exposes the whole state of a zero-copy connection to a file.
;  There are deliberately no extern lists here: a symbol cannot be declared
;  both global and extern, so each module declares only what it imports.
; =============================================================================

%ifndef CybouDB_INC
%define CybouDB_INC

%include "abi.inc"
%include "constants.inc"
%include "page.inc"
%include "format.inc"
%include "catalog.inc"
%include "pax.inc"
%include "varlen.inc"
%include "zonemap.inc"
%include "index.inc"
%include "queue.inc"
%include "stream.inc"

; -----------------------------------------------------------------------------
;  CybouDB_DB - open database descriptor (CybouDB_DB_SIZE bytes).
;
;  Filled in by db_open, released by db_close. The base field is the address
;  the file is mapped at: the header and the pages are to be read straight
;  from there, the engine keeps no buffers of its own.
; -----------------------------------------------------------------------------
%define DB_HANDLE         0             ; qword: file descriptor (HANDLE / fd)
%define DB_BASE           8             ; qword: address of the file mapping
%define DB_SIZE           16            ; qword: file size in bytes
%define DB_PAGES          24            ; qword: total_pages, live superblock
%define DB_ALLOC          32            ; qword: allocated_pages, live superblock
%define DB_GENERATION     40            ; qword: generation of that superblock
%define DB_SB_PAGE        48            ; qword: which copy won, 1 or 2
%define DB_SB_PTR         56            ; qword: address of that superblock
%define DB_FREELIST       64            ; qword: first free page, 0 when none
%define DB_WRITABLE       72            ; qword: 1 when opened for writing
%define DB_ROOT           80            ; qword: catalog root, 0 when absent
%define DB_MODE           88            ; 0 legacy, 1 COW, -1 failed sync
%define DB_COW_FLOOR      96            ; pages below this are immutable
%define DB_FEATURES       104           ; immutable incompatible capabilities
%define DB_BITMAP         112           ; selected/staged allocation-map page
%define DB_REUSE_NEXT     120           ; sweep cursor for reclaimed pages
%define DB_REUSABLE       128           ; retired pages the allocator may take
%define DB_DIRTY_LO       136           ; pages this transaction wrote, [lo, hi)
%define DB_DIRTY_HI       144           ; hi = 0 means it wrote none
%define DB_VERIFY         152           ; 1 = check every page, not just the new
%define DB_TX_ACTIVE      160           ; qword: 1 if inside explicit transaction, 0 if autocommit
%define DB_TX_ID          168           ; qword: monotonic transaction sequence counter
; Nonzero once this writer has validated the typed graph while the pages it
; staged were still unpublished. The walk deep-verifies exactly those pages,
; so repeating it per append costs time proportional to what is already
; staged; doing it once per transaction, and again at the commit that decides
; durability, protects the same boundary without the quadratic term. Cleared
; wherever staged state is published or discarded.
%define DB_VALIDATED      176           ; qword: graph checked in this transaction
%define CybouDB_DB_SIZE      184

; --- Transaction States ---
%define CybouDB_TX_NONE      0
%define CybouDB_TX_ACTIVE    1

%endif ; CybouDB_INC
