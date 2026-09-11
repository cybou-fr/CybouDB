; =============================================================================
;  src/console/repl.asm - CybouDB Interactive Console and Batch REPL
; =============================================================================
;  Phase 4: Interactive console and piped batch execution.
;
;  Features:
;    - Interactive input from terminal (Windows ReadConsoleW, Linux stdin)
;    - Stream reading for redirected pipes (cat script.sql | cyboudb db.cdb)
;    - Multiline SQL statement accumulation until terminating semicolon ';'
;    - Multiple statements per line support
;    - Trailing statement execution on EOF
;    - Meta-commands: .tables, .schema [TABLE], .info, .help, .quit / .exit
;    - Clean error reporting without terminating the interactive session
;    - Autocommit after mutating statements (CREATE TABLE, INSERT INTO, UPDATE)
; =============================================================================

%include "cyboudb.inc"
%include "sql.inc"

BITS 64
default rel

; --- OS & Core Imports -------------------------------------------------------
extern os_stdin_isatty
extern os_read_stdin
%ifdef CybouDB_WINDOWS
extern os_read_console
%endif
extern db_open, db_close
extern puts_asciiz, put_u64
extern print_db_info, cyboudb_exec_query

global cyboudb_repl

; Print string literal macro
%macro PUTS 1
    lea     ARG1, [%1]
    call    puts_asciiz
%endmacro

; =============================================================================
section .data

str_prompt_primary:     db "cyboudb> ", 0
str_prompt_continue:    db "  ...> ", 0
str_banner_1:           db "CybouDB Interactive Console", 10
                        db "Enter .help for usage hints, .quit to exit.", 10, 0
str_help_text:          db "Available meta-commands:", 10
                        db "  .help           Show this help message", 10
                        db "  .info           Show database metadata", 10
                        db "  .schema [TABLE] Show CREATE TABLE statement(s)", 10
                        db "  .tables         List all tables", 10
                        db "  .quit           Exit the console", 10
                        db "  .exit           Exit the console", 10, 0

str_meta_quit:          db ".quit", 0
str_meta_exit:          db ".exit", 0
str_meta_help:          db ".help", 0
str_meta_info:          db ".info", 0
str_meta_tables:        db ".tables", 0
str_meta_schema:        db ".schema", 0

str_err_unknown_meta:   db 'Error: unknown command: "', 0
str_err_unknown_suffix: db '". Enter ".help" for a list of commands.', 10, 0
str_err_table_not_found: db "Error: table not found: ", 0
str_msg_no_catalog:     db "Database does not contain a catalog.", 10, 0

str_create_table_pfx:   db "CREATE TABLE ", 0
str_open_paren:         db " (", 10, 0
str_close_paren:        db ");", 10, 0
str_col_indent:         db "  ", 0
str_comma_nl:           db ",", 10, 0
str_not_null:           db " NOT NULL", 0

str_type_int32:         db "INT32", 0
str_type_int64:         db "INT64", 0
str_type_float32:       db "FLOAT32", 0
str_type_bool:          db "BOOL", 0
str_type_unknown:       db "UNKNOWN", 0

str_repl_nl:            db 10, 0
str_err_input_limit:    db "error: REPL input exceeds line or statement limit; session stopped.", 10, 0

; =============================================================================
section .bss
    align 8

; Persistent REPL database context (CybouDB_DB descriptor)
repl_db_ctx:            resb CybouDB_DB_SIZE

; Stream input buffer for non-terminal reads (pipe / redirection)
stream_buf:             resb 4096
stream_pos:             resq 1
stream_len:             resq 1
stream_eof:             resq 1

; Line input buffer (4 KiB)
line_buf:               resb 4097

; SQL statement accumulation buffer (256 KiB)
repl_sql_buf:           resb 262144
repl_sql_len:           resq 1

; Flag: 1 if interactive terminal, 0 if redirected pipe
is_interactive:         resq 1
repl_had_error:         resq 1

; =============================================================================
section .text

