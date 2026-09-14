; Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
; SPDX-License-Identifier: Apache-2.0
; =============================================================================
;  sql.inc - SQL front-end declarations for CybouDB
; =============================================================================

%ifndef CybouDB_SQL_INC
%define CybouDB_SQL_INC

%include "cyboudb.inc"

; --- Token Types -------------------------------------------------------------
%define TOK_EOF             0
%define TOK_ERROR           1
%define TOK_IDENT           2
%define TOK_INT_LIT         3
%define TOK_FLOAT_LIT       4
%define TOK_STRING_LIT      5
%define TOK_BLOB_LIT        6

; Keywords
%define TOK_CREATE          10
%define TOK_TABLE           11
%define TOK_INSERT          12
%define TOK_INTO            13
%define TOK_VALUES          14
%define TOK_SELECT          15
%define TOK_FROM            16
%define TOK_WHERE           17
%define TOK_NULL            18
%define TOK_TRUE            19
%define TOK_FALSE           20
%define TOK_IS              21
%define TOK_NOT             22
%define TOK_AND             23
%define TOK_OR              24
%define TOK_COUNT           25
%define TOK_UPDATE          60
%define TOK_SET             61
%define TOK_DELETE          62
%define TOK_JOIN            63
%define TOK_INNER           64
%define TOK_LEFT            65
%define TOK_ON              66
%define TOK_AS              67
%define TOK_ORDER           68
%define TOK_BY              69
%define TOK_LIMIT           70
%define TOK_OFFSET_KW       71
%define TOK_VECTOR          72
%define TOK_ASC             73
%define TOK_DESC            74
%define TOK_DROP            75
%define TOK_LBRACKET        76          ; [
%define TOK_RBRACKET        77          ; ]
%define TOK_L2_DISTANCE     78
%define TOK_COSINE_DISTANCE 79
%define TOK_L2_OP           80          ; <->
%define TOK_COSINE_OP       81          ; <=>
%define TOK_BEGIN           82
%define TOK_TRANSACTION     83
%define TOK_COMMIT          84
%define TOK_ROLLBACK        85
%define TOK_INDEX           86
%define TOK_UNIQUE          87
%define TOK_QUEUE           88
%define TOK_ENQUEUE         89
%define TOK_DEQUEUE         90
%define TOK_STREAM          91
%define TOK_APPEND          92
%define TOK_TO              93
%define TOK_CURSOR          94
%define TOK_READ            95
%define TOK_TRIM            96
%define TOK_BEFORE          97
; A parameter placeholder. Positional and unnamed: the first `?` in a
; statement is parameter 0, and a statement says how many it has rather
; than the caller declaring them.
%define TOK_PARAM           98          ; ?

; Types
%define TOK_TYPE_INT32      30
%define TOK_TYPE_INT64      31
%define TOK_TYPE_FLOAT32    32
%define TOK_TYPE_BOOL       33
%define TOK_TYPE_TEXT       34
%define TOK_TYPE_BLOB       35
%define TOK_TYPE_VECTOR     36

; Operators and Punctuation
%define TOK_COMMA           40          ; ,
%define TOK_SEMICOLON       41          ; ;
%define TOK_LPAREN          42          ; (
%define TOK_RPAREN          43          ; )
%define TOK_STAR            44          ; *
%define TOK_EQ              45          ; =
%define TOK_NEQ             46          ; != or <>
%define TOK_LT              47          ; <
%define TOK_LTE             48          ; <=
%define TOK_GT              49          ; >
%define TOK_GTE             50          ; >=
%define TOK_PLUS            51          ; +
%define TOK_MINUS           52          ; -
%define TOK_DOT             53          ; .

; --- SQL Token Structure (32 bytes) ------------------------------------------
%define TOK_TYPE            0           ; qword: token type enum
%define TOK_OFFSET          8           ; qword: byte offset in source query
%define TOK_LEN             16          ; qword: byte length of token
%define TOK_LINE            24          ; dword: 1-based line number
%define TOK_COL             28          ; dword: 1-based column number
%define SQL_TOKEN_SIZE      32

