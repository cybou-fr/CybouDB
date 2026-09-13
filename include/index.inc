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
; page.
;
; CAT_OWNER is the index's own id, the same rule a schema page follows, so one
; ownership check in the directory walk serves both page kinds - and so the
; nodes of two indexes over one table are told apart by the owner they carry.
; The table being indexed is a field of its own, and finding every index of a
; table is a walk of the directory rather than a second structure to keep
; consistent.
%define CAT_INDEX 3
%define IDX_ROOT 40                      ; tree root page, 0 while empty
%define IDX_COLUMN 48                    ; indexed column, its schema position
%define IDX_FLAGS 52
%define IDX_ROWS 56                      ; entries the tree holds
%define IDX_NAME 64                      ; aliases CAT_TABLE_NAME: one namespace
%define IDX_NAME_SIZE 32
%define IDX_TABLE 96                     ; the table this indexes
%define IDX_UNIQUE 1                     ; IDX_FLAGS bit 0

; --- A tree node -------------------------------------------------------------
; One page. Leaves and internal nodes share every field; only the meaning of an
; entry differs, and the level says which it is.
%define IDX_MAGIC 0
%define IDX_VERSION 4
%define IDX_MAGIC_VALUE 0x49515341       ; ASQI
%define IDX_VERSION_VALUE 1
%define IDX_PAGE_ID 8
%define IDX_GENERATION 16
%define IDX_OWNER 24                     ; the index id, not the table id
%define IDX_LEVEL 32                     ; 0 is a leaf, higher is internal
%define IDX_COUNT 36                     ; entries in this node
; There is no sibling pointer. A leaf chain and copy-on-write cannot both be
; right: rewriting a leaf gives it a new page id, and its predecessor - which
; is not on the path from the root - would still name the retired one. Keeping
; the chain correct means copying backwards to the first leaf. A range scan
; descends with a path stack instead. See docs/INDEX.md.
; Entries at or below this node. What it buys is that validation can stop
; where a transaction stopped: under copy-on-write a subtree older than the
; candidate generation cannot have changed, so its size can be taken rather
; than walked for. Without it a commit proves the whole index and a one-row
; insert costs the size of the tree.
%define IDX_SUBTREE 40
%define IDX_RESERVED 48                  ; 16 bytes, zero
%define IDX_ENTRIES 64
%define IDX_CRC 4092
%define IDX_LEAF 0

; An entry is 24 bytes in both node kinds, which is what caps a node at 167 of
; them.
;
; The order the tree keeps is on the pair (key, row), not on the key: a key may
; name many rows, more of them than one leaf holds, so equal keys span several
; children and a separator that carried only a key could not say which of them
; an entry belongs to. Every entry therefore carries both halves of the order,
; and a comparison anywhere in the tree is the same lexicographic comparison.
%define IDX_ENTRY_SIZE 24
%define IDX_MAX_ENTRIES 167              ; (4092 - 64) / 24

; Leaf entry: the key, sign-extended to 64 bits, the row it names, and a word
; that is zero - the payload an internal entry spends on its child.
%define IDX_KEY 0
%define IDX_ROW 8

; Internal entry: the largest (key, row) anywhere beneath a child, and that
; child. Strictly increasing by that pair, so a search takes the first entry
; whose end is not smaller than the pair it wants.
%define IDX_KEY_END 0
%define IDX_ROW_END 8
%define IDX_CHILD 16

; --- Walking a tree in key order ---------------------------------------------
; The iterator keeps the path it descended. Moving to the next leaf is walking
; up to the deepest node that still has a child to its right and descending
; that child's left edge - what a sibling pointer would have done, without a
; pointer copy-on-write would have to maintain backwards. See docs/INDEX.md.
%define IDX_ITER_MAX 8                   ; deeper than this format can grow
%define ITER_CTX 0
%define ITER_DEPTH 8
%define ITER_NODE 16                     ; IDX_ITER_MAX page ids, root first
%define ITER_SLOT 80                     ; and where the walk stands in each
%define IDX_ITER_SIZE 144

%endif ; CybouDB_INDEX_INC
