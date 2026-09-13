; Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
; SPDX-License-Identifier: Apache-2.0
; =============================================================================
;  main.asm - CybouDB command line interface
; =============================================================================
;  Commands:
;      cyboudb create <path> <pages> [--force]
;                                   create a database file of <pages> pages
;      cyboudb info   <path>           print the parameters of an existing database
;      cyboudb alloc  <path> <count>   allocate pages and commit
;      cyboudb free   <path> <page>    return a page to the free list and commit
;
;  This module only parses arguments and prints. Work on the file format lives
;  in core/database.asm, system calls live in platform/<os>/. There are no
;  platform-dependent symbols here: the file builds unchanged for win64 and
;  for elf64.
; =============================================================================

%include "cyboudb.inc"
%include "sql.inc"

BITS 64
default rel

; --- OS layer ----------------------------------------------------------------
extern os_argc, os_argv, os_str_eq_ascii, os_str_to_u64, os_write, os_arg_to_utf8
extern os_cmdline_ok
; --- Core --------------------------------------------------------------------
extern db_create, db_open, db_alloc_page, db_free_page, db_commit, db_close
extern db_create_cow
extern db_create_catalog, db_create_pax, db_create_pax_multi
extern db_create_large, db_create_compressed, db_create_tombstones
; --- SQL ---------------------------------------------------------------------
extern sql_arena_init, sql_arena_alloc, sql_parse, sql_bind, sql_execute

extern cyboudb_repl

global cyboudb_main
global puts_asciiz, put_u64, print_db_info, cyboudb_exec_query

; Print a string literal declared with `db ... ,0`
%macro PUTS 1
    lea     ARG1, [%1]
    call    puts_asciiz
%endmacro

; =============================================================================
section .data

str_cmd_console: db "console", 0
str_cmd_repl:    db "repl", 0
str_cmd_create:  db "create", 0
str_cmd_create_cow: db "create-cow", 0
str_cmd_create_catalog: db "create-catalog", 0
str_cmd_create_pax_multi: db "create-pax-multi", 0
str_cmd_create_pax: db "create-pax", 0
str_cmd_create_large: db "create-large", 0
str_cmd_create_tomb: db "create-tombstones", 0
str_cmd_create_compressed: db "create-compressed", 0
str_cmd_info:    db "info", 0
str_cmd_check:   db "check", 0
str_cmd_alloc:   db "alloc", 0
str_cmd_free:    db "free", 0
str_cmd_query:   db "query", 0
str_opt_force:   db "--force", 0
str_opt_pax:     db "--pax", 0
str_opt_compress: db "--compress", 0
str_opt_help:    db "--help", 0
str_opt_h:       db "-h", 0

msg_usage:
    db "CybouDB - mmap-backed storage engine", 10
    db "Usage:", 10
    db "  cyboudb <path>                  open an interactive console", 10
    db "  cyboudb console <path>          the same", 10
    db "  cyboudb create <path> <pages> [--force] [--pax]", 10
    db "                               create a new database file;", 10
    db "                               --force replaces an existing one", 10
    db "  cyboudb query  <path> <statement>", 10
    db "                               execute a SQL statement", 10
    db "  cyboudb create-cow <path> <pages> [--force]", 10
    db "                               COW storage, 4..16112 pages", 10
    db "  cyboudb create-catalog <path> <pages> [--force]", 10
    db "                               COW storage with a typed catalog", 10
    db "  cyboudb create-pax <path> <pages> [--force]", 10
    db "                               typed catalog with PAX row storage", 10
    db "  cyboudb create-pax-multi <path> <pages> [--force]", 10
    db "                               multiple PAX pages per table", 10
    db "  cyboudb create-large <path> <pages> [--force]", 10
    db "  cyboudb create-tombstones <path> <pages> [--force]", 10
    db "                               the same, with per-row tombstones", 10
    db "  cyboudb create-compressed <path> <pages> [--force]", 10
    db "                               the same, with a paired multi-page", 10
    db "                               allocation map instead of one page", 10
    db "  cyboudb info   <path>           show database metadata", 10
    db "  cyboudb check  <path>           verify every page, not just the", 10
    db "                               newest generation's", 10
    db "  cyboudb alloc  <path> <count>   allocate pages and commit", 10
    db "  cyboudb free   <path> <page>    free a page and commit", 10, 0

msg_created:     db "Database created", 10
                 db "  Pages:           ", 0
msg_c_pagesize:  db "  Page Size:       ", 0
msg_c_filesize:  db "  File Size:       ", 0

msg_info_title:  db "CybouDB Database Info", 10
                 db "------------------", 10, 0
msg_magic:       db "  Magic:           CybouDB", 10, 0
msg_version:     db "  Format Version:  ", 0
msg_page_size:   db "  Page Size:       ", 0
msg_total_pages: db "  Total Pages:     ", 0
msg_alloc_pages: db "  Allocated Pages: ", 0
msg_freelist:    db "  Free List Root:  ", 0
msg_generation:  db "  Generation:      ", 0
msg_storage_legacy: db "  Storage:         legacy free list", 10, 0
msg_storage_cow: db "  Storage:         COW allocation map", 10, 0
msg_storage_catalog: db "  Storage:         COW catalog", 10, 0
msg_storage_pax_multi: db "  Storage:         COW catalog + multi-page PAX", 10, 0
msg_storage_pax: db "  Storage:         COW catalog + PAX", 10, 0
msg_storage_large: db "  Storage:         COW catalog + multi-page PAX, span map", 10, 0
msg_leaves_dense: db "  PAX Leaves:      multi-page runs", 10, 0
msg_leaves_sparse: db "  PAX Leaves:      one page each", 10, 0
msg_compression:   db "  Compression:     enabled", 10, 0
msg_superblock:  db "  Superblock:      page ", 0
msg_file_size:   db "  File Size:       ", 0
msg_status_ok:   db "  Status:          OK", 10, 0

msg_allocated:   db "Allocated:", 10, 0
msg_page_item:   db "  page ", 0
msg_freed:       db "Freed page ", 0
msg_committed:   db "Committed generation ", 0

msg_bytes:       db " bytes", 10, 0
str_nl:          db 10, 0

; --- Core error messages -----------------------------------------------------
;  Indexed by the CybouDB_E_* codes from constants.inc.
e_none:          db "error: unknown", 10, 0
e_pages:         db "error: <pages> must be a number of at least 3 "
                 db "(header plus two superblocks)", 10, 0
e_create:        db "error: cannot create file", 10, 0
e_open:          db "error: cannot open file", 10, 0
e_size:          db "error: cannot query file size", 10, 0
e_small:         db "error: file is too small to hold the CybouDB metadata", 10, 0
e_map:           db "error: memory mapping failed", 10, 0
e_magic:         db "error: bad signature - not an CybouDB database", 10, 0
e_version:       db "error: unsupported format version", 10, 0
e_pagesize:      db "error: unsupported page size", 10, 0
e_hdr_crc:       db "error: file header checksum mismatch - file is damaged", 10, 0
e_features:      db "error: file requires incompatible features "
                 db "this build does not implement", 10, 0
e_superblock:    db "error: no valid superblock - metadata is damaged", 10, 0
e_geometry:      db "error: page counts disagree with the file size", 10, 0
e_exists:        db "error: file already exists - refusing to overwrite it; "
                 db "pass --force to replace it", 10, 0
e_full:          db "error: database is full - no free page and no room "
                 db "left to grow", 10, 0
e_freelist:      db "error: the free list is corrupt", 10, 0
e_page:          db "error: page is outside the allocatable range, "
                 db "or already free", 10, 0