; -----------------------------------------------------------------------------
;  cyboudb_repl(ARG1 = db_path) -> EAX: process exit code
; -----------------------------------------------------------------------------
cyboudb_repl:
    FRAME_BEGIN 32, 0
    mov     [rbp - 8], ARG1             ; db_path

    ; Initialize stream reader state
    mov     qword [stream_pos], 0
    mov     qword [stream_len], 0
    mov     qword [stream_eof], 0
    mov     qword [repl_sql_len], 0
    mov     qword [repl_had_error], 0

    ; Check whether stdin is an interactive terminal
    call    os_stdin_isatty
    mov     [is_interactive], rax

    ; Open the database (try read-write first, fall back to read-only)
    mov     ARG1, [rbp - 8]
    lea     ARG2, [repl_db_ctx]
    mov     ARG3, 1                     ; writable = 1
    xor     ARG4, ARG4                  ; exhaustive = 0
    call    db_open
    test    rax, rax
    jz      .open_ok

    ; If opening read-write failed, attempt read-only
    mov     ARG1, [rbp - 8]
    lea     ARG2, [repl_db_ctx]
    xor     ARG3, ARG3                  ; writable = 0
    xor     ARG4, ARG4
    call    db_open
    test    rax, rax
    jnz     .open_failed

.open_ok:
    ; Verify that database supports PAX storage
    test    qword [repl_db_ctx + DB_FEATURES], CybouDB_FEATURE_PAX
    jz      .err_no_pax

    ; If interactive, print startup banner
    cmp     qword [is_interactive], 1
    jne     .repl_loop
    PUTS    str_banner_1

.repl_loop:
    ; 1. Show prompt if interactive
    cmp     qword [is_interactive], 1
    jne     .read_next_line

    cmp     qword [repl_sql_len], 0
    jne     .show_prompt_continue
    PUTS    str_prompt_primary
    jmp     .read_next_line

.show_prompt_continue:
    PUTS    str_prompt_continue

.read_next_line:
    ; 2. Read a line from stdin
    lea     ARG1, [line_buf]
    mov     ARG2, 4096                  ; allow CR before LF at the 4095-byte limit
    call    repl_read_line
    cmp     rax, -1
    je      .handle_eof                 ; EOF reached on input
    cmp     rax, -2
    je      .input_overflow
    cmp     rax, 4095
    ja      .input_overflow

    mov     [rbp - 16], rax             ; line_len (excluding trailing \r/\n)

    ; 3. Check for meta-commands (only when statement accumulator is empty)
    cmp     qword [repl_sql_len], 0
    jne     .accumulate_sql

    ; Skip leading whitespace on line
    xor     rsi, rsi
    lea     r11, [line_buf]
.skip_leading_ws:
    cmp     rsi, [rbp - 16]
    jae     .repl_loop                  ; empty / blank line
    movzx   eax, byte [r11 + rsi]
    cmp     al, ' '
    je      .inc_ws
    cmp     al, 9                       ; '\t'
    je      .inc_ws
    cmp     al, 13                      ; '\r'
    je      .inc_ws
    jmp     .check_meta_char
.inc_ws:
    inc     rsi
    jmp     .skip_leading_ws

.check_meta_char:
    cmp     byte [r11 + rsi], '.'
    jne     .accumulate_sql

    ; It is a meta-command!
    mov     rax, [rbp - 16]
    sub     rax, rsi
    mov     ARG3, rax                   ; remaining line len
    lea     ARG2, [r11 + rsi]
    lea     ARG1, [repl_db_ctx]
    call    repl_handle_meta
    test    rax, rax
    jnz     .repl_exit_clean            ; .quit or .exit returned 1
    jmp     .repl_loop

.accumulate_sql:
    ; Append line_buf into repl_sql_buf
    mov     rcx, [rbp - 16]             ; line_len
    test    rcx, rcx
    jz      .check_and_execute          ; empty line in continuation: check buffer

    mov     rdi, [repl_sql_len]
    ; Check the entire append before modifying the buffer. Reserve the NUL
    ; and, for continuation lines, the inserted newline.
    mov     rax, rdi
    test    rdi, rdi
    jz      .check_append_size
    inc     rax
.check_append_size:
    add     rax, rcx
    cmp     rax, 262143
    ja      .input_overflow
    lea     r9, [repl_sql_buf]
    lea     r8, [r9 + rdi]

    ; Add newline if continuing existing non-empty accumulator
    test    rdi, rdi
    jz      .do_copy
    mov     byte [r8], 10
    inc     rdi
    inc     r8
.do_copy:
    xor     rsi, rsi
    lea     r10, [line_buf]
.copy_line:
    cmp     rsi, rcx
    jae     .copy_done
    mov     al, [r10 + rsi]
    mov     [r8], al
    inc     rsi
    inc     rdi
    inc     r8
    jmp     .copy_line

