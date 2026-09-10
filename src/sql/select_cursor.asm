; One pull-based SELECT executor, shared by callback and public C APIs.
; sql_select_open(state, db, plan, batch_view, decode_storage) -> eax status.
; Caller owns state, batch and optional 32 KiB decode storage for the lifetime
; of the scan. Bound-plan and snapshot validation is identical for every API.
; sql_select_next(state) -> eax storage status, rdx selection mask (0 = DONE).
; A successful nonzero mask exposes the borrowed batch at state.SEL_BATCH.
%include "sql.inc"
%include "select_cursor.inc"
BITS 64
default rel
extern db_catalog_get, db_zone_lookup, sql_zone_eval
extern db_pax_scan_open_bound, db_pax_scan_batch_ex, eval_predicate_encoded
extern sql_zone_force_off, sql_zone_trace
extern sql_zone_leaf_total, sql_zone_leaf_none, sql_zone_leaf_all, sql_zone_leaf_unknown
extern sql_zone_batch_total, sql_zone_column_mask
extern sql_kernel_force_scalar, cpu_has_avx2
global sql_select_open, sql_select_next
section .text
sql_select_open:
    FRAME_BEGIN 16, 0
    mov [rbp - 8], r12
    mov r12, ARG1
    mov [r12 + SEL_DB], ARG2
    mov [r12 + SEL_PLAN], ARG3
    mov [r12 + SEL_BATCH], ARG4
    mov rax, IN_ARG5
    mov [r12 + SEL_DECODE], rax
    mov qword [r12 + SEL_COUNT], 0
    mov qword [r12 + SEL_DONE], 0
    mov qword [r12 + SEL_ERROR], 0
    mov r10, [r12 + SEL_PLAN]
    ; Fast path contract:
    ; 1. PLAN_SCHEMA_PAGE must be non-null
    mov     rax, [r10 + PLAN_SCHEMA_PAGE]
    test    rax, rax
    jz      .slow_scan_open
    ; 2. Same connection context
    mov     r11, [r12 + SEL_DB]              ; db_ctx
    cmp     r11, [r10 + PLAN_CTX]
    jne     .slow_scan_open
    ; 3. Same mapped memory base address
    mov     rcx, [r11 + DB_BASE]
    cmp     rcx, [r10 + PLAN_DB_BASE]
    jne     .slow_scan_open
    ; 4. Matching DB_GENERATION
    mov     rcx, [r11 + DB_GENERATION]
    cmp     rcx, [r10 + PLAN_GENERATION]
    jne     .slow_scan_open
    ; 5. Matching DB_ROOT catalog root page
    mov     rcx, [r11 + DB_ROOT]
    cmp     rcx, [r10 + PLAN_DB_ROOT]
    jne     .slow_scan_open
    ; 6. No uncommitted staged mutations in this transaction
    cmp     qword [r11 + DB_DIRTY_HI], 0
    jne     .slow_scan_open
    ; All conditions hold: direct scan open via cached schema page
    mov     [r12 + SEL_SCHEMA], rax
    mov     ARG1, r11
    mov     ARG2, rax                   ; schema_ptr
    lea     ARG3, [r12 + SEL_SCAN]           ; CybouDB_SCAN_SIZE scan cursor
    call    db_pax_scan_open_bound
    jmp     .scan_ready
.slow_scan_open:
    mov     ARG1, [r12 + SEL_DB]
    mov     ARG2, [r10 + PLAN_TABLE_ID]
    lea     ARG3, [r12 + SEL_SCHEMA_ID]
    call    db_catalog_get             ; validate and obtain this snapshot's schema
    test    eax, eax
    jnz     .open_exit
    mov     rax, [r12 + SEL_SCHEMA_ID]
    shl     rax, CybouDB_PAGE_SHIFT
    mov     r11, [r12 + SEL_DB]
    add     rax, [r11 + DB_BASE]
    mov     [r12 + SEL_SCHEMA], rax
    mov     ARG1, r11
    mov     ARG2, rax
    lea     ARG3, [r12 + SEL_SCAN]
    call    db_pax_scan_open_bound
.scan_ready:
    test    eax, eax
    jnz     .open_exit
    mov     qword [r12 + SEL_LEAF_END], 0        ; enter a leaf before its first batch
    mov     qword [r12 + SEL_PROJECTION], 0
    mov     r10, [r12 + SEL_PLAN]
    test    qword [r10 + PLAN_FLAGS], PLAN_FLAG_COUNT_STAR
    jnz     .open_done
    mov     r11, [r10 + PLAN_DATA2]
    xor     ecx, ecx
.projection_mask:
    cmp     rcx, [r10 + PLAN_DATA1]
    jae     .open_done
    mov     eax, [r11 + rcx * 4]
    bts     qword [r12 + SEL_PROJECTION], rax
    inc     rcx
    jmp     .projection_mask