e_readonly:      db "error: database is open read-only", 10, 0
e_sync:          db "error: the commit could not be flushed to disk", 10, 0
e_noent:         db "error: no such file or directory", 10, 0
e_access:        db "error: permission denied", 10, 0
e_state:         db "error: operation not allowed for this storage mode or handle", 10, 0
e_generation:    db "error: generation counter exhausted", 10, 0
e_bitmap:        db "error: staged allocation map or root is inconsistent", 10, 0
e_cow_pages:     db "error: COW page count must be between 4 and 16112", 10, 0
e_catalog:       db "error: catalog graph is corrupt", 10, 0
e_schema:        db "error: invalid schema or duplicate table name", 10, 0
e_notfound:      db "error: table id not found", 10, 0
e_catalog_full:  db "error: catalog directory is full", 10, 0

e_rows: db "error: row count or index exceeds table capacity", 10, 0
e_pax: db "error: invalid PAX data page", 10, 0
e_value: db "error: invalid value or NULL for column type", 10, 0
e_busy: db "error: database is locked by another writer", 10, 0

    align 8
err_table:
    dq e_none, e_pages, e_create, e_open, e_size, e_small, e_map, e_magic
    dq e_version, e_pagesize, e_hdr_crc, e_features, e_superblock, e_geometry
    dq e_exists, e_full, e_freelist, e_page, e_readonly, e_sync
    dq e_noent, e_access, e_state, e_generation
    dq e_bitmap, e_cow_pages
    dq e_catalog, e_schema, e_notfound, e_catalog_full
    dq e_rows, e_pax, e_value, e_busy

err_no_pax_cli:  db "error: database does not support PAX tables (create with create-pax-multi)", 10, 0
msg_sql_table_created: db "Table created.", 10, 0
msg_sql_table_dropped: db "Table dropped.", 10, 0
msg_sql_index_created: db "Index created.", 10, 0
msg_sql_index_dropped: db "Index dropped.", 10, 0
msg_sql_queue_created: db "Queue created.", 10, 0
msg_sql_queue_dropped: db "Queue dropped.", 10, 0
msg_sql_stream_created: db "Stream created.", 10, 0
msg_sql_stream_dropped: db "Stream dropped.", 10, 0
msg_sql_enqueued:      db "ENQUEUE 1", 10, 0
msg_sql_queue_empty:   db "(empty)", 10, 0
msg_sql_done:          db "OK.", 10, 0
msg_sql_insert_prefix: db "INSERT ", 0
msg_sql_update_prefix: db "UPDATE ", 0
msg_sql_delete_prefix: db "DELETE ", 0
msg_sql_begin:         db "BEGIN", 10, 0
msg_sql_commit:        db "COMMIT", 10, 0
msg_sql_rollback:      db "ROLLBACK", 10, 0
msg_sql_rows_prefix:   db "(", 0
msg_sql_rows_suffix:   db " rows)", 10, 0
msg_sql_row_suffix:    db " row)", 10, 0
str_pipe_sep:          db " | ", 0
str_null:              db "NULL", 0
str_true:              db "TRUE", 0
str_false:             db "FALSE", 0
str_dash_col:          db "--------", 0
str_count_star_col:    db "count(*)", 0
str_caret:             db "^", 10, 0
str_error_prefix:      db "error: ", 0
err_query_too_long:    db "error: SQL statement exceeds the command-line limit", 10, 0
str_at_offset:         db " at offset ", 0
str_two_spaces:        db "  ", 0
str_space:             db " ", 0
str_minus:             db "-", 0
str_dot:               db ".", 0
str_zero:              db "0", 0
str_blob_open:         db "X'", 0
str_quote:             db "'", 0
str_lbracket:          db "[", 0
str_rbracket:          db "]", 0
str_comma_sp:          db ", ", 0
hex_digits:            db "0123456789ABCDEF"

    align 4
flt_100:               dd 100.0

; =============================================================================
section .bss
    align 8
numbuf:           resb 32                     ; scratch buffer for decimal conversion
row_cb_plan:      resq 1
query_arena_desc: resb SQL_ARENA_SIZE
query_buf:        resb 262144
query_arena:      resb 1048576

sql_err_buf:      resb SQL_ERROR_SIZE

; =============================================================================
section .text

; -----------------------------------------------------------------------------
;  cyboudb_main() -> RAX: process exit code
;
;  Frame slots:
;      [rbp-8]  argc               [rbp-32] page count / page id
;      [rbp-16] argv[1] (command)  [rbp-40] force flag / loop counter
;      [rbp-24] argv[2] (path)     [rbp-48] saved error code
;      [rbp-56] create mode
;      [rbp+CTX] CybouDB_DB descriptor below the local slots
; -----------------------------------------------------------------------------
%define CTX (-64 - CybouDB_DB_SIZE)

cyboudb_main:
    FRAME_BEGIN 64 + CybouDB_DB_SIZE, 2

    call    os_argc
    mov     [rbp - 8], rax
    cmp     rax, 2
    jb      .usage
    je      .check_single_arg

    mov     ARG1, 1
    call    os_argv
    mov     [rbp - 16], rax

    mov     ARG1, [rbp - 16]
    lea     ARG2, [str_cmd_console]
    call    os_str_eq_ascii
    test    rax, rax
    jnz     .cmd_console

    mov     ARG1, [rbp - 16]
    lea     ARG2, [str_cmd_repl]
    call    os_str_eq_ascii
    test    rax, rax
    jnz     .cmd_console

    mov     ARG1, [rbp - 16]
    lea     ARG2, [str_cmd_create]
    call    os_str_eq_ascii
    test    rax, rax
    jnz     .cmd_create

    mov     ARG1, [rbp - 16]
    lea     ARG2, [str_cmd_create_cow]
    call    os_str_eq_ascii
    test    rax, rax
    jnz     .cmd_create_cow

    mov     ARG1, [rbp - 16]
    lea     ARG2, [str_cmd_create_catalog]
    call    os_str_eq_ascii
    test    rax, rax
    jnz     .cmd_create_catalog

    mov     ARG1, [rbp - 16]
    lea     ARG2, [str_cmd_create_pax]
    call    os_str_eq_ascii
    test    rax, rax
    jnz     .cmd_create_pax

    mov     ARG1, [rbp - 16]
    lea     ARG2, [str_cmd_create_pax_multi]
    call    os_str_eq_ascii
    test    rax, rax
    jnz     .cmd_create_pax_multi

    mov     ARG1, [rbp - 16]
    lea     ARG2, [str_cmd_create_large]
    call    os_str_eq_ascii
    test    rax, rax
    jnz     .cmd_create_large

    mov     ARG1, [rbp - 16]
    lea     ARG2, [str_cmd_create_compressed]
    call    os_str_eq_ascii
    test    rax, rax
    jnz     .cmd_create_compressed

    mov     ARG1, [rbp - 16]
    lea     ARG2, [str_cmd_create_tomb]
    call    os_str_eq_ascii
    test    rax, rax
    jnz     .cmd_create_tomb

    mov     ARG1, [rbp - 16]
    lea     ARG2, [str_cmd_check]
    call    os_str_eq_ascii
    test    rax, rax
    jnz     .cmd_check

    mov     ARG1, [rbp - 16]
    lea     ARG2, [str_cmd_info]
    call    os_str_eq_ascii
    test    rax, rax
    jnz     .cmd_info

    mov     ARG1, [rbp - 16]
    lea     ARG2, [str_cmd_alloc]
    call    os_str_eq_ascii
    test    rax, rax
    jnz     .cmd_alloc

    mov     ARG1, [rbp - 16]
    lea     ARG2, [str_cmd_free]
    call    os_str_eq_ascii
    test    rax, rax
    jnz     .cmd_free

    mov     ARG1, [rbp - 16]
    lea     ARG2, [str_cmd_query]
    call    os_str_eq_ascii
    test    rax, rax
    jnz     .cmd_query

    jmp     .usage