.copy_done:
    lea     r9, [repl_sql_buf]
    mov     byte [r9 + rdi], 0
    mov     [repl_sql_len], rdi

.check_and_execute:
    ; Process complete statements ended by ';' in repl_sql_buf
    call    repl_process_buffer
    jmp     .repl_loop

.handle_eof:
    ; If there is a pending statement in repl_sql_buf without ';', execute it
    mov     rax, [repl_sql_len]
    test    rax, rax
    jz      .repl_exit_clean

    ; Trim leading whitespace
    xor     rsi, rsi
    lea     r9, [repl_sql_buf]
.eof_trim_ws:
    cmp     rsi, [repl_sql_len]
    jae     .repl_exit_clean
    movzx   eax, byte [r9 + rsi]
    cmp     al, ' '
    je      .eof_inc_ws
    cmp     al, 9
    je      .eof_inc_ws
    cmp     al, 10
    je      .eof_inc_ws
    cmp     al, 13
    je      .eof_inc_ws
    jmp     .eof_have_content
.eof_inc_ws:
    inc     rsi
    jmp     .eof_trim_ws

.eof_have_content:
    ; Execute trailing statement
    mov     rax, [repl_sql_len]
    sub     rax, rsi
    mov     ARG3, rax
    lea     r9, [repl_sql_buf]
    lea     ARG2, [r9 + rsi]
    lea     ARG1, [repl_db_ctx]
    call    cyboudb_exec_query
    test    eax, eax
    jz      .repl_exit_clean
    mov     qword [repl_had_error], 1

.repl_exit_clean:
    lea     ARG1, [repl_db_ctx]
    call    db_close
    xor     eax, eax
    cmp     qword [is_interactive], 0
    jne     .return_status
    mov     eax, [repl_had_error]
.return_status:
    FRAME_END
    ret

.input_overflow:
    ; Fail closed: neither the prefix nor any following input is executed.
    PUTS    str_err_input_limit
    lea     ARG1, [repl_db_ctx]
    call    db_close
    mov     eax, 1
    FRAME_END
    ret

.err_no_pax:
    lea     ARG1, [repl_db_ctx]
    call    db_close
    PUTS    str_msg_no_catalog
    mov     eax, 1
    FRAME_END
    ret

.open_failed:
    ; db_open failed
    mov     eax, 1
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  repl_read_line(ARG1 = out_buf, ARG2 = max_len) -> RAX: len or -1 (EOF)
; -----------------------------------------------------------------------------
repl_read_line:
    FRAME_BEGIN 32, 0
    mov     [rbp - 8], ARG1
    mov     [rbp - 16], ARG2

%ifdef CybouDB_WINDOWS
    cmp     qword [is_interactive], 1
    jne     .read_via_stream

    ; Interactive console on Windows: use ReadConsoleW
    mov     ARG1, [rbp - 8]
    mov     ARG2, [rbp - 16]
    call    os_read_console
    cmp     rax, -1
    je      .read_eof
    test    rax, rax
    jz      .read_eof

    ; ReadConsoleW can return a partial line when its WCHAR buffer fills.
    ; Never treat such a chunk as a complete SQL line.
    mov     rdi, [rbp - 8]
    cmp     byte [rdi + rax - 1], 10
    jne     .read_overflow

    ; Strip trailing \r and \n
    mov     rdi, [rbp - 8]
    mov     rcx, rax
.win_strip:
    test    rcx, rcx
    jz      .win_done
    movzx   eax, byte [rdi + rcx - 1]
    cmp     al, 10
    je      .win_dec
    cmp     al, 13
    je      .win_dec
    jmp     .win_done
.win_dec:
    dec     rcx
    jmp     .win_strip
.win_done:
    mov     byte [rdi + rcx], 0
    mov     rax, rcx
    FRAME_END
    ret
%endif

.read_via_stream:
    mov     ARG1, [rbp - 8]
    mov     ARG2, [rbp - 16]
    call    stream_read_line
    FRAME_END
    ret

.read_eof:
    mov     rax, -1
    FRAME_END
    ret

