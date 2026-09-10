; =============================================================================
;  benchmarks/bench_harness.asm - in-process measurement of the batch executor
; =============================================================================
;  Usage: bench_harness <database> <sql> <iterations> [warmup]
;
;  Everything that is not the engine is kept outside the measured region. The
;  database is opened once, the statement is parsed and bound once, and the
;  result sink does O(1) work per batch - a popcount and a hash of the
;  selection mask, no per-row projection and no output. What remains between
;  the two clock reads is the scan, the predicate kernels and the batch
;  delivery.
;
;  This is why the harness exists at all rather than timing `cyboudb query`:
;  wrapping the CLI would measure process creation, mmap setup, decimal
;  formatting and a write to a pipe, which together dwarf the work being
;  studied.
;
;  Output is one binary record of ten u64 fields, described by BENCH_* below.
;  Formatting and the derived rates are left to benchmarks/run_benchmarks.py:
;  turning cycles into a table is not something to write in assembly.
; =============================================================================

%include "sql.inc"

BITS 64
default rel

extern os_argv, os_str_to_u64, os_write, os_arg_to_utf8, os_monotonic_ns
extern db_open, db_close, db_pax_insert, db_commit
extern catalog_find_table
extern sql_arena_init, sql_parse, sql_bind, sql_execute_batch
extern sql_kernel_force_scalar
extern sql_zone_force_off, sql_zone_trace
extern sql_zone_leaf_total, sql_zone_leaf_none, sql_zone_leaf_all, sql_zone_leaf_unknown
extern sql_zone_batch_total, sql_zone_column_mask

global cyboudb_main

; --- Output record -----------------------------------------------------------
%define BENCH_STATUS        0           ; SQL error code, 0 on success
%define BENCH_DOMAIN        8           ; SQL_DOMAIN_* for a nonzero status
%define BENCH_ITERATIONS    16          ; measured executions
%define BENCH_BATCHES       24          ; sink calls across all iterations
%define BENCH_SELECTED      32          ; rows selected across all iterations
%define BENCH_CHECKSUM      40          ; hash of every selection mask
%define BENCH_NS            48          ; nanoseconds spent in the loop
%define BENCH_TSC           56          ; TSC ticks spent in the loop
%define BENCH_REQUIRED      64          ; required-column bitmap from the plan
%define BENCH_ROW_BYTES     72          ; bytes per row actually mapped
%define BENCH_RECORD_SIZE   80

%define FNV_PRIME           1099511628211
%define FNV_OFFSET_BASIS    0xcbf29ce484222325
%define TAG_NULL            0xBF
%define TAG_VALUE           0x5A
%define ARENA_BYTES         1048576
%define SEED_CHUNK_ROWS     50000

; splitmix64's finalizer: a bijection on 64 bits, so distinct stream indices
; give distinct values. Input and output in RAX; clobbers RCX and RDX.
%macro SPLITMIX64 0
    mov     rcx, 0x9E3779B97F4A7C15
    add     rax, rcx
    mov     rdx, rax
    shr     rdx, 30
    xor     rax, rdx
    mov     rcx, 0xBF58476D1CE4E5B9
    imul    rax, rcx
    mov     rdx, rax
    shr     rdx, 27
    xor     rax, rdx
    mov     rcx, 0x94D049BB133111EB
    imul    rax, rcx
    mov     rdx, rax
    shr     rdx, 31
    xor     rax, rdx
%endmacro

section .data
    align 4
float_half:     dd 0.5
str_events:     db "events", 0

section .bss
    align 8
record:         resb BENCH_RECORD_SIZE
ctx:            resb CybouDB_DB_SIZE
arena:          resb SQL_ARENA_SIZE
memory:         resb ARENA_BYTES
error:          resb SQL_ERROR_SIZE
source:         resb 65536
stmt:           resq 1
plan:           resq 1
path:           resq 1
iterations:     resq 1
warmup:         resq 1
mode:           resq 1
force_scalar:   resq 1
force_zone:     resq 1
trace:          resq 1
arena_mark:     resq 1
sink_context:   resq 1