.check_single_arg:
    mov     ARG1, 1
    call    os_argv
    mov     [rbp - 16], rax

    mov     ARG1, [rbp - 16]
    lea     ARG2, [str_opt_help]
    call    os_str_eq_ascii
    test    rax, rax
    jnz     .usage

    mov     ARG1, [rbp - 16]
    lea     ARG2, [str_opt_h]
    call    os_str_eq_ascii
    test    rax, rax
    jnz     .usage

    ; Check if argument matches any other subcommand that requires more args
    mov     ARG1, [rbp - 16]
    lea     ARG2, [str_cmd_create]
    call    os_str_eq_ascii
    test    rax, rax
    jnz     .usage

    mov     ARG1, [rbp - 16]
    lea     ARG2, [str_cmd_create_cow]
    call    os_str_eq_ascii
    test    rax, rax
    jnz     .usage

    mov     ARG1, [rbp - 16]
    lea     ARG2, [str_cmd_create_catalog]
    call    os_str_eq_ascii
    test    rax, rax
    jnz     .usage

    mov     ARG1, [rbp - 16]
    lea     ARG2, [str_cmd_create_pax]
    call    os_str_eq_ascii
    test    rax, rax
    jnz     .usage

    mov     ARG1, [rbp - 16]
    lea     ARG2, [str_cmd_create_pax_multi]
    call    os_str_eq_ascii
    test    rax, rax
    jnz     .usage

    mov     ARG1, [rbp - 16]
    lea     ARG2, [str_cmd_create_large]
    call    os_str_eq_ascii
    test    rax, rax
    jnz     .usage

    mov     ARG1, [rbp - 16]
    lea     ARG2, [str_cmd_query]
    call    os_str_eq_ascii
    test    rax, rax
    jnz     .usage

    mov     ARG1, [rbp - 16]
    lea     ARG2, [str_cmd_info]
    call    os_str_eq_ascii
    test    rax, rax
    jnz     .usage

    mov     ARG1, [rbp - 16]
    lea     ARG2, [str_cmd_check]
    call    os_str_eq_ascii
    test    rax, rax
    jnz     .usage

    mov     ARG1, [rbp - 16]
    lea     ARG2, [str_cmd_alloc]
    call    os_str_eq_ascii
    test    rax, rax
    jnz     .usage

    mov     ARG1, [rbp - 16]
    lea     ARG2, [str_cmd_free]
    call    os_str_eq_ascii
    test    rax, rax
    jnz     .usage

    ; None of the subcommands matched: treat as database path for REPL!
    mov     ARG1, [rbp - 16]
    call    cyboudb_repl
    FRAME_END
    ret

.cmd_console:
    mov     ARG1, 2
    call    os_argv
    mov     ARG1, rax
    call    cyboudb_repl
    FRAME_END
    ret

.usage:
    PUTS    msg_usage
    mov     eax, EXIT_USAGE
    FRAME_END
    ret

; ---------------------------------------------------------------- create -----
.cmd_create:
    mov     qword [rbp - 56], 0
    jmp     .create_args
.cmd_create_cow:
    mov     qword [rbp - 56], 1
    jmp     .create_args
.cmd_create_catalog:
    mov     qword [rbp - 56], 2
    jmp     .create_args
.cmd_create_pax:
    mov     qword [rbp - 56], 3
    jmp     .create_args
.cmd_create_pax_multi:
    mov     qword [rbp - 56], 4
    jmp     .create_args
.cmd_create_large:
    mov     qword [rbp - 56], 5
    jmp     .create_args
.cmd_create_compressed:
    mov     qword [rbp - 56], 6
    jmp     .create_args
.cmd_create_tomb:
    mov     qword [rbp - 56], 7
    jmp     .create_args
.create_args:
    cmp     qword [rbp - 8], 4
    jb      .usage

    mov     ARG1, 2
    call    os_argv
    mov     [rbp - 24], rax             ; path

    mov     ARG1, 3
    call    os_argv
    mov     ARG1, rax
    lea     ARG2, [rbp - 32]            ; page count lands here
    call    os_str_to_u64
    test    rax, rax
    jz      .bad_number                 ; garbage, empty or out of range

    ; --- the optional --force and --pax flags --------------------------------
    mov     qword [rbp - 40], 0
    mov     r12, 4
.flag_loop:
    cmp     r12, [rbp - 8]
    jae     .have_flags
    mov     ARG1, r12
    call    os_argv
    mov     r13, rax

    mov     ARG1, r13
    lea     ARG2, [str_opt_force]
    call    os_str_eq_ascii
    test    rax, rax
    jz      .check_flag_pax
    mov     qword [rbp - 40], 1
    inc     r12
    jmp     .flag_loop

.check_flag_pax:
    mov     ARG1, r13
    lea     ARG2, [str_opt_pax]
    call    os_str_eq_ascii
    test    rax, rax
    jz      .check_flag_compress
    mov     qword [rbp - 56], 4         ; create_pax_multi
    inc     r12
    jmp     .flag_loop

.check_flag_compress:
    mov     ARG1, r13
    lea     ARG2, [str_opt_compress]
    call    os_str_eq_ascii
    test    rax, rax
    jz      .usage
    mov     qword [rbp - 56], 6         ; create_compressed
    inc     r12
    jmp     .flag_loop
.have_flags:

    mov     ARG1, [rbp - 24]
    mov     ARG2, [rbp - 32]
    mov     ARG3, [rbp - 40]
    cmp     qword [rbp - 56], 0
    jne     .create_cow
    call    db_create
    jmp     .create_result
.create_cow:
    cmp     qword [rbp - 56], 7
    je      .create_tomb
    cmp     qword [rbp - 56], 6
    je      .create_compressed
    cmp     qword [rbp - 56], 5
    je      .create_large
    cmp     qword [rbp - 56], 4
    je      .create_pax_multi
    cmp     qword [rbp - 56], 3
    je      .create_pax
    cmp     qword [rbp - 56], 2
    je      .create_catalog
    call    db_create_cow
    jmp     .create_result
.create_tomb:
    call    db_create_tombstones
    jmp     .create_result
.create_compressed:
    call    db_create_compressed
    jmp     .create_result
.create_pax_multi:
    call    db_create_pax_multi
    jmp     .create_result
.create_large:
    call    db_create_large
    jmp     .create_result
.create_pax:
    call    db_create_pax
    jmp     .create_result
.create_catalog:
    call    db_create_catalog
.create_result:
    test    rax, rax
    jnz     .fail                       ; RAX holds the core error code

    PUTS    msg_created
    mov     ARG1, [rbp - 32]
    call    put_u64
    PUTS    str_nl

    PUTS    msg_c_pagesize
    mov     ARG1, CybouDB_PAGE_SIZE
    call    put_u64
    PUTS    msg_bytes

    PUTS    msg_c_filesize
    mov     rax, [rbp - 32]
    PAGES_TO_BYTES rax
    mov     ARG1, rax
    call    put_u64
    PUTS    msg_bytes

    mov     eax, EXIT_OK
    FRAME_END
    ret

; ------------------------------------------------------------------ info -----
.cmd_check:
    mov     qword [rbp - 32], 1         ; verify every page, then print the same
    jmp     .open_to_read
.cmd_info:
    mov     qword [rbp - 32], 0
