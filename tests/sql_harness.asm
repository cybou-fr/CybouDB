; SQL API contract driver. Emits SQL_ERROR, first literal bits, required mask.
; Usage: sql_harness <database> <sql> [mode: 0 normal, 1 invalid plan, 2 OOM, 3 missing table, 4 NULL error]
%include "sql.inc"
BITS 64
default rel
extern os_argv, os_str_to_u64, os_write, os_arg_to_utf8
extern db_open, db_close, db_pax_scan_open, db_pax_scan_batch
extern sql_arena_init, sql_parse, sql_bind, sql_execute, sql_execute_batch
extern sql_zone_force_off, sql_zone_trace, sql_zone_leaf_total, sql_kernel_force_scalar
global cyboudb_main
section .bss
align 8
ctx: resb CybouDB_DB_SIZE
arena: resb SQL_ARENA_SIZE
memory: resb 1048576
error: resb SQL_ERROR_SIZE
stmt: resq 1
plan: resq 1
path: resq 1
source: resb 65536
mode: resq 1
literal_bits: resq 1
required_mask: resq 1
leaf_capacity: resq 1
scan_mask: resq 1
cursor: resb CybouDB_SCAN_SIZE
view: resb CybouDB_BATCH_VIEW_SIZE
scan_previous: resq 1
sink_stats:
sink_calls: resq 1
sink_rows: resq 1
sink_hash: resq 1
sink_nulls: resq 1
sink_arena_bytes: resq 1
sink_failure: resq 1
sink_arena_start: resq 1
sink_view: resq 1
sink_projection: resq 1
sink_pending: resq 1
sink_row: resq 1
sink_column: resq 1
sink_context: resq 1
mxcsr_before: resd 1
mxcsr_after: resd 1
zone_literal_bits: resq 1
section .text
cyboudb_main:
    FRAME_BEGIN 16, 2
    mov     ARG1, 1
    call    os_argv
    mov     [path], rax
    mov     ARG1, 2
    call    os_argv
    mov     ARG1, rax
    lea     ARG2, [source]
    mov     ARG3, 65536
    call    os_arg_to_utf8
    mov     ARG1, 3
    call    os_argv
    test    rax, rax
    jz      .init
    mov     ARG1, rax
    lea     ARG2, [mode]
    call    os_str_to_u64
.init:
    cmp     qword [mode], 34
    je      .force_scalar
    cmp     qword [mode], 35
    jne     .arena_init
.force_scalar:
    mov     dword [sql_kernel_force_scalar], 1
.arena_init:
    lea     ARG1, [arena]
    lea     ARG2, [memory]
    mov     ARG3, 1048576
    call    sql_arena_init
    ; Deliberately stale error: successful stages must clear the record.
    mov     qword [error + SQL_ERR_CODE], 99
    mov     qword [error + SQL_ERR_DOMAIN], 99
    mov     byte [error + SQL_ERR_MSG], 'x'
    ; Nondefault rounding, FTZ and DAZ must not affect literal conversion.
    mov     dword [mxcsr_before], 0xffc0
    ldmxcsr [mxcsr_before]
    lea     r10, [source]
    xor     eax, eax
.length:
    cmp     byte [r10 + rax], 0
    je      .parse
    inc     rax
    jmp     .length
.parse:
    mov     ARG1, r10
    mov     ARG2, rax
    lea     ARG3, [arena]
    lea     ARG4, [stmt]
    lea     rax, [error]
    PASS_ARG5 rax
    call    sql_parse
    stmxcsr [mxcsr_after]
    mov     edx, [mxcsr_before]
    cmp     edx, [mxcsr_after]
    jne     .bad_mxcsr
    test    eax, eax
    jnz     .output
    ; For INSERT fixtures, expose the first literal's raw value, before bind.
    mov     r10, [stmt]
    cmp     qword [r10 + AST_STMT_TYPE], STMT_INSERT
    jne     .open
    mov     r10, [r10 + AST_STMT_PAYLOAD]
    mov     r10, [r10 + STMT_EXTRA4]
    mov     r10, [r10]                  ; first row
    mov     r10, [r10]                  ; first expression
    mov     rax, [r10 + EXPR_LIT_VAL]
    mov     [literal_bits], rax
