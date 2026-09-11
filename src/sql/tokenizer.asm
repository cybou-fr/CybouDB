; =============================================================================
;  src/sql/tokenizer.asm - Zero-copy SQL Lexer
; =============================================================================

%include "sql.inc"

BITS 64
default rel

global sql_tok_init, sql_tok_next, sql_tok_peek

section .data
    align 8

; Keyword definitions: (string, length, token_type)
kw_create:   db "create", 0
kw_table:    db "table", 0
kw_insert:   db "insert", 0
kw_into:     db "into", 0
kw_values:   db "values", 0
kw_select:   db "select", 0
kw_from:     db "from", 0
kw_where:    db "where", 0
kw_null:     db "null", 0
kw_true:     db "true", 0
kw_false:    db "false", 0
kw_is:       db "is", 0
kw_not:      db "not", 0
kw_and:      db "and", 0
kw_or:       db "or", 0
kw_int32:    db "int32", 0
kw_int64:    db "int64", 0
kw_float32:  db "float32", 0
kw_bool:     db "bool", 0
kw_text:     db "text", 0
kw_blob:     db "blob", 0
kw_integer:  db "integer", 0
kw_bigint:   db "bigint", 0
kw_real:     db "real", 0
kw_boolean:  db "boolean", 0
kw_count:    db "count", 0
kw_update:   db "update", 0
kw_set:      db "set", 0
kw_delete:   db "delete", 0
kw_join:     db "join", 0
kw_inner:    db "inner", 0
kw_left:     db "left", 0
kw_on:       db "on", 0
kw_as:       db "as", 0
kw_order:    db "order", 0
kw_by:       db "by", 0
kw_limit:    db "limit", 0
kw_offset:   db "offset", 0
kw_vector:   db "vector", 0
kw_asc:      db "asc", 0
kw_desc:     db "desc", 0
kw_drop:     db "drop", 0
kw_l2_distance:     db "l2_distance", 0
kw_cosine_distance: db "cosine_distance", 0

    align 8
kw_table_entries:
    dq kw_create,  6, TOK_CREATE
    dq kw_table,   5, TOK_TABLE
    dq kw_insert,  6, TOK_INSERT
    dq kw_into,    4, TOK_INTO
    dq kw_values,  6, TOK_VALUES
    dq kw_select,  6, TOK_SELECT
    dq kw_from,    4, TOK_FROM
    dq kw_where,   5, TOK_WHERE
    dq kw_null,    4, TOK_NULL
    dq kw_true,    4, TOK_TRUE
    dq kw_false,   5, TOK_FALSE
    dq kw_is,      2, TOK_IS
    dq kw_not,     3, TOK_NOT
    dq kw_and,     3, TOK_AND
    dq kw_or,      2, TOK_OR
    dq kw_count,   5, TOK_COUNT
    dq kw_int32,   5, TOK_TYPE_INT32
    dq kw_int64,   5, TOK_TYPE_INT64
    dq kw_float32, 7, TOK_TYPE_FLOAT32
    dq kw_bool,    4, TOK_TYPE_BOOL
    dq kw_text,    4, TOK_TYPE_TEXT
    dq kw_blob,    4, TOK_TYPE_BLOB
    dq kw_integer, 7, TOK_TYPE_INT32
    dq kw_bigint,  6, TOK_TYPE_INT64
    dq kw_real,    4, TOK_TYPE_FLOAT32
    dq kw_boolean, 7, TOK_TYPE_BOOL
    dq kw_update,  6, TOK_UPDATE
    dq kw_set,     3, TOK_SET
    dq kw_delete,  6, TOK_DELETE
    dq kw_join,    4, TOK_JOIN
    dq kw_inner,   5, TOK_INNER
    dq kw_left,    4, TOK_LEFT
    dq kw_on,      2, TOK_ON
    dq kw_as,      2, TOK_AS
    dq kw_order,   5, TOK_ORDER
    dq kw_by,      2, TOK_BY
    dq kw_limit,   5, TOK_LIMIT
    dq kw_offset,  6, TOK_OFFSET_KW
    dq kw_vector,  6, TOK_VECTOR
    dq kw_asc,      3, TOK_ASC
    dq kw_desc,     4, TOK_DESC
    dq kw_drop,     4, TOK_DROP
    dq kw_l2_distance, 11, TOK_L2_DISTANCE
    dq kw_cosine_distance, 15, TOK_COSINE_DISTANCE
    dq 0,          0, 0                 ; terminator