.read_overflow:
    mov     rax, -2
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  stream_read_line(ARG1 = out_buf, ARG2 = max_len) -> RAX: len or -1 (EOF)
; -----------------------------------------------------------------------------
stream_read_line:
    FRAME_BEGIN 32, 0
    mov     [rbp - 8], ARG1             ; out_buf
    mov     [rbp - 16], ARG2            ; max_len
    mov     [rbp - 24], rbx             ; preserve callee-saved rbx
    xor     rbx, rbx                    ; out_idx = 0

.char_loop:
    mov     rax, [stream_pos]
    cmp     rax, [stream_len]
    jb      .get_char

    ; Need to refill stream_buf
    cmp     qword [stream_eof], 1
    je      .stream_finish

    lea     ARG1, [stream_buf]
    mov     ARG2, 4096
    call    os_read_stdin
    test    rax, rax
    jle     .set_eof

    mov     [stream_len], rax
    mov     qword [stream_pos], 0
    jmp     .get_char

.set_eof:
    mov     qword [stream_eof], 1
    jmp     .stream_finish

.get_char:
    mov     rax, [stream_pos]
    lea     r9, [stream_buf]
    movzx   ecx, byte [r9 + rax]
    inc     qword [stream_pos]

    ; Check newline
    cmp     cl, 10                      ; '\n'
    je      .line_done

    ; Reject the line before its truncated prefix can reach the executor.
    cmp     rbx, [rbp - 16]
    jae     .line_overflow
    mov     r10, [rbp - 8]
    mov     [r10 + rbx], cl
    inc     rbx
    jmp     .char_loop

.line_overflow:
    mov     rax, -2
    mov     rbx, [rbp - 24]
    FRAME_END
    ret

.line_done:
    ; Strip optional trailing \r
    test    rbx, rbx
    jz      .line_finish
    mov     r10, [rbp - 8]
    cmp     byte [r10 + rbx - 1], 13    ; '\r'
    jne     .line_finish
    dec     rbx

.line_finish:
    mov     r10, [rbp - 8]
    mov     byte [r10 + rbx], 0
    mov     rax, rbx
    mov     rbx, [rbp - 24]
    FRAME_END
    ret

.stream_finish:
    test    rbx, rbx
    jnz     .line_done                  ; non-empty buffer before EOF: yield line
    mov     rax, -1                     ; true EOF
    mov     rbx, [rbp - 24]
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  repl_process_buffer() -> void
;  Scans repl_sql_buf for ';' outside single quotes and comments '--'.
;  Executes complete statements and shifts remaining fragment to start of buffer.
; -----------------------------------------------------------------------------
repl_process_buffer:
    FRAME_BEGIN 80, 0
    lea     rax, [repl_sql_buf]
    mov     [rbp - 8], rax              ; [rbp - 8] = &repl_sql_buf
    mov     [rbp - 16], r12
    mov     [rbp - 24], r13
    mov     [rbp - 32], r14
    mov     [rbp - 40], r15

    xor     r12, r12                    ; stmt_start = 0
    xor     r13, r13                    ; curr = 0
    xor     r14, r14                    ; in_quote = 0

.scan_loop:
    cmp     r13, [repl_sql_len]
    jae     .shift_remaining

    mov     r11, [rbp - 8]
    movzx   eax, byte [r11 + r13]

    ; Check single quote
    cmp     al, "'"
    jne     .check_comment
    xor     r14, 1                      ; toggle in_quote
    inc     r13
    jmp     .scan_loop

.check_comment:
    test    r14, r14
    jnz     .check_semi                 ; inside quote, ignore comments

    cmp     al, '-'
    jne     .check_semi
    lea     rdx, [r13 + 1]
    cmp     rdx, [repl_sql_len]
    jae     .check_semi
    mov     r11, [rbp - 8]
    cmp     byte [r11 + rdx], '-'
    jne     .check_semi

    ; Skip line comment until '\n' or buffer end
    add     r13, 2
.comment_skip:
    cmp     r13, [repl_sql_len]
    jae     .shift_remaining
    mov     r11, [rbp - 8]
    cmp     byte [r11 + r13], 10
    je      .comment_end
    inc     r13
    jmp     .comment_skip
.comment_end:
    inc     r13
    jmp     .scan_loop

