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
; What this open is for. Three questions were tangled together until they were
; given separate answers; see docs/RECOVERY.md.
;
;   recovery   a normal open finds the newest generation that validates and
;              falls back to the one before it. Falling back is success.
;   commit     proves what this transaction publishes.
;   integrity  says whether the file is damaged, even when the damage is
;              recoverable - which a recovering open, by construction, cannot.
;
; DB_VERIFY carries policy bits rather than a flag. Anything nonzero still
; means "deep", so every existing `cmp DB_VERIFY, 0` reads the same.
%define CybouDB_VERIFY_DEEP      1         ; prove every page, not only new ones
%define CybouDB_VERIFY_INTEGRITY 2         ; report damage instead of recovering
%define DB_VERIFY         152           ; policy bits, 0 for an ordinary open
%define DB_TX_ACTIVE      160           ; qword: 1 if inside explicit transaction, 0 if autocommit
%define DB_TX_ID          168           ; qword: monotonic transaction sequence counter
; Nonzero once this writer has validated the typed graph while the pages it
; staged were still unpublished. The walk deep-verifies exactly those pages,
; so repeating it per append costs time proportional to what is already
; staged; doing it once per transaction, and again at the commit that decides
; durability, protects the same boundary without the quadratic term. Cleared
; wherever staged state is published or discarded.
%define DB_VALIDATED      176           ; qword: graph checked in this transaction
; Set when a superblock whose own checksum verifies turns out to publish a
; graph that does not. That is not the residue of an interrupted publication -
; a torn superblock fails its own checksum and never gets this far - so it is
; damage to pages the engine had already proved, and recovery hides it.
%define DB_DAMAGED        184           ; qword: a valid superblock, a bad graph

; --- the transaction change-set ---------------------------------------------
; What this transaction did to the allocation map, as (page, from, to) rather
; than as a map to be diffed. A commit that knows what changed can prove the
; change instead of re-proving the graph; see docs/COMMIT_VALIDATION.md.
;
; The log is allocated on first use and kept for the life of the descriptor,
; so a transaction never pays for it twice and a commit never fails for want
; of it. If it cannot be allocated, or a transaction makes more transitions
; than it holds, DB_CS_OVERFLOW is set and stays set until the transaction
; ends: an incomplete log must never be treated as a complete one, and the
; only safe reading of it is the exhaustive walk the engine does today.
%define DB_CS_LOG         192           ; qword: transition log, 0 = none yet
%define DB_CS_COUNT       200           ; qword: transitions this transaction
%define DB_CS_OVERFLOW    208           ; qword: 1 = the log is not complete
%define DB_CS_AUDIT       216           ; qword: 1 = prove the log at commit
%define CybouDB_DB_SIZE      224

; Entries in the log: page id, then the two states packed into one qword so an
; entry is 16 bytes and the whole thing is a flat array with no allocator.
%define CS_ENTRY_SIZE     16
%define CS_ENTRY_PAGE     0
%define CS_ENTRY_STATES   8             ; from | (to << 8)
%define CybouDB_CS_CAPACITY  8192          ; 128 KiB; past this, overflow

; --- Transaction States ---
%define CybouDB_TX_NONE      0
%define CybouDB_TX_ACTIVE    1

%endif ; CybouDB_INC