seed_batch:     resb 24
seed_table_id:  resq 1
seed_target:    resq 1
seed_dataset:   resq 1
seed_current:   resq 1
perm_a_mod:     resq 1
perm_b_mod:     resq 1
seed_values:    resq SEED_CHUNK_ROWS * 7
seed_nulls:     resb SEED_CHUNK_ROWS * 7

section .text

; -----------------------------------------------------------------------------
;  cyboudb_main - the platform layer calls this after argv is available.
;
;  Local slots: [rbp-8]=remaining iterations, [rbp-16]=saved start timestamp
; -----------------------------------------------------------------------------
cyboudb_main:
    FRAME_BEGIN 32, 2
    mov     qword [iterations], 1
    mov     qword [warmup], 0

    mov     ARG1, 1
    call    os_argv
    mov     [path], rax

    mov     ARG1, 2
    call    os_argv
    mov     ARG1, rax
    lea     ARG2, [source]
    mov     ARG3, 65536
    call    os_arg_to_utf8
    cmp     rax, -1
    je      .bad_setup                  ; a clipped statement measures nothing

    ; Check if command is --seed
    cmp     byte [source + 0], '-'
    jne     .not_seed
    cmp     byte [source + 1], '-'
    jne     .not_seed
    cmp     byte [source + 2], 's'
    jne     .not_seed
    cmp     byte [source + 3], 'e'
    jne     .not_seed
    cmp     byte [source + 4], 'e'
    jne     .not_seed
    cmp     byte [source + 5], 'd'
    jne     .not_seed
    cmp     byte [source + 6], 0
    je      .run_seeder

.not_seed:
    mov     qword [mode], 0
    mov     qword [force_scalar], 0
    mov     qword [force_zone], 0
    mov     qword [trace], 0
    mov     dword [sql_kernel_force_scalar], 0
    mov     dword [sql_zone_force_off], 0
    mov     dword [sql_zone_trace], 0

    mov     ARG1, 3
    call    os_argv
    test    rax, rax
    jz      .have_counts
    mov     ARG1, rax
    lea     ARG2, [iterations]
    call    os_str_to_u64
    mov     ARG1, 4
    call    os_argv
    test    rax, rax
    jz      .have_counts
    mov     ARG1, rax
    lea     ARG2, [warmup]
    call    os_str_to_u64
    mov     ARG1, 5
    call    os_argv
    test    rax, rax
    jz      .have_counts
    mov     ARG1, rax
    lea     ARG2, [mode]
    call    os_str_to_u64
    mov     ARG1, 6
    call    os_argv
    test    rax, rax
    jz      .have_counts
    mov     ARG1, rax
    lea     ARG2, [force_scalar]
    call    os_str_to_u64
    mov     eax, dword [force_scalar]
    mov     dword [sql_kernel_force_scalar], eax
    mov     ARG1, 7
    call    os_argv
    test    rax, rax
    jz      .have_counts
    mov     ARG1, rax
    lea     ARG2, [force_zone]
    call    os_str_to_u64
    mov     eax, dword [force_zone]
    mov     dword [sql_zone_force_off], eax
    mov     ARG1, 8
    call    os_argv
    test    rax, rax
    jz      .have_counts
    mov     ARG1, rax
    lea     ARG2, [trace]
    call    os_str_to_u64
    mov     eax, dword [trace]
    mov     dword [sql_zone_trace], eax
.have_counts:
    cmp     qword [iterations], 0
    jne     .arena
    mov     qword [iterations], 1

.arena:
    lea     ARG1, [arena]
    lea     ARG2, [memory]
    mov     ARG3, ARENA_BYTES
    call    sql_arena_init

    ; --- parse, open and bind: all outside the measured region ---------------
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
    test    eax, eax
    jnz     .report

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
    mov     [record + BENCH_REQUIRED], rax

    ; Every execution allocates its batch view from the arena, so the arena is
    ; rewound to this mark before each one. Without it a long run would report
    ; an out-of-memory failure rather than a measurement.
    mov     rax, [arena + ARENA_USED]
    mov     [arena_mark], rax

    ; --- warm up: page in the mapping and settle the branch predictors -------
    mov     rax, [warmup]
    mov     [rbp - 8], rax