.check_semi:
    test    r14, r14
    jnz     .next_char                  ; inside quote, ';' is literal

    cmp     al, ';'
    jne     .next_char

    ; Found terminating semicolon at r13!
    ; Statement range: [r12 .. r13] (length = r13 - r12 + 1)
    mov     r15, r13
    sub     r15, r12
    inc     r15                         ; stmt_len includes ';'

    ; Execute statement
    lea     ARG1, [repl_db_ctx]
    mov     r11, [rbp - 8]
    lea     ARG2, [r11 + r12]
    mov     ARG3, r15
    call    cyboudb_exec_query
    test    eax, eax
    jz      .statement_ok
    mov     qword [repl_had_error], 1
.statement_ok:

    ; Advance stmt_start past ';'
    lea     r12, [r13 + 1]
    mov     r13, r12

    ; Skip whitespace after semicolon
.skip_post_semi_ws:
    cmp     r12, [repl_sql_len]
    jae     .all_done
    mov     r11, [rbp - 8]
    movzx   eax, byte [r11 + r12]
    cmp     al, ' '
    je      .post_ws_inc
    cmp     al, 9
    je      .post_ws_inc
    cmp     al, 10
    je      .post_ws_inc
    cmp     al, 13
    je      .post_ws_inc
    mov     r13, r12
    jmp     .scan_loop
.post_ws_inc:
    inc     r12
    mov     r13, r12
    jmp     .skip_post_semi_ws

.next_char:
    inc     r13
    jmp     .scan_loop

.all_done:
    mov     qword [repl_sql_len], 0
    mov     r11, [rbp - 8]
    mov     byte [r11], 0
    mov     r12, [rbp - 16]
    mov     r13, [rbp - 24]
    mov     r14, [rbp - 32]
    mov     r15, [rbp - 40]
    FRAME_END
    ret

.shift_remaining:
    ; Remaining fragment from r12 to repl_sql_len
    mov     rax, [repl_sql_len]
    sub     rax, r12                    ; remaining len
    jz      .all_done

    test    r12, r12
    jz      .no_shift                   ; already at start of buffer

    ; Shift bytes [r12 .. repl_sql_len) to repl_sql_buf
    xor     rcx, rcx
    mov     r11, [rbp - 8]
    lea     rsi, [r11 + r12]
.shift_loop:
    cmp     rcx, rax
    jae     .shift_done
    mov     dl, [rsi + rcx]
    mov     [r11 + rcx], dl
    inc     rcx
    jmp     .shift_loop
.shift_done:
    mov     [repl_sql_len], rax
    mov     r11, [rbp - 8]
    mov     byte [r11 + rax], 0
.no_shift:
    mov     r12, [rbp - 16]
    mov     r13, [rbp - 24]
    mov     r14, [rbp - 32]
    mov     r15, [rbp - 40]
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  repl_handle_meta(ARG1 = db_ctx, ARG2 = cmd_line, ARG3 = cmd_len) -> RAX: 0=cont, 1=exit
; -----------------------------------------------------------------------------
repl_handle_meta:
    FRAME_BEGIN 64, 0
    mov     [rbp - 8], ARG1             ; db_ctx
    mov     [rbp - 16], ARG2            ; cmd_line
    mov     [rbp - 24], ARG3            ; cmd_len

    ; Extract command token (until whitespace or end)
    mov     r10, ARG2
    mov     rcx, ARG3
    xor     rsi, rsi
.token_len:
    cmp     rsi, rcx
    jae     .have_token
    movzx   eax, byte [r10 + rsi]
    cmp     al, ' '
    je      .have_token
    cmp     al, 9
    je      .have_token
    cmp     al, 13
    je      .have_token
    inc     rsi
    jmp     .token_len