.open:
    mov     ARG1, [path]
    lea     ARG2, [ctx]
    xor     ARG3, ARG3
    xor     ARG4, ARG4
    call    db_open
    test    eax, eax
    jnz     .bad_setup
    lea     ARG1, [ctx]
    mov     ARG2, [stmt]
    lea     ARG3, [arena]
    lea     ARG4, [plan]
    lea     rax, [error]
    PASS_ARG5 rax
    call    sql_bind
    test    eax, eax
    jnz     .close
    mov     r10, [plan]
    mov     rax, [r10 + PLAN_REQUIRED_COLS]
    mov     [required_mask], rax
    ; Rows per leaf, so a test can predict where batches break without
    ; repeating the engine's layout arithmetic. A leaf is not a whole number
    ; of 64-row groups any more, so "every 64 rows" is no longer the answer.
    ; Failures are ignored: several modes deliberately have no scannable table.
    cmp     qword [r10 + PLAN_TYPE], STMT_SELECT
    jne     .capacity_done
    lea     ARG1, [ctx]
    mov     ARG2, [r10 + PLAN_TABLE_ID]
    lea     ARG3, [cursor]
    call    db_pax_scan_open
    test    eax, eax
    jnz     .capacity_done
    mov     rax, [cursor + SCAN_CAPACITY]
    mov     [leaf_capacity], rax
.capacity_done:
    cmp     qword [mode], 32
    jae     .zone_delivery
    cmp     qword [mode], 19
    jae     near .fast_path_test
    cmp     qword [mode], 8
    jae     near .delivery
    cmp     qword [mode], 5
    jae     near .batch_test
    cmp     qword [mode], 1
    jne     short .check_oom
    mov     r10, [plan]
    mov     qword [r10 + PLAN_TYPE], 999
.check_oom:
    cmp     qword [mode], 2
    jne     short .check_bad_table
    mov     qword [arena + ARENA_CAP], 0
.check_bad_table:
    cmp     qword [mode], 3
    jne     .prepare_execute
    mov     r10, [plan]
    mov     qword [r10 + PLAN_TABLE_ID], 999
    mov     qword [r10 + PLAN_SCHEMA_PAGE], 0
    jmp     .prepare_execute

.fast_path_test:
    cmp     qword [mode], 19
    jne     .fast_mode20
    mov     r10, [plan]
    mov     qword [r10 + PLAN_TABLE_ID], 999
    jmp     .prepare_execute
.fast_mode20:
    cmp     qword [mode], 20
    jne     .fast_mode21
    mov     r10, [plan]
    mov     qword [r10 + PLAN_GENERATION], -1
    jmp     .prepare_execute
.fast_mode21:
    cmp     qword [mode], 21
    jne     .fast_mode22
    mov     qword [ctx + DB_DIRTY_HI], 1
    jmp     .prepare_execute
.fast_mode22:
    mov     r10, [plan]
    mov     qword [r10 + PLAN_CTX], 0

.prepare_execute:
    mov     qword [error + SQL_ERR_CODE], 99
    mov     qword [error + SQL_ERR_DOMAIN], 99
    mov     byte [error + SQL_ERR_MSG], 'x'
    lea     ARG1, [ctx]
    mov     ARG2, [plan]
    lea     ARG3, [arena]
    lea     ARG4, [discard_row]
    xor     eax, eax
    PASS_ARG5 rax
    lea     rax, [error]
    cmp     qword [mode], 4
    jne     .with_error
    xor     eax, eax
.with_error:
    PASS_ARG6 rax
    call    sql_execute
    cmp     qword [mode], 4
    je      .close
    cmp     rax, [error + SQL_ERR_CODE]
    jne     .bad_setup
.close:
    lea     ARG1, [ctx]
    call    db_close
.output:
    lea     ARG1, [error]
    mov     ARG2, SQL_ERROR_SIZE
    call    os_write
    lea     ARG1, [literal_bits]
    mov     ARG2, 24                    ; literal_bits + required_mask + capacity
    call    os_write
    cmp     qword [mode], 32
    jae     .zone_output
    cmp     qword [mode], 8
    jb      .output_done
    cmp     qword [mode], 19
    jae     .output_done
    lea     ARG1, [sink_stats]
    mov     ARG2, 48
    call    os_write
    jmp     .output_done
.zone_output:
    lea     ARG1, [sink_stats]
    mov     ARG2, 48
    call    os_write
    lea     ARG1, [sql_zone_leaf_total]
    mov     ARG2, 48                    ; total/none/all/unknown/batches/column mask
    call    os_write
.output_done:
    xor     eax, eax
    FRAME_END
    ret