.warm_loop:
    cmp     qword [rbp - 8], 0
    je      .measure
    call    run_once
    test    eax, eax
    jnz     .close
    dec     qword [rbp - 8]
    jmp     .warm_loop

    ; --- measured region -----------------------------------------------------
.measure:
    mov     qword [sql_zone_leaf_total], 0
    mov     qword [sql_zone_leaf_none], 0
    mov     qword [sql_zone_leaf_all], 0
    mov     qword [sql_zone_leaf_unknown], 0
    mov     qword [sql_zone_batch_total], 0
    mov     qword [sql_zone_column_mask], 0

    mov     qword [record + BENCH_BATCHES], 0
    mov     qword [record + BENCH_SELECTED], 0
    mov     rax, FNV_OFFSET_BASIS
    mov     [record + BENCH_CHECKSUM], rax
    mov     rax, [iterations]
    mov     [rbp - 8], rax

    call    os_monotonic_ns
    mov     [rbp - 16], rax
    rdtsc
    shl     rdx, 32
    or      rax, rdx
    mov     [rbp - 24], rax

.measure_loop:
    call    run_once
    test    eax, eax
    jnz     .measure_end
    dec     qword [rbp - 8]
    jnz     .measure_loop
.measure_end:
    mov     [rbp - 32], rax             ; keep the status across the clock reads
    rdtsc
    shl     rdx, 32
    or      rax, rdx
    sub     rax, [rbp - 24]
    mov     [record + BENCH_TSC], rax
    call    os_monotonic_ns
    sub     rax, [rbp - 16]
    mov     [record + BENCH_NS], rax

    mov     rax, [iterations]
    sub     rax, [rbp - 8]
    mov     [record + BENCH_ITERATIONS], rax

.close:
    lea     ARG1, [ctx]
    call    db_close
.report:
    mov     rax, [error + SQL_ERR_CODE]
    mov     [record + BENCH_STATUS], rax
    mov     rax, [error + SQL_ERR_DOMAIN]
    mov     [record + BENCH_DOMAIN], rax
    lea     ARG1, [record]
    mov     ARG2, BENCH_RECORD_SIZE
    call    os_write

    cmp     qword [trace], 0
    je      .done_report
    lea     ARG1, [sql_zone_leaf_total]
    mov     ARG2, 48
    call    os_write
.done_report:
    xor     eax, eax
    FRAME_END
    ret

.run_seeder:
    call    seed_events_table
    test    eax, eax
    jnz     .bad_setup
    xor     eax, eax
    FRAME_END
    ret

.bad_setup:
    mov     qword [record + BENCH_STATUS], -1
    lea     ARG1, [record]
    mov     ARG2, BENCH_RECORD_SIZE
    call    os_write
    mov     eax, 1
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  seed_events_table() -> EAX: 0 on success, 1 on error
;  Fast in-process seeder writing chunks of 10,000 rows via db_pax_insert.
; -----------------------------------------------------------------------------
seed_events_table:
    FRAME_BEGIN 80, 0
    mov     [rbp - 8], rbx
    mov     [rbp - 16], r12
    mov     [rbp - 24], r13
    mov     [rbp - 32], rsi
    mov     [rbp - 40], rdi
    mov     [rbp - 48], r14
    mov     [rbp - 56], r15

    mov     qword [seed_target], 0
    mov     ARG1, 3
    call    os_argv
    test    rax, rax
    jz      .seed_fail
    mov     ARG1, rax
    lea     ARG2, [seed_target]
    call    os_str_to_u64
    cmp     qword [seed_target], 0
    je      .seed_fail

    ; Optional argument 4 selects the dataset: 0 structured, 1 high entropy, 2 shuffled structured
    mov     qword [seed_dataset], 0
    mov     ARG1, 4
    call    os_argv
    test    rax, rax
    jz      .seed_dataset_ready
    mov     ARG1, rax
    lea     ARG2, [seed_dataset]
    call    os_str_to_u64