.have_token:
    mov     [rbp - 32], rsi             ; token_len

    ; 1. Check .quit
    mov     ARG1, [rbp - 16]
    mov     ARG2, [rbp - 32]
    lea     ARG3, [str_meta_quit]
    mov     ARG4, 5
    call    str_eq_exact
    test    rax, rax
    jnz     .meta_exit

    ; 2. Check .exit
    mov     ARG1, [rbp - 16]
    mov     ARG2, [rbp - 32]
    lea     ARG3, [str_meta_exit]
    mov     ARG4, 5
    call    str_eq_exact
    test    rax, rax
    jnz     .meta_exit

    ; 3. Check .help
    mov     ARG1, [rbp - 16]
    mov     ARG2, [rbp - 32]
    lea     ARG3, [str_meta_help]
    mov     ARG4, 5
    call    str_eq_exact
    test    rax, rax
    jnz     .meta_help

    ; 4. Check .info
    mov     ARG1, [rbp - 16]
    mov     ARG2, [rbp - 32]
    lea     ARG3, [str_meta_info]
    mov     ARG4, 5
    call    str_eq_exact
    test    rax, rax
    jnz     .meta_info

    ; 5. Check .tables
    mov     ARG1, [rbp - 16]
    mov     ARG2, [rbp - 32]
    lea     ARG3, [str_meta_tables]
    mov     ARG4, 7
    call    str_eq_exact
    test    rax, rax
    jnz     .meta_tables

    ; 6. Check .schema
    mov     ARG1, [rbp - 16]
    mov     ARG2, [rbp - 32]
    lea     ARG3, [str_meta_schema]
    mov     ARG4, 7
    call    str_eq_exact
    test    rax, rax
    jnz     .meta_schema

    ; Unknown command
    PUTS    str_err_unknown_meta
    mov     r10, [rbp - 16]
    mov     rcx, [rbp - 32]
    xor     rsi, rsi
    lea     r8, [line_buf]
.print_bad_cmd:
    cmp     rsi, rcx
    jae     .print_bad_cmd_done
    mov     al, [r10 + rsi]
    mov     [r8 + rsi], al
    inc     rsi
    jmp     .print_bad_cmd
.print_bad_cmd_done:
    mov     byte [r8 + rsi], 0
    lea     ARG1, [line_buf]
    call    puts_asciiz
    PUTS    str_err_unknown_suffix
    xor     eax, eax
    FRAME_END
    ret

.meta_exit:
    mov     eax, 1                      ; signal exit
    FRAME_END
    ret

.meta_help:
    PUTS    str_help_text
    xor     eax, eax
    FRAME_END
    ret

.meta_info:
    mov     ARG1, [rbp - 8]
    call    print_db_info
    xor     eax, eax
    FRAME_END
    ret

.meta_tables:
    mov     ARG1, [rbp - 8]
    call    repl_meta_tables
    xor     eax, eax
    FRAME_END
    ret

.meta_schema:
    ; Look for optional table argument after .schema
    mov     rsi, [rbp - 32]             ; skip command word
    mov     r10, [rbp - 16]
    mov     rcx, [rbp - 24]
.skip_arg_ws:
    cmp     rsi, rcx
    jae     .no_schema_arg
    movzx   eax, byte [r10 + rsi]
    cmp     al, ' '
    je      .inc_arg_ws
    cmp     al, 9
    je      .inc_arg_ws
    jmp     .have_schema_arg
.inc_arg_ws:
    inc     rsi
    jmp     .skip_arg_ws

.have_schema_arg:
    ; Extract filter argument
    mov     rax, rcx
    sub     rax, rsi
    mov     ARG3, rax                   ; filter_len
    lea     ARG2, [r10 + rsi]
    mov     ARG1, [rbp - 8]             ; db_ctx
    call    repl_meta_schema
    xor     eax, eax
    FRAME_END
    ret

.no_schema_arg:
    mov     ARG1, [rbp - 8]
    xor     ARG2, ARG2
    xor     ARG3, ARG3
    call    repl_meta_schema
    xor     eax, eax
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  str_eq_exact(ARG1=s1, ARG2=len1, ARG3=s2, ARG4=len2) -> EAX: 1 if match, 0 if not
; -----------------------------------------------------------------------------
str_eq_exact:
    cmp     ARG2, ARG4
    jne     .mismatch
    mov     r10, ARG1
    mov     r11, ARG3
    mov     rcx, ARG2
    xor     rsi, rsi
.eq_loop:
    cmp     rsi, rcx
    jae     .match
    mov     al, [r10 + rsi]
    mov     dl, [r11 + rsi]
    cmp     al, dl
    jne     .mismatch
    inc     rsi
    jmp     .eq_loop
.match:
    mov     eax, 1
    ret
.mismatch:
    xor     eax, eax
    ret