.open_done:
    mov r10, [r12 + SEL_PLAN]
    mov rax, [r10 + PLAN_REQUIRED_VALUES]
    not rax
    and rax, [r10 + PLAN_REQUIRED_COLS]
    mov [r12 + SEL_OPTIONS + PAX_SCANOPT_NULL_ONLY], rax
    mov rax, [r12 + SEL_PROJECTION]
    not rax
    and rax, [r10 + PLAN_REQUIRED_VALUES]
    mov r11, [r12 + SEL_DB]
    test qword [r11 + DB_FEATURES], CybouDB_FEATURE_COMPRESSION
    jnz .encoding_mask_ready
    xor eax, eax
.encoding_mask_ready:
    mov [r12 + SEL_OPTIONS + PAX_SCANOPT_ENCODED], rax
    mov qword [r12 + SEL_OPTIONS + PAX_SCANOPT_FLAGS], 0
    test qword [r11 + DB_FEATURES], CybouDB_FEATURE_COMPRESSION
    jz .direct_for_ready
    cmp dword [sql_kernel_force_scalar], 0
    jne .direct_for_ready
    call cpu_has_avx2
    test eax, eax
    jz .direct_for_ready
    or qword [r12 + SEL_OPTIONS + PAX_SCANOPT_FLAGS], PAX_SCANOPT_DIRECT_FOR
.direct_for_ready:
    mov qword [r12 + SEL_ENCODING_VIEWS], 0
    mov rax, [r12 + SEL_OPTIONS + PAX_SCANOPT_ENCODED]
    test rax, rax
    jz .encoding_views_ready
    lea rax, [r12 + SEL_OPTIONS + PAX_SCANOPT_VIEWS]
    mov [r12 + SEL_ENCODING_VIEWS], rax
.encoding_views_ready:
    xor eax, eax
.open_exit:
    mov r12, [rbp - 8]
    FRAME_END
    ret

sql_select_next:
    FRAME_BEGIN 16, 1
    mov [rbp - 8], r12
    mov r12, ARG1
    mov rax, [r12 + SEL_ERROR]
    xor edx, edx
    test eax, eax
    jnz .next_exit
    cmp qword [r12 + SEL_DONE], 0
    jne .done
.scan_loop:
    ; Skipped leaves must enforce the same cursor lifetime as scan_batch.
    mov     r11, [r12 + SEL_DB]
    cmp     qword [r11 + DB_BASE], 0
    je      .scan_state
    cmp     qword [r11 + DB_MODE], -1
    je      .scan_state
    mov     rax, [r11 + DB_GENERATION]
    cmp     rax, [r12 + SEL_SCAN + SCAN_GENERATION]
    jne     .scan_state
    mov     rax, [r12 + SEL_SCAN + SCAN_NEXT]
    cmp     rax, [r12 + SEL_SCAN + SCAN_ROWS]
    jae     .scan_finished
    cmp     rax, [r12 + SEL_LEAF_END]
    jb      .read_batch
    ; We are at a leaf boundary. Geometry comes from the validated cursor;
    ; neither NONE nor COUNT/ALL needs to resolve or touch the PAX leaf.
    xor     edx, edx
    div     qword [r12 + SEL_SCAN + SCAN_CAPACITY]
    mov     [r12 + SEL_LEAF_INDEX], rax
    mov     rax, [r12 + SEL_SCAN + SCAN_ROWS]
    sub     rax, [r12 + SEL_SCAN + SCAN_NEXT]
    mov     rcx, [r12 + SEL_SCAN + SCAN_CAPACITY]
    cmp     rax, rcx
    cmova   rax, rcx
    add     rax, [r12 + SEL_SCAN + SCAN_NEXT]
    mov     [r12 + SEL_LEAF_END], rax
    mov     qword [r12 + SEL_DECISION], ZONE_TEST_UNKNOWN
    cmp     dword [sql_zone_force_off], 0
    jne     .zone_decided
    mov     ARG1, [r12 + SEL_DB]
    mov     ARG2, [r12 + SEL_SCHEMA]
    mov     ARG3, [r12 + SEL_LEAF_INDEX]
    call    db_zone_lookup
    mov     ARG2, rax
    mov     r10, [r12 + SEL_PLAN]
    mov     ARG1, [r10 + PLAN_DATA4]
    mov     ARG3, [r12 + SEL_SCHEMA]
    call    sql_zone_eval
    mov     [r12 + SEL_DECISION], rax
.zone_decided:
    cmp     dword [sql_zone_trace], 0
    je      .zone_apply
    inc     qword [sql_zone_leaf_total]
    cmp     qword [r12 + SEL_DECISION], ZONE_TEST_NONE
    jne     .trace_all
    inc     qword [sql_zone_leaf_none]
    jmp     .zone_apply
