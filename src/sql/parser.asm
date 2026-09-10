; =============================================================================
;  src/sql/parser.asm - SQL Parser (CREATE TABLE, INSERT, SELECT)
; =============================================================================

%include "sql.inc"

BITS 64
default rel

extern sql_tok_init, sql_tok_next, sql_tok_peek
global sql_arena_init, sql_arena_alloc, sql_parse

section .data
    align 8
err_syntax_msg:      db "syntax error near token", 0
err_unexp_token:     db "unexpected token", 0
err_unexp_eof:       db "unexpected end of statement", 0
err_expected_table:  db "expected table name", 0
err_expected_col:    db "expected column name", 0
err_expected_type:   db "expected column data type (INT32, INT64, FLOAT32, BOOL)", 0
err_expected_lparen: db "expected '('", 0
err_expected_rparen: db "expected ')'", 0
err_expected_comma:  db "expected ','", 0
err_expected_values: db "expected VALUES keyword", 0
err_expected_from:   db "expected FROM keyword", 0
err_expected_ident:  db "expected identifier", 0
err_expected_expr:   db "expected expression", 0
err_bad_number:      db "malformed numeric literal", 0
err_overflow:        db "integer literal overflow", 0
err_float_range:     db "FLOAT32 literal exceeds range or 128 digits", 0
err_bad_blob:        db "BLOB literal must contain only an even number of hex digits", 0
err_col_limit:       db "column count exceeds maximum of 64", 0
err_row_limit:       db "row count exceeds maximum of 256", 0
err_proj_limit:      db "projection count exceeds maximum of 64", 0
err_oom:             db "memory arena capacity exceeded", 0
err_expr_depth:      db "expression nesting exceeds maximum of 64", 0

section .bss
; Current parse_expr_prec nesting. sql_parse resets it, so a parse that failed
; and unwound early cannot leave the next statement believing it is already
; deep.
expr_depth:          resq 1

section .text

; Enter one level of expression recursion; branch to %1 when the tree would
; grow deeper than the parser promises the binder and executor it will.
%macro EXPR_DEPTH_ENTER 1
    inc     qword [expr_depth]
    cmp     qword [expr_depth], SQL_MAX_EXPR_DEPTH
    ja      %1
%endmacro

%macro EXPR_DEPTH_LEAVE 0
    dec     qword [expr_depth]
%endmacro

; -----------------------------------------------------------------------------
;  sql_arena_init(ARG1=arena, ARG2=buffer, ARG3=capacity)
; -----------------------------------------------------------------------------
sql_arena_init:
    mov     r10, ARG1
    mov     [r10 + ARENA_BASE], ARG2
    mov     qword [r10 + ARENA_USED], 0
    mov     [r10 + ARENA_CAP], ARG3
    mov     qword [r10 + ARENA_FAILED], 0
    xor     eax, eax
    ret

; -----------------------------------------------------------------------------
;  sql_arena_alloc(ARG1=arena, ARG2=size) -> RAX: pointer or 0
; -----------------------------------------------------------------------------
sql_arena_alloc:
    mov     r10, ARG1
    mov     rax, ARG2
    add     rax, 7
    jc      .oom
    and     rax, ~7                     ; 8-byte align
    mov     rcx, [r10 + ARENA_USED]
    mov     rdx, rcx
    add     rdx, rax
    jc      .oom
    cmp     rdx, [r10 + ARENA_CAP]
    ja      .oom
    mov     [r10 + ARENA_USED], rdx
    mov     r8, [r10 + ARENA_BASE]
    add     r8, rcx                     ; r8 = allocated block
    ; Zero rax bytes in block
    mov     rcx, rax
    shr     rcx, 3                      ; qwords
    mov     r9, r8
    xor     eax, eax
.zero_loop:
    test    rcx, rcx
    jz      .zero_done
    mov     [r9], rax
    add     r9, 8
    dec     rcx
    jmp     .zero_loop
.zero_done:
    mov     rax, r8
    ret
.oom:
    mov     qword [r10 + ARENA_FAILED], 1
    xor     eax, eax
    ret

; -----------------------------------------------------------------------------
;  set_error(err_struct, code, tok_ptr, msg_ptr)
; -----------------------------------------------------------------------------
set_error:
    test    ARG1, ARG1
    jz      .done
    mov     r10, ARG1
    mov     qword [r10 + SQL_ERR_DOMAIN], SQL_DOMAIN_SQL
    mov     [r10 + SQL_ERR_CODE], ARG2
    test    ARG3, ARG3
    jz      .no_tok
    mov     r11, ARG3
    mov     rax, [r11 + TOK_OFFSET]
    mov     [r10 + SQL_ERR_OFFSET], rax
    mov     eax, [r11 + TOK_LINE]
    mov     [r10 + SQL_ERR_LINE], eax
    mov     eax, [r11 + TOK_COL]
    mov     [r10 + SQL_ERR_COL], eax
    jmp     .copy_msg
.no_tok:
    mov     qword [r10 + SQL_ERR_OFFSET], 0
    mov     dword [r10 + SQL_ERR_LINE], 1
    mov     dword [r10 + SQL_ERR_COL], 1
.copy_msg:
    test    ARG4, ARG4
    jz      .done
    mov     r8, ARG4
    lea     r9, [r10 + SQL_ERR_MSG]
    mov     ecx, 70
.msg_loop:
    mov     al, [r8]
    mov     [r9], al
    test    al, al
    jz      .done
    inc     r8
    inc     r9
    dec     ecx
    jnz     .msg_loop
    mov     byte [r9], 0
.done:
    mov     rax, ARG2
    ret

; -----------------------------------------------------------------------------
;  parse_number(tok_ptr, sql_src, out_val, out_type, is_neg) -> 1 on ok, 0 malformed, -1 integer overflow, -2 float range/length
; -----------------------------------------------------------------------------
parse_number:
    FRAME_BEGIN 224, 0
    mov     [rbp - 8], ARG1             ; tok_ptr
    mov     [rbp - 16], ARG2            ; sql_src
    mov     [rbp - 24], ARG3            ; out_val
    mov     [rbp - 32], ARG4            ; out_type
    mov     rax, IN_ARG5
    mov     [rbp - 40], rax             ; is_neg

    mov     r10, [rbp - 8]
    mov     rax, [r10 + TOK_OFFSET]
    add     rax, [rbp - 16]
    mov     rcx, [r10 + TOK_LEN]        ; len
    mov     r10, rax                    ; char ptr

    mov     r11, [rbp - 8]
    cmp     qword [r11 + TOK_TYPE], TOK_FLOAT_LIT
    je      .parse_float

    ; Parse integer
    xor     rax, rax                    ; accumulator
    test    rcx, rcx
    jz      .num_fail
    cmp     byte [r10], '-'
    jne     .int_check_plus
    mov     qword [rbp - 40], 1
    inc     r10
    dec     rcx
    jz      .num_fail
    jmp     .int_loop
.int_check_plus:
    cmp     byte [r10], '+'
    jne     .int_loop
    inc     r10
    dec     rcx
    jz      .num_fail

.int_loop:
    movzx   r9d, byte [r10]
    sub     r9d, '0'
    cmp     r9d, 9
    ja      .num_fail

    mov     r8, 10
    mul     r8                          ; rdx:rax = rax * 10
    test    rdx, rdx
    jnz     .num_overflow

    add     rax, r9
    jc      .num_overflow

    inc     r10
    dec     rcx
    jnz     .int_loop

    cmp     qword [rbp - 40], 0
    jne     .int_neg

    ; Positive INT64: bit 63 cannot be set (max 0x7FFFFFFFFFFFFFFF)
    test    rax, rax
    js      .num_overflow
    jmp     .int_store

.int_neg:
    ; Negative INT64: max magnitude 0x8000000000000000
    mov     r8, 0x8000000000000000
    cmp     rax, r8
    ja      .num_overflow
    neg     rax

.int_store:
    mov     r11, [rbp - 24]
    mov     [r11], rax
    mov     r11, [rbp - 32]
    mov     dword [r11], CAT_INT64      ; default int type
    mov     eax, 1
    FRAME_END
    ret

.parse_float:
    ; Exact decimal rational in two 512-bit integers. 128 digits need at most
    ; 426 bits; normalization and rounding need at most one extra bit.
    cmp     rcx, SQL_FLOAT_MAX_DIGITS + 1
    ja      .float_overflow
    mov     [rbp - 56], rcx
    mov     [rbp - 64], r10
    mov     qword [rbp - 48], 0         ; seen dot
    lea     r8, [rbp - 192]
    mov     ecx, 16
    xor     eax, eax
.flt_clear:
    mov     [r8], rax
    add     r8, 8
    dec     ecx
    jnz     .flt_clear
    mov     qword [rbp - 192], 1        ; denominator
.flt_digits:
    mov     r10, [rbp - 64]
    movzx   r11d, byte [r10]
    cmp     r11b, '.'
    je      .flt_dot
    sub     r11d, '0'
    cmp     r11d, 9
    ja      .num_fail
    lea     r8, [rbp - 128]             ; numerator = numerator * 10 + digit
    call    .big_mul10
    cmp     qword [rbp - 48], 0
    je      .flt_next
    lea     r8, [rbp - 192]
    xor     r11d, r11d
    call    .big_mul10                  ; denominator *= 10 after decimal point
    jmp     .flt_next
.flt_dot:
    cmp     qword [rbp - 48], 0
    jne     .num_fail
    mov     qword [rbp - 48], 1
.flt_next:
    inc     qword [rbp - 64]
    dec     qword [rbp - 56]
    jnz     .flt_digits
    lea     r8, [rbp - 128]
    lea     r9, [rbp - 192]
    xor     eax, eax
    mov     ecx, 8
.flt_zero_check:
    or      rax, [r8 + rcx * 8 - 8]
    dec     ecx
    jnz     .flt_zero_check
    test    rax, rax
    jz      .flt_store
    mov     qword [rbp - 200], 0        ; binary exponent
    call    .big_compare
    jb      .flt_scale_numerator
.flt_scale_denominator:
    xchg    r8, r9
    call    .big_shl
    xchg    r8, r9
    inc     qword [rbp - 200]
    call    .big_compare
    jae     .flt_scale_denominator
    ; Undo the final denominator shift. It was exact and even.
    lea     r11, [r9 + 56]
    mov     ecx, 8
    clc