; --- Tokenizer State (80 bytes) ----------------------------------------------
%define TOKZ_SRC            0           ; qword: pointer to SQL text
%define TOKZ_LEN            8           ; qword: total length in bytes
%define TOKZ_POS            16          ; qword: current read offset
%define TOKZ_LINE           24          ; dword: current line number
%define TOKZ_COL            28          ; dword: current column number
%define TOKZ_PEEKED         32          ; dword: 1 if peek token valid
%define TOKZ_PEEK_TOK       40          ; SQL_TOKEN_SIZE (32 bytes)
%define SQL_TOKENIZER_SIZE  80

; --- Memory Arena Structure --------------------------------------------------
%define ARENA_BASE          0           ; qword: buffer base pointer
%define ARENA_USED          8           ; qword: allocated bytes
%define ARENA_CAP           16          ; qword: buffer capacity
%define ARENA_FAILED        24          ; qword: allocation failed since last init
%define SQL_ARENA_SIZE      32

; --- AST Statement Types -----------------------------------------------------
%define STMT_CREATE_TABLE   1
%define STMT_INSERT         2
%define STMT_SELECT         3
%define STMT_UPDATE         4
%define STMT_DROP_TABLE     5
%define STMT_BEGIN          6
%define STMT_COMMIT         7
%define STMT_ROLLBACK       8
%define STMT_DELETE         9
%define STMT_CREATE_INDEX   10
%define STMT_DROP_INDEX     11
%define STMT_CREATE_QUEUE   12
%define STMT_DROP_QUEUE     13
%define STMT_ENQUEUE        14
%define STMT_DEQUEUE        15
%define STMT_CREATE_STREAM  16
%define STMT_DROP_STREAM    17
%define STMT_APPEND         18
%define STMT_CREATE_CURSOR  19
%define STMT_DROP_CURSOR    20
%define STMT_READ           21
%define STMT_TRIM           22

; =============================================================================
;  A prepared plan is immutable across executions.
; =============================================================================
;  `cyboudb_reset` exists so a statement can be run again, and the public header
;  says so. Everything a binder writes into a BOUND_PLAN is therefore input:
;  execution may read it and may not change it. State that belongs to one
;  execution - a materialised extent root, a row count, a resolved page address
;  - lives in the executor's frame or its arena, never in the plan.
;
;  This was learned three times in one afternoon, and all three were the same
;  mistake wearing different clothes:
;
;    * materialising a TEXT, BLOB or VECTOR cell wrote its extent root over the
;      pointer to the literal's bytes, so the second execution read a page id
;      as an address;
;    * PLAN_SCHEMA_PAGE cached a page *address*, and copy-on-write moves that
;      page on every commit, so a re-run UPDATE sized its scratch from the row
;      count the table had at prepare time and silently changed 154 of the 205
;      rows it matched - while reporting success;
;    * an UPDATE left its row count in PLAN_DATA1, which is where a SELECT plan
;      keeps its projection count, so the next execution followed PLAN_DATA2 as
;      an array of projections that never existed.
;
;  A cached page address is the subtle one: it is not wrong when it is written,
;  only later. Re-resolve through db_catalog_page, the way .exec_insert always
;  has, or guard the cache against the generation the way sql_select_open does.
;
;  tests/prepared_rerun_test.c is the regression suite for this rule and is
;  release-critical: it executes, resets and re-executes every mutating
;  statement that can be prepared, and checks that the second run wrote what
;  the first one wrote.

; --- AST Statement header and statement-specific payload --------------------
%define AST_STMT_TYPE       0           ; qword: STMT_*
%define AST_STMT_PAYLOAD    8           ; qword: CREATE/INSERT/SELECT payload
; Placeholders the statement holds, counted while it was parsed. A statement
; says how many it has; a caller does not declare them.
%define AST_STMT_PARAMS     16          ; qword: how many `?` it holds
%define AST_STMT_SIZE       24

