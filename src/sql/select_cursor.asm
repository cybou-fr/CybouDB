; Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
; SPDX-License-Identifier: Apache-2.0
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
extern db_catalog_page, db_index_node_addr
extern db_index_iter_open, db_index_iter_next
extern db_pax_scan_open_bound, db_pax_scan_batch_ex, eval_predicate_encoded
extern sql_zone_force_off, sql_zone_trace
extern sql_zone_leaf_total, sql_zone_leaf_none, sql_zone_leaf_all, sql_zone_leaf_unknown
extern sql_zone_batch_total, sql_zone_column_mask
extern sql_kernel_force_scalar, cpu_has_avx2
global sql_select_open, sql_select_next
section .data
; Times a SELECT found its row through a tree instead of by reading the
; table. A test can assert the answer and this together, which is the
; difference between a query that is right and a query that is right for the
; reason the plan claims.
global index_lookups
index_lookups: dq 0

section .text
sql_select_open:
    FRAME_BEGIN 32, 1
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
    mov qword [r12 + SEL_LIMIT_SKIP], 0
    mov qword [r12 + SEL_LIMIT_LEFT], -1
    test qword [r10 + PLAN_FLAGS], PLAN_FLAG_LIMIT
    jz .limit_state_ready
    test qword [r10 + PLAN_FLAGS], (PLAN_FLAG_ORDER | PLAN_FLAG_VECTOR_TOPK)
    jnz .limit_state_ready
    mov rax, [r10 + PLAN_OFFSET_VALUE]
    mov [r12 + SEL_LIMIT_SKIP], rax
    mov rax, [r10 + PLAN_LIMIT_VALUE]
    mov [r12 + SEL_LIMIT_LEFT], rax
.limit_state_ready:
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

    ; --- the index, if the plan chose one ---------------------------------
    ; The seek lives here rather than in one executor because every reader
    ; opens its cursor through this function: the batch executor, the pull
    ; cursor the ABI steps, and whatever reads next. Putting it in a caller is
    ; how a second copy of a statement's behaviour starts.
    mov qword [r12 + SEL_LOOKUP], 0
    mov r10, [r12 + SEL_PLAN]
    test qword [r10 + PLAN_FLAGS], PLAN_FLAG_INDEX_EQ
    jz .lookup_ready
    inc qword [rel index_lookups]
    mov rax, [r10 + PLAN_INDEX_KEY]
    mov [r12 + SEL_LOOKUP_KEY], rax
    mov ARG1, [r12 + SEL_DB]
    mov ARG2, [r10 + PLAN_INDEX_ID]
    call db_catalog_page
    test rax, rax
    jz .lookup_empty
    cmp dword [rax + CAT_TYPE], CAT_INDEX
    jne .lookup_empty
    ; The root goes in a register no argument aliases: ARG1 is RCX on one of
    ; the two ABIs, and loading the context would take the root with it.
    mov r11, [rax + IDX_ROOT]
    test r11, r11
    jz .lookup_empty                    ; an empty index names nothing
    mov ARG1, [r12 + SEL_DB]
    mov ARG2, r11
    mov ARG3, [r12 + SEL_LOOKUP_KEY]
    lea ARG4, [r12 + SEL_ITER]
    call db_index_iter_open
    test eax, eax
    jz .lookup_empty
    mov qword [r12 + SEL_LOOKUP], 1     ; seek before the next batch

    mov qword [r12 + SEL_LOOKUP_ROW], -2
    jmp .lookup_ready
.lookup_empty:
    mov qword [r12 + SEL_LOOKUP], 0
    mov qword [r12 + SEL_DONE], 1       ; the tree says there is nothing to read
.lookup_ready:
    xor eax, eax
.open_exit:
    mov r12, [rbp - 8]
    FRAME_END
    ret