.flt_shr_denominator:
    rcr     qword [r11], 1
    lea     r11, [r11 - 8]
    dec     ecx
    jnz     .flt_shr_denominator
    dec     qword [rbp - 200]
    jmp     .flt_normalized
.flt_scale_numerator:
    call    .big_shl
    dec     qword [rbp - 200]
    call    .big_compare
    jb      .flt_scale_numerator
.flt_normalized:
    ; 1 <= numerator / denominator < 2. Generate significant bits exactly.
    mov     rax, [rbp - 200]
    cmp     rax, 127
    jg      .float_overflow
    cmp     rax, -150
    jl      .flt_zero
    je      .flt_half_subnormal
    mov     ecx, 23
    cmp     rax, -126
    jge     .flt_precision
    lea     ecx, [eax + 149]            ; subnormal precision (0..22 fraction bits)
.flt_precision:
    mov     [rbp - 216], rcx
    mov     qword [rbp - 208], 1
    call    .big_subtract
    cmp     qword [rbp - 216], 0
    je      .flt_round
.flt_bit:
    call    .big_shl
    shl     qword [rbp - 208], 1
    call    .big_compare
    jb      .flt_bit_next
    call    .big_subtract
    or      qword [rbp - 208], 1
.flt_bit_next:
    dec     qword [rbp - 216]
    jnz     .flt_bit
.flt_round:
    call    .big_shl                    ; compare exact remainder with half denominator
    call    .big_compare
    jb      .flt_encode
    ja      .flt_round_up
    test    qword [rbp - 208], 1        ; ties to even
    jz      .flt_encode
.flt_round_up:
    inc     qword [rbp - 208]
.flt_encode:
    mov     rax, [rbp - 208]
    mov     rcx, [rbp - 200]
    cmp     rcx, -126
    jl      .flt_store                 ; subnormal bits (may round to min normal)
    cmp     eax, 0x1000000
    jne     .flt_exponent
    shr     eax, 1
    inc     rcx
.flt_exponent:
    cmp     rcx, 127
    jg      .float_overflow
    add     ecx, 127
    shl     ecx, 23
    and     eax, 0x7fffff
    or      eax, ecx
    jmp     .flt_store
.flt_half_subnormal:
    call    .big_compare
    seta    al                         ; exact half rounds to even zero
    movzx   eax, al
    jmp     .flt_store
.flt_zero:
    xor     eax, eax
.flt_store:
    cmp     qword [rbp - 40], 0
    je      .flt_positive
    xor     eax, 0x80000000             ; preserve negative zero
.flt_positive:
    mov     r11, [rbp - 24]
    mov     [r11], rax
    mov     r11, [rbp - 32]
    mov     dword [r11], CAT_FLOAT32
    mov     eax, 1
    FRAME_END
    ret
.float_overflow:
    mov     eax, -2
    FRAME_END
    ret

; Private leaf helpers: r8/r9 are little-endian 8-limb operands.
; No floating instructions: rounding is independent of caller MXCSR.
.big_mul10:
    mov     ecx, 8
    mov     r10d, 10
    mov     [rbp - 224], r8
.big_mul_loop:
    mov     rax, [r8]
    mul     r10
    add     rax, r11
    adc     rdx, 0
    mov     [r8], rax
    mov     r11, rdx
    add     r8, 8
    dec     ecx
    jnz     .big_mul_loop
    mov     r8, [rbp - 224]
    ret
.big_compare:
    mov     ecx, 8
.big_cmp_loop:
    mov     rax, [r8 + rcx * 8 - 8]
    cmp     rax, [r9 + rcx * 8 - 8]
    jne     .big_cmp_return
    dec     ecx
    jnz     .big_cmp_loop
    xor     eax, eax                    ; equal: ZF=1, CF=0
.big_cmp_return:
    ret
.big_shl:
    mov     r11, r8
    mov     ecx, 8
    clc
.big_shl_loop:
    rcl     qword [r11], 1
    lea     r11, [r11 + 8]
    dec     ecx
    jnz     .big_shl_loop
    ret
.big_subtract:
    mov     ecx, 8
    xor     r11d, r11d                  ; also clears carry
.big_sub_loop:
    mov     rax, [r9 + r11 * 8]
    sbb     [r8 + r11 * 8], rax
    inc     r11
    dec     ecx
    jnz     .big_sub_loop
    ret

.num_overflow:
    mov     eax, -1
    FRAME_END
    ret

.num_fail:
    xor     eax, eax
    FRAME_END
    ret

; ASCII hex digit in AL -> EAX 0..15, or -1.
hex_nibble:
    cmp     al, '0'
    jb      .bad
    cmp     al, '9'
    jbe     .digit
    or      al, 32
    cmp     al, 'a'
    jb      .bad
    cmp     al, 'f'
    ja      .bad
    movzx   eax, al
    sub     eax, 'a' - 10
    ret
.digit:
    movzx   eax, al
    sub     eax, '0'
    ret
.bad:
    mov     eax, -1
    ret

; -----------------------------------------------------------------------------
;  parse_primary(tok_ctx, sql_src, arena, out_err) -> RAX: AST_EXPR* or 0
; -----------------------------------------------------------------------------
parse_primary:
    FRAME_BEGIN 112, 1
    mov     [rbp - 8], ARG1             ; tok_ctx
    mov     [rbp - 16], ARG2            ; sql_src
    mov     [rbp - 24], ARG3            ; arena
    mov     [rbp - 32], ARG4            ; out_err
    mov     qword [rbp - 80], 0         ; is_negative = 0

    ; Peek token
    mov     ARG1, [rbp - 8]
    lea     ARG2, [rbp - 64]            ; token buffer (32 bytes)
    call    sql_tok_peek
    test    eax, eax
    jnz     .fail

    mov     rax, [rbp - 64 + TOK_TYPE]

    cmp     rax, TOK_PLUS
    je      .is_unary_plus
    cmp     rax, TOK_MINUS
    je      .is_unary_minus

    ; Check IDENT
    cmp     rax, TOK_IDENT
    je      .is_ident

    ; Check INT_LIT or FLOAT_LIT
    cmp     rax, TOK_INT_LIT
    je      .is_num
    cmp     rax, TOK_FLOAT_LIT
    je      .is_num

    ; Variable-width literals are decoded into arena-owned byte slices.
    cmp     rax, TOK_STRING_LIT
    je      .is_string
    cmp     rax, TOK_BLOB_LIT
    je      .is_blob

    ; Check TRUE
    cmp     rax, TOK_TRUE
    je      .is_true

    ; Check FALSE
    cmp     rax, TOK_FALSE
    je      .is_false

    ; Check NULL
    cmp     rax, TOK_NULL
    je      .is_null

    ; Check '('
    cmp     rax, TOK_LPAREN
    je      .is_paren

    ; Check NOT
    cmp     rax, TOK_NOT
    je      .is_not

    ; Unexpected token
    mov     ARG1, [rbp - 32]
    mov     ARG2, SQL_ERR_SYNTAX
    lea     ARG3, [rbp - 64]
    lea     ARG4, [err_expected_expr]
    call    set_error
    xor     eax, eax
    FRAME_END
    ret

.is_unary_minus:
    mov     qword [rbp - 80], 1
.is_unary_plus:
    ; Consume unary '+' or '-'
    mov     ARG1, [rbp - 8]
    lea     ARG2, [rbp - 64]
    call    sql_tok_next

    ; Peek next token
    mov     ARG1, [rbp - 8]
    lea     ARG2, [rbp - 64]
    call    sql_tok_peek
    test    eax, eax
    jnz     .fail

    mov     rax, [rbp - 64 + TOK_TYPE]
    cmp     rax, TOK_INT_LIT
    je      .is_num
    cmp     rax, TOK_FLOAT_LIT
    je      .is_num

    ; If not a number literal after unary +/-: syntax error
    mov     ARG1, [rbp - 32]
    mov     ARG2, SQL_ERR_SYNTAX
    lea     ARG3, [rbp - 64]
    lea     ARG4, [err_expected_expr]
    call    set_error
    xor     eax, eax
    FRAME_END
    ret

.is_ident:
    ; Consume IDENT
    mov     ARG1, [rbp - 8]
    lea     ARG2, [rbp - 64]
    call    sql_tok_next

    mov     rax, [rbp - 64 + TOK_OFFSET]
    add     rax, [rbp - 16]
    mov     [rbp - 88], rax            ; first identifier ptr
    mov     rax, [rbp - 64 + TOK_LEN]
    mov     [rbp - 96], rax            ; first identifier len
    mov     eax, [rbp - 64 + TOK_OFFSET]
    mov     [rbp - 104], eax

    ; A column may be qualified by its table name or table alias.
    mov     ARG1, [rbp - 8]
    lea     ARG2, [rbp - 64]
    call    sql_tok_peek
    test    eax, eax
    jnz     .fail
    cmp     qword [rbp - 64 + TOK_TYPE], TOK_DOT
    jne     .ident_unqualified

    mov     ARG1, [rbp - 8]
    lea     ARG2, [rbp - 64]
    call    sql_tok_next               ; consume '.'
    mov     ARG1, [rbp - 8]
    lea     ARG2, [rbp - 64]
    call    sql_tok_next               ; consume column component
    test    eax, eax
    jnz     .fail
    cmp     qword [rbp - 64 + TOK_TYPE], TOK_IDENT
    jne     .ident_expected_after_dot

    ; Allocate AST_EXPR
    mov     ARG1, [rbp - 24]
    mov     ARG2, AST_EXPR_SIZE
    call    sql_arena_alloc
    test    rax, rax
    jz      .oom
    mov     [rbp - 72], rax             ; expr ptr

    mov     qword [rax + EXPR_KIND], EXPR_COLUMN
    mov     qword [rax + EXPR_OP], 0
    mov     rdx, [rbp - 88]
    mov     [rax + EXPR_QUAL_PTR], rdx
    mov     rdx, [rbp - 96]
    mov     [rax + EXPR_QUAL_LEN], rdx

    mov     rdx, [rbp - 64 + TOK_OFFSET]
    add     rdx, [rbp - 16]
    mov     [rax + EXPR_NAME_PTR], rdx
    mov     rdx, [rbp - 64 + TOK_LEN]
    mov     [rax + EXPR_NAME_LEN], rdx
    mov     edx, [rbp - 64 + TOK_OFFSET]
    mov     [rax + EXPR_TOK_OFFSET], edx

    mov     rax, [rbp - 72]
    FRAME_END
    ret

