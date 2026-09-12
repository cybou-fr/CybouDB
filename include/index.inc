; Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
; SPDX-License-Identifier: Apache-2.0
; Secondary B+tree indexes. Requires COW + catalog + PAX, and
; CybouDB_FEATURE_INDEX. The decisions behind this layout are in
; docs/INDEX.md; what follows is only where the bytes are.
%ifndef CybouDB_INDEX_INC
%define CybouDB_INDEX_INC

; --- The catalog page that defines one index, CAT_TYPE = CAT_INDEX -----------
; It carries the catalog header, so CAT_MAGIC, CAT_VERSION, CAT_PAGE_ID,
; CAT_GENERATION and CAT_CRC mean what they mean on every directory-reachable
; page. CAT_OWNER names the indexed table, which is what makes "every index of
; this table" a walk of the directory rather than a second structure to keep
; consistent.
%define CAT_INDEX 3
%define IDX_ROOT 40                      ; tree root page, 0 while empty
%define IDX_COLUMN 48                    ; indexed column, its schema position
%define IDX_FLAGS 52
%define IDX_ROWS 56                      ; entries the tree holds
%define IDX_NAME 64
%define IDX_NAME_SIZE 32
%define IDX_UNIQUE 1                     ; IDX_FLAGS bit 0

; --- A tree node -------------------------------------------------------------
; One page. Leaves and internal nodes share every field; only the meaning of an
; entry differs, and the level says which it is.
%define IDX_MAGIC_VALUE 0x49515341       ; ASQI
%define IDX_VERSION_VALUE 1
%define IDX_PAGE_ID 8
%define IDX_GENERATION 16
%define IDX_OWNER 24                     ; the index id, not the table id
%define IDX_LEVEL 32                     ; 0 is a leaf, higher is internal
%define IDX_COUNT 36                     ; entries in this node
%define IDX_NEXT 40                      ; next leaf at this level, 0 at the end
%define IDX_RESERVED 48                  ; 16 bytes, zero
%define IDX_ENTRIES 64
%define IDX_CRC 4092
%define IDX_LEAF 0

; An entry is 16 bytes in both node kinds, which is what caps a node at 251 of
; them - the fan-out the PAX directory has, for the same reason.
%define IDX_ENTRY_SIZE 16
%define IDX_MAX_ENTRIES 251              ; (4092 - 64) / 16

; Leaf entry: the key, sign-extended to 64 bits, and the row it names.
%define IDX_KEY 0
%define IDX_ROW 8

; Internal entry: a child, and the largest key anywhere beneath it. Strictly
; increasing by IDX_KEY_END, so a search takes the first entry whose end is not
; smaller than the key it wants. Deliberately the shape PAX_DIRECTORY already
; uses: a second kind of downward walk costs more than any separator-key layout
; would save.
%define IDX_CHILD 0
%define IDX_KEY_END 8

%endif ; CybouDB_INDEX_INC