section .text

; -----------------------------------------------------------------------------
;  sql_tok_init(ARG1=tok_ctx, ARG2=sql_str, ARG3=sql_len)
; -----------------------------------------------------------------------------
sql_tok_init:
    mov     r10, ARG1
    mov     [r10 + TOKZ_SRC], ARG2
    mov     [r10 + TOKZ_LEN], ARG3
    mov     qword [r10 + TOKZ_POS], 0
    mov     dword [r10 + TOKZ_LINE], 1
    mov     dword [r10 + TOKZ_COL], 1
    mov     dword [r10 + TOKZ_PEEKED], 0
    xor     eax, eax
    ret

; -----------------------------------------------------------------------------
;  sql_tok_peek(ARG1=tok_ctx, ARG2=out_token) -> EAX: SQL_OK
; -----------------------------------------------------------------------------
sql_tok_peek:
    FRAME_BEGIN 32, 0
    mov     [rbp - 8], ARG1
    mov     [rbp - 16], ARG2

    mov     r10, ARG1
    cmp     dword [r10 + TOKZ_PEEKED], 1
    je      .use_cached

    ; Fetch next into peek buffer
    mov     ARG1, [rbp - 8]
    mov     r10, ARG1
    lea     ARG2, [r10 + TOKZ_PEEK_TOK]
    call    sql_tok_next
    test    eax, eax
    jnz     .done

    mov     r10, [rbp - 8]
    mov     dword [r10 + TOKZ_PEEKED], 1

.use_cached:
    mov     r10, [rbp - 8]
    mov     r11, [rbp - 16]
    ; Copy 32 bytes from TOKZ_PEEK_TOK to out_token
    mov     rax, [r10 + TOKZ_PEEK_TOK + 0]
    mov     [r11 + 0], rax
    mov     rax, [r10 + TOKZ_PEEK_TOK + 8]
    mov     [r11 + 8], rax
    mov     rax, [r10 + TOKZ_PEEK_TOK + 16]
    mov     [r11 + 16], rax
    mov     rax, [r10 + TOKZ_PEEK_TOK + 24]
    mov     [r11 + 24], rax
    xor     eax, eax

.done:
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  sql_tok_next(ARG1=tok_ctx, ARG2=out_token) -> EAX: SQL_OK
; -----------------------------------------------------------------------------
sql_tok_next:
    FRAME_BEGIN 112, 0
    mov     [rbp - 56], rbx
    mov     [rbp - 64], r12
    mov     [rbp - 72], r13
    mov     [rbp - 80], r14
    mov     [rbp - 88], r15
    mov     [rbp - 96], rsi
    mov     [rbp - 104], rdi

    mov     [rbp - 8], ARG1             ; tok_ctx
    mov     [rbp - 16], ARG2            ; out_token

    mov     r10, ARG1
    cmp     dword [r10 + TOKZ_PEEKED], 1
    jne     .lex_fresh

    ; Return peeked token and invalidate cache
    mov     r11, [rbp - 16]
    mov     rax, [r10 + TOKZ_PEEK_TOK + 0]
    mov     [r11 + 0], rax
    mov     rax, [r10 + TOKZ_PEEK_TOK + 8]
    mov     [r11 + 8], rax
    mov     rax, [r10 + TOKZ_PEEK_TOK + 16]
    mov     [r11 + 16], rax
    mov     rax, [r10 + TOKZ_PEEK_TOK + 24]
    mov     [r11 + 24], rax
    mov     dword [r10 + TOKZ_PEEKED], 0
    xor     eax, eax
    jmp     .tok_exit

.lex_fresh:
    mov     r8, [r10 + TOKZ_SRC]        ; sql string
    mov     r9, [r10 + TOKZ_LEN]        ; sql len
    mov     rsi, [r10 + TOKZ_POS]       ; current pos
    mov     ebx, [r10 + TOKZ_LINE]      ; current line
    mov     ecx, [r10 + TOKZ_COL]       ; current col