.ident_unqualified:
    ; Peek replaced the token buffer, so use the preserved first component.
    mov     ARG1, [rbp - 24]
    mov     ARG2, AST_EXPR_SIZE
    call    sql_arena_alloc
    test    rax, rax
    jz      .oom
    mov     qword [rax + EXPR_KIND], EXPR_COLUMN
    mov     qword [rax + EXPR_OP], 0
    mov     qword [rax + EXPR_QUAL_PTR], 0
    mov     qword [rax + EXPR_QUAL_LEN], 0
    mov     rdx, [rbp - 88]
    mov     [rax + EXPR_NAME_PTR], rdx
    mov     rdx, [rbp - 96]
    mov     [rax + EXPR_NAME_LEN], rdx
    mov     edx, [rbp - 104]
    mov     [rax + EXPR_TOK_OFFSET], edx
    FRAME_END
    ret

.ident_expected_after_dot:
    mov     ARG1, [rbp - 32]
    mov     ARG2, SQL_ERR_SYNTAX
    lea     ARG3, [rbp - 64]
    lea     ARG4, [err_expected_expr]
    call    set_error
    xor     eax, eax
    FRAME_END
    ret

.is_string:
    mov     ARG1, [rbp - 8]
    lea     ARG2, [rbp - 64]
    call    sql_tok_next

    mov     ARG1, [rbp - 24]
    mov     ARG2, AST_EXPR_SIZE
    call    sql_arena_alloc
    test    rax, rax
    jz      .oom
    mov     qword [rax + EXPR_KIND], EXPR_LITERAL
    mov     qword [rax + EXPR_OP], 0
    mov     [rbp - 72], rax
    mov     rdx, [rbp - 64 + TOK_LEN]
    sub     rdx, 2                      ; decoded length is at most this
    mov     ARG1, [rbp - 24]
    mov     ARG2, rdx
    inc     ARG2                        ; keep empty strings addressable
    call    sql_arena_alloc
    test    rax, rax
    jz      .oom
    mov     rdi, rax
    mov     r8, rax                     ; decoded start
    mov     rsi, [rbp - 64 + TOK_OFFSET]
    add     rsi, [rbp - 16]
    inc     rsi                         ; exclude opening quote
    mov     rcx, [rbp - 64 + TOK_LEN]
    sub     rcx, 2
.string_decode:
    test    rcx, rcx
    jz      .string_decoded
    mov     al, [rsi]
    mov     [rdi], al
    inc     rsi
    inc     rdi
    dec     rcx
    cmp     al, "'"
    jne     .string_decode
    ; The tokenizer only permits an interior quote as a doubled quote.
    inc     rsi
    dec     rcx
    jmp     .string_decode
.string_decoded:
    mov     rax, [rbp - 72]
    mov     [rax + EXPR_LIT_PTR], r8
    sub     rdi, r8
    mov     [rax + EXPR_LIT_LEN], rdi
    mov     qword [rax + EXPR_LIT_VAL], 0
    mov     dword [rax + EXPR_LIT_TYPE], CAT_TEXT
    mov     edx, [rbp - 64 + TOK_OFFSET]
    mov     [rax + EXPR_TOK_OFFSET], edx
    FRAME_END
    ret

.is_blob:
    mov     ARG1, [rbp - 8]
    lea     ARG2, [rbp - 64]
    call    sql_tok_next

    mov     rcx, [rbp - 64 + TOK_LEN]
    sub     rcx, 3                      ; X plus opening/closing quotes
    test    rcx, 1
    jnz     .bad_blob

    mov     ARG1, [rbp - 24]
    mov     ARG2, AST_EXPR_SIZE
    call    sql_arena_alloc
    test    rax, rax
    jz      .oom
    mov     [rbp - 72], rax
    mov     qword [rax + EXPR_KIND], EXPR_LITERAL
    mov     qword [rax + EXPR_OP], 0

    mov     rdx, [rbp - 64 + TOK_LEN]
    sub     rdx, 3
    shr     rdx, 1
    mov     ARG1, [rbp - 24]
    mov     ARG2, rdx
    inc     ARG2
    call    sql_arena_alloc
    test    rax, rax
    jz      .oom
    mov     rdi, rax
    mov     r8, rax
    mov     rsi, [rbp - 64 + TOK_OFFSET]
    add     rsi, [rbp - 16]
    add     rsi, 2                      ; exclude X and opening quote
    mov     rcx, [rbp - 64 + TOK_LEN]
    sub     rcx, 3
.blob_decode:
    test    rcx, rcx
    jz      .blob_decoded
    movzx   eax, byte [rsi]
    call    hex_nibble
    test    eax, eax
    js      .bad_blob
    mov     r10d, eax
    shl     r10d, 4
    movzx   eax, byte [rsi + 1]
    call    hex_nibble
    test    eax, eax
    js      .bad_blob
    or      eax, r10d
    mov     [rdi], al
    add     rsi, 2
    inc     rdi
    sub     rcx, 2
    jmp     .blob_decode
.blob_decoded:
    mov     rax, [rbp - 72]
    mov     [rax + EXPR_LIT_PTR], r8
    sub     rdi, r8
    mov     [rax + EXPR_LIT_LEN], rdi
    mov     qword [rax + EXPR_LIT_VAL], 0
    mov     dword [rax + EXPR_LIT_TYPE], CAT_BLOB
    mov     edx, [rbp - 64 + TOK_OFFSET]
    mov     [rax + EXPR_TOK_OFFSET], edx
    FRAME_END
    ret

.bad_blob:
    mov     ARG1, [rbp - 32]
    mov     ARG2, SQL_ERR_SYNTAX
    lea     ARG3, [rbp - 64]
    lea     ARG4, [err_bad_blob]
    call    set_error
    xor     eax, eax
    FRAME_END
    ret

.is_num:
    ; Consume number
    mov     ARG1, [rbp - 8]
    lea     ARG2, [rbp - 64]
    call    sql_tok_next

    ; Allocate AST_EXPR
    mov     ARG1, [rbp - 24]
    mov     ARG2, AST_EXPR_SIZE
    call    sql_arena_alloc
    test    rax, rax
    jz      .oom
    mov     [rbp - 72], rax

    mov     qword [rax + EXPR_KIND], EXPR_LITERAL
    mov     qword [rax + EXPR_LEFT], 0
    mov     qword [rax + EXPR_RIGHT], 0
    mov     edx, [rbp - 64 + TOK_OFFSET]
    mov     [rax + EXPR_TOK_OFFSET], edx

    ; Parse number value into expr
    lea     ARG1, [rbp - 64]
    mov     ARG2, [rbp - 16]
    mov     r10, [rbp - 72]
    lea     ARG3, [r10 + EXPR_LIT_VAL]
    lea     ARG4, [r10 + EXPR_LIT_TYPE]
    mov     rax, [rbp - 80]             ; is_negative
    PASS_ARG5 rax
    call    parse_number
    cmp     eax, 1
    je      .num_ok
    cmp     eax, -2
    je      .float_range
    cmp     eax, -1
    je      .overflow
    jmp     .bad_num

.num_ok:
    mov     rax, [rbp - 72]
    FRAME_END
    ret

.float_range:
    lea     r11, [err_float_range]
    jmp     .number_error
.overflow:
    lea     r11, [err_overflow]
.number_error:
    mov     ARG1, [rbp - 32]
    mov     ARG2, SQL_ERR_SYNTAX
    lea     ARG3, [rbp - 64]
    mov     ARG4, r11
    call    set_error
    xor     eax, eax
    FRAME_END
    ret

.is_true:
    mov     ARG1, [rbp - 8]
    lea     ARG2, [rbp - 64]
    call    sql_tok_next

    mov     ARG1, [rbp - 24]
    mov     ARG2, AST_EXPR_SIZE
    call    sql_arena_alloc
    test    rax, rax
    jz      .oom
    mov     qword [rax + EXPR_KIND], EXPR_LITERAL
    mov     qword [rax + EXPR_LIT_VAL], 1
    mov     dword [rax + EXPR_LIT_TYPE], CAT_BOOL
    mov     edx, [rbp - 64 + TOK_OFFSET]
    mov     [rax + EXPR_TOK_OFFSET], edx
    FRAME_END
    ret

.is_false:
    mov     ARG1, [rbp - 8]
    lea     ARG2, [rbp - 64]
    call    sql_tok_next

    mov     ARG1, [rbp - 24]
    mov     ARG2, AST_EXPR_SIZE
    call    sql_arena_alloc
    test    rax, rax
    jz      .oom
    mov     qword [rax + EXPR_KIND], EXPR_LITERAL
    mov     qword [rax + EXPR_LIT_VAL], 0
    mov     dword [rax + EXPR_LIT_TYPE], CAT_BOOL
    mov     edx, [rbp - 64 + TOK_OFFSET]
    mov     [rax + EXPR_TOK_OFFSET], edx
    FRAME_END
    ret

.is_null:
    mov     ARG1, [rbp - 8]
    lea     ARG2, [rbp - 64]
    call    sql_tok_next

    mov     ARG1, [rbp - 24]
    mov     ARG2, AST_EXPR_SIZE
    call    sql_arena_alloc
    test    rax, rax
    jz      .oom
    mov     qword [rax + EXPR_KIND], EXPR_LITERAL
    mov     qword [rax + EXPR_LIT_VAL], 0
    mov     dword [rax + EXPR_LIT_TYPE], 0 ; TYPE_NULL
    mov     edx, [rbp - 64 + TOK_OFFSET]
    mov     [rax + EXPR_TOK_OFFSET], edx
    FRAME_END
    ret

.is_paren:
    ; Consume '('
    mov     ARG1, [rbp - 8]
    lea     ARG2, [rbp - 64]
    call    sql_tok_next

    ; Parse inside expression with min_prec = 1
    mov     ARG1, [rbp - 8]
    mov     ARG2, [rbp - 16]
    mov     ARG3, [rbp - 24]
    mov     ARG4, [rbp - 32]
    mov     rax, 1
    PASS_ARG5 rax
    EXPR_DEPTH_ENTER .too_deep
    call    parse_expr_prec
    EXPR_DEPTH_LEAVE
    test    rax, rax
    jz      .fail
    mov     [rbp - 72], rax

    ; Expect ')'
    mov     ARG1, [rbp - 8]
    lea     ARG2, [rbp - 64]
    call    sql_tok_next
    cmp     qword [rbp - 64 + TOK_TYPE], TOK_RPAREN
    jne     .paren_mismatch

    mov     rax, [rbp - 72]
    FRAME_END
    ret