; Legacy-compatible common prefix used while CREATE/INSERT call sites migrate.
%define STMT_NAME_PTR       0           ; qword: pointer to table name
%define STMT_NAME_LEN       8           ; qword: length of table name
%define STMT_EXTRA1         16          ; qword: col_count / proj_count
%define STMT_EXTRA2         24          ; qword: columns / projections array ptr
%define STMT_EXTRA3         32          ; qword: row_count / where_expr ptr
%define STMT_EXTRA4         40          ; qword: rows array ptr
; CREATE INDEX has more names to carry than a statement over one table does:
; its own, the table it is on, and the column. The first goes in STMT_NAME_*,
; the others here. See docs/INDEX.md.
%define STMT_INDEX_UNIQUE   16          ; aliases STMT_EXTRA1
%define STMT_INDEX_TABLE_PTR 24         ; aliases STMT_EXTRA2
%define STMT_INDEX_TABLE_LEN 32         ; aliases STMT_EXTRA3
%define STMT_INDEX_COL_PTR  40          ; aliases STMT_EXTRA4
%define STMT_INDEX_COL_LEN  48
%define AST_STMT_PAYLOAD_SIZE 104

; Statement-specific payload field names. Their layouts may evolve
; independently even though the initial arena allocation size is shared.
%define CREATE_TABLE_NAME_PTR   0
%define CREATE_TABLE_NAME_LEN   8
%define CREATE_COLUMN_COUNT    16
%define CREATE_COLUMNS_PTR     24
%define CREATE_PAYLOAD_SIZE    32

%define INSERT_TABLE_NAME_PTR   0
%define INSERT_TABLE_NAME_LEN   8
%define INSERT_ROW_COUNT       32
%define INSERT_ROWS_PTR        40
%define INSERT_PAYLOAD_SIZE    48

; Correctness-first UPDATE: one literal assignment plus a mandatory WHERE.
%define UPDATE_TABLE_NAME_PTR  0
%define UPDATE_TABLE_NAME_LEN  8
%define UPDATE_COLUMN_NAME_PTR 16
%define UPDATE_COLUMN_NAME_LEN 24
%define UPDATE_VALUE_EXPR      32       ; AST_EXPR*; a literal or a placeholder
%define UPDATE_WHERE_EXPR      40       ; AST_EXPR*; mandatory in V1
%define UPDATE_PAYLOAD_SIZE    48
 
; DELETE-V1: the whole table, published as one COW truncation. A WHERE clause
; parses so that the error names the clause rather than the keyword, and the
; binder refuses it until predicated deletion exists.
%define DELETE_TABLE_NAME_PTR  0
%define DELETE_TABLE_NAME_LEN  8
%define DELETE_WHERE_EXPR     16       ; AST_EXPR*, or zero
%define DELETE_PAYLOAD_SIZE   24

%define DROP_TABLE_NAME_PTR    0
%define DROP_TABLE_NAME_LEN    8
%define DROP_PAYLOAD_SIZE      16

; ENQUEUE INTO q VALUES (literal) and DEQUEUE FROM q. The queue's name goes
; where every other statement over one object puts a name.
%define QUEUE_NAME_PTR         0
%define QUEUE_NAME_LEN         8
%define QUEUE_VALUE_EXPR      16       ; AST_EXPR*; parser requires a literal
; A cursor statement names two things: the reader, and the stream it reads.
; The stream goes where every other statement over one object puts a name,
; so what is added is the reader.
%define CURSOR_NAME_PTR       32
%define CURSOR_NAME_LEN       40
%define TRIM_POSITION         32       ; TRIM: where the stream now begins
%define QUEUE_PAYLOAD_SIZE    48

%define SELECT_TABLE_NAME_PTR   0
%define SELECT_TABLE_NAME_LEN   8
%define SELECT_PROJ_COUNT      16
%define SELECT_PROJECTIONS_PTR 24
%define SELECT_WHERE_EXPR      32
%define SELECT_TABLE_ALIAS     40
%define SELECT_JOIN_HEAD       48       ; AST_JOIN* or 0
%define SELECT_JOIN_COUNT      56
%define SELECT_LIMIT_VALUE     64       ; qword, -1 when absent
%define SELECT_OFFSET_VALUE    72       ; qword, zero when absent
%define SELECT_ORDER_NAME      80       ; AST_NAME* or 0
%define SELECT_ORDER_DESC      88       ; qword boolean
%define SELECT_ORDER_EXPR      96       ; AST_EXPR* or 0
%define SELECT_PAYLOAD_SIZE    104