.open_to_read:
    mov     ARG1, 2
    call    os_argv
    mov     [rbp - 24], rax

    mov     ARG1, [rbp - 24]
    lea     ARG2, [rbp + CTX]           ; CybouDB_DB descriptor on our own frame
    mov     ARG3, 0                     ; read-only: inspecting never writes
    mov     ARG4, [rbp - 32]            ; `check` asks for the exhaustive walk
    call    db_open
    test    rax, rax
    jnz     .fail

    lea     ARG1, [rbp + CTX]
    call    print_db_info

    lea     ARG1, [rbp + CTX]
    call    db_close

    mov     eax, EXIT_OK
    FRAME_END
    ret

; ----------------------------------------------------------------- alloc -----
.cmd_alloc:
    cmp     qword [rbp - 8], 4
    jb      .usage

    mov     ARG1, 2
    call    os_argv
    mov     [rbp - 24], rax

    mov     ARG1, 3
    call    os_argv
    mov     ARG1, rax
    lea     ARG2, [rbp - 40]            ; how many pages to hand out
    call    os_str_to_u64
    test    rax, rax
    jz      .bad_number
    cmp     qword [rbp - 40], 0
    je      .bad_number                 ; allocating nothing is a mistake

    mov     ARG1, [rbp - 24]
    lea     ARG2, [rbp + CTX]
    mov     ARG3, 1                     ; read-write: this commits
    xor     ARG4, ARG4
    call    db_open
    test    rax, rax
    jnz     .fail

    PUTS    msg_allocated
.alloc_loop:
    lea     ARG1, [rbp + CTX]
    lea     ARG2, [rbp - 32]            ; the page id lands here
    call    db_alloc_page
    test    rax, rax
    jnz     .fail_close                 ; full, corrupt or read-only

    PUTS    msg_page_item
    mov     ARG1, [rbp - 32]
    call    put_u64
    PUTS    str_nl

    dec     qword [rbp - 40]
    jnz     .alloc_loop

    lea     ARG1, [rbp + CTX]
    call    db_commit
    test    rax, rax
    jnz     .fail_close
    jmp     .report_commit

; ------------------------------------------------------------------ free -----
.cmd_free:
    cmp     qword [rbp - 8], 4
    jb      .usage

    mov     ARG1, 2
    call    os_argv
    mov     [rbp - 24], rax

    mov     ARG1, 3
    call    os_argv
    mov     ARG1, rax
    lea     ARG2, [rbp - 32]            ; the page to release
    call    os_str_to_u64
    test    rax, rax
    jz      .bad_number

    mov     ARG1, [rbp - 24]
    lea     ARG2, [rbp + CTX]
    mov     ARG3, 1                     ; read-write: this commits
    xor     ARG4, ARG4
    call    db_open
    test    rax, rax
    jnz     .fail

    lea     ARG1, [rbp + CTX]
    mov     ARG2, [rbp - 32]
    call    db_free_page
    test    rax, rax
    jnz     .fail_close

    lea     ARG1, [rbp + CTX]
    call    db_commit
    test    rax, rax
    jnz     .fail_close

    PUTS    msg_freed
    mov     ARG1, [rbp - 32]
    call    put_u64
    PUTS    str_nl
    ; fall through to the shared tail

; --- shared tail of alloc and free -------------------------------------------
.report_commit:
    PUTS    msg_committed
    mov     ARG1, [rbp + CTX + DB_GENERATION]
    call    put_u64
    PUTS    str_nl

    PUTS    msg_superblock
    mov     ARG1, [rbp + CTX + DB_SB_PAGE]
    call    put_u64
    PUTS    str_nl

    lea     ARG1, [rbp + CTX]
    call    db_close

    mov     eax, EXIT_OK
    FRAME_END
    ret

; ---------------------------------------------------------------- failure ----
;  RAX holds an CybouDB_E_* code; print the matching message from the table.
;  .fail_close is for failures after db_open succeeded: the descriptor still
;  owns a mapping and a file handle, and the error code has to survive the
;  call that releases them.
; ---------------------------------------------------------------- query -----
.cmd_query:
    cmp     qword [rbp - 8], 4
    jb      .usage

    mov     ARG1, 2
    call    os_argv
    mov     [rbp - 24], rax             ; path

    mov     ARG1, 3
    call    os_argv
    mov     r10, rax                    ; sql arg

    ; Convert sql arg to UTF-8. A statement that does not fit is refused
    ; rather than clipped: half a WHERE clause is still valid SQL, and running
    ; it would silently mean something the user never asked for.
    mov     ARG1, r10
    lea     ARG2, [query_buf]
    mov     ARG3, 65536
    call    os_arg_to_utf8
    cmp     rax, -1
    je      .query_too_long
    mov     [rbp - 32], rax             ; sql_len

    ; On Windows the command line itself is captured into a fixed buffer, so
    ; an oversized invocation loses its tail before argv is even split.
    call    os_cmdline_ok
    test    rax, rax
    jz      .query_too_long

    ; Initialize arena for preliminary parse to check statement type
    lea     ARG1, [query_arena_desc]
    lea     ARG2, [query_arena]
    mov     ARG3, 1048576
    call    sql_arena_init

    ; Parse SQL statement
    lea     ARG1, [query_buf]
    mov     ARG2, [rbp - 32]
    lea     ARG3, [query_arena_desc]
    lea     ARG4, [rbp - 40]            ; out_stmt
    lea     rax, [sql_err_buf]
    PASS_ARG5 rax                       ; out_err
    call    sql_parse
    test    eax, eax
    jnz     .sql_parse_failed

    ; Check whether statement mutates
    mov     r10, [rbp - 40]             ; ast_stmt
    cmp     qword [r10 + AST_STMT_TYPE], STMT_SELECT
    je      .query_ro
    mov     ARG3, 1                     ; writable = 1
    jmp     .query_open
.query_ro:
    mov     ARG3, 0                     ; writable = 0

.query_open:
    mov     ARG1, [rbp - 24]            ; path
    lea     ARG2, [rbp + CTX]           ; CybouDB_DB
    mov     ARG4, 0                     ; exhaustive = 0
    call    db_open
    test    rax, rax
    jnz     .fail

    ; Verify that database supports PAX storage
    test    qword [rbp + CTX + DB_FEATURES], CybouDB_FEATURE_PAX
    jz      .query_no_pax

    ; Execute statement via shared cyboudb_exec_query
    lea     ARG1, [rbp + CTX]
    lea     ARG2, [query_buf]
    mov     ARG3, [rbp - 32]
    call    cyboudb_exec_query
    mov     [rbp - 48], rax             ; save exit status (0 = success, 1 = failure)

    lea     ARG1, [rbp + CTX]
    call    db_close

    mov     rax, [rbp - 48]
    test    rax, rax
    jnz     .query_exit_err

    mov     eax, EXIT_OK
    FRAME_END
    ret

.query_exit_err:
    mov     eax, EXIT_FAILURE
    FRAME_END
    ret

.query_no_pax:
    lea     ARG1, [rbp + CTX]
    call    db_close
    PUTS    err_no_pax_cli
    mov     eax, EXIT_FAILURE
    FRAME_END
    ret

.query_too_long:
    PUTS    err_query_too_long
    mov     eax, EXIT_FAILURE
    FRAME_END
    ret

.sql_parse_failed:
    call    print_sql_error
    mov     eax, EXIT_FAILURE
    FRAME_END
    ret

.fail_close:
    mov     [rbp - 48], rax
    lea     ARG1, [rbp + CTX]
    call    db_close
    mov     rax, [rbp - 48]
    jmp     .fail