.paren_mismatch:
    mov     ARG1, [rbp - 32]
    mov     ARG2, SQL_ERR_SYNTAX
    lea     ARG3, [rbp - 64]
    lea     ARG4, [err_expected_rparen]
    call    set_error
    xor     eax, eax
    FRAME_END
    ret

.is_not:
    ; Consume 'NOT'
    mov     ARG1, [rbp - 8]
    lea     ARG2, [rbp - 64]
    call    sql_tok_next

    ; Save token offset
    mov     edx, [rbp - 64 + TOK_OFFSET]
    mov     [rbp - 88], rdx

    ; Parse operand with min_prec = 3 (binds comparisons and IS NULL)
    mov     ARG1, [rbp - 8]
    mov     ARG2, [rbp - 16]
    mov     ARG3, [rbp - 24]
    mov     ARG4, [rbp - 32]
    mov     rax, 3
    PASS_ARG5 rax
    EXPR_DEPTH_ENTER .too_deep
    call    parse_expr_prec
    EXPR_DEPTH_LEAVE
    test    rax, rax
    jz      .fail
    mov     [rbp - 72], rax             ; operand expr

    ; Allocate unary AST_EXPR
    mov     ARG1, [rbp - 24]
    mov     ARG2, AST_EXPR_SIZE
    call    sql_arena_alloc
    test    rax, rax
    jz      .oom

    mov     qword [rax + EXPR_KIND], EXPR_UNARY
    mov     qword [rax + EXPR_OP], OP_NOT
    mov     rdx, [rbp - 72]
    mov     [rax + EXPR_LEFT], rdx
    mov     qword [rax + EXPR_RIGHT], 0
    mov     edx, [rbp - 88]
    mov     [rax + EXPR_TOK_OFFSET], edx

    FRAME_END
    ret

.bad_num:
    mov     ARG1, [rbp - 32]
    mov     ARG2, SQL_ERR_SYNTAX
    lea     ARG3, [rbp - 64]
    lea     ARG4, [err_bad_number]
    call    set_error
    xor     eax, eax
    FRAME_END
    ret

.too_deep:
    mov     ARG1, [rbp - 32]
    mov     ARG2, SQL_ERR_EXPR_DEPTH
    lea     ARG3, [rbp - 64]
    lea     ARG4, [err_expr_depth]
    call    set_error
    xor     eax, eax
    FRAME_END
    ret

.oom:
    mov     ARG1, [rbp - 32]
    mov     ARG2, SQL_ERR_NO_STORAGE
    lea     ARG3, [rbp - 64]
    lea     ARG4, [err_oom]
    call    set_error
    xor     eax, eax
    FRAME_END
    ret

.fail:
    xor     eax, eax
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  parse_expr_prec(tok_ctx, sql_src, arena, out_err, min_prec)
; -----------------------------------------------------------------------------
parse_expr_prec:
    FRAME_BEGIN 112, 1
    mov     [rbp - 8], ARG1             ; tok_ctx
    mov     [rbp - 16], ARG2            ; sql_src
    mov     [rbp - 24], ARG3            ; arena
    mov     [rbp - 32], ARG4            ; out_err
    mov     rax, IN_ARG5
    mov     [rbp - 40], rax             ; min_prec

    ; Parse primary into left
    call    parse_primary
    test    rax, rax
    jz      .fail
    mov     [rbp - 48], rax             ; left expr

.loop:
    ; Peek next token
    mov     ARG1, [rbp - 8]
    lea     ARG2, [rbp - 80]            ; tok buffer
    call    sql_tok_peek
    test    eax, eax
    jnz     .fail

    mov     rax, [rbp - 80 + TOK_TYPE]

    ; Check postfix "IS [NOT] NULL"
    cmp     rax, TOK_IS
    je      .handle_is

    ; Map token to binary operator and precedence
    ; Precedence levels:
    ; OR: 1
    ; AND: 2
    ; Comparisons: 3
    cmp     rax, TOK_OR
    je      .op_or
    cmp     rax, TOK_AND
    je      .op_and
    cmp     rax, TOK_EQ
    je      .op_eq
    cmp     rax, TOK_NEQ
    je      .op_neq
    cmp     rax, TOK_LT
    je      .op_lt
    cmp     rax, TOK_LTE
    je      .op_lte
    cmp     rax, TOK_GT
    je      .op_gt
    cmp     rax, TOK_GTE
    je      .op_gte

    ; Not an operator -> done with this precedence level
    jmp     .done

.op_or:
    mov     r10, OP_OR
    mov     r11, 1                      ; prec 1
    jmp     .check_prec
.op_and:
    mov     r10, OP_AND
    mov     r11, 2                      ; prec 2
    jmp     .check_prec
.op_eq:
    mov     r10, OP_EQ
    mov     r11, 3
    jmp     .check_prec
.op_neq:
    mov     r10, OP_NEQ
    mov     r11, 3
    jmp     .check_prec
.op_lt:
    mov     r10, OP_LT
    mov     r11, 3
    jmp     .check_prec
.op_lte:
    mov     r10, OP_LTE
    mov     r11, 3
    jmp     .check_prec
.op_gt:
    mov     r10, OP_GT
    mov     r11, 3
    jmp     .check_prec
.op_gte:
    mov     r10, OP_GTE
    mov     r11, 3
    jmp     .check_prec

.check_prec:
    cmp     r11, [rbp - 40]
    jb      .done                       ; prec < min_prec

    mov     [rbp - 88], r10             ; op
    mov     [rbp - 96], r11             ; prec

    ; Consume operator token
    mov     ARG1, [rbp - 8]
    lea     ARG2, [rbp - 80]
    call    sql_tok_next

    ; Parse right operand with min_prec = op_prec + 1
    mov     ARG1, [rbp - 8]
    mov     ARG2, [rbp - 16]
    mov     ARG3, [rbp - 24]
    mov     ARG4, [rbp - 32]
    mov     rax, [rbp - 96]
    inc     rax
    PASS_ARG5 rax
    EXPR_DEPTH_ENTER .too_deep
    call    parse_expr_prec
    EXPR_DEPTH_LEAVE
    test    rax, rax
    jz      .fail
    mov     [rbp - 104], rax            ; right expr

    ; Allocate binary AST_EXPR
    mov     ARG1, [rbp - 24]
    mov     ARG2, AST_EXPR_SIZE
    call    sql_arena_alloc
    test    rax, rax
    jz      .oom

    mov     qword [rax + EXPR_KIND], EXPR_BINARY
    mov     rdx, [rbp - 88]
    mov     [rax + EXPR_OP], rdx
    mov     rdx, [rbp - 48]
    mov     [rax + EXPR_LEFT], rdx
    mov     rdx, [rbp - 104]
    mov     [rax + EXPR_RIGHT], rdx
    mov     edx, [rbp - 80 + TOK_OFFSET]
    mov     [rax + EXPR_TOK_OFFSET], edx

    mov     [rbp - 48], rax             ; left = new binary expr
    jmp     .loop

.handle_is:
    ; IS NULL / IS NOT NULL has precedence 4
    cmp     qword [rbp - 40], 4
    ja      .done

    ; Consume 'IS'
    mov     ARG1, [rbp - 8]
    lea     ARG2, [rbp - 80]
    call    sql_tok_next

    ; Peek next
    mov     ARG1, [rbp - 8]
    lea     ARG2, [rbp - 80]
    call    sql_tok_peek
    test    eax, eax
    jnz     .fail

    cmp     qword [rbp - 80 + TOK_TYPE], TOK_NOT
    je      .is_not_null
    cmp     qword [rbp - 80 + TOK_TYPE], TOK_NULL
    je      .is_null_op

    mov     ARG1, [rbp - 32]
    mov     ARG2, SQL_ERR_SYNTAX
    lea     ARG3, [rbp - 80]
    lea     ARG4, [err_syntax_msg]
    call    set_error
    xor     eax, eax
    FRAME_END
    ret

.is_not_null:
    ; Consume NOT
    mov     ARG1, [rbp - 8]
    lea     ARG2, [rbp - 80]
    call    sql_tok_next
    ; Consume NULL
    mov     ARG1, [rbp - 8]
    lea     ARG2, [rbp - 80]
    call    sql_tok_next
    cmp     qword [rbp - 80 + TOK_TYPE], TOK_NULL
    jne     .is_syntax_err

    mov     r10, OP_IS_NOT_NULL
    jmp     .create_unary

.is_null_op:
    ; Consume NULL
    mov     ARG1, [rbp - 8]
    lea     ARG2, [rbp - 80]
    call    sql_tok_next
    mov     r10, OP_IS_NULL

.create_unary:
    mov     [rbp - 88], r10
    mov     ARG1, [rbp - 24]
    mov     ARG2, AST_EXPR_SIZE
    call    sql_arena_alloc
    test    rax, rax
    jz      .oom
    mov     qword [rax + EXPR_KIND], EXPR_UNARY
    mov     rdx, [rbp - 88]
    mov     [rax + EXPR_OP], rdx
    mov     rdx, [rbp - 48]
    mov     [rax + EXPR_LEFT], rdx
    mov     qword [rax + EXPR_RIGHT], 0
    mov     edx, [rbp - 80 + TOK_OFFSET]
    mov     [rax + EXPR_TOK_OFFSET], edx

    mov     [rbp - 48], rax
    jmp     .loop

.is_syntax_err:
    mov     ARG1, [rbp - 32]
    mov     ARG2, SQL_ERR_SYNTAX
    lea     ARG3, [rbp - 80]
    lea     ARG4, [err_syntax_msg]
    call    set_error
    xor     eax, eax
    FRAME_END
    ret

.too_deep:
    mov     ARG1, [rbp - 32]
    mov     ARG2, SQL_ERR_EXPR_DEPTH
    lea     ARG3, [rbp - 80]
    lea     ARG4, [err_expr_depth]
    call    set_error
    xor     eax, eax
    FRAME_END
    ret