.seed_dataset_ready:
    cmp     qword [seed_dataset], 2
    jne     .seed_dataset_done
    ; Find coprime A >= 6364136223846793005 with seed_target
    mov     r14, 6364136223846793005
.find_coprime:
    mov     rax, r14
    mov     rbx, [seed_target]
.gcd_loop:
    test    rbx, rbx
    jz      .gcd_done
    xor     edx, edx
    div     rbx
    mov     rax, rbx
    mov     rbx, rdx
    jmp     .gcd_loop
.gcd_done:
    cmp     rax, 1
    je      .coprime_found
    add     r14, 2
    jmp     .find_coprime
.coprime_found:
    mov     rax, r14
    xor     edx, edx
    div     qword [seed_target]
    mov     [perm_a_mod], rdx

    mov     rax, 1442695040888963407
    xor     edx, edx
    div     qword [seed_target]
    mov     [perm_b_mod], rdx
.seed_dataset_done:

    ; Open database writable
    mov     ARG1, [path]
    lea     ARG2, [ctx]
    mov     ARG3, 1                     ; writable = 1
    xor     ARG4, ARG4                  ; verify = 0
    call    db_open
    test    eax, eax
    jnz     .seed_fail

    ; Find events table ID
    lea     ARG1, [ctx]
    lea     ARG2, [str_events]
    mov     ARG3, 6
    lea     ARG4, [seed_table_id]
    call    catalog_find_table
    test    rax, rax
    jz      .seed_close_fail

    ; Setup seed batch descriptor
    lea     rax, [seed_values]
    mov     [seed_batch + BATCH_VALUES], rax
    lea     rax, [seed_nulls]
    mov     [seed_batch + BATCH_NULLS], rax
    mov     qword [seed_current], 0

.seed_chunk_loop:
    mov     rax, [seed_target]
    sub     rax, [seed_current]
    jz      .seed_chunk_done
    cmp     rax, SEED_CHUNK_ROWS
    jbe     .seed_count_ready
    mov     rax, SEED_CHUNK_ROWS
.seed_count_ready:
    mov     [seed_batch + BATCH_ROWS], rax
    mov     r12, rax                    ; chunk rows

    ; Fill chunk rows
    lea     r9, [seed_values]
    lea     r10, [seed_nulls]
    xor     ebx, ebx                    ; i = 0
    cmp     qword [seed_dataset], 1
    je      .seed_fill_row_entropy
.seed_fill_row:
    mov     rsi, [seed_current]
    add     rsi, rbx                    ; row index
    cmp     qword [seed_dataset], 2
    jne     .have_permuted_row
    mov     rax, rsi
    mov     rcx, [perm_a_mod]
    mul     rcx
    add     rax, [perm_b_mod]
    adc     rdx, 0
    div     qword [seed_target]
    mov     rsi, rdx