.bad_number:
    mov     eax, CybouDB_E_PAGES
.fail:
    cmp     rax, CybouDB_E_COUNT
    jb      .fail_known
    xor     eax, eax                    ; unknown code - fall back to a generic
.fail_known:                            ; message
    lea     r10, [err_table]
    mov     ARG1, [r10 + rax * 8]
    call    puts_asciiz
    mov     eax, EXIT_FAILURE
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  print_db_info(ARG1 = pointer to CybouDB_DB)
; -----------------------------------------------------------------------------
print_db_info:
    FRAME_BEGIN 16, 0
    mov     [rbp - 8], ARG1
    mov     r9, ARG1

    PUTS    msg_info_title
    PUTS    msg_magic
    mov     r9, [rbp - 8]
    cmp     qword [r9 + DB_FEATURES], 0
    je      .info_legacy
    test    qword [r9 + DB_FEATURES], CybouDB_FEATURE_MAP_SPAN
    jnz     .info_large
    test    qword [r9 + DB_FEATURES], CybouDB_FEATURE_PAX
    jnz     .info_pax
    test    qword [r9 + DB_FEATURES], CybouDB_FEATURE_CATALOG
    jnz     .info_catalog
    PUTS    msg_storage_cow
    jmp     .info_mode_done
.info_pax:
    test    qword [r9 + DB_FEATURES], CybouDB_FEATURE_PAX_MULTI
    jnz     .info_pax_multi
    PUTS    msg_storage_pax
    jmp     .info_mode_done
.info_pax_multi:
    PUTS    msg_storage_pax_multi
    jmp     .info_mode_done
.info_large:
    PUTS    msg_storage_large
    jmp     .info_mode_done
.info_catalog:
    PUTS    msg_storage_catalog
    jmp     .info_mode_done
.info_legacy:
    PUTS    msg_storage_legacy
.info_mode_done:

    mov     r9, [rbp - 8]
    test    qword [r9 + DB_FEATURES], CybouDB_FEATURE_PAX
    jz      .info_leaves_done
    test    qword [r9 + DB_FEATURES], CybouDB_FEATURE_PAX_RUNS
    jz      .info_leaves_sparse
    PUTS    msg_leaves_dense
    jmp     .info_leaves_done
.info_leaves_sparse:
    PUTS    msg_leaves_sparse
.info_leaves_done:

    PUTS    msg_version
    mov     r9, [rbp - 8]
    mov     r10, [r9 + DB_BASE]
    mov     ARG1d, [r10 + HDR_VERSION]
    call    put_u64
    PUTS    str_nl

    PUTS    msg_page_size
    mov     r9, [rbp - 8]
    mov     r10, [r9 + DB_BASE]
    mov     ARG1d, [r10 + HDR_PAGE_SIZE]
    call    put_u64
    PUTS    msg_bytes

    PUTS    msg_total_pages
    mov     r9, [rbp - 8]
    mov     ARG1, [r9 + DB_PAGES]
    call    put_u64
    PUTS    str_nl

    PUTS    msg_alloc_pages
    mov     r9, [rbp - 8]
    mov     ARG1, [r9 + DB_ALLOC]
    call    put_u64
    PUTS    str_nl

    PUTS    msg_freelist
    mov     r9, [rbp - 8]
    mov     ARG1, [r9 + DB_FREELIST]
    call    put_u64
    PUTS    str_nl

    PUTS    msg_generation
    mov     r9, [rbp - 8]
    mov     ARG1, [r9 + DB_GENERATION]
    call    put_u64
    PUTS    str_nl

    PUTS    msg_superblock
    mov     r9, [rbp - 8]
    mov     ARG1, [r9 + DB_SB_PAGE]
    call    put_u64
    PUTS    str_nl

    PUTS    msg_file_size
    mov     r9, [rbp - 8]
    mov     ARG1, [r9 + DB_SIZE]
    call    put_u64
    PUTS    msg_bytes

    PUTS    msg_status_ok
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  cyboudb_exec_query(ARG1 = db_ctx, ARG2 = sql_str, ARG3 = sql_len)
;    -> EAX: 0 on success, 1 on failure
; -----------------------------------------------------------------------------
cyboudb_exec_query:
    FRAME_BEGIN 96, 2
    mov     [rbp - 8], ARG1             ; db_ctx
    mov     [rbp - 16], ARG2            ; sql_str
    mov     [rbp - 24], ARG3            ; sql_len
    mov     qword [rbp - 32], 0         ; out_stmt
    mov     qword [rbp - 40], 0         ; out_plan
    mov     qword [rbp - 48], 0         ; total_rows

    ; Preserve callee-saved registers
    mov     [rbp - 56], rbx
    mov     [rbp - 64], r12
    mov     [rbp - 72], r13
    mov     [rbp - 80], r14

    ; 1. Copy sql_str to query_buf if not already pointing there
    mov     rsi, [rbp - 16]
    lea     rdi, [query_buf]
    cmp     rsi, rdi
    je      .sql_in_query_buf

    mov     rcx, [rbp - 24]
    cmp     rcx, 262140
    jbe     .len_fit
    mov     rcx, 262140
.len_fit:
    mov     [rbp - 24], rcx
    xor     rdx, rdx
.copy_q:
    cmp     rdx, rcx
    jae     .copy_q_done
    mov     al, [rsi + rdx]
    mov     [rdi + rdx], al
    inc     rdx
    jmp     .copy_q
.copy_q_done:
    mov     byte [rdi + rcx], 0

.sql_in_query_buf:
    mov     rcx, [rbp - 24]
    lea     rdi, [query_buf]
    mov     byte [rdi + rcx], 0

    ; 2. Initialize SQL arena
    lea     ARG1, [query_arena_desc]
    lea     ARG2, [query_arena]
    mov     ARG3, 1048576
    call    sql_arena_init

    ; 3. Parse SQL statement
    lea     ARG1, [query_buf]
    mov     ARG2, [rbp - 24]
    lea     ARG3, [query_arena_desc]
    lea     ARG4, [rbp - 32]            ; out_stmt
    lea     rax, [sql_err_buf]
    PASS_ARG5 rax                       ; out_err
    call    sql_parse
    test    eax, eax
    jnz     .parse_fail

    ; 4. Bind statement against database schema
    mov     ARG1, [rbp - 8]             ; db_ctx
    mov     ARG2, [rbp - 32]            ; ast_stmt
    lea     ARG3, [query_arena_desc]
    lea     ARG4, [rbp - 40]            ; out_plan
    lea     rax, [sql_err_buf]
    PASS_ARG5 rax                       ; out_err
    call    sql_bind
    test    eax, eax
    jnz     .bind_fail

    ; 5. Dispatch based on statement type
    mov     r10, [rbp - 40]             ; bound_plan
    cmp     qword [r10 + PLAN_TYPE], STMT_SELECT
    je      .exec_select

    ; Non-SELECT: CREATE TABLE or INSERT
    ; Check if database is writable
    mov     r9, [rbp - 8]               ; db_ctx
    cmp     qword [r9 + DB_WRITABLE], 1
    je      .is_writable
    ; Read-only database error
    mov     eax, CybouDB_E_READONLY
    jmp     .storage_fail