; JOIN descriptors are arena-owned and chained from a future SELECT payload
; extension without changing AST_STMT.
%define JOIN_TYPE               0       ; qword: JOIN_INNER / JOIN_LEFT
%define JOIN_TABLE_NAME_PTR     8
%define JOIN_TABLE_NAME_LEN    16
%define JOIN_TABLE_ALIAS       24       ; AST_NAME* or 0
%define JOIN_ON_EXPR           32
%define JOIN_NEXT              40
%define AST_JOIN_SIZE          48
%define JOIN_INNER              1
%define JOIN_LEFT               2
%define AST_NAME_PTR         0
%define AST_NAME_LEN         8
%define AST_NAME_QUAL_PTR   16          ; optional table/alias qualifier
%define AST_NAME_QUAL_LEN   24
%define AST_NAME_SIZE       32
%define PROJ_COUNT_STAR     -1          ; special STMT_EXTRA1 value for COUNT(*)

; --- AST Column Definition (24 bytes) ----------------------------------------
%define COLDEF_NAME_PTR     0           ; qword
%define COLDEF_NAME_LEN     8           ; qword
%define COLDEF_TYPE         16          ; dword: CAT_INT32, CAT_INT64, etc.
%define COLDEF_FLAGS        20          ; dword: CAT_NULLABLE or 0
%define AST_COLDEF_SIZE     24

; --- AST Expression Kinds ----------------------------------------------------
%define EXPR_LITERAL        1
%define EXPR_COLUMN         2
%define EXPR_BINARY         3
%define EXPR_UNARY          4
; A value the statement does not carry: supplied by cyboudb_bind_* before
; the statement is stepped. EXPR_LIT_VAL holds its index, and nothing else
; about it is known until it is bound.
%define EXPR_PARAM          5

; Expression Operators
%define OP_EQ               1
%define OP_NEQ              2
%define OP_LT               3
%define OP_LTE              4
%define OP_GT               5
%define OP_GTE              6
%define OP_AND              7
%define OP_OR               8
%define OP_IS_NULL          9
%define OP_IS_NOT_NULL      10
%define OP_NOT              11
%define OP_L2_DISTANCE      12
%define OP_COSINE_DISTANCE  13

; --- AST Expression Structure (64 bytes) -------------------------------------
%define EXPR_KIND           0           ; qword: EXPR_*
%define EXPR_OP             8           ; qword: OP_*
%define EXPR_LEFT           16          ; qword: left child expr ptr
%define EXPR_RIGHT          24          ; qword: right child expr ptr
%define EXPR_QUAL_PTR       EXPR_LEFT   ; for EXPR_COLUMN: optional qualifier
%define EXPR_QUAL_LEN       EXPR_RIGHT
%define EXPR_LIT_PTR        EXPR_LEFT   ; for variable-width literal: decoded bytes
%define EXPR_LIT_LEN        EXPR_RIGHT
%define EXPR_NAME_PTR       32          ; qword: for EXPR_COLUMN: name ptr
%define EXPR_NAME_LEN       40          ; qword: for EXPR_COLUMN: name len
%define EXPR_LIT_VAL        48          ; qword: for EXPR_LITERAL: 64-bit value
%define EXPR_LIT_TYPE       56          ; dword: CAT_*, or 0 (NULL)
%define EXPR_TOK_OFFSET     60          ; dword: source offset for error reporting
%define AST_EXPR_SIZE       64

; --- Error Codes -------------------------------------------------------------
%define SQL_OK              0
%define SQL_FLOAT_MAX_DIGITS 128

%define SQL_ERR_SYNTAX      1
%define SQL_ERR_UNEXPECTED  2
%define SQL_ERR_TABLE_NOT_FOUND 3
%define SQL_ERR_COLUMN_NOT_FOUND 4
%define SQL_ERR_DUPLICATE_TABLE 5
%define SQL_ERR_DUPLICATE_COLUMN 6
%define SQL_ERR_TYPE_MISMATCH 7
%define SQL_ERR_NOT_NULLABLE 8
%define SQL_ERR_VALUE_COUNT 9
%define SQL_ERR_NO_STORAGE  10
%define SQL_ERR_EXEC        11
%define SQL_ERR_EXPR_DEPTH  12
%define SQL_ERR_SINK        13