.skip_ws:
    cmp     rsi, r9
    jae     .emit_eof

    movzx   eax, byte [r8 + rsi]

    ; Check spaces, tabs, CR
    cmp     al, ' '
    je      .ws_char
    cmp     al, 9                       ; '\t'
    je      .ws_char
    cmp     al, 13                      ; '\r'
    je      .ws_char

    ; Check newline
    cmp     al, 10                      ; '\n'
    je      .newline_char

    ; Check comment '--'
    cmp     al, '-'
    jne     .start_token
    lea     rdx, [rsi + 1]
    cmp     rdx, r9
    jae     .start_token
    cmp     byte [r8 + rdx], '-'
    jne     .start_token

    ; It is a comment: skip until '\n' or EOF
    add     rsi, 2
    add     ecx, 2
.comment_loop:
    cmp     rsi, r9
    jae     .emit_eof
    cmp     byte [r8 + rsi], 10
    je      .newline_char
    inc     rsi
    inc     ecx
    jmp     .comment_loop

.ws_char:
    inc     rsi
    inc     ecx
    jmp     .skip_ws

.newline_char:
    inc     rsi
    inc     ebx                         ; line++
    mov     ecx, 1                      ; col = 1
    jmp     .skip_ws

.emit_eof:
    ; Update context
    mov     r10, [rbp - 8]
    mov     [r10 + TOKZ_POS], rsi
    mov     [r10 + TOKZ_LINE], ebx
    mov     [r10 + TOKZ_COL], ecx

    mov     r11, [rbp - 16]
    mov     qword [r11 + TOK_TYPE], TOK_EOF
    mov     [r11 + TOK_OFFSET], rsi
    mov     qword [r11 + TOK_LEN], 0
    mov     [r11 + TOK_LINE], ebx
    mov     [r11 + TOK_COL], ecx
    xor     eax, eax
    jmp     .tok_exit

.start_token:
    ; Record start of token
    mov     [rbp - 24], rsi             ; start offset
    mov     [rbp - 32], ebx             ; start line
    mov     [rbp - 36], ecx             ; start col

    movzx   eax, byte [r8 + rsi]

    ; Check single-character punctuation
    cmp     al, ','
    je      .tok_comma
    cmp     al, ';'
    je      .tok_semicolon
    cmp     al, '['
    je      .tok_lbracket
    cmp     al, ']'
    je      .tok_rbracket
    cmp     al, '('
    je      .tok_lparen
    cmp     al, ')'
    je      .tok_rparen
    cmp     al, '*'
    je      .tok_star
    cmp     al, '+'
    je      .tok_plus
    cmp     al, '.'
    je      .tok_dot
    cmp     al, '='
    je      .tok_eq

    ; Check '!' -> '!='
    cmp     al, '!'
    je      .check_excl

    ; Check '<' -> '<', '<=', '<>'
    cmp     al, '<'
    je      .check_lt

    ; Check '>' -> '>', '>='
    cmp     al, '>'
    je      .check_gt

    ; Check '-' -> could be minus operator (or negative number handled in parser)
    cmp     al, '-'
    je      .tok_minus

    ; Check identifier or keyword: [a-zA-Z_]
    cmp     al, '_'
    je      .lex_ident
    cmp     al, 'X'
    je      .check_blob_prefix
    cmp     al, 'x'
    je      .check_blob_prefix
    cmp     al, 'A'
    jb      .check_digit
    cmp     al, 'Z'
    jbe     .lex_ident
    cmp     al, 'a'
    jb      .check_digit
    cmp     al, 'z'
    jbe     .lex_ident

.check_digit:
    cmp     al, '0'
    jb      .check_string
    cmp     al, '9'
    jbe     .lex_number

.check_string:
    cmp     al, "'"
    jne     .unknown_char
    mov     qword [rbp - 56], TOK_STRING_LIT
    jmp     .lex_string

    ; Unknown character
.unknown_char:
    inc     rsi
    inc     ecx
    mov     rdi, TOK_ERROR
    jmp     .finish_token