.trace_all:
    cmp     qword [r12 + SEL_DECISION], ZONE_TEST_ALL
    jne     .trace_unknown
    inc     qword [sql_zone_leaf_all]
    jmp     .zone_apply
.trace_unknown:
    inc     qword [sql_zone_leaf_unknown]
.zone_apply:
    cmp     qword [r12 + SEL_DECISION], ZONE_TEST_NONE
    je      .skip_leaf
    mov     r10, [r12 + SEL_PLAN]
    mov     rax, [r10 + PLAN_REQUIRED_COLS]
    mov     [r12 + SEL_REQUIRED], rax
    cmp     qword [r12 + SEL_DECISION], ZONE_TEST_ALL
    jne     .read_batch
    test    qword [r10 + PLAN_FLAGS], PLAN_FLAG_COUNT_STAR
    jz      .projection_only
    mov     rax, [r12 + SEL_LEAF_END]
    sub     rax, [r12 + SEL_SCAN + SCAN_NEXT]
    add     [r12 + SEL_COUNT], rax
.skip_leaf:
    mov     rax, [r12 + SEL_LEAF_END]
    mov     [r12 + SEL_SCAN + SCAN_NEXT], rax
    jmp     .scan_loop
.projection_only:
    mov     rax, [r12 + SEL_PROJECTION]
    mov     [r12 + SEL_REQUIRED], rax
.read_batch:
    cmp     dword [sql_zone_trace], 0
    je      .batch_args
    inc     qword [sql_zone_batch_total]
    mov     rax, [r12 + SEL_REQUIRED]
    or      [sql_zone_column_mask], rax
.batch_args:
    lea rax, [r12 + SEL_OPTIONS]
    PASS_ARG5 rax
    lea     ARG1, [r12 + SEL_SCAN]
    mov     ARG2, [r12 + SEL_BATCH]
    mov     ARG3, [r12 + SEL_REQUIRED]
    mov     ARG4, [r12 + SEL_DECODE]
    call    db_pax_scan_batch_ex
    test    eax, eax
    jnz     .storage_done
    test    rdx, rdx
    jz      .scan_finished
    cmp     qword [r12 + SEL_DECISION], ZONE_TEST_ALL
    je      .batch_all
    mov     r10, [r12 + SEL_PLAN]
    mov     ARG1, [r10 + PLAN_DATA4]
    mov     ARG2, rdx
    mov     ARG3, [r12 + SEL_BATCH]
    mov     ARG4, [r12 + SEL_ENCODING_VIEWS]
    call    eval_predicate_encoded
    jmp     .selected
.batch_all:
    mov     rax, -1
    cmp     rdx, 64
    jae     .selected
    mov     rcx, rdx
    mov     rax, 1
    shl     rax, cl
    dec     rax
.selected:
    test    rax, rax
    jz      .scan_loop

    ; If COUNT(*), accumulate popcount and continue scanning
    mov     r10, [r12 + SEL_PLAN]
    test    qword [r10 + PLAN_FLAGS], PLAN_FLAG_COUNT_STAR
    jnz     .count_star_accum


    mov rdx, rax
    xor eax, eax
    jmp .next_exit
.count_star_accum:
    extern cyboudb_popcount64
    mov     ARG1, rax
    call    cyboudb_popcount64
    add     [r12 + SEL_COUNT], rax
    jmp     .scan_loop


.scan_finished:
    mov qword [r12 + SEL_DONE], 1
    mov r10, [r12 + SEL_PLAN]
    test qword [r10 + PLAN_FLAGS], PLAN_FLAG_COUNT_STAR
    jz .done
.count_star_deliver:
    mov     r10, [r12 + SEL_BATCH]            ; batch_view
    mov     qword [r10 + BATCH_VIEW_ROWS], 1
    lea     r11, [r10 + BATCH_VIEW_COLUMNS] ; colview 0
    lea     rax, [r12 + SEL_COUNT]             ; pointer to count_accum
    mov     [r11 + COLVIEW_VALUES_PTR], rax
    mov     qword [r11 + COLVIEW_NULL_MASK], 0
    mov     dword [r11 + COLVIEW_TYPE], CAT_INT64
    mov     dword [r11 + COLVIEW_WIDTH], 8


    mov edx, 1
    xor eax, eax
    jmp .next_exit
.done:
    xor eax, eax
    xor edx, edx
    jmp .next_exit
.scan_state:
    mov eax, CybouDB_E_STATE
.storage_done:
    mov [r12 + SEL_ERROR], rax
    xor edx, edx
.next_exit:
    mov r12, [rbp - 8]
    FRAME_END
    ret