; --- Result sink contract ----------------------------------------------------
; What a batch or row callback returns. A consumer needs a way to say "I
; failed" - a full disk, a closed pipe, no memory - distinctly from "I have
; seen enough". Fixing that before the C ABI is public costs nothing; after,
; it would be a breaking change.
%define CybouDB_SINK_CONTINUE  0           ; deliver the next batch
%define CybouDB_SINK_STOP      1           ; stop early; the statement succeeded
%define CybouDB_SINK_ERROR     -1          ; the sink failed; the statement fails


; Deepest nesting the parser will build. Parser, binder and executor all walk
; the expression tree recursively, so an input like NOT(NOT(NOT(...))) would
; otherwise decide how much stack CybouDB uses. The parser enforces the limit
; once and everything downstream inherits a tree it can safely recurse over.
%define SQL_MAX_EXPR_DEPTH  64
; Placeholders one statement may hold. The same 64 the column count is, and
; for the same reason: the arrays that carry them are sized once.
%define SQL_MAX_PARAMS      64

; --- SQL Error Structure (96 bytes) ------------------------------------------
%define SQL_ERR_CODE        0           ; qword: 0 or code interpreted by SQL_ERR_DOMAIN
%define SQL_ERR_OFFSET      8           ; qword: byte offset in source
%define SQL_ERR_LINE        16          ; dword: line number
%define SQL_ERR_COL         20          ; dword: column number
%define SQL_ERR_MSG         24          ; 72 bytes: ASCIIZ message
%define SQL_ERR_DOMAIN      96          ; qword: SQL_DOMAIN_*, code is domain-local
%define SQL_ERROR_SIZE      104
%define SQL_DOMAIN_NONE     0
%define SQL_DOMAIN_SQL      1
%define SQL_DOMAIN_STORAGE  2
%define SQL_DOMAIN_OS       3           ; reserved: raw OS errors are not exposed yet
%define SQL_OFFSET_UNKNOWN -1

; Clear the public error record without changing argument registers.
%macro SQL_CLEAR_ERROR 1
    test    %1, %1
    jz      %%done
    mov     qword [%1 + SQL_ERR_CODE], 0
    mov     qword [%1 + SQL_ERR_DOMAIN], SQL_DOMAIN_NONE
    mov     qword [%1 + SQL_ERR_OFFSET], SQL_OFFSET_UNKNOWN
    mov     qword [%1 + SQL_ERR_LINE], 0
    mov     byte [%1 + SQL_ERR_MSG], 0
%%done:
%endmacro