; Zone parity modes: 32 on/auto, 33 off/auto, 34 on/scalar, 35 off/scalar,
; 36 stale generation, 37 invalid cached schema, 38 on/unmasked, 39 off/unmasked.
; Optional arg4 overrides a single comparison's bound literal with raw bits.
.zone_delivery:
    cmp     qword [mode], 39
    ja      .bad_setup
    mov     dword [sql_zone_trace], 1
    mov     rax, [mode]
    cmp     rax, 33
    je      .zone_off
    cmp     rax, 35
    je      .zone_off
    cmp     rax, 39
    jne     .zone_snapshot
.zone_off:
    mov     dword [sql_zone_force_off], 1
.zone_snapshot:
    cmp     qword [mode], 36
    jne     .zone_schema
    mov     r10, [plan]
    mov     qword [r10 + PLAN_GENERATION], -1
.zone_schema:
    cmp     qword [mode], 37
    jne     .zone_literal
    mov     r10, [plan]
    mov     qword [r10 + PLAN_CTX], 0
    mov     qword [r10 + PLAN_SCHEMA_PAGE], -1
.zone_literal:
    mov     ARG1, 4
    call    os_argv
    test    rax, rax
    jz      .zone_mxcsr
    mov     ARG1, rax
    lea     ARG2, [zone_literal_bits]
    call    os_str_to_u64
    test    eax, eax
    jz      .bad_setup
    mov     r10, [plan]
    mov     r10, [r10 + PLAN_DATA4]
    test    r10, r10
    jz      .bad_setup
    cmp     qword [r10 + BEXPR_KIND], BEXPR_COMPARE_COL_LIT
    jne     .bad_setup
    mov     rax, [zone_literal_bits]
    mov     [r10 + BEXPR_LIT_VAL], rax
.zone_mxcsr:
    mov     dword [mxcsr_before], 0xffc0
    cmp     qword [mode], 38
    jb      .zone_environment
    mov     dword [mxcsr_before], 0x8040 ; DAZ/FTZ, all exceptions unmasked
.zone_environment:
    ldmxcsr [mxcsr_before]
    jmp     .delivery
; Delivery modes: 8 batch, 9 batch stop, 10 row, 11 row stop,
; 12 missing batch sink, 13 missing row sink, 14 minimal batch arena,
; 15 undersized batch arena, 16 minimal row arena, 17 batch sink error,
; 18 row sink error.
.delivery:
    mov     rax, [arena + ARENA_USED]
    mov     [sink_arena_start], rax
    cmp     qword [mode], 14
    jb      .delivery_args
    cmp     qword [mode], 16            ; only 14-16 narrow the arena
    ja      .delivery_args
    add     rax, CybouDB_BATCH_VIEW_SIZE
    cmp     qword [mode], 15
    jne     .delivery_cap
    dec     rax
.delivery_cap:
    mov     [arena + ARENA_CAP], rax
.delivery_args:
    lea     ARG1, [ctx]
    mov     ARG2, [plan]
    lea     ARG3, [arena]
    lea     ARG4, [test_batch_sink]
    cmp     qword [mode], 10
    je      .delivery_row
    cmp     qword [mode], 11
    je      .delivery_row
    cmp     qword [mode], 13
    je      .delivery_row
    cmp     qword [mode], 18
    je      .delivery_row
    cmp     qword [mode], 16
    jne     .delivery_sink
.delivery_row:
    lea     ARG4, [test_row_sink]
.delivery_sink:
    cmp     qword [mode], 12
    je      .delivery_missing
    cmp     qword [mode], 13
    jne     .delivery_context
.delivery_missing:
    xor     ARG4, ARG4
.delivery_context:
    lea     rax, [sink_context]
    PASS_ARG5 rax
    lea     rax, [error]
    PASS_ARG6 rax
    cmp     qword [mode], 10
    je      .call_row
    cmp     qword [mode], 11
    je      .call_row
    cmp     qword [mode], 13
    je      .call_row
    cmp     qword [mode], 16
    je      .call_row
    cmp     qword [mode], 18
    je      .call_row
    call    sql_execute_batch
    jmp     .delivery_done
.call_row:
    call    sql_execute
.delivery_done:
    cmp     qword [mode], 32
    jb      .delivery_status
    stmxcsr [mxcsr_after]
    mov     edx, [mxcsr_before]
    cmp     edx, [mxcsr_after]
    jne     .bad_mxcsr
.delivery_status:
    cmp     rax, [error + SQL_ERR_CODE]
    jne     .bad_setup
    mov     rax, [arena + ARENA_USED]
    sub     rax, [sink_arena_start]
    mov     [sink_arena_bytes], rax
    jmp     .close