; -----------------------------------------------------------------------------
;  repl_meta_tables(ARG1 = db_ctx)
; -----------------------------------------------------------------------------
repl_meta_tables:
    FRAME_BEGIN 48, 0
    mov     [rbp - 8], ARG1             ; db_ctx
    mov     [rbp - 32], rbx             ; preserve callee-saved rbx

    test    qword [ARG1 + DB_FEATURES], CybouDB_FEATURE_CATALOG
    jz      .no_tables

    mov     rax, [ARG1 + DB_ROOT]
    test    rax, rax
    jz      .no_tables

    mov     r10, [ARG1 + DB_BASE]
    shl     rax, CybouDB_PAGE_SHIFT
    add     r10, rax                    ; r10 = catalog directory page
    mov     [rbp - 16], r10

    cmp     dword [r10 + CAT_MAGIC], CAT_MAGIC_VALUE
    jne     .no_tables
    cmp     dword [r10 + CAT_TYPE], CAT_DIRECTORY
    jne     .no_tables

    mov     ecx, [r10 + CAT_COUNT]
    test    ecx, ecx
    jz      .no_tables
    mov     [rbp - 24], rcx             ; table_count

    xor     rbx, rbx                    ; table_idx = 0
.tbl_loop:
    mov     r10, [rbp - 16]
    mov     r11, rbx
    shl     r11, 4
    lea     r11, [r10 + CAT_DATA + r11]
    mov     rax, [r11 + 8]              ; schema_page_id
    shl     rax, CybouDB_PAGE_SHIFT
    mov     r8, [rbp - 8]
    add     rax, [r8 + DB_BASE]         ; rax = schema_ptr

    lea     ARG1, [rax + CAT_TABLE_NAME]
    call    puts_asciiz
    PUTS    str_repl_nl

    inc     rbx
    cmp     rbx, [rbp - 24]
    jb      .tbl_loop

.no_tables:
    mov     rbx, [rbp - 32]
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  repl_meta_schema(ARG1 = db_ctx, ARG2 = filter_str, ARG3 = filter_len)
; -----------------------------------------------------------------------------
repl_meta_schema:
    FRAME_BEGIN 80, 0
    mov     [rbp - 8], ARG1             ; db_ctx
    mov     [rbp - 16], ARG2            ; filter_str
    mov     [rbp - 24], ARG3            ; filter_len
    mov     qword [rbp - 32], 0         ; tables_matched
    mov     [rbp - 64], rbx             ; preserve callee-saved rbx

    test    qword [ARG1 + DB_FEATURES], CybouDB_FEATURE_CATALOG
    jz      .done_schema

    mov     rax, [ARG1 + DB_ROOT]
    test    rax, rax
    jz      .done_schema

    mov     r10, [ARG1 + DB_BASE]
    shl     rax, CybouDB_PAGE_SHIFT
    add     r10, rax                    ; catalog directory page
    mov     [rbp - 40], r10

    cmp     dword [r10 + CAT_MAGIC], CAT_MAGIC_VALUE
    jne     .done_schema
    cmp     dword [r10 + CAT_TYPE], CAT_DIRECTORY
    jne     .done_schema

    mov     ecx, [r10 + CAT_COUNT]
    test    ecx, ecx
    jz      .done_schema
    mov     [rbp - 48], rcx             ; table_count

    xor     rbx, rbx                    ; table_idx = 0
.schema_loop:
    mov     r10, [rbp - 40]
    mov     r11, rbx
    shl     r11, 4
    lea     r11, [r10 + CAT_DATA + r11]
    mov     rax, [r11 + 8]              ; schema_page_id
    shl     rax, CybouDB_PAGE_SHIFT
    mov     r8, [rbp - 8]
    add     rax, [r8 + DB_BASE]         ; schema_ptr
    mov     [rbp - 56], rax

    ; Check filter if provided
    mov     rcx, [rbp - 24]             ; filter_len
    test    rcx, rcx
    jz      .print_single_schema

    mov     ARG3, [rbp - 24]            ; filter_len
    mov     ARG2, [rbp - 16]            ; filter_str
    lea     ARG1, [rax + CAT_TABLE_NAME] ; table_name
    call    table_name_matches
    test    rax, rax
    jz      .next_schema_table

.print_single_schema:
    inc     qword [rbp - 32]            ; match found
    mov     ARG1, [rbp - 56]
    call    print_table_create_stmt

.next_schema_table:
    inc     rbx
    cmp     rbx, [rbp - 48]
    jb      .schema_loop

    ; If a specific filter was asked for and no match found, report error
    cmp     qword [rbp - 24], 0
    jz      .done_schema
    cmp     qword [rbp - 32], 0
    jnz     .done_schema

    PUTS    str_err_table_not_found
    ; Null-terminate filter string into line_buf
    mov     rcx, [rbp - 24]
    cmp     rcx, 100
    jbe     .filter_len_ok
    mov     rcx, 100