; --- Bound Plan Structure (272 bytes) ----------------------------------------
%define PLAN_TYPE           0           ; qword: STMT_CREATE_TABLE / STMT_INSERT / STMT_SELECT / STMT_UPDATE
%define PLAN_TABLE_ID       8           ; qword: resolved table ID
%define PLAN_SCHEMA_PAGE    16          ; qword: pointer to mapped schema page
%define PLAN_DATA1          24          ; qword: CREATE: schema image | INSERT: batch ptr | SELECT: proj_count
%define PLAN_DATA2          32          ; qword: SELECT: proj_indices ptr
%define PLAN_DATA3          40          ; qword: SELECT: proj_types ptr
%define PLAN_DATA4          48          ; qword: SELECT: bound_expr (predicate) ptr
%define PLAN_REQUIRED_COLS  56          ; qword: physical columns used by SELECT and WHERE
%define PLAN_GENERATION     64          ; qword: db generation when statement was bound
%define PLAN_CAPACITY       72          ; qword: leaf capacity of the table
%define PLAN_RUN_PAGES      80          ; qword: pages in one leaf run
%define PLAN_DB_BASE        88          ; qword: mapped base address at bind time
%define PLAN_DB_ROOT        96          ; qword: catalog root page at bind time
%define PLAN_CTX            104         ; qword: connection context ptr at bind time
%define PLAN_FLAGS          112         ; qword: plan flags
%define PLAN_FLAG_COUNT_STAR 1          ; bit 0: SELECT COUNT(*) aggregation
%define PLAN_REQUIRED_VALUES 120        ; references needing values, not only NULLs
%define PLAN_JOIN_TYPE      128         ; JOIN_INNER / JOIN_LEFT, or 0
%define PLAN_RIGHT_TABLE_ID 136
%define PLAN_RIGHT_SCHEMA   144         ; mapped right schema at bind time
%define PLAN_JOIN_AST       152         ; validated AST_JOIN pending lowering
%define PLAN_JOIN_LEFT_COL  160         ; qword physical index in left schema
%define PLAN_JOIN_RIGHT_COL 168         ; qword physical index in right schema
%define PLAN_JOIN_KEY_TYPE  176         ; qword CAT_* shared by both keys
%define PLAN_JOIN_PROJECTIONS 184       ; encoded source/index descriptors
%define PLAN_LIMIT_VALUE    192         ; qword row limit
%define PLAN_OFFSET_VALUE   200         ; qword rows skipped before delivery
%define PLAN_ORDER_ORDINAL  208         ; qword compact result-column ordinal
%define PLAN_ORDER_TYPE     216         ; qword CAT_* scalar type
%define PLAN_ORDER_DESC     224         ; qword boolean
%define PLAN_UPDATE_COL_IDX 232         ; qword physical target column index
%define PLAN_UPDATE_COL_TYPE 240        ; qword CAT_* target type
%define PLAN_UPDATE_VALUE   248         ; qword normalized scalar or varlen pointer
%define PLAN_UPDATE_LENGTH  256         ; qword TEXT/BLOB byte length, otherwise zero
%define PLAN_UPDATE_IS_NULL 264         ; qword boolean
%define PLAN_VECTOR_TOPK_EXPR 272       ; qword: bound vector distance expr
%define PLAN_DELETE_ROWS    280         ; qword rows a DELETE removed
%define BOUND_PLAN_SIZE     384
%define PLAN_PROJ_RIGHT_BIT 0x80000000  ; u32 projection index belongs to RHS
%define PLAN_FLAG_LIMIT     2           ; bit 1: LIMIT clause is present
%define PLAN_FLAG_ORDER     4           ; bit 2: ORDER BY is present
%define PLAN_FLAG_VECTOR_TOPK 8         ; bit 3: vector streaming top-K ORDER BY
; bit 4: the predicate is one comparison over an indexed column, so the rows it
; names can be found through the tree instead of by reading the whole table.
; The rows are still read and the predicate still evaluated over them: an index
; is an access path, and a wrong one has to cost time rather than answers.
;
; The bounds are inclusive and both always present: an equality is the case
; where they are equal, and an open side is the extreme of the key's range.
%define PLAN_FLAG_INDEX_SEEK 16
%define PLAN_INDEX_ID       288         ; the index that lookup uses
%define PLAN_INDEX_LO       296         ; the lowest key it wants
%define PLAN_INDEX_HI       304         ; and the highest
; The column that index is over. A plan outlives the objects it named: an index
; can be dropped, and its id can be handed to another one. So what opening a
; cursor checks is not that the id is still there but that what it names is
; still this table's index over this column - and when it is not, the plan
; reads the table, because an access path that has gone is not an empty one.
%define PLAN_INDEX_COL      312
; The reader a cursor statement names. It has a slot of its own rather than
; sharing PLAN_DATA1 with the record a READ hands back, because a prepared
; statement is stepped more than once: the first step would otherwise write
; the record over the name and the second would look up whatever that was.
%define PLAN_READER_PTR     320
%define PLAN_READER_LEN     328
; A bound INSERT batch carries pointers to the literal bytes of its TEXT, BLOB
; and VECTOR cells. Materialising them writes each cell's extent root over that
; pointer, which is fine once and fatal twice: a prepared statement stepped
; again would read a page id as an address. The plan therefore keeps an
; untouched copy of the whole values array and the execution restores from it,
; so that what prepare produced stays what prepare produced.
;
; PLAN_INSERT_CELLS is the number of qwords in it, not bytes.
%define PLAN_INSERT_PRISTINE 336
%define PLAN_INSERT_CELLS    344