.oom:
    mov     ARG1, [rbp - 32]
    mov     ARG2, SQL_ERR_NO_STORAGE
    lea     ARG3, [rbp - 80]
    lea     ARG4, [err_oom]
    call    set_error
    xor     eax, eax
    FRAME_END
    ret

.done:
    mov     rax, [rbp - 48]
    FRAME_END
    ret

.fail:
    xor     eax, eax
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  sql_parse(sql_src, sql_len, arena, out_stmt, out_err) -> RAX: SQL_OK / err
; -----------------------------------------------------------------------------
; -----------------------------------------------------------------------------
;  sql_parse(sql_src, sql_len, arena, out_stmt, out_err) -> RAX: SQL_OK / err
; -----------------------------------------------------------------------------
sql_parse:
    FRAME_BEGIN 256, 1
    mov     [rbp - 8], ARG1             ; sql_src
    mov     [rbp - 16], ARG2            ; sql_len
    mov     [rbp - 24], ARG3            ; arena
    mov     [rbp - 32], ARG4            ; out_stmt
    mov     rax, IN_ARG5
    mov     [rbp - 40], rax             ; out_err
    SQL_CLEAR_ERROR rax
    mov     qword [expr_depth], 0

    ; Init tokenizer in local frame: [rbp-160] is SQL_TOKENIZER (80 bytes: -160 to -81)
    lea     ARG1, [rbp - 160]
    mov     ARG2, [rbp - 8]
    mov     ARG3, [rbp - 16]
    call    sql_tok_init

    ; Allocate AST_STMT in arena
    mov     ARG1, [rbp - 24]
    mov     ARG2, AST_STMT_SIZE
    call    sql_arena_alloc
    test    rax, rax
    jz      .oom
    mov     [rbp - 48], rax             ; stmt ptr
    mov     r11, [rbp - 32]
    mov     [r11], rax

    ; Allocate the statement-specific payload separately from the stable AST
    ; header. Existing statement kinds currently share this initial layout.
    mov     ARG1, [rbp - 24]
    mov     ARG2, AST_STMT_PAYLOAD_SIZE
    call    sql_arena_alloc
    test    rax, rax
    jz      .oom
    mov     r10, [rbp - 32]
    mov     r10, [r10]
    mov     [r10 + AST_STMT_PAYLOAD], rax
    mov     [rbp - 48], rax             ; parser body works on payload

    ; Fetch first token into [rbp - 192] (32 bytes: -192 to -161)
    lea     ARG1, [rbp - 160]
    lea     ARG2, [rbp - 192]           ; token buffer (32 bytes)
    call    sql_tok_next
    test    eax, eax
    jnz     .fail

    mov     rax, [rbp - 192 + TOK_TYPE]
    cmp     rax, TOK_CREATE
    je      .parse_create
    cmp     rax, TOK_INSERT
    je      .parse_insert
    cmp     rax, TOK_SELECT
    je      .parse_select

    ; Unknown initial token
    mov     ARG1, [rbp - 40]
    mov     ARG2, SQL_ERR_SYNTAX
    lea     ARG3, [rbp - 192]
    lea     ARG4, [err_syntax_msg]
    call    set_error
    mov     eax, SQL_ERR_SYNTAX
    FRAME_END
    ret

; --- CREATE TABLE ------------------------------------------------------------
.parse_create:
    mov     r10, [rbp - 32]
    mov     r10, [r10]
    mov     qword [r10 + AST_STMT_TYPE], STMT_CREATE_TABLE

    ; Expect TABLE
    lea     ARG1, [rbp - 160]
    lea     ARG2, [rbp - 192]
    call    sql_tok_next
    cmp     qword [rbp - 192 + TOK_TYPE], TOK_TABLE
    jne     .bad_syntax

    ; Expect IDENT (table name)
    lea     ARG1, [rbp - 160]
    lea     ARG2, [rbp - 192]
    call    sql_tok_next
    cmp     qword [rbp - 192 + TOK_TYPE], TOK_IDENT
    jne     .bad_table_name

    mov     r10, [rbp - 48]
    mov     rax, [rbp - 192 + TOK_OFFSET]
    add     rax, [rbp - 8]
    mov     [r10 + STMT_NAME_PTR], rax
    mov     rax, [rbp - 192 + TOK_LEN]
    mov     [r10 + STMT_NAME_LEN], rax

    ; Expect '('
    lea     ARG1, [rbp - 160]
    lea     ARG2, [rbp - 192]
    call    sql_tok_next
    cmp     qword [rbp - 192 + TOK_TYPE], TOK_LPAREN
    jne     .bad_lparen

    ; Allocate column definitions array (up to 64 cols * 24 bytes = 1536 bytes)
    mov     ARG1, [rbp - 24]
    mov     ARG2, 64 * AST_COLDEF_SIZE
    call    sql_arena_alloc
    test    rax, rax
    jz      .oom
    mov     r10, [rbp - 48]
    mov     [r10 + STMT_EXTRA2], rax    ; col_defs array
    mov     qword [rbp - 56], 0         ; col_count = 0

.col_loop:
    cmp     qword [rbp - 56], 64
    jae     .bad_col_limit

    ; Expect column name IDENT
    lea     ARG1, [rbp - 160]
    lea     ARG2, [rbp - 192]
    call    sql_tok_next
    cmp     qword [rbp - 192 + TOK_TYPE], TOK_IDENT
    jne     .bad_col_name

    mov     rcx, [rbp - 56]
    mov     r10, [rbp - 48]
    mov     r11, [r10 + STMT_EXTRA2]
    imul    rdx, rcx, AST_COLDEF_SIZE
    add     rdx, r11                    ; col_def slot

    mov     rax, [rbp - 192 + TOK_OFFSET]
    add     rax, [rbp - 8]
    mov     [rdx + COLDEF_NAME_PTR], rax
    mov     rax, [rbp - 192 + TOK_LEN]
    mov     [rdx + COLDEF_NAME_LEN], rax

    ; Expect type
    lea     ARG1, [rbp - 160]
    lea     ARG2, [rbp - 192]
    call    sql_tok_next

    mov     rax, [rbp - 192 + TOK_TYPE]
    mov     r8d, CAT_INT32
    cmp     rax, TOK_TYPE_INT32
    je      .type_ok
    mov     r8d, CAT_INT64
    cmp     rax, TOK_TYPE_INT64
    je      .type_ok
    mov     r8d, CAT_FLOAT32
    cmp     rax, TOK_TYPE_FLOAT32
    je      .type_ok
    mov     r8d, CAT_BOOL
    cmp     rax, TOK_TYPE_BOOL
    je      .type_ok
    mov     r8d, CAT_TEXT
    cmp     rax, TOK_TYPE_TEXT
    je      .type_ok
    mov     r8d, CAT_BLOB
    cmp     rax, TOK_TYPE_BLOB
    je      .type_ok
    jmp     .bad_type

.type_ok:
    mov     rcx, [rbp - 56]
    mov     r10, [rbp - 48]
    mov     r11, [r10 + STMT_EXTRA2]
    imul    rdx, rcx, AST_COLDEF_SIZE
    add     rdx, r11
    mov     [rdx + COLDEF_TYPE], r8d
    mov     dword [rdx + COLDEF_FLAGS], CAT_NULLABLE ; default nullable (SQL standard)

    ; Check optional NULL / NOT NULL
    lea     ARG1, [rbp - 160]
    lea     ARG2, [rbp - 192]
    call    sql_tok_peek
    cmp     qword [rbp - 192 + TOK_TYPE], TOK_NULL
    jne     .check_not_null
    ; Explicit NULL
    lea     ARG1, [rbp - 160]
    lea     ARG2, [rbp - 192]
    call    sql_tok_next
    jmp     .col_sep

.check_not_null:
    cmp     qword [rbp - 192 + TOK_TYPE], TOK_NOT
    jne     .col_sep
    lea     ARG1, [rbp - 160]
    lea     ARG2, [rbp - 192]
    call    sql_tok_next                ; consume NOT
    lea     ARG1, [rbp - 160]
    lea     ARG2, [rbp - 192]
    call    sql_tok_next                ; consume NULL
    cmp     qword [rbp - 192 + TOK_TYPE], TOK_NULL
    jne     .bad_syntax
    ; Explicit NOT NULL -> clear CAT_NULLABLE
    mov     rcx, [rbp - 56]
    mov     r10, [rbp - 48]
    mov     r11, [r10 + STMT_EXTRA2]
    imul    rdx, rcx, AST_COLDEF_SIZE
    add     rdx, r11
    mov     dword [rdx + COLDEF_FLAGS], 0 ; not nullable

.col_sep:
    inc     qword [rbp - 56]

    ; Check comma or ')'
    lea     ARG1, [rbp - 160]
    lea     ARG2, [rbp - 192]
    call    sql_tok_next
    cmp     qword [rbp - 192 + TOK_TYPE], TOK_COMMA
    je      .col_loop
    cmp     qword [rbp - 192 + TOK_TYPE], TOK_RPAREN
    je      .create_done
    jmp     .bad_comma

.create_done:
    mov     r10, [rbp - 48]
    mov     rax, [rbp - 56]
    mov     [r10 + STMT_EXTRA1], rax    ; col_count
    jmp     .check_eof

; --- INSERT INTO -------------------------------------------------------------
.parse_insert:
    mov     r10, [rbp - 32]
    mov     r10, [r10]
    mov     qword [r10 + AST_STMT_TYPE], STMT_INSERT

    ; Expect INTO
    lea     ARG1, [rbp - 160]
    lea     ARG2, [rbp - 192]
    call    sql_tok_next
    cmp     qword [rbp - 192 + TOK_TYPE], TOK_INTO
    jne     .bad_syntax

    ; Expect table name
    lea     ARG1, [rbp - 160]
    lea     ARG2, [rbp - 192]
    call    sql_tok_next
    cmp     qword [rbp - 192 + TOK_TYPE], TOK_IDENT
    jne     .bad_table_name

    mov     r10, [rbp - 48]
    mov     rax, [rbp - 192 + TOK_OFFSET]
    add     rax, [rbp - 8]
    mov     [r10 + STMT_NAME_PTR], rax
    mov     rax, [rbp - 192 + TOK_LEN]
    mov     [r10 + STMT_NAME_LEN], rax

    ; Optional column list: ( col1, col2, ... )
    lea     ARG1, [rbp - 160]
    lea     ARG2, [rbp - 192]
    call    sql_tok_peek
    cmp     qword [rbp - 192 + TOK_TYPE], TOK_LPAREN
    jne     .insert_values

    ; Skip column list for now or consume it
    lea     ARG1, [rbp - 160]
    lea     ARG2, [rbp - 192]
    call    sql_tok_next                ; consume '('