sql_select_next:
    FRAME_BEGIN 64, 1
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
    cmp     qword [r12 + SEL_LOOKUP], 1
    je      .lookup_seek                ; the tree says where the next rows are
    mov     rax, [r12 + SEL_SCAN + SCAN_NEXT]
    cmp     rax, [r12 + SEL_SCAN + SCAN_ROWS]
    jae     .scan_finished
    cmp     rax, [r12 + SEL_LEAF_END]
    jb      .read_batch
    ; We have entered a leaf. Geometry comes from the validated cursor;
    ; neither NONE nor COUNT/ALL needs to resolve or touch the PAX leaf.
    ;
    ; A scan enters a leaf at its first row, but a lookup enters one wherever
    ; the tree pointed. What is left of the leaf is its capacity less how far
    ; into it we already stand - the same number a scan has always seen, since
    ; for a scan that distance is zero.
    xor     edx, edx
    div     qword [r12 + SEL_SCAN + SCAN_CAPACITY]
    mov     [r12 + SEL_LEAF_INDEX], rax
    mov     rax, [r12 + SEL_SCAN + SCAN_CAPACITY]
    sub     rax, rdx                    ; the part of this leaf still ahead
    mov     rcx, [r12 + SEL_SCAN + SCAN_ROWS]
    sub     rcx, [r12 + SEL_SCAN + SCAN_NEXT]
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
    ; Counting a leaf the zone map accepted whole, without reading it, counts
    ; its dead rows too. The leaf's own count would answer for a whole leaf,
    ; but this shortcut also covers the part of one a scan has left, so the
    ; batches are read and the mask does the work.
    mov     r11, [r12 + SEL_DB]
    test    qword [r11 + DB_FEATURES], CybouDB_FEATURE_TOMBSTONES
    jnz     .read_batch
    mov     rax, [r12 + SEL_LEAF_END]
    sub     rax, [r12 + SEL_SCAN + SCAN_NEXT]
    add     [r12 + SEL_COUNT], rax
.skip_leaf:
    mov     rax, [r12 + SEL_LEAF_END]
    mov     [r12 + SEL_SCAN + SCAN_NEXT], rax
    jmp     .scan_loop
.projection_only:
    mov     rax, [r12 + SEL_PROJECTION]
    test    qword [r10 + PLAN_FLAGS], PLAN_FLAG_VECTOR_TOPK
    jz      .proj_only_store
    mov     r11, [r10 + PLAN_VECTOR_TOPK_EXPR]
    mov     rcx, [r11 + BEXPR_COL_IDX]
    bts     rax, rcx
.proj_only_store:
    mov     [r12 + SEL_REQUIRED], rax
    jmp     .read_batch

.lookup_seek:
    ; Where the next rows for this key are. The walk moves forward only, so an
    ; entry it produces is either inside a batch already delivered - which the
    ; scan's own position states, rather than a guess about how many rows a
    ; batch carried - or it is the row the next batch has to start at.
    cmp     qword [r12 + SEL_LOOKUP_ROW], -1
    je      .lookup_spent
    cmp     qword [r12 + SEL_LOOKUP_ROW], -2
    jne     .lookup_have_row
.lookup_pull:
    mov     ARG1, [r12 + SEL_DB]
    lea     ARG2, [r12 + SEL_ITER]
    lea     ARG3, [rbp - 24]
    lea     ARG4, [rbp - 32]
    call    db_index_iter_next
    test    eax, eax
    jz      .lookup_spent
    mov     rax, [rbp - 24]
    cmp     rax, [r12 + SEL_LOOKUP_KEY]
    jne     .lookup_spent               ; past every row this key names
    mov     rax, [rbp - 32]
    mov     [r12 + SEL_LOOKUP_ROW], rax