; --- Parameters --------------------------------------------------------------
; A prepared plan is immutable across executions, and a bound value is not part
; of the plan: it is input to one execution. What the plan holds is three
; pointers the binder allocates once and never re-points - the slots a caller
; binds into, and the buffer the engine copies variable-width bytes into. Their
; contents change between executions the way the batch's own values array does;
; the plan itself does not.
;
; The copy is deliberate. A slot could have held the caller's pointer, which is
; cheaper and is what SQLITE_STATIC does, but it makes the lifetime of the
; caller's buffer part of this library's contract, and the failure when it is
; broken is a use-after-free at commit time. Copying turns that into
; CybouDB_NOMEM at the call, which is the same bounded-buffer-and-an-honest-
; refusal shape the change-set and the flush runs already have.
%define PLAN_PARAM_SLOTS     352        ; qword: SQL_MAX_PARAMS slots, or 0
%define PLAN_PARAM_BUF       360        ; qword: copy buffer, or 0
%define PLAN_PARAM_COUNT     368        ; qword: placeholders this plan holds

; One parameter. The first three fields are what the binder resolved - where
; the value goes and what it has to be - and are written once; the rest is what
; a caller bound and is rewritten by every bind.
%define PARAM_TARGET        0           ; qword: where the value goes, per PARAM_KIND
%define PARAM_CELL          PARAM_TARGET ; INSERT: index into the batch values
%define PARAM_TYPE          8           ; qword: CAT_* of the target column
%define PARAM_FLAGS         16          ; qword: column flags, incl. dimension
%define PARAM_VAL           24          ; qword: scalar, or offset into the buffer
%define PARAM_LEN           32          ; qword: bytes, for TEXT/BLOB/VECTOR
%define PARAM_CAP           40          ; qword: bytes this slot already owns
%define PARAM_STATE         48          ; qword: PARAM_UNBOUND / _BOUND / _NULL
; What PARAM_TARGET names. A placeholder in VALUES fills a cell of the batch;
; one in a predicate fills the literal field of a bound expression node. The
; two differ in where the value lands and in nothing else, which is why they
; share a slot rather than getting a second mechanism.
%define PARAM_KIND          56          ; qword: PARAM_TO_CELL / PARAM_TO_BEXPR
%define PARAM_SLOT_SIZE     64

%define PARAM_TO_CELL       0
%define PARAM_TO_BEXPR      1
%define PARAM_TO_PLAN_UPDATE 2

%define PARAM_UNBOUND       0
%define PARAM_BOUND         1
%define PARAM_NULL          2

; The buffer opens with how much of it is spent, so that the plan holds only
; pointers it never rewrites. A slot that is bound again reuses the bytes it
; already owns when the new value fits, which is what keeps binding in a loop
; from walking the cursor forward until it runs out.
%define PARAM_BUF_USED      0
%define PARAM_BUF_BYTES     8
%define CybouDB_PARAM_BUF_SIZE 32768

; Projection descriptor passed to batch result sinks (aliases PLAN_DATA1..3).
%define RESULT_PROJ_COUNT   0           ; qword: projection count, 1..64
%define RESULT_PROJ_INDICES 8           ; qword: pointer to physical u32 indices
%define RESULT_PROJ_TYPES   16          ; qword: pointer to u32 scalar types

; --- Bound Predicate Node (64 bytes) -----------------------------------------
%define BEXPR_KIND          0           ; qword: BEXPR_*
%define BEXPR_OP            8           ; qword: OP_EQ, OP_NEQ, etc.
%define BEXPR_COL_IDX       16          ; qword: physical column index
%define BEXPR_COL_TYPE      24          ; qword: CAT_INT32, CAT_INT64, etc.
%define BEXPR_LIT_VAL       32          ; qword: literal value
%define BEXPR_LEFT          40          ; qword: left bound expr (for AND/OR/NOT)
%define BEXPR_RIGHT         48          ; qword: right bound expr (for AND/OR)
%define BEXPR_KERNEL        56          ; qword: resolved comparison kernel function pointer
%define BOUND_EXPR_SIZE     64

%define BEXPR_COMPARE_COL_LIT 1
%define BEXPR_IS_NULL       2
%define BEXPR_IS_NOT_NULL   3
%define BEXPR_AND           4
%define BEXPR_OR            5
%define BEXPR_NOT           6
%define BEXPR_COMPARE_NULL_LIT 7

%endif ; CybouDB_SQL_INC