; Modes 5/6/7 directly verify sparse views, zero masks and invalid masks.
.batch_test:
    mov     rax, [required_mask]
    mov     [scan_mask], rax
    cmp     qword [mode], 6
    jne     .batch_invalid_mask
    mov     qword [scan_mask], 0
.batch_invalid_mask:
    cmp     qword [mode], 7
    jne     .batch_open
    mov     rax, 0x8000000000000000
    mov     [scan_mask], rax
.batch_open:
    lea     ARG1, [ctx]
    mov     r10, [plan]
    mov     ARG2, [r10 + PLAN_TABLE_ID]
    lea     ARG3, [cursor]
    call    db_pax_scan_open
    test    eax, eax
    jnz     .bad_setup
.batch_loop:
    mov     rax, [cursor + SCAN_NEXT]
    mov     [scan_previous], rax
    ; Poison every slot each call. Only requested slots may be overwritten.
    lea     r10, [view]
    mov     ecx, CybouDB_BATCH_VIEW_SIZE / 8
    mov     rax, 0xa5a5a5a5a5a5a5a5
.batch_poison:
    mov     [r10], rax
    add     r10, 8
    dec     ecx
    jnz     .batch_poison
    lea     ARG1, [cursor]
    lea     ARG2, [view]
    mov     ARG3, [scan_mask]
    call    db_pax_scan_batch
    cmp     qword [mode], 7
    je      .batch_expect_invalid
    test    eax, eax
    jnz     .bad_setup
    cmp     rdx, [view + BATCH_VIEW_ROWS]
    jne     .bad_setup
    cmp     rdx, 64
    ja      .bad_setup
    mov     rax, [scan_previous]
    add     rax, rdx
    cmp     rax, [cursor + SCAN_NEXT]
    jne     .bad_setup
    test    rdx, rdx
    jz      .batch_end
    xor     ecx, ecx
    lea     r10, [view + BATCH_VIEW_COLUMNS]
.batch_slot:
    bt      [scan_mask], rcx
    jc      .batch_requested
    mov     rax, 0xa5a5a5a5a5a5a5a5
    cmp     [r10], rax
    jne     .bad_setup
    cmp     [r10 + 8], rax
    jne     .bad_setup
    cmp     [r10 + 16], rax
    jne     .bad_setup
    jmp     .batch_slot_next
.batch_requested:
    ; Values must reference the current mapped leaf, not a copied row buffer.
    ; A leaf is a run of pages, so the bound is the whole run.
    mov     rax, [r10 + COLVIEW_VALUES_PTR]
    sub     rax, [cursor + SCAN_LEAF]
    mov     r11, [cursor + SCAN_RUN_PAGES]
    shl     r11, CybouDB_PAGE_SHIFT
    cmp     rax, r11
    jae     .bad_setup
    mov     rax, [plan]
    mov     rax, [rax + PLAN_SCHEMA_PAGE]
    mov     r11, rcx
    shl     r11, 5
    mov     eax, [rax + CAT_COLUMNS + r11]
    cmp     eax, [r10 + COLVIEW_TYPE]
    jne     .bad_setup
    cmp     eax, CAT_BOOL
    je      .batch_width1
    cmp     eax, CAT_INT64
    je      .batch_width8
    mov     eax, 4
    jmp     .batch_width
.batch_width1:
    mov     eax, 1
    jmp     .batch_width
.batch_width8:
    mov     eax, 8
.batch_width:
    cmp     eax, [r10 + COLVIEW_WIDTH]
    jne     .bad_setup
.batch_slot_next:
    inc     ecx
    add     r10, CybouDB_COLVIEW_SIZE
    cmp     ecx, 64
    jb      .batch_slot
    jmp     .batch_loop
.batch_end:
    mov     rax, [cursor + SCAN_NEXT]
    cmp     rax, [cursor + SCAN_ROWS]
    jne     .bad_setup
    jmp     .close
.batch_expect_invalid:
    cmp     eax, CybouDB_E_STATE
    jne     .bad_setup
    test    rdx, rdx
    jnz     .bad_setup
    cmp     qword [view + BATCH_VIEW_ROWS], 0
    jne     .bad_setup
    mov     rax, [scan_previous]
    cmp     rax, [cursor + SCAN_NEXT]
    jne     .bad_setup
    mov     qword [error + SQL_ERR_DOMAIN], SQL_DOMAIN_STORAGE
    mov     qword [error + SQL_ERR_CODE], CybouDB_E_STATE
    jmp     .close
