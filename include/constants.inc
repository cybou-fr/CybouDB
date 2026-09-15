; Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
; SPDX-License-Identifier: Apache-2.0
; =============================================================================
;  constants.inc - Engine-wide CybouDB constants
; =============================================================================
;  Only things that depend on neither the CPU architecture nor the OS:
;  the format signature, the version, core error codes and process exit codes.
; =============================================================================

%ifndef CybouDB_CONSTANTS_INC
%define CybouDB_CONSTANTS_INC

; --- Format identification ---------------------------------------------------
%define CybouDB_MAGIC        0x4C515341    ; 'A','S','Q','L' in little-endian order
%define CybouDB_VERSION      1

; --- Core error codes --------------------------------------------------------
;  Returned in RAX by the db_* functions. Zero means success, anything else
;  is a failure. The values double as an index into the CLI message table,
;  so they must stay consecutive and gap-free.
%define CybouDB_OK           0
%define CybouDB_E_PAGES      1             ; invalid page count
%define CybouDB_E_CREATE     2             ; cannot create the file
%define CybouDB_E_OPEN       3             ; cannot open the file
%define CybouDB_E_SIZE       4             ; cannot query the file size
%define CybouDB_E_SMALL      5             ; file smaller than the metadata pages
%define CybouDB_E_MAP        6             ; memory mapping failed
%define CybouDB_E_MAGIC      7             ; foreign signature
%define CybouDB_E_VERSION    8             ; unsupported format version
%define CybouDB_E_PAGESIZE   9             ; unsupported page size
%define CybouDB_E_HDR_CRC    10            ; file header checksum mismatch
%define CybouDB_E_FEATURES   11            ; unknown incompatible feature bits
%define CybouDB_E_SUPERBLOCK 12            ; no superblock copy verifies
%define CybouDB_E_GEOMETRY   13            ; page counts disagree with the file
%define CybouDB_E_EXISTS     14            ; refusing to overwrite an existing file
%define CybouDB_E_FULL       15            ; no page left to hand out
%define CybouDB_E_FREELIST   16            ; the free list is corrupt
%define CybouDB_E_PAGE       17            ; page id outside the allocatable range
%define CybouDB_E_READONLY   18            ; the database was opened read-only
%define CybouDB_E_SYNC       19            ; the commit could not reach the disk
%define CybouDB_E_NOENT      20            ; the path does not exist
%define CybouDB_E_ACCESS     21            ; the OS refused permission
%define CybouDB_E_STATE      22            ; invalid mutation mode or failed handle
%define CybouDB_E_GENERATION 23            ; generation counter exhausted
%define CybouDB_E_BITMAP     24            ; staged allocation state is inconsistent
%define CybouDB_E_COW_PAGES  25            ; outside the single-map capacity
%define CybouDB_E_CATALOG    26            ; invalid catalog graph
%define CybouDB_E_SCHEMA     27            ; invalid schema or duplicate table name
%define CybouDB_E_NOTFOUND   28            ; table id absent from catalog
%define CybouDB_E_CATALOG_FULL 29          ; directory capacity reached
%define CybouDB_E_ROWS       30            ; invalid batch count or row index
%define CybouDB_E_PAX        31            ; invalid PAX data page
%define CybouDB_E_VALUE      32            ; invalid scalar value or NULL constraint
%define CybouDB_E_BUSY       33            ; another writer owns the database
%define CybouDB_E_CURSOR     34            ; no reader of that name on the stream
%define CybouDB_E_RETAINED   35            ; a reader still needs what a trim would drop
; A superblock that verifies published a graph that does not. The file is
; still readable - an older generation is intact and an ordinary open recovers
; to it - but pages this engine had already proved have been damaged since.
; Only an open asking for CybouDB_VERIFY_INTEGRITY is told, because recovering
; is the right answer to every other question.
%define CybouDB_E_DAMAGED    36
; A lease operation refused: the message is not claimed, or the token is not
; the one the current claim has. Routine rather than exceptional - it is what a
; worker whose lease was reclaimed is told - so it says so rather than sharing
; a message with a bad column value.
%define CybouDB_E_LEASE      37
; --- what a database sealed with a key can refuse with -----------------------
;  docs/KEY_HIERARCHY.md, step 4. These three exist so that an engine never has
;  to say one sentence for three different situations. A user who is told
;  "damaged" reaches for a backup; a user who is told "this key does not open
;  this file" reaches for the other passphrase. Collapsing them costs the first
;  user nothing and costs the second one their afternoon.
;
;  A failed unwrap is ALWAYS E_KEY and never a damage code. It cannot be
;  anything else: an AEAD tag that does not verify is what a wrong key looks
;  like, what a flipped bit looks like, and what an attacker looks like, and
;  the file cannot tell them apart. Of those three the only one the engine may
;  assert is the one that does not accuse the storage of being broken.
%define CybouDB_E_KEY         38            ; this key does not open this file
%define CybouDB_E_CRYPTO_ROOT 39            ; the crypto root page contradicts itself
%define CybouDB_E_CRYPTO_CRC  40            ; the crypto root page is damaged

; A mistyped recovery phrase is decidable without the file - the checksum says
; so - which makes it a different sentence from a phrase that is well formed
; and belongs to another database. One is "that is not a phrase we wrote", the
; other is CybouDB_E_KEY.
%define CybouDB_E_PHRASE      41            ; the phrase does not checksum

; A page whose tag does not verify was altered, or damaged in a way the CRC
; cannot see. The engine cannot tell those apart and does not pretend to: the
; sentence names both, because naming only one of them would be a guess about
; whether there is an adversary.
%define CybouDB_E_SEAL        42            ; a page is not the one that was written

; A database that is encrypted and was opened without a key. Not E_FEATURES -
; this build implements the feature - and not E_KEY, which means a key was
; offered and did not fit. The difference matters to the person reading it:
; one says "upgrade", another says "wrong key", this one says "bring a key".
%define CybouDB_E_NEEDS_KEY   43            ; encrypted, and no key was offered

%define CybouDB_E_COUNT      44            ; size of the message table

; --- Why an operating system call failed -------------------------------------
;  The platform layer translates its native error - errno on Linux, the Win32
;  error code on Windows - into one of these before handing it up. Core code
;  must never see a raw errno: the numbers differ between systems, and mapping
;  them in core/ would put OS knowledge exactly where it does not belong.
;
;  Everything not worth distinguishing collapses into OTHER on purpose. These
;  four are the ones a caller can actually do something about.
%define CybouDB_OSERR_NONE   0
%define CybouDB_OSERR_NOENT  1             ; no such file or directory
%define CybouDB_OSERR_ACCESS 2             ; permission denied
%define CybouDB_OSERR_EXISTS 3             ; the path is already taken
%define CybouDB_OSERR_OTHER  4
%define CybouDB_OSERR_BUSY   5             ; sharing/advisory writer lock conflict

; --- Process exit codes ------------------------------------------------------
%define EXIT_OK           0
%define EXIT_USAGE        1
%define EXIT_FAILURE      2

%endif ; CybouDB_CONSTANTS_INC