.have_permuted_row:
    imul    rdi, rbx, 7                 ; cell_base index

    ; Col 0: id INT64 = row
    mov     [r9 + rdi * 8 + 0], rsi
    mov     byte [r10 + rdi + 0], 0

    ; Col 1: category INT32 = row % 8
    mov     rax, rsi
    and     eax, 7
    mov     [r9 + rdi * 8 + 8], rax
    mov     byte [r10 + rdi + 1], 0

    ; Col 2: score INT32 = row % 100
    mov     rax, rsi
    xor     edx, edx
    mov     ecx, 100
    div     rcx
    mov     [r9 + rdi * 8 + 16], rdx
    mov     byte [r10 + rdi + 2], 0

    ; Col 3: amount INT64 = row * 3
    lea     rax, [rsi + rsi * 2]
    mov     [r9 + rdi * 8 + 24], rax
    mov     byte [r10 + rdi + 3], 0

    ; Col 4: active BOOL = row % 2
    mov     rax, rsi
    and     eax, 1
    mov     [r9 + rdi * 8 + 32], rax
    mov     byte [r10 + rdi + 4], 0

    ; Col 5: weight FLOAT32 = (row % 1000) + 0.5
    mov     rax, rsi
    xor     edx, edx
    mov     ecx, 1000
    div     rcx
    cvtsi2ss xmm0, edx
    addss   xmm0, [float_half]
    movd    eax, xmm0
    mov     [r9 + rdi * 8 + 40], rax
    mov     byte [r10 + rdi + 5], 0

    ; Col 6: tag INT32 = (row % 5 == 0 ? NULL : row % 7)
    mov     rax, rsi
    xor     edx, edx
    mov     ecx, 5
    div     rcx
    test    edx, edx
    jz      .seed_col6_null
    mov     rax, rsi
    xor     edx, edx
    mov     ecx, 7
    div     rcx
    mov     [r9 + rdi * 8 + 48], rdx
    mov     byte [r10 + rdi + 6], 0
    jmp     .seed_col6_done
.seed_col6_null:
    mov     qword [r9 + rdi * 8 + 48], 0
    mov     byte [r10 + rdi + 6], 1
.seed_col6_done:

    inc     rbx
    cmp     rbx, r12
    jb      .seed_fill_row
    jmp     .seed_insert_chunk

    ; High entropy dataset: every column is an independent splitmix64 stream
    ; of the row index, so values do not cluster within a leaf and neither
    ; zone maps nor run-length encoding have anything to work with. Value
    ; ranges match the structured dataset, so the same predicates keep
    ; comparable selectivity. Must stay bit-identical to
    ; benchmarks/datasets.py, which seeds the other engines.
.seed_fill_row_entropy:
    mov     rsi, [seed_current]
    add     rsi, rbx                    ; row index
    imul    rdi, rbx, 7                 ; cell_base index
    mov     r8, rsi
    shl     r8, 3                       ; stream base = row * 8

    ; Col 0: id INT64 = mix(base + 0)
    mov     rax, r8
    SPLITMIX64
    mov     [r9 + rdi * 8 + 0], rax
    mov     byte [r10 + rdi + 0], 0

    ; Col 1: category INT32 = mix(base + 1) % 8
    lea     rax, [r8 + 1]
    SPLITMIX64
    and     eax, 7
    mov     [r9 + rdi * 8 + 8], rax
    mov     byte [r10 + rdi + 1], 0

    ; Col 2: score INT32 = mix(base + 2) % 100
    lea     rax, [r8 + 2]
    SPLITMIX64
    xor     edx, edx
    mov     ecx, 100
    div     rcx
    mov     [r9 + rdi * 8 + 16], rdx
    mov     byte [r10 + rdi + 2], 0

    ; Col 3: amount INT64 = mix(base + 3)
    lea     rax, [r8 + 3]
    SPLITMIX64
    mov     [r9 + rdi * 8 + 24], rax
    mov     byte [r10 + rdi + 3], 0

    ; Col 4: active BOOL = mix(base + 4) & 1
    lea     rax, [r8 + 4]
    SPLITMIX64
    and     eax, 1
    mov     [r9 + rdi * 8 + 32], rax
    mov     byte [r10 + rdi + 4], 0

    ; Col 5: weight FLOAT32 = (mix(base + 5) % 2000) * 0.5, exact in binary32
    lea     rax, [r8 + 5]
    SPLITMIX64
    xor     edx, edx
    mov     ecx, 2000
    div     rcx
    cvtsi2ss xmm0, edx
    mulss   xmm0, [float_half]
    movd    eax, xmm0
    mov     [r9 + rdi * 8 + 40], rax
    mov     byte [r10 + rdi + 5], 0

    ; Col 6: tag INT32 = (h % 5 == 0 ? NULL : h % 7), h = mix(base + 6)
    lea     rax, [r8 + 6]
    SPLITMIX64
    mov     r11, rax
    xor     edx, edx
    mov     ecx, 5
    div     rcx
    test    edx, edx
    jz      .entropy_col6_null
    mov     rax, r11
    xor     edx, edx
    mov     ecx, 7
    div     rcx
    mov     [r9 + rdi * 8 + 48], rdx
    mov     byte [r10 + rdi + 6], 0
    jmp     .entropy_col6_done