.bad_mxcsr:
    mov     eax, 98
    FRAME_END
    ret
.bad_setup:
    mov     eax, 99
    FRAME_END
    ret
discard_row:
    xor     eax, eax
    ret

; Test consumers independently hash selected projected cells in row order.
test_row_sink:
    FRAME_BEGIN 0, 0
    lea     rax, [sink_context]
    cmp     ARG1, rax
    jne     sink_failed
    mov     r10, ARG3
    mov     r11, ARG4
    mov     r8, ARG2
    inc     qword [sink_calls]
    inc     qword [sink_rows]
    xor     ecx, ecx
.cell:
    mov     rax, [r10 + rcx * 8]
    movzx   edx, byte [r11 + rcx]
    call    hash_cell
    inc     rcx
    cmp     rcx, r8
    jb      .cell
    cmp     qword [mode], 18
    je      .row_sink_error
    xor     eax, eax
    cmp     qword [mode], 11
    sete    al
    FRAME_END
    ret
.row_sink_error:
    mov     eax, CybouDB_SINK_ERROR
    FRAME_END
    ret

test_batch_sink:
    FRAME_BEGIN 0, 0
    lea     rax, [sink_context]
    cmp     ARG1, rax
    jne     sink_failed
    mov     [sink_view], ARG2
    mov     [sink_projection], ARG3
    mov     [sink_pending], ARG4
    test    ARG4, ARG4
    jz      sink_failed                 ; executor must suppress empty selections
    inc     qword [sink_calls]
.row:
    bsf     rcx, [sink_pending]
    btr     qword [sink_pending], rcx
    mov     [sink_row], rcx
    mov     r10, [sink_view]
    cmp     rcx, [r10 + BATCH_VIEW_ROWS]
    jae     sink_failed
    inc     qword [sink_rows]
    mov     qword [sink_column], 0
.cell:
    mov     r10, [sink_projection]
    mov     r11, [r10 + RESULT_PROJ_INDICES]
    mov     rcx, [sink_column]
    mov     eax, [r11 + rcx * 4]
    imul    rax, CybouDB_COLVIEW_SIZE
    mov     r10, [sink_view]
    lea     r10, [r10 + BATCH_VIEW_COLUMNS + rax]
    ; Types are parallel to indices and preserve duplicate projection order.
    mov     r11, [sink_projection]
    mov     r11, [r11 + RESULT_PROJ_TYPES]
    mov     eax, [r11 + rcx * 4]
    cmp     eax, [r10 + COLVIEW_TYPE]
    jne     sink_failed
    mov     rcx, [sink_row]
    bt      [r10 + COLVIEW_NULL_MASK], rcx
    setc    dl
    movzx   edx, dl
    xor     eax, eax
    test    edx, edx
    jnz     .hash
    mov     r11, [r10 + COLVIEW_VALUES_PTR]
    cmp     dword [r10 + COLVIEW_WIDTH], 8
    je      .value8
    cmp     dword [r10 + COLVIEW_WIDTH], 4
    je      .value4
    movzx   eax, byte [r11 + rcx]
    jmp     .hash
.value8:
    mov     rax, [r11 + rcx * 8]
    jmp     .hash
.value4:
    mov     eax, [r11 + rcx * 4]
    cmp     dword [r10 + COLVIEW_TYPE], CAT_INT32
    jne     .hash
    movsxd  rax, eax
.hash:
    call    hash_cell
    inc     qword [sink_column]
    mov     r10, [sink_projection]
    mov     rax, [sink_column]
    cmp     rax, [r10 + RESULT_PROJ_COUNT]
    jb      .cell
    cmp     qword [sink_pending], 0
    jne     .row
    cmp     qword [mode], 17
    je      .batch_sink_error
    xor     eax, eax
    cmp     qword [mode], 9
    sete    al
    FRAME_END
    ret
.batch_sink_error:
    mov     eax, CybouDB_SINK_ERROR
    FRAME_END
    ret
sink_failed:
    mov     qword [sink_failure], 1
    mov     eax, 1
    FRAME_END
    ret
; Private leaf helper: (rax=value, rdx=null) clobbers only rax.
hash_cell:
    add     [sink_nulls], rdx
    xor     rax, [sink_hash]
    imul    rax, [hash_multiplier]
    xor     rax, rdx
    imul    rax, [hash_multiplier]
    mov     [sink_hash], rax
    ret
section .rodata
hash_multiplier: dq 1099511628211