.filter_len_ok:
    mov     r10, [rbp - 16]
    xor     rsi, rsi
    lea     r8, [line_buf]
.copy_filter:
    cmp     rsi, rcx
    jae     .copy_filter_done
    mov     al, [r10 + rsi]
    mov     [r8 + rsi], al
    inc     rsi
    jmp     .copy_filter
.copy_filter_done:
    mov     byte [r8 + rsi], 0
    lea     ARG1, [line_buf]
    call    puts_asciiz
    PUTS    str_repl_nl

.done_schema:
    mov     rbx, [rbp - 64]
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  table_name_matches(ARG1 = asciiz_name, ARG2 = query_name, ARG3 = query_len) -> EAX
; -----------------------------------------------------------------------------
table_name_matches:
    mov     r10, ARG1
    mov     r11, ARG2
    mov     rcx, ARG3
    xor     rsi, rsi
.match_chars:
    cmp     rsi, rcx
    jae     .check_end
    movzx   eax, byte [r10 + rsi]
    movzx   edx, byte [r11 + rsi]
    cmp     al, dl
    je      .char_ok
    ; Case-insensitive ASCII fold
    or      al, 0x20
    or      dl, 0x20
    cmp     al, dl
    jne     .no_match
    cmp     al, 'a'
    jb      .no_match
    cmp     al, 'z'
    ja      .no_match
.char_ok:
    inc     rsi
    jmp     .match_chars
.check_end:
    cmp     byte [r10 + rsi], 0
    jne     .no_match
    mov     eax, 1
    ret
.no_match:
    xor     eax, eax
    ret

; -----------------------------------------------------------------------------
;  print_table_create_stmt(ARG1 = schema_ptr)
; -----------------------------------------------------------------------------
print_table_create_stmt:
    FRAME_BEGIN 48, 0
    mov     [rbp - 8], ARG1             ; schema_ptr
    mov     [rbp - 32], r12             ; preserve callee-saved r12

    PUTS    str_create_table_pfx
    mov     r8, [rbp - 8]
    lea     ARG1, [r8 + CAT_TABLE_NAME]
    call    puts_asciiz
    PUTS    str_open_paren

    mov     r8, [rbp - 8]
    mov     ecx, [r8 + CAT_COUNT]       ; column count
    mov     [rbp - 16], rcx

    xor     r12, r12                    ; col_idx = 0
.col_loop:
    PUTS    str_col_indent

    mov     r8, [rbp - 8]
    mov     r9, r12
    shl     r9, 5
    lea     r9, [r8 + CAT_COLUMNS + r9]
    mov     [rbp - 24], r9

    ; Column name (offset 8)
    lea     ARG1, [r9 + 8]
    call    puts_asciiz
    PUTS    str_col_indent              ; space separator

    ; Column type (offset 0)
    mov     r9, [rbp - 24]
    mov     eax, [r9 + 0]
    cmp     eax, CAT_INT32
    je      .print_int32
    cmp     eax, CAT_INT64
    je      .print_int64
    cmp     eax, CAT_FLOAT32
    je      .print_float32
    cmp     eax, CAT_BOOL
    je      .print_bool
    PUTS    str_type_unknown
    jmp     .print_nullability

.print_int32:
    PUTS    str_type_int32
    jmp     .print_nullability
.print_int64:
    PUTS    str_type_int64
    jmp     .print_nullability
.print_float32:
    PUTS    str_type_float32
    jmp     .print_nullability
.print_bool:
    PUTS    str_type_bool

.print_nullability:
    mov     r9, [rbp - 24]
    test    dword [r9 + 4], CAT_NULLABLE
    jnz     .check_trailing_comma
    PUTS    str_not_null

.check_trailing_comma:
    mov     rax, r12
    inc     rax
    cmp     rax, [rbp - 16]
    jae     .col_last
    PUTS    str_comma_nl
    jmp     .col_next
.col_last:
    PUTS    str_repl_nl
.col_next:
    inc     r12
    cmp     r12, [rbp - 16]
    jb      .col_loop

    PUTS    str_close_paren
    mov     r12, [rbp - 32]
    FRAME_END
    ret

%ifdef CybouDB_LINUX
section .note.GNU-stack noalloc noexec nowrite progbits
%endif