.check_blob_prefix:
    lea     rdx, [rsi + 1]
    cmp     rdx, r9
    jae     .lex_ident
    cmp     byte [r8 + rdx], "'"
    jne     .lex_ident
    mov     qword [rbp - 56], TOK_BLOB_LIT
    inc     rsi                         ; leave RSI on the opening quote
    inc     ecx
    jmp     .lex_string

.tok_comma:
    inc     rsi
    inc     ecx
    mov     rdi, TOK_COMMA
    jmp     .finish_token

.tok_semicolon:
    inc     rsi
    inc     ecx
    mov     rdi, TOK_SEMICOLON
    jmp     .finish_token

.tok_lparen:
    inc     rsi
    inc     ecx
    mov     rdi, TOK_LPAREN
    jmp     .finish_token

.tok_rparen:
    inc     rsi
    inc     ecx
    mov     rdi, TOK_RPAREN
    jmp     .finish_token

.tok_lbracket:
    inc     rsi
    inc     ecx
    mov     rdi, TOK_LBRACKET
    jmp     .finish_token

.tok_rbracket:
    inc     rsi
    inc     ecx
    mov     rdi, TOK_RBRACKET
    jmp     .finish_token

.tok_star:
    inc     rsi
    inc     ecx
    mov     rdi, TOK_STAR
    jmp     .finish_token

.tok_plus:
    inc     rsi
    inc     ecx
    mov     rdi, TOK_PLUS
    jmp     .finish_token

.tok_minus:
    inc     rsi
    inc     ecx
    mov     rdi, TOK_MINUS
    jmp     .finish_token

.tok_dot:
    inc     rsi
    inc     ecx
    mov     rdi, TOK_DOT
    jmp     .finish_token

.tok_eq:
    inc     rsi
    inc     ecx
    mov     rdi, TOK_EQ
    jmp     .finish_token

.check_excl:
    lea     rdx, [rsi + 1]
    cmp     rdx, r9
    jae     .bad_excl
    cmp     byte [r8 + rdx], '='
    jne     .bad_excl
    add     rsi, 2
    add     ecx, 2
    mov     rdi, TOK_NEQ
    jmp     .finish_token
.bad_excl:
    inc     rsi
    inc     ecx
    mov     rdi, TOK_ERROR
    jmp     .finish_token

.check_lt:
    lea     rdx, [rsi + 1]
    cmp     rdx, r9
    jae     .emit_lt
    movzx   edx, byte [r8 + rdx]
    cmp     dl, '='
    je      .emit_lte
    cmp     dl, '>'
    je      .emit_neq
.emit_lt:
    inc     rsi
    inc     ecx
    mov     rdi, TOK_LT
    jmp     .finish_token
.emit_lte:
    add     rsi, 2
    add     ecx, 2
    mov     rdi, TOK_LTE
    jmp     .finish_token
.emit_neq:
    add     rsi, 2
    add     ecx, 2
    mov     rdi, TOK_NEQ
    jmp     .finish_token

.check_gt:
    lea     rdx, [rsi + 1]
    cmp     rdx, r9
    jae     .emit_gt
    cmp     byte [r8 + rdx], '='
    je      .emit_gte
.emit_gt:
    inc     rsi
    inc     ecx
    mov     rdi, TOK_GT
    jmp     .finish_token
.emit_gte:
    add     rsi, 2
    add     ecx, 2
    mov     rdi, TOK_GTE
    jmp     .finish_token

.lex_ident:
    inc     rsi
    inc     ecx
    cmp     rsi, r9
    jae     .ident_done
    movzx   eax, byte [r8 + rsi]
    cmp     al, '_'
    je      .lex_ident
    cmp     al, 'A'
    jb      .ident_digit
    cmp     al, 'Z'
    jbe     .lex_ident
    cmp     al, 'a'
    jb      .ident_digit
    cmp     al, 'z'
    jbe     .lex_ident
.ident_digit:
    cmp     al, '0'
    jb      .ident_done
    cmp     al, '9'
    jbe     .lex_ident

.ident_done:
    ; Match against keyword table
    mov     rax, rsi
    sub     rax, [rbp - 24]             ; ident length
    mov     [rbp - 48], rax             ; length

    lea     r12, [kw_table_entries]