.entropy_col6_null:
    mov     qword [r9 + rdi * 8 + 48], 0
    mov     byte [r10 + rdi + 6], 1
.entropy_col6_done:

    inc     rbx
    cmp     rbx, r12
    jb      .seed_fill_row_entropy

.seed_insert_chunk:
    ; Insert chunk into PAX
    lea     ARG1, [ctx]
    mov     ARG2, [seed_table_id]
    lea     ARG3, [seed_batch]
    call    db_pax_insert
    test    eax, eax
    jnz     .seed_close_fail

    ; Commit chunk so leaves become live snapshot and avoid quadratic CRC checks
    lea     ARG1, [ctx]
    call    db_commit
    test    eax, eax
    jnz     .seed_close_fail

    add     [seed_current], r12
    jmp     .seed_chunk_loop

.seed_chunk_done:
    lea     ARG1, [ctx]
    call    db_close
    xor     eax, eax
    jmp     .seed_exit

.seed_close_fail:
    lea     ARG1, [ctx]
    call    db_close
.seed_fail:
    mov     eax, 1
.seed_exit:
    mov     rbx, [rbp - 8]
    mov     r12, [rbp - 16]
    mov     r13, [rbp - 24]
    mov     rsi, [rbp - 32]
    mov     rdi, [rbp - 40]
    mov     r14, [rbp - 48]
    mov     r15, [rbp - 56]
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  run_once() -> RAX: the executor's status code.
;  Rewinds the arena, then executes the already bound plan.
; -----------------------------------------------------------------------------
run_once:
    FRAME_BEGIN 0, 2
    mov     rax, [arena_mark]
    mov     [arena + ARENA_USED], rax
    lea     ARG1, [ctx]
    mov     ARG2, [plan]
    lea     ARG3, [arena]
    lea     ARG4, [bench_sink]
    lea     rax, [sink_context]
    PASS_ARG5 rax
    lea     rax, [error]
    PASS_ARG6 rax
    call    sql_execute_batch
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  bench_sink(ctx, batch_view, projection, selection_mask) -> CybouDB_SINK_*
;
;  Deliberately O(1) per batch. Counting the selected rows and folding the
;  mask into a hash is enough to keep the optimiser and the CPU honest - the
;  scan cannot be skipped and the masks have to be produced - while adding
;  nothing per row that would be measured as engine cost.
;
;  Uses only volatile registers, so no saves are needed.
; -----------------------------------------------------------------------------
bench_sink:
    FRAME_BEGIN 96, 0
    mov     [rbp - 8], rbx
    mov     [rbp - 16], r12
    mov     [rbp - 24], r13
    mov     [rbp - 32], r14
    mov     [rbp - 40], r15
    mov     [rbp - 48], rsi
    mov     [rbp - 56], rdi
    mov     [rbp - 64], ARG2            ; batch_view
    mov     [rbp - 72], ARG3            ; projection
    mov     [rbp - 80], ARG4            ; selection_mask

    inc     qword [record + BENCH_BATCHES]

    ; Runtime-dispatched population count, also safe on baseline x86-64.
    extern cyboudb_popcount64
    mov     ARG1, [rbp - 80]
    call    cyboudb_popcount64
    add     [record + BENCH_SELECTED], rax

    ; Bytes per row is read once, from the first batch that arrives
    cmp     qword [record + BENCH_ROW_BYTES], 0
    jne     .width_done
    mov     r10, [rbp - 64]
    add     r10, BATCH_VIEW_COLUMNS
    xor     ecx, ecx                    ; column slot
    xor     eax, eax                    ; accumulated width