.is_writable:
    mov     ARG1, [rbp - 8]             ; db_ctx
    mov     ARG2, [rbp - 40]            ; bound_plan
    lea     ARG3, [query_arena_desc]
    xor     ARG4, ARG4                  ; cb = NULL
    xor     eax, eax
    PASS_ARG5 rax                       ; cb_ctx = NULL
    lea     rax, [sql_err_buf]
    PASS_ARG6 rax                       ; out_err
    call    sql_execute
    test    rax, rax
    jnz     .exec_fail

    ; Check if transaction control statement
    mov     r10, [rbp - 40]
    cmp     qword [r10 + PLAN_TYPE], STMT_BEGIN
    je      .begin_done
    cmp     qword [r10 + PLAN_TYPE], STMT_COMMIT
    je      .commit_done
    cmp     qword [r10 + PLAN_TYPE], STMT_ROLLBACK
    je      .rollback_done

    ; If inside an active transaction, do NOT autocommit!
    mov     r9, [rbp - 8]
    cmp     qword [r9 + DB_TX_ACTIVE], 0
    jne     .mutation_done

    ; A predicate that matched no UPDATE rows staged no pages. Preserve the
    ; generation as well as the data instead of publishing an empty commit.
    cmp     qword [r10 + PLAN_TYPE], STMT_DELETE
    jne     .check_empty_update
    cmp     qword [r10 + PLAN_DELETE_ROWS], 0
    je      .mutation_done
    jmp     .commit_mutation
.check_empty_update:
    cmp     qword [r10 + PLAN_TYPE], STMT_UPDATE
    jne     .commit_mutation
    cmp     qword [r10 + PLAN_DATA1], 0
    je      .mutation_done
.commit_mutation:
    ; Autocommit mutating statements
    mov     ARG1, [rbp - 8]             ; db_ctx
    call    db_commit
    test    rax, rax
    jnz     .storage_fail

.mutation_done:
    mov     r10, [rbp - 40]
    cmp     qword [r10 + PLAN_TYPE], STMT_CREATE_TABLE
    je      .create_done
    cmp     qword [r10 + PLAN_TYPE], STMT_DROP_TABLE
    je      .drop_done
    cmp     qword [r10 + PLAN_TYPE], STMT_UPDATE
    je      .update_done
    cmp     qword [r10 + PLAN_TYPE], STMT_DELETE
    je      .delete_done
    cmp     qword [r10 + PLAN_TYPE], STMT_CREATE_INDEX
    je      .index_created
    cmp     qword [r10 + PLAN_TYPE], STMT_DROP_INDEX
    je      .index_dropped
    cmp     qword [r10 + PLAN_TYPE], STMT_CREATE_QUEUE
    je      .queue_created
    cmp     qword [r10 + PLAN_TYPE], STMT_DROP_QUEUE
    je      .queue_dropped
    cmp     qword [r10 + PLAN_TYPE], STMT_CREATE_STREAM
    je      .stream_created
    cmp     qword [r10 + PLAN_TYPE], STMT_DROP_STREAM
    je      .stream_dropped
    cmp     qword [r10 + PLAN_TYPE], STMT_ENQUEUE
    je      .enqueued
    cmp     qword [r10 + PLAN_TYPE], STMT_DEQUEUE
    je      .dequeued
    ; Anything else has to say so rather than be assumed to be an INSERT. It
    ; used to fall through into the line below, which reads PLAN_DATA1 as a
    ; batch - and a statement that leaves that field zero, as DROP QUEUE does,
    ; took the process with it. A new statement kind should print the wrong
    ; word at worst.
    cmp     qword [r10 + PLAN_TYPE], STMT_INSERT
    jne     .mutation_unnamed

    ; Insert completed: print "INSERT <rows>\n"
    PUTS    msg_sql_insert_prefix
    mov     r10, [rbp - 40]
    mov     r11, [r10 + PLAN_DATA1]     ; batch
    mov     ARG1, [r11 + BATCH_ROWS]
    call    put_u64
    PUTS    str_nl
    jmp     .exec_success

.begin_done:
    PUTS    msg_sql_begin
    jmp     .exec_success

.commit_done:
    PUTS    msg_sql_commit
    jmp     .exec_success

.rollback_done:
    PUTS    msg_sql_rollback
    jmp     .exec_success

.update_done:
    PUTS    msg_sql_update_prefix
    mov     r10, [rbp - 40]
    mov     ARG1, [r10 + PLAN_DATA1]
    call    put_u64
    PUTS    str_nl
    jmp     .exec_success

.delete_done:
    PUTS    msg_sql_delete_prefix
    mov     r10, [rbp - 40]
    mov     ARG1, [r10 + PLAN_DELETE_ROWS]
    call    put_u64
    PUTS    str_nl
    jmp     .exec_success

.drop_done:
    PUTS    msg_sql_table_dropped
    jmp     .exec_success

.create_done:
    PUTS    msg_sql_table_created
    jmp     .exec_success

.enqueued:
    PUTS    msg_sql_enqueued
    jmp     .exec_success

; The payload, as the bytes it is. A queue stores what it was given and has no
; column to say how to read it back, so printing it is printing bytes.
.dequeued:
    mov     r10, [rbp - 40]
    cmp     qword [r10 + PLAN_DATA3], 0
    je      .dequeued_empty
    mov     ARG1, [r10 + PLAN_DATA1]
    mov     ARG2, [r10 + PLAN_DATA2]
    call    os_write
    PUTS    str_nl
    jmp     .exec_success
.dequeued_empty:
    PUTS    msg_sql_queue_empty
    jmp     .exec_success

.queue_created:
    PUTS    msg_sql_queue_created
    jmp     .exec_success

.queue_dropped:
    PUTS    msg_sql_queue_dropped
    jmp     .exec_success

.stream_created:
    PUTS    msg_sql_stream_created
    jmp     .exec_success

.stream_dropped:
    PUTS    msg_sql_stream_dropped
    jmp     .exec_success

.mutation_unnamed:
    PUTS    msg_sql_done
    jmp     .exec_success

.index_created:
    PUTS    msg_sql_index_created
    jmp     .exec_success

.index_dropped:
    PUTS    msg_sql_index_dropped
    jmp     .exec_success

.exec_select:
    ; Print column headers
    mov     r10, [rbp - 40]
    test    qword [r10 + PLAN_FLAGS], PLAN_FLAG_COUNT_STAR
    jnz     .hdr_count_star

    mov     r12, [r10 + PLAN_SCHEMA_PAGE]
    mov     r13, [r10 + PLAN_DATA1]     ; proj_count
    mov     r14, [r10 + PLAN_DATA2]     ; proj_indices
    xor     r15d, r15d
    cmp     qword [r10 + PLAN_JOIN_TYPE], 0
    je      .hdr_sources_ready
    mov     r15, [r10 + PLAN_JOIN_PROJECTIONS]
.hdr_sources_ready:

    xor     rbx, rbx                    ; p = 0
.hdr_loop:
    test    rbx, rbx
    jz      .hdr_no_sep
    PUTS    str_pipe_sep
.hdr_no_sep:
    mov     r11, r12                    ; default: left schema
    mov     eax, [r14 + rbx * 4]        ; ordinary physical col_idx
    test    r15, r15
    jz      .hdr_column_ready
    mov     eax, [r15 + rbx * 4]        ; joined source descriptor
    test    eax, PLAN_PROJ_RIGHT_BIT
    jz      .hdr_join_left
    and     eax, 0x7fffffff
    mov     r10, [rbp - 40]
    mov     r11, [r10 + PLAN_RIGHT_SCHEMA]
.hdr_join_left:
.hdr_column_ready:
    shl     rax, 5
    lea     ARG1, [r11 + CAT_COLUMNS + rax + 8] ; col name
    call    puts_asciiz
    inc     rbx
    cmp     rbx, r13
    jb      .hdr_loop

    PUTS    str_nl

    ; Print underline dashes
    xor     rbx, rbx
