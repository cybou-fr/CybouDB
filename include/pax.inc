; PAX leaves and optional data directories. Requires COW + catalog + PAX.
%ifndef CybouDB_PAX_INC
%define CybouDB_PAX_INC
%define PAX_MAGIC_VALUE 0x50515341       ; ASQP
%define PAX_VERSION_VALUE 1
%define PAX_PAGE_ID 8
%define PAX_GENERATION 16
%define PAX_OWNER 24
%define PAX_ROWS 32
%define PAX_COLUMNS 36
%define PAX_CAPACITY 40
%define PAX_DIRECTORY 64
%define PAX_CRC 4092
; Rows covered by one NULL mask, and the unit a future vector engine works on.
; A page holds as many whole groups as fit, so storage density and execution
; width are independent.
%define PAX_GROUP_ROWS 64
; Leaf runs, with CybouDB_FEATURE_PAX_RUNS. A leaf is the smallest power-of-two
; run of contiguous pages that holds PAX_RUN_TARGET rows, so that every schema
; delivers full 64-row batches and a scan walks long runs rather than
; scattered pages. PAX_RUN_MAX bounds what one leaf can cost: at 32 pages even
; 64 INT64 columns reach 249 rows, and nothing wider than 64 columns exists.
%define PAX_RUN_TARGET 256
%define PAX_RUN_MAX 32
%define PAX_DIR_MAGIC 0x44515341         ; ASQD
%define PAX_DIR_MAX 251                 ; (4092 - 64) / 16
; Directory depth, with CybouDB_FEATURE_PAX_TREE. A directory at level 0 names
; leaves, one at level 1 names level-0 directories; both use the same entry
; shape, so only the meaning of the page id changes. A table starts flat and
; is promoted the first time it would need a 252nd leaf, which keeps a small
; table byte-identical to what a build without the feature writes.
;
; The field is the first four bytes of what was reserved-zero, so a directory
; written before the feature reads back as level 0 - which is what it is.
%define PAX_DIR_LEVEL 44
%define PAX_DIR_LEAF 0
%define PAX_DIR_ROOT 1
%define PAX_TREE_MAX (PAX_DIR_MAX * PAX_DIR_MAX)
%define CAT_DATA_ROOT 40                ; schema only, with PAX capability
%define CAT_TABLE_ROWS 48
; Batch row-major input: one u64 slot and optional NULL byte per cell.
%define BATCH_ROWS 0
%define BATCH_VALUES 8
%define BATCH_NULLS 16
%define BATCH_VAR_LENGTHS 24             ; optional u64 length per row-major cell
%define CybouDB_BATCH_SIZE 32
; One UPDATE predicate batch. START is the global first row represented by MASK.
%define UPDATE_SPAN_START 0
%define UPDATE_SPAN_MASK  8
%define UPDATE_SPAN_SIZE  16
; Row read output: arrays with schema column-count slots/bytes.
%define ROW_VALUES 0
%define ROW_NULLS 8
; Scan cursor: one table's graph, validated once when the cursor is opened.
%define SCAN_CTX 0
%define SCAN_ROOT 8                     ; mapped directory, or the single leaf
%define SCAN_ROWS 16
%define SCAN_NEXT 24
%define SCAN_CAPACITY 32
%define SCAN_COLUMNS 40
%define SCAN_GENERATION 48
%define SCAN_LEAF 56                    ; leaf the cursor last addressed
%define SCAN_LEAF_INDEX 64
%define SCAN_RUN_PAGES 72               ; pages in one leaf of this table
%define CybouDB_SCAN_SIZE 80
; Scan output: row-major, laid out exactly like a batch insert's input.
%define SCAN_VALUES 0
%define SCAN_NULLS 8
%define SCAN_MAX 16

; Columnar batch view: borrowed typed batch views (may point to decoded scratch or mapped PAX leaf).
; Per-column view descriptor (24 bytes):
%define COLVIEW_VALUES_PTR  0           ; qword: pointer to values (mapped PAX leaf or decode scratch)
%define COLVIEW_NULL_MASK   8           ; qword: 64-bit NULL bitmask (bit i = 1 if row i is NULL)
%define COLVIEW_TYPE        16          ; dword: CAT_INT32, CAT_INT64, CAT_FLOAT32, CAT_BOOL
%define COLVIEW_WIDTH       20          ; dword: 1, 4, 8 bytes
%define CybouDB_COLVIEW_SIZE   24

; Batch view container (1544 bytes for up to 64 columns):
%define BATCH_VIEW_ROWS     0           ; qword: valid rows in this batch (1..64)
%define BATCH_VIEW_COLUMNS  8           ; physical-indexed slots; only requested columns are valid
%define CybouDB_BATCH_VIEW_SIZE (8 + 64 * CybouDB_COLVIEW_SIZE)

; Column directory flags and codec extraction:
%define PAX_COL_FLAG_NULLABLE 0x0001
%define PAX_COL_CODEC_SHIFT   8
%define PAX_COL_CODEC_MASK    0xFF00

; Decompression scratch buffer: 64 rows * 8 bytes = 512 bytes per column
%define PAX_DECODE_COL_BYTES  512
%define PAX_DECODE_MAX_BYTES  (64 * PAX_DECODE_COL_BYTES) ; 32768 bytes

; Private scan options; public typed batch layouts are unchanged.
%define PAX_SCANOPT_NULL_ONLY 0
%define PAX_SCANOPT_ENCODED   8
%define PAX_SCANOPT_FLAGS     16
%define PAX_SCANOPT_VIEWS     24

%define PAX_SCANOPT_DIRECT_FOR 1

; Per-column encoding descriptor (PAX_ENC_SIZE = 16 bytes).
;
; PAX_ENC_META (qword at offset 0):
;   low 8 bits  = encoding kind (PAX_ENC_KIND_* constants below)
;   bits [63:8] = first_row_in_leaf for FOR8/FOR16 (zero for CONST/BOOL)
;
; PAX_ENC_DATA (qword at offset 8):
;   kind 0 (typed)    : unused
;   kind 1 (CONST)    : constant value bits
;   kind 2 (BOOL)     : 64-bit truth mask for current batch
;   kind 3 (FOR8)     : pointer to FOR stream header (base at [ptr+0], stream at [ptr+16])
;   kind 4 (FOR16)    : pointer to FOR stream header (same layout)

%define PAX_ENC_META         0          ; qword: kind | (first_row << 8)
%define PAX_ENC_DATA         8          ; qword: payload (see above)
%define PAX_ENC_SIZE         16

; Aliases for backward compatibility with existing code that uses PAX_ENC_KIND
%define PAX_ENC_KIND         PAX_ENC_META

; Encoding kind constants stored in low 8 bits of PAX_ENC_META
%define PAX_ENC_KIND_TYPED   0          ; not encoded: use decoded values
%define PAX_ENC_KIND_CONST   1          ; CONST codec: constant value in DATA
%define PAX_ENC_KIND_BOOL    2          ; packed BOOL: 64-bit truth mask in DATA
%define PAX_ENC_KIND_FOR8    3          ; FOR width=8: DATA = stream ptr
%define PAX_ENC_KIND_FOR16   4          ; FOR width=16: DATA = stream ptr

%define PAX_SCANOPT_SIZE     (24 + 64 * PAX_ENC_SIZE)

%endif