.insert_skip_cols:
    lea     ARG1, [rbp - 160]
    lea     ARG2, [rbp - 192]
    call    sql_tok_next
    cmp     qword [rbp - 192 + TOK_TYPE], TOK_RPAREN
    je      .insert_values
    jmp     .insert_skip_cols

.insert_values:
    ; Expect VALUES
    lea     ARG1, [rbp - 160]
    lea     ARG2, [rbp - 192]
    call    sql_tok_next
    cmp     qword [rbp - 192 + TOK_TYPE], TOK_VALUES
    jne     .bad_values

    ; Allocate array of row pointers (up to 256 rows * 8 bytes = 2048 bytes)
    mov     ARG1, [rbp - 24]
    mov     ARG2, 256 * 8
    call    sql_arena_alloc
    test    rax, rax
    jz      .oom
    mov     r10, [rbp - 48]
    mov     [r10 + STMT_EXTRA4], rax    ; rows array ptr
    xor     ecx, ecx                    ; row_count = 0

.row_loop:
    cmp     rcx, 256
    jae     .bad_row_limit
    mov     [rbp - 56], rcx             ; save row_count

    ; Expect '('
    lea     ARG1, [rbp - 160]
    lea     ARG2, [rbp - 192]
    call    sql_tok_next
    cmp     qword [rbp - 192 + TOK_TYPE], TOK_LPAREN
    jne     .bad_lparen

    ; Allocate row expressions array (up to 64 cols * 8 bytes)
    mov     ARG1, [rbp - 24]
    mov     ARG2, 64 * 8
    call    sql_arena_alloc
    test    rax, rax
    jz      .oom
    mov     [rbp - 64], rax             ; current row values array ptr

    mov     rcx, [rbp - 56]
    mov     r10, [rbp - 48]
    mov     r11, [r10 + STMT_EXTRA4]
    mov     [r11 + rcx * 8], rax        ; store row ptr

    mov     qword [rbp - 72], 0         ; val_count = 0

.val_loop:
    cmp     qword [rbp - 72], 64
    jae     .bad_col_limit

    ; Parse primary literal expression
    lea     ARG1, [rbp - 160]
    mov     ARG2, [rbp - 8]
    mov     ARG3, [rbp - 24]
    mov     ARG4, [rbp - 40]
    call    parse_primary
    test    rax, rax
    jz      .fail

    mov     rcx, [rbp - 72]             ; val_count
    mov     rdx, [rbp - 64]             ; row_values ptr
    mov     [rdx + rcx * 8], rax        ; store expr ptr
    inc     rcx
    mov     [rbp - 72], rcx

    ; Check comma or ')'
    lea     ARG1, [rbp - 160]
    lea     ARG2, [rbp - 192]
    call    sql_tok_next
    cmp     qword [rbp - 192 + TOK_TYPE], TOK_COMMA
    je      .val_loop
    cmp     qword [rbp - 192 + TOK_TYPE], TOK_RPAREN
    jne     .bad_rparen

    ; Row done
    mov     rcx, [rbp - 56]
    inc     rcx
    mov     [rbp - 56], rcx

    ; Save column count from first row
    mov     r10, [rbp - 48]
    cmp     qword [r10 + STMT_EXTRA1], 0
    jne     .check_next_row
    mov     rax, [rbp - 72]
    mov     [r10 + STMT_EXTRA1], rax    ; col_count

.check_next_row:
    ; Check if another row follows ','
    lea     ARG1, [rbp - 160]
    lea     ARG2, [rbp - 192]
    call    sql_tok_peek
    cmp     qword [rbp - 192 + TOK_TYPE], TOK_COMMA
    jne     .insert_done
    ; Consume comma and parse next row
    lea     ARG1, [rbp - 160]
    lea     ARG2, [rbp - 192]
    call    sql_tok_next
    mov     rcx, [rbp - 56]
    jmp     .row_loop

.insert_done:
    mov     r10, [rbp - 48]
    mov     rax, [rbp - 56]
    mov     [r10 + STMT_EXTRA3], rax    ; row_count
    jmp     .check_eof

; --- SELECT ------------------------------------------------------------------
.parse_select:
    mov     r10, [rbp - 32]
    mov     r10, [r10]
    mov     qword [r10 + AST_STMT_TYPE], STMT_SELECT
    mov     r10, [rbp - 48]
    mov     qword [r10 + SELECT_JOIN_HEAD], 0
    mov     qword [r10 + SELECT_JOIN_COUNT], 0
    mov     qword [r10 + SELECT_LIMIT_VALUE], -1
    mov     qword [r10 + SELECT_OFFSET_VALUE], 0
    mov     qword [r10 + SELECT_ORDER_NAME], 0
    mov     qword [r10 + SELECT_ORDER_DESC], 0

    ; Peek projection
    lea     ARG1, [rbp - 160]
    lea     ARG2, [rbp - 192]
    call    sql_tok_peek
    cmp     qword [rbp - 192 + TOK_TYPE], TOK_STAR
    je      .proj_star
    cmp     qword [rbp - 192 + TOK_TYPE], TOK_COUNT
    je      .proj_count_star
    jmp     .proj_columns

.proj_star:
    ; SELECT *
    lea     ARG1, [rbp - 160]
    lea     ARG2, [rbp - 192]
    call    sql_tok_next                ; consume '*'
    mov     r10, [rbp - 48]
    mov     qword [r10 + STMT_EXTRA1], 0 ; proj_count = 0 (means *)
    mov     qword [r10 + STMT_EXTRA2], 0
    jmp     .select_from

.proj_count_star:
    ; SELECT COUNT(*)
    lea     ARG1, [rbp - 160]
    lea     ARG2, [rbp - 192]
    call    sql_tok_next                ; consume 'count'

    ; Expect '('
    lea     ARG1, [rbp - 160]
    lea     ARG2, [rbp - 192]
    call    sql_tok_next
    cmp     qword [rbp - 192 + TOK_TYPE], TOK_LPAREN
    jne     .bad_syntax

    ; Expect '*'
    lea     ARG1, [rbp - 160]
    lea     ARG2, [rbp - 192]
    call    sql_tok_next
    cmp     qword [rbp - 192 + TOK_TYPE], TOK_STAR
    jne     .bad_syntax

    ; Expect ')'
    lea     ARG1, [rbp - 160]
    lea     ARG2, [rbp - 192]
    call    sql_tok_next
    cmp     qword [rbp - 192 + TOK_TYPE], TOK_RPAREN
    jne     .bad_syntax

    ; Disallow comma after COUNT(*)
    lea     ARG1, [rbp - 160]
    lea     ARG2, [rbp - 192]
    call    sql_tok_peek
    cmp     qword [rbp - 192 + TOK_TYPE], TOK_COMMA
    je      .bad_syntax

    mov     r10, [rbp - 48]
    mov     qword [r10 + STMT_EXTRA1], PROJ_COUNT_STAR
    mov     qword [r10 + STMT_EXTRA2], 0
    jmp     .select_from

.proj_columns:
    ; Allocate projection array (up to 64 qualified-name descriptors).
    mov     ARG1, [rbp - 24]
    mov     ARG2, 64 * AST_NAME_SIZE
    call    sql_arena_alloc
    test    rax, rax
    jz      .oom
    mov     r10, [rbp - 48]
    mov     [r10 + STMT_EXTRA2], rax    ; projections array ptr
    xor     ecx, ecx                    ; proj_count = 0

.proj_loop:
    cmp     rcx, 64
    jae     .bad_proj_limit
    mov     [rbp - 56], rcx

    lea     ARG1, [rbp - 160]
    lea     ARG2, [rbp - 192]
    call    sql_tok_next
    cmp     qword [rbp - 192 + TOK_TYPE], TOK_IDENT
    jne     .bad_col_name

    mov     rax, [rbp - 192 + TOK_OFFSET]
    add     rax, [rbp - 8]
    mov     [rbp - 200], rax
    mov     rax, [rbp - 192 + TOK_LEN]
    mov     [rbp - 208], rax

    lea     ARG1, [rbp - 160]
    lea     ARG2, [rbp - 192]
    call    sql_tok_peek
    cmp     qword [rbp - 192 + TOK_TYPE], TOK_DOT
    jne     .proj_unqualified
    lea     ARG1, [rbp - 160]
    lea     ARG2, [rbp - 192]
    call    sql_tok_next                ; consume '.'
    lea     ARG1, [rbp - 160]
    lea     ARG2, [rbp - 192]
    call    sql_tok_next
    cmp     qword [rbp - 192 + TOK_TYPE], TOK_IDENT
    jne     .bad_col_name

    mov     rcx, [rbp - 56]
    mov     r10, [rbp - 48]
    mov     r11, [r10 + STMT_EXTRA2]
    imul    rcx, AST_NAME_SIZE
    add     rcx, r11

    mov     rax, [rbp - 192 + TOK_OFFSET]
    add     rax, [rbp - 8]
    mov     [rcx + AST_NAME_PTR], rax
    mov     rax, [rbp - 192 + TOK_LEN]
    mov     [rcx + AST_NAME_LEN], rax
    mov     rax, [rbp - 200]
    mov     [rcx + AST_NAME_QUAL_PTR], rax
    mov     rax, [rbp - 208]
    mov     [rcx + AST_NAME_QUAL_LEN], rax
    jmp     .proj_name_stored

.proj_unqualified:
    mov     rcx, [rbp - 56]
    mov     r10, [rbp - 48]
    mov     r11, [r10 + STMT_EXTRA2]
    imul    rcx, AST_NAME_SIZE
    add     rcx, r11
    mov     rax, [rbp - 200]
    mov     [rcx + AST_NAME_PTR], rax
    mov     rax, [rbp - 208]
    mov     [rcx + AST_NAME_LEN], rax
    mov     qword [rcx + AST_NAME_QUAL_PTR], 0
    mov     qword [rcx + AST_NAME_QUAL_LEN], 0