.dash_loop:
    test    rbx, rbx
    jz      .dash_no_sep
    PUTS    str_pipe_sep
.dash_no_sep:
    PUTS    str_dash_col
    inc     rbx
    cmp     rbx, r13
    jb      .dash_loop

    PUTS    str_nl
    jmp     .exec_select_rows

.hdr_count_star:
    PUTS    str_count_star_col
    PUTS    str_nl
    PUTS    str_dash_col
    PUTS    str_nl

.exec_select_rows:
    ; Execute SELECT with callback
    mov     qword [rbp - 48], 0         ; total_rows = 0
    mov     ARG1, [rbp - 8]             ; db_ctx
    mov     r10, [rbp - 40]             ; bound_plan
    mov     ARG2, r10
    lea     ARG3, [query_arena_desc]
    lea     ARG4, [query_row_callback]
    lea     rax, [rbp - 48]
    PASS_ARG5 rax
    mov     [row_cb_plan], r10
    lea     rax, [sql_err_buf]
    PASS_ARG6 rax
    call    sql_execute
    test    rax, rax
    jnz     .exec_fail

    ; Print row count summary
    PUTS    msg_sql_rows_prefix
    mov     ARG1, [rbp - 48]
    call    put_u64
    cmp     qword [rbp - 48], 1
    je      .one_row
    PUTS    msg_sql_rows_suffix
    jmp     .exec_success
.one_row:
    PUTS    msg_sql_row_suffix

.exec_success:
    mov     rbx, [rbp - 56]
    mov     r12, [rbp - 64]
    mov     r13, [rbp - 72]
    mov     r14, [rbp - 80]
    xor     eax, eax
    FRAME_END
    ret

.parse_fail:
.bind_fail:
    call    print_sql_error
    mov     rbx, [rbp - 56]
    mov     r12, [rbp - 64]
    mov     r13, [rbp - 72]
    mov     r14, [rbp - 80]
    mov     eax, 1
    FRAME_END
    ret

.exec_fail:
    cmp     qword [sql_err_buf + SQL_ERR_DOMAIN], SQL_DOMAIN_STORAGE
    je      .storage_fail
    PUTS    str_error_prefix
    lea     ARG1, [sql_err_buf + SQL_ERR_MSG]
    call    puts_asciiz
    PUTS    str_nl
    mov     rbx, [rbp - 56]
    mov     r12, [rbp - 64]
    mov     r13, [rbp - 72]
    mov     r14, [rbp - 80]
    mov     eax, 1
    FRAME_END
    ret

.storage_fail:
    cmp     rax, CybouDB_E_COUNT
    jb      .storage_fail_known
    xor     eax, eax
.storage_fail_known:
    lea     r10, [err_table]
    mov     ARG1, [r10 + rax * 8]
    call    puts_asciiz
    mov     rbx, [rbp - 56]
    mov     r12, [rbp - 64]
    mov     r13, [rbp - 72]
    mov     r14, [rbp - 80]
    mov     eax, 1
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  puts_asciiz(ARG1 = pointer to a zero-terminated ASCII string)
;  Measures the length and hands the buffer to os_write in one call.
; -----------------------------------------------------------------------------
puts_asciiz:
    FRAME_BEGIN 16, 0                   ; [rbp-8] = saved pointer
    mov     [rbp - 8], ARG1
    mov     r10, ARG1
    xor     r11d, r11d
.len:
    cmp     byte [r10 + r11], 0
    je      .done
    inc     r11
    jmp     .len
.done:
    mov     ARG1, [rbp - 8]
    mov     ARG2, r11
    call    os_write
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  put_u64(ARG1 = unsigned 64-bit value) - print it in decimal.
;  Digits are produced from the end of the buffer, so no reversal is needed.
; -----------------------------------------------------------------------------
put_u64:
    FRAME_BEGIN 0, 0
    mov     rax, ARG1
    lea     r11, [numbuf + 31]
    mov     byte [r11], 0
    mov     r9d, 10
.digit:
    xor     edx, edx
    div     r9                          ; RDX:RAX / 10 -> RAX quotient, RDX rem
    add     dl, '0'
    dec     r11
    mov     [r11], dl
    test    rax, rax
    jnz     .digit

    mov     ARG1, r11
    call    puts_asciiz
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  put_s64(ARG1 = signed 64-bit value) - print decimal with optional minus sign
; -----------------------------------------------------------------------------
put_s64:
    FRAME_BEGIN 16, 0
    mov     rax, ARG1
    test    rax, rax
    jns     .s64_pos
    neg     rax
    mov     [rbp - 8], rax
    PUTS    str_minus
    mov     rax, [rbp - 8]
.s64_pos:
    mov     ARG1, rax
    call    put_u64
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  put_f32(ARG1 = 32-bit IEEE float bits) - print decimal float
; -----------------------------------------------------------------------------
put_f32:
    FRAME_BEGIN 32, 0
    mov     eax, ARG1d
    test    eax, 0x80000000
    jz      .f_pos
    mov     [rbp - 8], eax
    PUTS    str_minus
    mov     eax, [rbp - 8]
    and     eax, 0x7FFFFFFF
.f_pos:
    movd    xmm0, eax
    cvttss2si rax, xmm0
    mov     [rbp - 16], rax
    cvtsi2ss xmm1, rax
    subss   xmm0, xmm1
    mulss   xmm0, [flt_100]
    cvttss2si rdx, xmm0
    mov     [rbp - 24], rdx

    mov     ARG1, [rbp - 16]
    call    put_u64
    PUTS    str_dot

    mov     rax, [rbp - 24]
    cmp     rax, 10
    jae     .f_two
    PUTS    str_zero
.f_two:
    mov     ARG1, [rbp - 24]
    call    put_u64
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  print_sql_error - displays syntax/binder error with offset and caret
; -----------------------------------------------------------------------------
print_sql_error:
    FRAME_BEGIN 16, 0
    PUTS    str_error_prefix
    lea     ARG1, [sql_err_buf + SQL_ERR_MSG]
    call    puts_asciiz
    PUTS    str_at_offset
    mov     ARG1, [sql_err_buf + SQL_ERR_OFFSET]
    call    put_u64
    PUTS    str_nl

    PUTS    str_two_spaces
    lea     ARG1, [query_buf]
    call    puts_asciiz
    PUTS    str_nl

    PUTS    str_two_spaces
    mov     rcx, [sql_err_buf + SQL_ERR_OFFSET]
    cmp     rcx, 200
    ja      .skip_caret
.err_spaces:
    test    rcx, rcx
    jz      .draw_caret
    mov     [rbp - 8], rcx
    PUTS    str_space
    mov     rcx, [rbp - 8]
    dec     rcx
    jmp     .err_spaces
.draw_caret:
    PUTS    str_caret
.skip_caret:
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  query_row_callback(cb_ctx, proj_count, row_values, row_nulls) -> RAX: 0
; -----------------------------------------------------------------------------
query_row_callback:
    FRAME_BEGIN 112, 0
    mov     [rbp - 8], ARG1             ; cb_ctx
    mov     [rbp - 16], ARG2            ; proj_count
    mov     [rbp - 24], ARG3            ; row_values
    mov     [rbp - 32], ARG4            ; row_nulls
    mov     rax, IN_ARG5
    mov     [rbp - 96], rax             ; row varlen lengths

    ; Preserve callee-saved registers
    mov     [rbp - 40], rbx
    mov     [rbp - 48], r12
    mov     [rbp - 56], r13
    mov     [rbp - 64], r14
    mov     [rbp - 72], r15
    mov     [rbp - 80], rsi
    mov     [rbp - 88], rdi

    mov     r10, [row_cb_plan]
    mov     r12, [r10 + PLAN_DATA3]     ; proj_types array

    xor     rbx, rbx                    ; p = 0