.kw_loop:
    mov     rax, [rbp - 48]             ; length
    mov     rdx, [r12]                  ; keyword str
    test    rdx, rdx
    jz      .not_kw
    cmp     [r12 + 8], rax              ; check length
    jne     .next_kw

    ; Compare characters case-insensitively
    mov     r13, [rbp - 24]             ; start offset
    mov     r14, [r12]                  ; kw string ptr
    mov     r15, [rbp - 48]             ; length
.kw_cmp:
    movzx   eax, byte [r8 + r13]
    cmp     al, 'A'
    jb      .kw_no_lower
    cmp     al, 'Z'
    ja      .kw_no_lower
    add     al, 32                      ; lowercase
.kw_no_lower:
    cmp     al, byte [r14]
    jne     .next_kw
    inc     r13
    inc     r14
    dec     r15
    jnz     .kw_cmp

    ; Matched keyword!
    mov     rdi, [r12 + 16]
    jmp     .finish_token

.next_kw:
    add     r12, 24
    jmp     .kw_loop

.not_kw:
    mov     rdi, TOK_IDENT
    jmp     .finish_token

.lex_number:
    inc     rsi
    inc     ecx
    cmp     rsi, r9
    jae     .int_done
    movzx   eax, byte [r8 + rsi]
    cmp     al, '0'
    jb      .check_float_dot
    cmp     al, '9'
    jbe     .lex_number

.check_float_dot:
    cmp     al, '.'
    jne     .int_done
    ; Peek if next is digit
    lea     rdx, [rsi + 1]
    cmp     rdx, r9
    jae     .int_done
    movzx   eax, byte [r8 + rdx]
    cmp     al, '0'
    jb      .int_done
    cmp     al, '9'
    ja      .int_done

    ; Float dot confirmed
    inc     rsi
    inc     ecx
.float_loop:
    inc     rsi
    inc     ecx
    cmp     rsi, r9
    jae     .float_done
    movzx   eax, byte [r8 + rsi]
    cmp     al, '0'
    jb      .float_done
    cmp     al, '9'
    jbe     .float_loop

.float_done:
    mov     rdi, TOK_FLOAT_LIT
    jmp     .finish_token

.int_done:
    mov     rdi, TOK_INT_LIT
    jmp     .finish_token

.lex_string:
    inc     rsi
    inc     ecx
.str_loop:
    cmp     rsi, r9
    jae     .str_unterminated
    movzx   eax, byte [r8 + rsi]
    cmp     al, "'"
    je      .str_quote
    cmp     al, 10
    jne     .str_adv
    inc     ebx
    mov     ecx, 0
.str_adv:
    inc     rsi
    inc     ecx
    jmp     .str_loop

.str_quote:
    inc     rsi
    inc     ecx
    ; check for escaped quote ''
    cmp     rsi, r9
    jae     .str_done
    cmp     byte [r8 + rsi], "'"
    jne     .str_done
    inc     rsi
    inc     ecx
    jmp     .str_loop

.str_done:
    mov     rdi, [rbp - 56]
    jmp     .finish_token

.str_unterminated:
    mov     rdi, TOK_ERROR
    jmp     .finish_token

.finish_token:
    ; Update context
    mov     r10, [rbp - 8]
    mov     [r10 + TOKZ_POS], rsi
    mov     [r10 + TOKZ_LINE], ebx
    mov     [r10 + TOKZ_COL], ecx

    ; Compute token length
    mov     rax, rsi
    sub     rax, [rbp - 24]

    ; Fill out_token
    mov     r11, [rbp - 16]
    mov     [r11 + TOK_TYPE], rdi
    mov     rdx, [rbp - 24]
    mov     [r11 + TOK_OFFSET], rdx
    mov     [r11 + TOK_LEN], rax
    mov     edx, [rbp - 32]
    mov     [r11 + TOK_LINE], edx
    mov     edx, [rbp - 36]
    mov     [r11 + TOK_COL], edx

    xor     eax, eax
    jmp     .tok_exit

.tok_exit:
    mov     rbx, [rbp - 56]
    mov     r12, [rbp - 64]
    mov     r13, [rbp - 72]
    mov     r14, [rbp - 80]
    mov     r15, [rbp - 88]
    mov     rsi, [rbp - 96]
    mov     rdi, [rbp - 104]
    FRAME_END
    ret