.proj_name_stored:

    mov     rcx, [rbp - 56]
    inc     rcx
    mov     [rbp - 56], rcx

    ; Check comma
    lea     ARG1, [rbp - 160]
    lea     ARG2, [rbp - 192]
    call    sql_tok_peek
    cmp     qword [rbp - 192 + TOK_TYPE], TOK_COMMA
    jne     .proj_done
    lea     ARG1, [rbp - 160]
    lea     ARG2, [rbp - 192]
    call    sql_tok_next                ; consume comma
    mov     rcx, [rbp - 56]
    jmp     .proj_loop

.proj_done:
    mov     r10, [rbp - 48]
    mov     rax, [rbp - 56]
    mov     [r10 + STMT_EXTRA1], rax

.select_from:
    ; Expect FROM
    lea     ARG1, [rbp - 160]
    lea     ARG2, [rbp - 192]
    call    sql_tok_next
    cmp     qword [rbp - 192 + TOK_TYPE], TOK_FROM
    jne     .bad_from

    ; Expect table name
    lea     ARG1, [rbp - 160]
    lea     ARG2, [rbp - 192]
    call    sql_tok_next
    cmp     qword [rbp - 192 + TOK_TYPE], TOK_IDENT
    jne     .bad_table_name

    mov     r10, [rbp - 48]
    mov     rax, [rbp - 192 + TOK_OFFSET]
    add     rax, [rbp - 8]
    mov     [r10 + STMT_NAME_PTR], rax
    mov     rax, [rbp - 192 + TOK_LEN]
    mov     [r10 + STMT_NAME_LEN], rax

    ; Optional table alias: FROM table AS alias, or FROM table alias.
    lea     ARG1, [rbp - 160]
    lea     ARG2, [rbp - 192]
    call    sql_tok_peek
    cmp     qword [rbp - 192 + TOK_TYPE], TOK_AS
    je      .select_alias_as
    cmp     qword [rbp - 192 + TOK_TYPE], TOK_IDENT
    je      .select_alias_bare
    jmp     .select_no_alias
.select_alias_as:
    lea     ARG1, [rbp - 160]
    lea     ARG2, [rbp - 192]
    call    sql_tok_next                ; consume AS
    lea     ARG1, [rbp - 160]
    lea     ARG2, [rbp - 192]
    call    sql_tok_next
    cmp     qword [rbp - 192 + TOK_TYPE], TOK_IDENT
    jne     .bad_table_name
    jmp     .select_alias_store
.select_alias_bare:
    lea     ARG1, [rbp - 160]
    lea     ARG2, [rbp - 192]
    call    sql_tok_next
.select_alias_store:
    mov     ARG1, [rbp - 24]
    mov     ARG2, AST_NAME_SIZE
    call    sql_arena_alloc
    test    rax, rax
    jz      .oom
    mov     rdx, [rbp - 192 + TOK_OFFSET]
    add     rdx, [rbp - 8]
    mov     [rax + AST_NAME_PTR], rdx
    mov     rdx, [rbp - 192 + TOK_LEN]
    mov     [rax + AST_NAME_LEN], rdx
    mov     r10, [rbp - 48]
    mov     [r10 + STMT_EXTRA4], rax
    jmp     .select_alias_done
.select_no_alias:
    mov     r10, [rbp - 48]
    mov     qword [r10 + STMT_EXTRA4], 0
.select_alias_done:

    ; Parse one relational JOIN descriptor. Execution is enabled separately
    ; after the two-table bound-plan ABI is available.
    lea     ARG1, [rbp - 160]
    lea     ARG2, [rbp - 192]
    call    sql_tok_peek
    cmp     qword [rbp - 192 + TOK_TYPE], TOK_JOIN
    je      .select_join_plain
    cmp     qword [rbp - 192 + TOK_TYPE], TOK_INNER
    je      .select_join_inner
    cmp     qword [rbp - 192 + TOK_TYPE], TOK_LEFT
    je      .select_join_left
    jmp     .select_after_join

.select_join_plain:
    mov     qword [rbp - 224], JOIN_INNER
    jmp     .select_join_consume_join
.select_join_inner:
    mov     qword [rbp - 224], JOIN_INNER
    lea     ARG1, [rbp - 160]
    lea     ARG2, [rbp - 192]
    call    sql_tok_next                ; consume INNER
    jmp     .select_join_expect_join
.select_join_left:
    mov     qword [rbp - 224], JOIN_LEFT
    lea     ARG1, [rbp - 160]
    lea     ARG2, [rbp - 192]
    call    sql_tok_next                ; consume LEFT
.select_join_expect_join:
    lea     ARG1, [rbp - 160]
    lea     ARG2, [rbp - 192]
    call    sql_tok_next
    cmp     qword [rbp - 192 + TOK_TYPE], TOK_JOIN
    jne     .bad_syntax
    jmp     .select_join_table
.select_join_consume_join:
    lea     ARG1, [rbp - 160]
    lea     ARG2, [rbp - 192]
    call    sql_tok_next                ; consume JOIN
.select_join_table:
    mov     ARG1, [rbp - 24]
    mov     ARG2, AST_JOIN_SIZE
    call    sql_arena_alloc
    test    rax, rax
    jz      .oom
    mov     [rbp - 216], rax
    mov     rdx, [rbp - 224]
    mov     [rax + JOIN_TYPE], rdx
    mov     qword [rax + JOIN_TABLE_ALIAS], 0
    mov     qword [rax + JOIN_ON_EXPR], 0
    mov     qword [rax + JOIN_NEXT], 0

    lea     ARG1, [rbp - 160]
    lea     ARG2, [rbp - 192]
    call    sql_tok_next
    cmp     qword [rbp - 192 + TOK_TYPE], TOK_IDENT
    jne     .bad_table_name
    mov     r10, [rbp - 216]
    mov     rax, [rbp - 192 + TOK_OFFSET]
    add     rax, [rbp - 8]
    mov     [r10 + JOIN_TABLE_NAME_PTR], rax
    mov     rax, [rbp - 192 + TOK_LEN]
    mov     [r10 + JOIN_TABLE_NAME_LEN], rax

    ; Optional right-table alias.
    lea     ARG1, [rbp - 160]
    lea     ARG2, [rbp - 192]
    call    sql_tok_peek
    cmp     qword [rbp - 192 + TOK_TYPE], TOK_AS
    je      .select_join_alias_as
    cmp     qword [rbp - 192 + TOK_TYPE], TOK_IDENT
    je      .select_join_alias_bare
    jmp     .select_join_on
.select_join_alias_as:
    lea     ARG1, [rbp - 160]
    lea     ARG2, [rbp - 192]
    call    sql_tok_next
    lea     ARG1, [rbp - 160]
    lea     ARG2, [rbp - 192]
    call    sql_tok_next
    cmp     qword [rbp - 192 + TOK_TYPE], TOK_IDENT
    jne     .bad_table_name
    jmp     .select_join_alias_store
.select_join_alias_bare:
    lea     ARG1, [rbp - 160]
    lea     ARG2, [rbp - 192]
    call    sql_tok_next
.select_join_alias_store:
    mov     ARG1, [rbp - 24]
    mov     ARG2, AST_NAME_SIZE
    call    sql_arena_alloc
    test    rax, rax
    jz      .oom
    mov     rdx, [rbp - 192 + TOK_OFFSET]
    add     rdx, [rbp - 8]
    mov     [rax + AST_NAME_PTR], rdx
    mov     rdx, [rbp - 192 + TOK_LEN]
    mov     [rax + AST_NAME_LEN], rdx
    mov     r10, [rbp - 216]
    mov     [r10 + JOIN_TABLE_ALIAS], rax
.select_join_on:
    lea     ARG1, [rbp - 160]
    lea     ARG2, [rbp - 192]
    call    sql_tok_next
    cmp     qword [rbp - 192 + TOK_TYPE], TOK_ON
    jne     .bad_syntax
    lea     ARG1, [rbp - 160]
    mov     ARG2, [rbp - 8]
    mov     ARG3, [rbp - 24]
    mov     ARG4, [rbp - 40]
    mov     rax, 1
    PASS_ARG5 rax
    call    parse_expr_prec
    test    rax, rax
    jz      .fail
    mov     r10, [rbp - 216]
    mov     [r10 + JOIN_ON_EXPR], rax
    mov     r11, [rbp - 48]
    mov     [r11 + SELECT_JOIN_HEAD], r10
    mov     qword [r11 + SELECT_JOIN_COUNT], 1

.select_after_join:

    ; Check optional WHERE
    lea     ARG1, [rbp - 160]
    lea     ARG2, [rbp - 192]
    call    sql_tok_peek
    cmp     qword [rbp - 192 + TOK_TYPE], TOK_WHERE
    jne     .no_where

    ; Consume WHERE
    lea     ARG1, [rbp - 160]
    lea     ARG2, [rbp - 192]
    call    sql_tok_next

    ; Parse WHERE expression
    lea     ARG1, [rbp - 160]
    mov     ARG2, [rbp - 8]
    mov     ARG3, [rbp - 24]
    mov     ARG4, [rbp - 40]
    mov     rax, 1
    PASS_ARG5 rax                       ; min_prec = 1
    call    parse_expr_prec
    test    rax, rax
    jz      .fail
    mov     r10, [rbp - 48]
    mov     [r10 + STMT_EXTRA3], rax    ; where_expr
    jmp     .select_tail

.no_where:
    mov     r10, [rbp - 48]
    mov     qword [r10 + STMT_EXTRA3], 0

