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
; Set by db_commit while it validates the candidate it has staged. Outside
; that, the published and staged map copies differ for reasons no change-set
; describes - db_open is looking at generations this process did not write -
; so the leaf check would be asking a question that has no answer.
%define DB_CS_PROVE       224           ; qword: 1 = a staged candidate, here

; --- what a transaction wrote, as runs rather than as a hull ----------------
; DB_DIRTY_LO..HI is the smallest range covering every page a transaction
; touched, and a hull is the wrong shape for a flush: one page far from the
; rest widens it to everything in between. That happens in ordinary use - once
; the allocator starts reusing retired pages it serves them from the bottom of
; the file while the transaction still writes near the high-water - and it was
; measured at 7,999 pages flushed to publish a change of a few. See
; benchmarks/results/2026-09-14-flush.md.
;
; So the pages are also kept as a small set of contiguous runs. The hull stays:
; it is still what says whether a transaction wrote anything at all, and it is
; what a commit falls back to when there are more runs than fit here. Flushing
; a superset is slow; flushing a subset loses data, so the fallback is the
; hull and never the runs.
%define DB_RUN_N          232           ; qword: runs recorded
%define DB_RUN_OVF        240           ; qword: 1 = did not fit; use the hull
%define DB_RUNS           248           ; CybouDB_DIRTY_RUNS_MAX entries
%define RUN_FIRST         0
%define RUN_COUNT         8
%define RUN_SIZE          16
%define CybouDB_DIRTY_RUNS_MAX 32

; --- what an encrypted database carries, and a plain one does not ------------
;  docs/ENCRYPTED_ENGINE.md. DB_CACHE is the switch the page-address macro
;  branches on: zero for every database that is not encrypted, which is every
;  database that exists today, so the branch predicts perfectly and a plain
;  page address stays a shift and an add.
;
;  The rest is what the resolver needs to build the associated data for a page
;  it has been asked for: the file's identity, the generation the live
;  superblock publishes, the seal epoch the crypto root records, the page seal
;  key of that epoch, and where the seal directory begins. The page's type is
;  not here - it comes out of the nonce, which is Decision 5b.
%define DB_CACHE          (DB_RUNS + CybouDB_DIRTY_RUNS_MAX * RUN_SIZE)
%define DB_SEAL_KEY       (DB_CACHE + 8)      ; 32 bytes
%define DB_UUID           (DB_SEAL_KEY + 32)  ; 16 bytes
%define DB_SEAL_EPOCH     (DB_UUID + 16)
%define DB_SEAL_DIR       (DB_SEAL_EPOCH + 8) ; first leaf page
%define DB_SEAL_LEAVES    (DB_SEAL_DIR + 8)
%define DB_ENC_ERROR      (DB_SEAL_LEAVES + 8); the last seal failure, or zero
; The metadata key, 32 bytes, held for as long as the database is open.
;
;  It is here rather than derived when needed because every commit tags a
;  superblock with it and the root key it comes from is wiped at the end of the
;  open - deliberately, so that the value everything else derives from exists
;  for the shortest time this design allows. That leaves two keys resident: the
;  page seal key, which every miss needs, and this one. Both are epoch keys,
;  both die with the handle, and neither is the root.
%define DB_META_KEY       (DB_ENC_ERROR + 8)
%define DB_TREE_KEY       (DB_META_KEY + 32)   ; 32 bytes: the seal tree's key
%define DB_SEAL_PAGES     (DB_TREE_KEY + 32)   ; pages in one tree copy
%define DB_SEAL_DEPTH     (DB_SEAL_PAGES + 8)  ; root level, one or greater
%define DB_SEAL_ROOT      (DB_SEAL_DEPTH + 8)  ; MAC published by superblock
; --- which seal leaves a transaction changed -------------------------------
; A deep commit wants to touch only the ancestor paths of the leaves this
; transaction actually changed, and by the time it runs, the evidence is gone:
; the flush has already invalidated the ciphertext frames it read them from.
; So the flush writes the leaf indices down as it goes.
;
; The capacity is the journal's own, and deliberately nothing else's. An
; earlier version sized it to the page cache and then refused to attach to a
; cache larger than it - which quietly made an internal scratch array the
; ceiling on the one setting that matters most to an encrypted database's
; speed. It follows DB_RUNS instead: when the list does not fit, say so and
; let the commit fall back to the exhaustive walk. A superset of the work is
; slow; a subset would publish a tree that does not cover the pages under it.
%define DB_DIRTY_LEAF_N   (DB_SEAL_ROOT + 16)  ; snapshot retained by flush
%define DB_DIRTY_LEAF_OVF (DB_DIRTY_LEAF_N + 8); 1 = did not fit; walk them all
%define DB_DIRTY_LEAVES   (DB_DIRTY_LEAF_OVF + 8)
%define CybouDB_DIRTY_LEAF_MAX 256

;  Three keys stay resident while a database is open, and it is worth being
;  able to name all three rather than discovering a fourth later: the page seal
;  key, which every cache miss needs; the seal tree key, which every commit
;  needs to re-MAC the directory; and the metadata key, which tags the
;  superblock. All three belong to one seal epoch and all three die with the
;  handle. The root key is not among them - it is wiped at the end of the open,
;  which is the whole reason these are derived rather than kept.

%define CybouDB_DB_SIZE      (DB_DIRTY_LEAVES + CybouDB_DIRTY_LEAF_MAX * 8)

; Entries in the log: page id, then the two states packed into one qword so an
; entry is 16 bytes and the whole thing is a flat array with no allocator.
%define CS_ENTRY_SIZE     16
%define CS_ENTRY_PAGE     0
%define CS_ENTRY_STATES   8             ; from | (to << 8)
%ifndef CybouDB_CS_CAPACITY
; Overridable so a build can be made to overflow on purpose: an incomplete
; log must send the commit down the exhaustive path, and a capacity nothing
; ever reaches is a branch nothing ever tests. `build.sh --cs-overflow`.
%define CybouDB_CS_CAPACITY  8192          ; 128 KiB; past this, overflow
%endif

; --- Transaction States ---
%define CybouDB_TX_NONE      0
%define CybouDB_TX_ACTIVE    1

%endif ; CybouDB_INC