.width_loop:
    cmp     qword [r10 + COLVIEW_VALUES_PTR], 0
    je      .width_next
    mov     edx, [r10 + COLVIEW_WIDTH]
    add     rax, rdx
.width_next:
    add     r10, CybouDB_COLVIEW_SIZE
    inc     ecx
    cmp     ecx, 64
    jb      .width_loop
    mov     [record + BENCH_ROW_BYTES], rax
.width_done:

    cmp     qword [mode], 0
    jne     .sink_materialize

    ; Mode 0: Filter mode - fold selection mask into FNV hash
    mov     rax, [record + BENCH_CHECKSUM]
    xor     rax, [rbp - 80]
    mov     r10, FNV_PRIME
    imul    rax, r10
    mov     [record + BENCH_CHECKSUM], rax
    jmp     .sink_done

.sink_materialize:
    ; Mode 1: Materialize mode - read and fold actual cell values of projected columns
    mov     r12, [rbp - 64]             ; batch_view
    mov     r13, [rbp - 72]             ; projection descriptor
    mov     r14, [rbp - 80]             ; selection_mask
    mov     rbx, [record + BENCH_CHECKSUM] ; current checksum

.mat_row_loop:
    test    r14, r14
    jz      .mat_rows_done
    tzcnt   rsi, r14                    ; rsi = active row index in batch (0..63)
    lea     rax, [r14 - 1]
    and     r14, rax                    ; clear lowest set bit

    mov     r15, [r13 + 0]              ; proj_count (1..64)
    mov     rdi, [r13 + 8]              ; proj_indices pointer (u32 array)
    xor     ecx, ecx                    ; col_p = 0

.mat_col_loop:
    mov     edx, [rdi + rcx * 4]        ; physical col_idx
    imul    rax, rdx, CybouDB_COLVIEW_SIZE
    lea     r10, [r12 + BATCH_VIEW_COLUMNS + rax]

    ; Check if row rsi is NULL: bit rsi of null_mask
    mov     r8, [r10 + COLVIEW_NULL_MASK]
    bt      r8, rsi
    jc      .mat_cell_null

    ; Non-null cell: fold TAG_VALUE first
    xor     rbx, TAG_VALUE
    mov     rax, FNV_PRIME
    imul    rbx, rax

    ; Read value into r8
    mov     rax, [r10 + COLVIEW_VALUES_PTR]
    mov     edx, [r10 + COLVIEW_WIDTH]
    cmp     edx, 8
    je      .mat_read_8
    cmp     edx, 4
    je      .mat_read_4
    ; width == 1 (BOOL)
    movzx   r8, byte [rax + rsi]
    jmp     .mat_fold_val

.mat_read_8:
    mov     r8, [rax + rsi * 8]
    jmp     .mat_fold_val

.mat_read_4:
    mov     r8d, [rax + rsi * 4]         ; zero-extended to 64-bit r8

.mat_fold_val:
    xor     rbx, r8
    mov     rax, FNV_PRIME
    imul    rbx, rax
    jmp     .mat_col_next

.mat_cell_null:
    ; Fold TAG_NULL
    xor     rbx, TAG_NULL
    mov     rax, FNV_PRIME
    imul    rbx, rax

.mat_col_next:
    inc     rcx
    cmp     rcx, r15
    jb      .mat_col_loop

    jmp     .mat_row_loop

.mat_rows_done:
    mov     [record + BENCH_CHECKSUM], rbx

.sink_done:
    mov     rbx, [rbp - 8]
    mov     r12, [rbp - 16]
    mov     r13, [rbp - 24]
    mov     r14, [rbp - 32]
    mov     r15, [rbp - 40]
    mov     rsi, [rbp - 48]
    mov     rdi, [rbp - 56]
    xor     eax, eax                    ; CybouDB_SINK_CONTINUE
    FRAME_END
    ret