.select_tail:
    ; Optional ORDER BY [qualifier.]column [ASC|DESC].
    lea     ARG1, [rbp - 160]
    lea     ARG2, [rbp - 192]
    call    sql_tok_peek
    cmp     qword [rbp - 192 + TOK_TYPE], TOK_ORDER
    jne     .select_limit_tail
    lea     ARG1, [rbp - 160]
    lea     ARG2, [rbp - 192]
    call    sql_tok_next                ; consume ORDER
    lea     ARG1, [rbp - 160]
    lea     ARG2, [rbp - 192]
    call    sql_tok_next
    cmp     qword [rbp - 192 + TOK_TYPE], TOK_BY
    jne     .bad_syntax
    lea     ARG1, [rbp - 160]
    lea     ARG2, [rbp - 192]
    call    sql_tok_next
    cmp     qword [rbp - 192 + TOK_TYPE], TOK_IDENT
    jne     .bad_col_name
    mov     rax, [rbp - 192 + TOK_OFFSET]
    add     rax, [rbp - 8]
    mov     [rbp - 200], rax
    mov     rax, [rbp - 192 + TOK_LEN]
    mov     [rbp - 208], rax
    mov     ARG1, [rbp - 24]
    mov     ARG2, AST_NAME_SIZE
    call    sql_arena_alloc
    test    rax, rax
    jz      .oom
    mov     [rbp - 216], rax
    mov     rdx, [rbp - 200]
    mov     [rax + AST_NAME_PTR], rdx
    mov     rdx, [rbp - 208]
    mov     [rax + AST_NAME_LEN], rdx
    mov     qword [rax + AST_NAME_QUAL_PTR], 0
    mov     qword [rax + AST_NAME_QUAL_LEN], 0
    lea     ARG1, [rbp - 160]
    lea     ARG2, [rbp - 192]
    call    sql_tok_peek
    cmp     qword [rbp - 192 + TOK_TYPE], TOK_DOT
    jne     .order_name_ready
    lea     ARG1, [rbp - 160]
    lea     ARG2, [rbp - 192]
    call    sql_tok_next
    lea     ARG1, [rbp - 160]
    lea     ARG2, [rbp - 192]
    call    sql_tok_next
    cmp     qword [rbp - 192 + TOK_TYPE], TOK_IDENT
    jne     .bad_col_name
    mov     r10, [rbp - 216]
    mov     rdx, [r10 + AST_NAME_PTR]
    mov     [r10 + AST_NAME_QUAL_PTR], rdx
    mov     rdx, [r10 + AST_NAME_LEN]
    mov     [r10 + AST_NAME_QUAL_LEN], rdx
    mov     rdx, [rbp - 192 + TOK_OFFSET]
    add     rdx, [rbp - 8]
    mov     [r10 + AST_NAME_PTR], rdx
    mov     rdx, [rbp - 192 + TOK_LEN]
    mov     [r10 + AST_NAME_LEN], rdx
.order_name_ready:
    mov     r10, [rbp - 48]
    mov     rax, [rbp - 216]
    mov     [r10 + SELECT_ORDER_NAME], rax
    lea     ARG1, [rbp - 160]
    lea     ARG2, [rbp - 192]
    call    sql_tok_peek
    cmp     qword [rbp - 192 + TOK_TYPE], TOK_ASC
    je      .order_consume_direction
    cmp     qword [rbp - 192 + TOK_TYPE], TOK_DESC
    jne     .select_limit_tail
    mov     r10, [rbp - 48]
    mov     qword [r10 + SELECT_ORDER_DESC], 1
.order_consume_direction:
    lea     ARG1, [rbp - 160]
    lea     ARG2, [rbp - 192]
    call    sql_tok_next

.select_limit_tail:
    ; Optional LIMIT n [OFFSET n]. Both values are non-negative INT64 literals.
    lea     ARG1, [rbp - 160]
    lea     ARG2, [rbp - 192]
    call    sql_tok_peek
    cmp     qword [rbp - 192 + TOK_TYPE], TOK_LIMIT
    jne     .check_eof
    lea     ARG1, [rbp - 160]
    lea     ARG2, [rbp - 192]
    call    sql_tok_next                ; consume LIMIT
    lea     ARG1, [rbp - 160]
    lea     ARG2, [rbp - 192]
    call    sql_tok_next
    cmp     qword [rbp - 192 + TOK_TYPE], TOK_INT_LIT
    jne     .bad_syntax
    lea     ARG1, [rbp - 192]
    mov     ARG2, [rbp - 8]
    lea     ARG3, [rbp - 232]
    lea     ARG4, [rbp - 240]
    xor     eax, eax
    PASS_ARG5 rax
    call    parse_number
    cmp     eax, 1
    jne     .bad_syntax
    mov     r10, [rbp - 48]
    mov     rax, [rbp - 232]
    mov     [r10 + SELECT_LIMIT_VALUE], rax

    lea     ARG1, [rbp - 160]
    lea     ARG2, [rbp - 192]
    call    sql_tok_peek
    cmp     qword [rbp - 192 + TOK_TYPE], TOK_OFFSET_KW
    jne     .check_eof
    lea     ARG1, [rbp - 160]
    lea     ARG2, [rbp - 192]
    call    sql_tok_next                ; consume OFFSET
    lea     ARG1, [rbp - 160]
    lea     ARG2, [rbp - 192]
    call    sql_tok_next
    cmp     qword [rbp - 192 + TOK_TYPE], TOK_INT_LIT
    jne     .bad_syntax
    lea     ARG1, [rbp - 192]
    mov     ARG2, [rbp - 8]
    lea     ARG3, [rbp - 232]
    lea     ARG4, [rbp - 240]
    xor     eax, eax
    PASS_ARG5 rax
    call    parse_number
    cmp     eax, 1
    jne     .bad_syntax
    mov     r10, [rbp - 48]
    mov     rax, [rbp - 232]
    mov     [r10 + SELECT_OFFSET_VALUE], rax

.check_eof:
    ; Optional semicolon
    lea     ARG1, [rbp - 160]
    lea     ARG2, [rbp - 192]
    call    sql_tok_peek
    cmp     qword [rbp - 192 + TOK_TYPE], TOK_SEMICOLON
    jne     .require_eof
    lea     ARG1, [rbp - 160]
    lea     ARG2, [rbp - 192]
    call    sql_tok_next

.require_eof:
    lea     ARG1, [rbp - 160]
    lea     ARG2, [rbp - 192]
    call    sql_tok_next
    cmp     qword [rbp - 192 + TOK_TYPE], TOK_EOF
    jne     .bad_trailing

    xor     eax, eax
    FRAME_END
    ret

; --- Error Handlers ----------------------------------------------------------
.bad_syntax:
    mov     ARG1, [rbp - 40]
    mov     ARG2, SQL_ERR_SYNTAX
    lea     ARG3, [rbp - 192]
    lea     ARG4, [err_syntax_msg]
    call    set_error
    mov     eax, SQL_ERR_SYNTAX
    FRAME_END
    ret

.bad_table_name:
    mov     ARG1, [rbp - 40]
    mov     ARG2, SQL_ERR_SYNTAX
    lea     ARG3, [rbp - 192]
    lea     ARG4, [err_expected_table]
    call    set_error
    mov     eax, SQL_ERR_SYNTAX
    FRAME_END
    ret

.bad_col_name:
    mov     ARG1, [rbp - 40]
    mov     ARG2, SQL_ERR_SYNTAX
    lea     ARG3, [rbp - 192]
    lea     ARG4, [err_expected_col]
    call    set_error
    mov     eax, SQL_ERR_SYNTAX
    FRAME_END
    ret

.bad_type:
    mov     ARG1, [rbp - 40]
    mov     ARG2, SQL_ERR_SYNTAX
    lea     ARG3, [rbp - 192]
    lea     ARG4, [err_expected_type]
    call    set_error
    mov     eax, SQL_ERR_SYNTAX
    FRAME_END
    ret

.bad_lparen:
    mov     ARG1, [rbp - 40]
    mov     ARG2, SQL_ERR_SYNTAX
    lea     ARG3, [rbp - 192]
    lea     ARG4, [err_expected_lparen]
    call    set_error
    mov     eax, SQL_ERR_SYNTAX
    FRAME_END
    ret

.bad_rparen:
    mov     ARG1, [rbp - 40]
    mov     ARG2, SQL_ERR_SYNTAX
    lea     ARG3, [rbp - 192]
    lea     ARG4, [err_expected_rparen]
    call    set_error
    mov     eax, SQL_ERR_SYNTAX
    FRAME_END
    ret

.bad_comma:
    mov     ARG1, [rbp - 40]
    mov     ARG2, SQL_ERR_SYNTAX
    lea     ARG3, [rbp - 192]
    lea     ARG4, [err_expected_comma]
    call    set_error
    mov     eax, SQL_ERR_SYNTAX
    FRAME_END
    ret

.bad_values:
    mov     ARG1, [rbp - 40]
    mov     ARG2, SQL_ERR_SYNTAX
    lea     ARG3, [rbp - 192]
    lea     ARG4, [err_expected_values]
    call    set_error
    mov     eax, SQL_ERR_SYNTAX
    FRAME_END
    ret

.bad_from:
    mov     ARG1, [rbp - 40]
    mov     ARG2, SQL_ERR_SYNTAX
    lea     ARG3, [rbp - 192]
    lea     ARG4, [err_expected_from]
    call    set_error
    mov     eax, SQL_ERR_SYNTAX
    FRAME_END
    ret

.bad_trailing:
    mov     ARG1, [rbp - 40]
    mov     ARG2, SQL_ERR_SYNTAX
    lea     ARG3, [rbp - 192]
    lea     ARG4, [err_unexp_token]
    call    set_error
    mov     eax, SQL_ERR_SYNTAX
    FRAME_END
    ret

.bad_col_limit:
    mov     ARG1, [rbp - 40]
    mov     ARG2, SQL_ERR_SYNTAX
    lea     ARG3, [rbp - 192]
    lea     ARG4, [err_col_limit]
    call    set_error
    mov     eax, SQL_ERR_SYNTAX
    FRAME_END
    ret

.bad_row_limit:
    mov     ARG1, [rbp - 40]
    mov     ARG2, SQL_ERR_SYNTAX
    lea     ARG3, [rbp - 192]
    lea     ARG4, [err_row_limit]
    call    set_error
    mov     eax, SQL_ERR_SYNTAX
    FRAME_END
    ret

.bad_proj_limit:
    mov     ARG1, [rbp - 40]
    mov     ARG2, SQL_ERR_SYNTAX
    lea     ARG3, [rbp - 192]
    lea     ARG4, [err_proj_limit]
    call    set_error
    mov     eax, SQL_ERR_SYNTAX
    FRAME_END
    ret

.oom:
    mov     ARG1, [rbp - 40]
    mov     ARG2, SQL_ERR_NO_STORAGE
    lea     ARG3, [rbp - 192]
    lea     ARG4, [err_oom]
    call    set_error
    mov     eax, SQL_ERR_NO_STORAGE
    FRAME_END
    ret

.fail:
    mov     eax, SQL_ERR_SYNTAX
    FRAME_END
    ret