.lookup_have_row:
    mov     rdx, [r12 + SEL_LOOKUP_ROW]
    cmp     rdx, [r12 + SEL_SCAN + SCAN_ROWS]
    jae     .lookup_drop                ; a row the table no longer has
    cmp     rdx, [r12 + SEL_SCAN + SCAN_NEXT]
    jb      .lookup_drop                ; a row some batch has already carried
    and     rdx, ~63                    ; the group it sits in
    cmp     rdx, [r12 + SEL_SCAN + SCAN_NEXT]
    jb      .lookup_placed              ; that group is the one we stand in
    mov     [r12 + SEL_SCAN + SCAN_NEXT], rdx
    mov     qword [r12 + SEL_LEAF_END], 0   ; enter the leaf it lands in
.lookup_placed:
    ; The entry stays where it is. Whether this batch reaches it is the next
    ; seek's question, and by then the scan's position answers it.
    mov     qword [r12 + SEL_LOOKUP], 3
    jmp     .scan_loop
.lookup_drop:
    mov     qword [r12 + SEL_LOOKUP_ROW], -2
    jmp     .lookup_pull
.lookup_spent:
    mov     qword [r12 + SEL_DONE], 1
    jmp     .done

.read_batch:
    ; A lookup reads the batch its rows are in and then asks the tree again,
    ; whether or not the predicate kept anything in this one.
    cmp     qword [r12 + SEL_LOOKUP], 3
    jne     .lookup_noted
    mov     qword [r12 + SEL_LOOKUP], 1
.lookup_noted:
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
    ; A dead row is invisible to everything above this point: the predicate
    ; kernels, LIMIT, the projection and COUNT all work from this mask, so
    ; intersecting here is the whole of what tombstones mean to a reader.
    ; A file without them never reaches the intersection at all, so its
    ; selection is what it always was.
    mov     r11, [r12 + SEL_DB]
    test    qword [r11 + DB_FEATURES], CybouDB_FEATURE_TOMBSTONES
    jz      .selection_live
    mov     r8, [r12 + SEL_SCAN + SCAN_DEAD]
    not     r8
    and     rax, r8
.selection_live:
    test    rax, rax
    jz      .scan_loop

    ; If COUNT(*), accumulate popcount and continue scanning
    mov     r10, [r12 + SEL_PLAN]
    test    qword [r10 + PLAN_FLAGS], PLAN_FLAG_COUNT_STAR
    jnz     .count_star_accum

    test    qword [r10 + PLAN_FLAGS], PLAN_FLAG_LIMIT
    jz      .selection_ready
    mov     r8, rax                    ; input selection
    xor     r9d, r9d                   ; limited selection
.limit_lane:
    test    r8, r8
    jz      .limit_lanes_done
    bsf     rcx, r8
    lea     rax, [r8 - 1]
    and     r8, rax
    cmp     qword [r12 + SEL_LIMIT_SKIP], 0
    je      .limit_take
    dec     qword [r12 + SEL_LIMIT_SKIP]
    jmp     .limit_lane
.limit_take:
    cmp     qword [r12 + SEL_LIMIT_LEFT], 0
    je      .limit_lanes_done
    bts     r9, rcx
    dec     qword [r12 + SEL_LIMIT_LEFT]
    jmp     .limit_lane
.limit_lanes_done:
    mov     rax, r9
    cmp     qword [r12 + SEL_LIMIT_LEFT], 0
    jne     .limit_not_done
    mov     qword [r12 + SEL_DONE], 1
.limit_not_done:
    test    rax, rax
    jnz     .selection_ready
    cmp     qword [r12 + SEL_DONE], 0
    jne     .done
    jmp     .scan_loop
.selection_ready:
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
    test qword [r10 + PLAN_FLAGS], PLAN_FLAG_LIMIT
    jz .count_star_emit
    cmp qword [r12 + SEL_LIMIT_LEFT], 0
    je .done
    cmp qword [r12 + SEL_LIMIT_SKIP], 0
    je .count_limit_take
    dec qword [r12 + SEL_LIMIT_SKIP]
    jmp .done
.count_limit_take:
    dec qword [r12 + SEL_LIMIT_LEFT]
.count_star_emit:
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

%ifdef CybouDB_LINUX
section .note.GNU-stack noalloc noexec nowrite progbits
%endif
