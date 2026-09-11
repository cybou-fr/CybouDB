; Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
; SPDX-License-Identifier: Apache-2.0
; Per-leaf zone metadata, with CybouDB_FEATURE_ZONE_MAPS.
;
; A zone entry summarises what one column holds inside one PAX leaf: whether it
; has any values at all, whether any of them are NULL, and the range the
; comparable ones fall in. A scan can then decide a whole leaf against a
; predicate - impossible, always true, or must be evaluated - before it maps a
; single column page.
;
; The metadata lives beside the data rather than inside it. A PAX leaf is
; byte-for-byte what it was before this feature, and a table's stats hang off
; CAT_STATS_ROOT, an eight-byte field the schema page already reserved and
; validated as zero. A build without the feature therefore refuses to open a
; database that carries it, rather than silently ignoring metadata it would not
; maintain.
;
; See docs/ZONEMAP.md.
%ifndef CybouDB_ZONEMAP_INC
%define CybouDB_ZONEMAP_INC

; The schema page's reserved eight bytes at offset 56, zero in every database
; written without this feature and validated as zero by every build without it.
%define CAT_STATS_ROOT 56

%define ZONE_MAGIC_VALUE 0x5A515341      ; ASQZ
%define ZONE_VERSION_VALUE 1

; Page header, laid out like a PAX directory page so the same validation shape
; applies: magic, version, identity, generation and owner, then what the page
; describes.
%define ZONE_MAGIC 0
%define ZONE_VERSION 4
%define ZONE_PAGE_ID 8
%define ZONE_GENERATION 16
%define ZONE_OWNER 24                    ; catalog owner of the table
%define ZONE_LEVEL 32                    ; ZONE_LEAF, ZONE_DIR or ZONE_ROOT
%define ZONE_COUNT 36                    ; entries in use on this page
%define ZONE_FIRST 40                    ; index of the first leaf described
%define ZONE_STRIDE 48                   ; bytes per described leaf
%define ZONE_RESERVED 56
%define ZONE_DATA 64
%define ZONE_CRC 4092

; Level 0 pages carry leaf statistics; level 1 names level-0 pages; level 2
; names level-1 pages. A table small enough for one page of statistics has a
; level-0 page as its root, so nothing pays for depth it does not need.
%define ZONE_LEAF 0
%define ZONE_DIR 1
%define ZONE_ROOT 2

; A directory entry is a page id and the first leaf index that page describes,
; the same sixteen bytes a PAX directory entry uses.
%define ZONE_ENTRY_PAGE 0
%define ZONE_ENTRY_FIRST 8
%define ZONE_ENTRY_SIZE 16
%define ZONE_DIR_MAX 251                 ; (4092 - 64) / 16

; One column's statistics inside one leaf.
;
; MIN and MAX describe only comparable values: NULLs are excluded, and so is
; NaN, which compares false against everything and would otherwise widen a
; range that no predicate can use. FLOAT32 keeps the binary32 bit pattern
; zero-extended into the eight-byte slot, so a reader loads it as a float
; rather than reinterpreting an integer.
%define ZSTAT_FLAGS 0
%define ZSTAT_MIN 8
%define ZSTAT_MAX 16
%define ZSTAT_SIZE 24

%define ZSTAT_HAS_COMPARABLE 1           ; at least one non-NULL, non-NaN value
%define ZSTAT_HAS_NULLS 2                ; at least one NULL
%define ZSTAT_HAS_NAN 4                  ; FLOAT32 only, excluded from MIN/MAX
%define ZSTAT_HAS_FALSE 8                ; BOOL only
%define ZSTAT_HAS_TRUE 16                ; BOOL only

; What a zone test concluded about one leaf, before any column page is read.
%define ZONE_TEST_UNKNOWN 0              ; evaluate the predicate per row
%define ZONE_TEST_NONE 1                 ; no row in this leaf can match
%define ZONE_TEST_ALL 2                  ; every row in this leaf matches

%endif