.cell_loop:
    test    rbx, rbx
    jz      .no_cell_sep
    PUTS    str_pipe_sep
.no_cell_sep:
    mov     rsi, [rbp - 32]             ; row_nulls
    cmp     byte [rsi + rbx], 1
    je      .cell_null

    mov     eax, [r12 + rbx * 4]        ; col_type
    mov     rsi, [rbp - 24]
    mov     rdx, [rsi + rbx * 8]        ; col_value

    cmp     eax, CAT_INT32
    je      .cell_i32
    cmp     eax, CAT_INT64
    je      .cell_i64
    cmp     eax, CAT_FLOAT32
    je      .cell_f32
    cmp     eax, CAT_BOOL
    je      .cell_bool
    cmp     eax, CAT_TEXT
    je      .cell_text
    cmp     eax, CAT_BLOB
    je      .cell_blob
    cmp     eax, CAT_VECTOR
    je      .cell_vector

    mov     ARG1, rdx
    call    put_u64
    jmp     .next_p

.cell_null:
    PUTS    str_null
    jmp     .next_p

.cell_i32:
    movsxd  ARG1, edx
    call    put_s64
    jmp     .next_p

.cell_i64:
    mov     ARG1, rdx
    call    put_s64
    jmp     .next_p

.cell_f32:
    mov     ARG1d, edx
    call    put_f32
    jmp     .next_p

.cell_bool:
    test    dl, dl
    jz      .cell_bool_false
    PUTS    str_true
    jmp     .next_p
.cell_bool_false:
    PUTS    str_false
    jmp     .next_p

.cell_text:
    mov     r11, rdx                    ; ARG3 is RDX under SysV: preserve root
    mov     rsi, [rbp - 96]
    mov     ARG3, [rsi + rbx * 8]
    mov     ARG2, r11
    mov     r10, [row_cb_plan]
    mov     r10, [r10 + PLAN_CTX]
    mov     ARG1, [r10 + DB_BASE]
    xor     ARG4d, ARG4d
    call    print_varlen
    jmp     .next_p

.cell_blob:
    mov     r11, rdx                    ; ARG3 is RDX under SysV: preserve root
    mov     rsi, [rbp - 96]
    mov     ARG3, [rsi + rbx * 8]
    mov     ARG2, r11
    mov     r10, [row_cb_plan]
    mov     r10, [r10 + PLAN_CTX]
    mov     ARG1, [r10 + DB_BASE]
    mov     ARG4, 1
    call    print_varlen
    jmp     .next_p

.cell_vector:
    mov     r11, rdx                    ; ARG3 is RDX under SysV: preserve root
    mov     rsi, [rbp - 96]
    mov     ARG3, [rsi + rbx * 8]
    mov     ARG2, r11
    mov     r10, [row_cb_plan]
    mov     r10, [r10 + PLAN_CTX]
    mov     ARG1, [r10 + DB_BASE]
    call    print_vector
    jmp     .next_p

.next_p:
    inc     rbx
    cmp     rbx, [rbp - 16]
    jb      .cell_loop

    PUTS    str_nl

    ; Increment total rows count
    mov     r10, [rbp - 8]
    inc     qword [r10]

    ; Restore callee-saved registers
    mov     rbx, [rbp - 40]
    mov     r12, [rbp - 48]
    mov     r13, [rbp - 56]
    mov     r14, [rbp - 64]
    mov     r15, [rbp - 72]
    mov     rsi, [rbp - 80]
    mov     rdi, [rbp - 88]

    xor     eax, eax                    ; continue scanning
    FRAME_END
    ret

; print_varlen(base, root, length, hex_mode). The PAX graph walk validated the
; complete chain before the descriptor reached this output sink.
print_varlen:
    FRAME_BEGIN 80, 0
    mov     [rbp - 8], ARG1
    mov     [rbp - 16], ARG2
    mov     [rbp - 24], ARG3
    mov     [rbp - 32], ARG4
    test    ARG4, ARG4
    jz      .var_page
    PUTS    str_blob_open
.var_page:
    cmp     qword [rbp - 24], 0
    je      .var_done
    mov     r10, [rbp - 16]
    shl     r10, CybouDB_PAGE_SHIFT
    add     r10, [rbp - 8]
    mov     rax, [r10 + VAR_NEXT]
    mov     [rbp - 40], rax
    mov     eax, [r10 + VAR_USED]
    mov     [rbp - 48], rax
    mov     [rbp - 64], rax
    lea     r10, [r10 + VAR_DATA]
    mov     [rbp - 56], r10
    cmp     qword [rbp - 32], 0
    jne     .var_hex
    mov     ARG1, r10
    mov     ARG2, [rbp - 48]
    call    os_write
    jmp     .var_advance
.var_hex:
    mov     r10, [rbp - 56]
    movzx   eax, byte [r10]
    mov     ecx, eax
    shr     eax, 4
    and     ecx, 15
    lea     r11, [hex_digits]
    mov     al, [r11 + rax]
    mov     [numbuf], al
    mov     al, [r11 + rcx]
    mov     [numbuf + 1], al
    lea     ARG1, [numbuf]
    mov     ARG2, 2
    call    os_write
    inc     qword [rbp - 56]
    dec     qword [rbp - 48]
    jnz     .var_hex
.var_advance:
    mov     rax, [rbp - 64]
    sub     [rbp - 24], rax
    mov     rax, [rbp - 40]
    mov     [rbp - 16], rax
    jmp     .var_page
.var_done:
    cmp     qword [rbp - 32], 0
    je      .var_return
    PUTS    str_quote
.var_return:
    FRAME_END
    ret

; print_vector(base, root, length).
print_vector:
    FRAME_BEGIN 80, 0
    mov     [rbp - 8], ARG1             ; base
    mov     [rbp - 16], ARG2            ; root
    mov     [rbp - 24], ARG3            ; length
    mov     qword [rbp - 64], 0         ; first_flag = 0

    PUTS    str_lbracket

.vec_page:
    cmp     qword [rbp - 24], 0
    je      .vec_done
    cmp     qword [rbp - 16], 0
    je      .vec_done

    mov     r10, [rbp - 16]
    shl     r10, CybouDB_PAGE_SHIFT
    add     r10, [rbp - 8]
    mov     rax, [r10 + VAR_NEXT]
    mov     [rbp - 32], rax
    mov     eax, [r10 + VAR_USED]
    mov     [rbp - 40], rax
    lea     r10, [r10 + VAR_DATA]
    mov     [rbp - 48], r10

.vec_elem:
    cmp     qword [rbp - 40], 4
    jb      .vec_next_page
    cmp     qword [rbp - 24], 4
    jb      .vec_next_page

    cmp     qword [rbp - 64], 0
    je      .vec_elem_val
    PUTS    str_comma_sp

.vec_elem_val:
    mov     qword [rbp - 64], 1
    mov     r10, [rbp - 48]
    mov     ARG1d, [r10]
    call    put_f32

    add     qword [rbp - 48], 4
    sub     qword [rbp - 40], 4
    sub     qword [rbp - 24], 4
    jmp     .vec_elem

.vec_next_page:
    mov     rax, [rbp - 32]
    mov     [rbp - 16], rax
    jmp     .vec_page

.vec_done:
    PUTS    str_rbracket
    FRAME_END
    ret



%ifdef CybouDB_LINUX
section .note.GNU-stack noalloc noexec nowrite progbits
%endif
