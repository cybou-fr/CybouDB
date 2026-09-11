; Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
; SPDX-License-Identifier: Apache-2.0
; Core integration driver, linked to the real VFS without the CLI.
; Usage: cow_harness <path> <mode>. See cow_tests.py for the scenarios.
%include "cyboudb.inc"
BITS 64
default rel
extern os_argv, os_str_to_u64, os_exit
extern db_create, db_open, db_open_cow, db_close, db_commit
extern db_create_cow
extern db_alloc_page, db_free_page, db_cow_alloc_page, db_cow_copy_page
extern db_cow_write_page, db_cow_set_root, vfs_sync
extern db_catalog_put, db_catalog_get
extern db_pax_insert, db_pax_read, db_pax_update_one, os_write
extern db_zone_lookup, db_zone_stride
extern db_pax_scan_open, db_pax_scan_next
extern vfs_open_ro, vfs_size, vfs_map_ro
global cyboudb_main, test_sync, test_commit_hook

%macro CTX 0
    lea ARG1, [ctx]
%endmacro
%macro REQUIRE 1
    cmp eax, %1
    jne failure
%endmacro

section .bss
align 8
ctx: resb CybouDB_DB_SIZE
mode: resq 1
path: resq 1
page: resq 1
sync_count: resq 1
fault_kind: resq 1
table_id: resq 1
column_type: resq 1
schema_page: resq 1
zone_entry: resq 1
zone_mxcsr_saved: resd 1
zone_mxcsr_after: resd 1
batch: resq 3
row_out: resq 2
row_values: resq 64
row_nulls: resb 64
fixture_handle: resq 1
column_count: resq 1
cursor: resb CybouDB_SCAN_SIZE
scan_out: resq 3
scan_rows: resq 1
update_span: resq 4
update_group: resq 2
; Batch fixture geometry, matching tests/pax_support.py: a row count, then
; FIXTURE_SLOTS u64 value slots, then one NULL byte per slot.
%define FIXTURE_SLOTS 16384
%define FIXTURE_NULLS (8 + FIXTURE_SLOTS * 8)
%define FIXTURE_BYTES (FIXTURE_NULLS + FIXTURE_SLOTS)

scan_values: resq FIXTURE_SLOTS
scan_nulls: resb FIXTURE_SLOTS
payload: resb CybouDB_PAGE_SIZE

section .text
cyboudb_main:
    FRAME_BEGIN 16, 0
    mov ARG1, 1
    call os_argv
    mov [path], rax
    mov ARG1, 2
    call os_argv
    mov ARG1, rax
    lea ARG2, [mode]
    call os_str_to_u64
    test eax, eax
    jz failure

    cmp qword [mode], 20
    jb .args_ready
    mov ARG1, 3
    call os_argv
    test rax, rax
    jz failure
    mov ARG1, rax
    lea ARG2, [table_id]
    call os_str_to_u64
    test eax, eax
    jz failure
    mov qword [column_type], CAT_INT64
    mov ARG1, 4
    call os_argv
    test rax, rax
    jz .args_ready
    mov ARG1, rax
    lea ARG2, [column_type]
    call os_str_to_u64
    test eax, eax
    jz failure
    mov ARG1, 6
    call os_argv
    test rax, rax
    jz .args_ready
    mov ARG1, rax
    lea ARG2, [fault_kind]
    call os_str_to_u64
    test eax, eax
    jz failure
.args_ready:

    cmp qword [mode], 10
    je .create_failure
    mov ARG1, [path]
    lea ARG2, [ctx]
    cmp qword [mode], 8
    je .readonly
    cmp qword [mode], 41
    je .catalog_readonly
    cmp qword [mode], 51
    je .catalog_readonly
    cmp qword [mode], 52
    je .catalog_readonly
    cmp qword [mode], 47
    je .catalog_readonly
    cmp qword [mode], 21
    je .catalog_readonly
    cmp qword [mode], 29
    je .catalog_readonly
    call db_open_cow
    jmp .opened
.catalog_readonly:
    xor ARG3, ARG3
    xor ARG4, ARG4
    call db_open
.opened:
    test eax, eax
    jnz .return                     ; Python checks expected open refusals
    cmp qword [mode], 40
    jae .pax
    cmp qword [mode], 20
    jae .catalog

    cmp qword [mode], 7
    je .guards
    cmp qword [mode], 11
    je .metadata_guards
    cmp qword [mode], 12
    je .root_only
    cmp qword [mode], 13
    je .clear_root
    cmp qword [mode], 14
    je .bad_staged_root
    CTX
    mov ARG2, [ctx + DB_ROOT]
    test ARG2, ARG2
    jz .allocate
    lea ARG3, [page]
    call db_cow_copy_page
    test eax, eax
    jnz .return
    ; Check the complete clone before replacing its contents.
    mov r10, [ctx + DB_ROOT]
    shl r10, CybouDB_PAGE_SHIFT
    add r10, [ctx + DB_BASE]
    mov r11, [page]
    shl r11, CybouDB_PAGE_SHIFT
    add r11, [ctx + DB_BASE]
    mov ecx, CybouDB_PAGE_SIZE / 8
.compare:
    mov rax, [r10]
    cmp rax, [r11]
    jne failure
    add r10, 8
    add r11, 8
    dec ecx
    jnz .compare
    jmp .allocated
.allocate:
    lea ARG2, [page]
    call db_alloc_page              ; dispatches to COW on this handle
    test eax, eax
    jnz .return
.allocated:
    lea r10, [payload]
    mov ecx, CybouDB_PAGE_SIZE / 8
    mov rax, 0xA5A5A5A5A5A5A5A5
.fill:
    mov [r10], rax
    add r10, 8
    dec ecx
    jnz .fill
    CTX
    mov ARG2, [page]
    lea ARG3, [payload]
    call db_cow_write_page
    REQUIRE CybouDB_OK
    CTX
    mov ARG2, [page]
    call db_cow_set_root
    REQUIRE CybouDB_OK

    cmp qword [mode], 0
    je .abrupt
    cmp qword [mode], 2
    je .close
    CTX
    call db_commit
    cmp qword [mode], 3
    je .failed_sync
    cmp qword [mode], 4
    je .failed_sync
    REQUIRE CybouDB_OK
    cmp qword [mode], 6
    jne .close
    ; After commit, every previously writable page is protected.
    CTX
    mov ARG2, [page]
    lea ARG3, [payload]
    call db_cow_write_page
    REQUIRE CybouDB_E_PAGE
    CTX
    mov ARG2, [page]
    lea ARG3, [page]
    call db_cow_copy_page
    REQUIRE CybouDB_OK
    CTX
    mov ARG2, [page]
    call db_cow_set_root
    REQUIRE CybouDB_OK
    CTX
    call db_commit
    REQUIRE CybouDB_OK
    jmp .close

.failed_sync:
    REQUIRE CybouDB_E_SYNC
    cmp qword [mode], 40
    jb .failed_sync_common
    CTX
    mov ARG2, [table_id]
    lea ARG3, [batch]
    call db_pax_insert
    REQUIRE CybouDB_E_STATE
.failed_sync_common:
    CTX
    call db_commit
    REQUIRE CybouDB_E_STATE
    CTX
    lea ARG2, [page]
    call db_alloc_page
    REQUIRE CybouDB_E_STATE
    CTX
    mov ARG2, [page]
    call db_free_page
    REQUIRE CybouDB_E_STATE
    CTX
    mov ARG2, [page]
    lea ARG3, [payload]
    call db_cow_write_page
    REQUIRE CybouDB_E_STATE
    CTX
    mov ARG2, [page]
    call db_cow_set_root
    REQUIRE CybouDB_E_STATE
    cmp qword [mode], 58
    jne .failed_sync_close
    CTX
    call db_close
    xor eax, eax
    jmp .return
.failed_sync_close:
    jmp .close

.guards:
    CTX
    mov ARG2, [ctx + DB_ROOT]
    lea ARG3, [payload]
    call db_cow_write_page
    REQUIRE CybouDB_E_PAGE
    CTX
    mov ARG2, [ctx + DB_ROOT]
    call db_free_page
    REQUIRE CybouDB_E_STATE
    CTX
    mov ARG2, 1
    lea ARG3, [page]
    call db_cow_copy_page
    REQUIRE CybouDB_E_PAGE
    CTX
    mov ARG2, [ctx + DB_ALLOC]
    call db_cow_set_root
    REQUIRE CybouDB_E_PAGE
    jmp .close

.metadata_guards:
    CTX
    lea ARG2, [page]
    call db_alloc_page
    REQUIRE CybouDB_OK
    CTX
    mov ARG2, [ctx + DB_BITMAP]
    lea ARG3, [payload]
    call db_cow_write_page
    REQUIRE CybouDB_E_PAGE
    CTX
    mov ARG2, [ctx + DB_BITMAP]
    lea ARG3, [page]
    call db_cow_copy_page
    REQUIRE CybouDB_E_PAGE
    CTX
    mov ARG2, [ctx + DB_BITMAP]
    call db_cow_set_root
    REQUIRE CybouDB_E_PAGE
    jmp .close
.clear_root:
    CTX
    xor ARG2, ARG2
    call db_cow_set_root
    REQUIRE CybouDB_OK
.root_only:
    CTX
    call db_commit
    REQUIRE CybouDB_OK
    jmp .close
.bad_staged_root:
    ; Simulate a higher-layer bug bypassing the root setter.
    mov rax, [ctx + DB_BITMAP]
    mov [ctx + DB_ROOT], rax
    CTX
    call db_commit
    REQUIRE CybouDB_E_BITMAP
    jmp .close

.pax:
    cmp qword [mode], 41
    je .pax_read
    cmp qword [mode], 51
    je .pax_scan
    cmp qword [mode], 52
    je .zone_dump
    mov ARG1, 5
    call os_argv
    test rax, rax
    jz failure
    mov ARG1, rax
    xor ARG2, ARG2
    call vfs_open_ro
    cmp rax, -1
    je failure
    mov [fixture_handle], rax
    mov ARG1, rax
    call vfs_size
    cmp rax, FIXTURE_BYTES
    jne failure
    mov ARG1, [fixture_handle]
    mov ARG2, rax
    call vfs_map_ro
    test rax, rax
    jz failure
    mov rdx, [rax]
    mov [batch + BATCH_ROWS], rdx
    lea rdx, [rax + 8]
    mov [batch + BATCH_VALUES], rdx
    add rax, FIXTURE_NULLS
    cmp qword [mode], 48
    jne .pax_nulls
    xor eax, eax
.pax_nulls:
    mov [batch + BATCH_NULLS], rax
    ; Mode 53 inserts raw FLOAT32 fixtures under the MXCSR supplied in arg4.
    ; Check flags as well as controls, and restore the caller's environment.
    cmp qword [mode], 53
    jne .pax_environment_ready
    stmxcsr [zone_mxcsr_saved]
    ldmxcsr [column_type]
.pax_environment_ready:
    CTX
    mov ARG2, [table_id]
    lea ARG3, [batch]
    cmp qword [mode], 58
    je .pax_inserted
    call db_pax_insert
    cmp qword [mode], 53
    jne .pax_environment_checked
    stmxcsr [zone_mxcsr_after]
    ldmxcsr [zone_mxcsr_saved]
    mov edx, [column_type]
    cmp edx, [zone_mxcsr_after]
    jne failure
.pax_environment_checked:
    test eax, eax
    jnz .return
    cmp qword [mode], 46
    jne .pax_inserted
    CTX
    mov ARG2, [table_id]
    lea ARG3, [batch]
    call db_pax_insert
    REQUIRE CybouDB_OK
.pax_inserted:
    cmp qword [mode], 54
    je .pax_update
    cmp qword [mode], 58
    jne .pax_not_update
.pax_update:
    CTX
    mov ARG2, [table_id]
    mov ARG3, [column_type]
    mov ARG4, 99
    xor rax, rax
    PASS_ARG5 rax
    mov qword [update_span + UPDATE_SPAN_START], 0
    mov qword [update_span + UPDATE_SPAN_MASK], 2
    mov qword [update_span + UPDATE_SPAN_SIZE + UPDATE_SPAN_START], 2
    mov qword [update_span + UPDATE_SPAN_SIZE + UPDATE_SPAN_MASK], 1
    lea rax, [update_span]
    mov [update_group + UPDATE_GROUP_SPANS], rax
    mov qword [update_group + UPDATE_GROUP_COUNT], 2
    lea rax, [update_group]
    PASS_ARG6 rax
    call db_pax_update_one
    test eax, eax
    jnz .return
.pax_not_update:
    cmp qword [mode], 42
    je .abrupt
    cmp qword [mode], 49
    je .pax_corrupt
    cmp qword [mode], 50
    jne .pax_commit
.pax_corrupt:
    CTX
    mov ARG2, [table_id]
    lea ARG3, [page]
    call db_catalog_get
    REQUIRE CybouDB_OK
    mov rax, [page]
    shl rax, CybouDB_PAGE_SHIFT
    add rax, [ctx + DB_BASE]
    mov rax, [rax + CAT_DATA_ROOT]
    shl rax, CybouDB_PAGE_SHIFT
    add rax, [ctx + DB_BASE]
    cmp qword [mode], 50
    jne .pax_corrupt_page
    test qword [ctx + DB_FEATURES], CybouDB_FEATURE_PAX_MULTI
    jz .pax_corrupt_page
    ; Corrupt the last leaf: unlike full prefix leaves, it belongs to this txn.
    cmp dword [rax + PAX_DIR_LEVEL], PAX_DIR_ROOT
    jne .pax_last_leaf
    mov ecx, [rax + PAX_COLUMNS]
    dec ecx
    shl rcx, 4
    mov rax, [rax + PAX_DIRECTORY + rcx]
    shl rax, CybouDB_PAGE_SHIFT
    add rax, [ctx + DB_BASE]
.pax_last_leaf:
    mov ecx, [rax + PAX_COLUMNS]
    dec ecx
    shl rcx, 4
    mov rax, [rax + PAX_DIRECTORY + rcx]
    shl rax, CybouDB_PAGE_SHIFT
    add rax, [ctx + DB_BASE]
.pax_corrupt_page:
    xor byte [rax + PAX_CRC], 1
.pax_commit:
    CTX
    call db_commit
    cmp qword [mode], 49
    je .pax_bad_commit
    cmp qword [mode], 50
    jne .pax_committed
.pax_bad_commit:
    REQUIRE CybouDB_E_BITMAP
    jmp .close
.pax_committed:
    cmp qword [mode], 43
    je .failed_sync
    cmp qword [mode], 44
    je .failed_sync
    cmp qword [mode], 58
    jne .pax_commit_status_ready
    cmp qword [fault_kind], 3
    je .failed_sync
    cmp qword [fault_kind], 4
    je .failed_sync
.pax_commit_status_ready:
    REQUIRE CybouDB_OK
    jmp .close
.pax_read:
    CTX
    mov ARG2, [table_id]
    lea ARG3, [page]
    call db_catalog_get
    test eax, eax
    jnz .return
    mov rax, [page]
    shl rax, CybouDB_PAGE_SHIFT
    add rax, [ctx + DB_BASE]
    mov eax, [rax + CAT_COUNT]
    mov [column_count], rax
    lea rax, [row_values]
    mov [row_out + ROW_VALUES], rax
    lea rax, [row_nulls]
    mov [row_out + ROW_NULLS], rax
    CTX
    mov ARG2, [table_id]
    mov ARG3, [column_type]
    lea ARG4, [row_out]
    call db_pax_read
    test eax, eax
    jnz .return
    lea ARG1, [row_values]
    mov ARG2, [column_count]
    shl ARG2, 3
    call os_write
    lea ARG1, [row_nulls]
    mov ARG2, [column_count]
    call os_write
    jmp .close

; Print the zone statistics of leaf argv[4], or nothing when the table keeps
; none for it: one leaf's worth of raw entries, for Python to decode.
.zone_dump:
    CTX
    mov ARG2, [table_id]
    lea ARG3, [page]
    call db_catalog_get
    test eax, eax
    jnz .return
    mov rax, [page]
    shl rax, CybouDB_PAGE_SHIFT
    add rax, [ctx + DB_BASE]
    mov [schema_page], rax
    CTX
    mov ARG2, rax
    mov ARG3, [column_type]
    call db_zone_lookup
    mov [zone_entry], rax
    test rax, rax
    jz .close
    mov ARG1, [schema_page]
    call db_zone_stride
    mov ARG2, rax
    mov ARG1, [zone_entry]
    call os_write
    jmp .close

; Scan the whole table in blocks of argv[4] rows and print every cell.
.pax_scan:
    lea rax, [scan_values]
    mov [scan_out + SCAN_VALUES], rax
    lea rax, [scan_nulls]
    mov [scan_out + SCAN_NULLS], rax
    mov rax, [column_type]
    mov [scan_out + SCAN_MAX], rax
    CTX
    mov ARG2, [table_id]
    lea ARG3, [cursor]
    call db_pax_scan_open
    test eax, eax
    jnz .return
    mov rax, [cursor + SCAN_COLUMNS]
    mov [column_count], rax
.scan_block:
    lea ARG1, [cursor]
    lea ARG2, [scan_out]
    call db_pax_scan_next
    test eax, eax
    jnz .return
    test rdx, rdx
    jz .close
    mov [scan_rows], rdx
    lea ARG1, [scan_values]
    mov ARG2, [scan_rows]
    imul ARG2, [column_count]
    shl ARG2, 3
    call os_write
    lea ARG1, [scan_nulls]
    mov ARG2, [scan_rows]
    imul ARG2, [column_count]
    call os_write
    jmp .scan_block

.catalog:
    cmp qword [mode], 21
    je .catalog_get
    lea r10, [payload + CAT_TABLE_NAME]
    mov byte [r10], 't'
    mov rax, [table_id]
    cmp qword [mode], 31
    jne .name_known
    mov eax, 1                      ; duplicate-name input for tests
.name_known:
    mov ecx, 16
.hex_name:
    mov rdx, rax
    and edx, 15
    add edx, '0'
    cmp edx, '9'
    jbe .hex_digit
    add edx, 7
.hex_digit:
    mov [r10 + rcx], dl
    shr rax, 4
    dec ecx
    jnz .hex_name
    mov dword [payload + CAT_COUNT], 1
    mov rax, [column_type]
    mov [payload + CAT_COLUMNS], eax
    mov dword [payload + CAT_COLUMNS + 8], 'valu'
    mov byte [payload + CAT_COLUMNS + 12], 'e'
    CTX
    mov ARG2, [table_id]
    lea ARG3, [payload]
    call db_catalog_put
    test eax, eax
    jnz .return
    cmp qword [mode], 26
    jne .catalog_put_done
    mov dword [payload + CAT_COLUMNS], CAT_BOOL
    CTX
    mov ARG2, [table_id]
    lea ARG3, [payload]
    call db_catalog_put
    REQUIRE CybouDB_OK
.catalog_put_done:
    CTX
    mov ARG2, [table_id]
    lea ARG3, [page]
    call db_catalog_get
    REQUIRE CybouDB_OK
    cmp qword [mode], 22
    je .abrupt
    cmp qword [mode], 30
    jne .catalog_commit
    mov rax, [page]
    shl rax, CybouDB_PAGE_SHIFT
    add rax, [ctx + DB_BASE]
    xor byte [rax + CAT_TABLE_NAME], 1
.catalog_commit:
    CTX
    call db_commit
    cmp qword [mode], 23
    je .failed_sync
    cmp qword [mode], 24
    je .failed_sync
    cmp qword [mode], 30
    jne .catalog_ok
    REQUIRE CybouDB_E_BITMAP
    jmp .close
.catalog_ok:
    REQUIRE CybouDB_OK
    jmp .close
.catalog_get:
    CTX
    mov ARG2, [table_id]
    lea ARG3, [page]
    call db_catalog_get
    jmp .return

.readonly:
    xor ARG3, ARG3
    xor ARG4, ARG4
    call db_open
    REQUIRE CybouDB_OK
    CTX
    lea ARG2, [page]
    call db_cow_alloc_page
    REQUIRE CybouDB_E_READONLY
    CTX
    mov ARG2, [ctx + DB_ROOT]
    lea ARG3, [payload]
    call db_cow_write_page
    REQUIRE CybouDB_E_READONLY
    CTX
    xor ARG2, ARG2
    call db_cow_set_root
    REQUIRE CybouDB_E_READONLY
    jmp .close

.create_failure:
    mov ARG1, [path]
    mov ARG2, 16
    xor ARG3, ARG3
    call db_create_cow
    REQUIRE CybouDB_E_SYNC
    xor eax, eax
    jmp .return
.abrupt:
    ; Force writeback BEFORE publication, then terminate without close.
    mov ARG1, [ctx + DB_HANDLE]
    mov ARG2, [ctx + DB_BASE]
    mov ARG3, [ctx + DB_SIZE]
    call vfs_sync
    REQUIRE 0
    xor ARG1, ARG1
    call os_exit
.close:
    CTX
    call db_close
    CTX
    lea ARG2, [page]
    call db_cow_alloc_page
    REQUIRE CybouDB_E_READONLY
    xor eax, eax
.return:
    FRAME_END
    ret

failure:
    mov ARG1, 99
    call os_exit

; Core-test-only db_commit hook. Fault kinds mirror the historical sync modes:
; 3 fails the data barrier, 4 fails publication, 5 tears the inactive copy.
test_commit_hook:
    mov rax, [fault_kind]
    test rax, rax
    jz .commit_hook_ok
    cmp rax, 3
    jne .commit_hook_publish
    cmp ARG1, 1
    jne .commit_hook_ok
    mov eax, 1
    ret
.commit_hook_publish:
    cmp ARG1, 2
    jne .commit_hook_ok
    cmp rax, 4
    je .commit_hook_fail
    cmp rax, 5
    jne .commit_hook_ok
    mov r10, CybouDB_SB_PAGE_A + CybouDB_SB_PAGE_B
    sub r10, [ctx + DB_SB_PAGE]
    shl r10, CybouDB_PAGE_SHIFT
    add r10, [ctx + DB_BASE]
    mov dword [r10], 0
    FRAME_BEGIN 0, 0
    mov ARG1, [ctx + DB_HANDLE]
    mov ARG2, [ctx + DB_BASE]
    mov ARG3, [ctx + DB_SIZE]
    call vfs_sync
    xor ARG1, ARG1
    call os_exit
.commit_hook_fail:
    mov eax, 1
    ret
.commit_hook_ok:
    xor eax, eax
    ret

; Only database.asm calls this shim; real VFS calls remain available above.
test_sync:
    inc qword [sync_count]
    mov rax, [mode]
    cmp rax, 40
    jb .catalog_mode
    sub rax, 40
    jmp .mode_known
.catalog_mode:
    cmp rax, 20
    jb .mode_known
    sub rax, 20
.mode_known:
    cmp qword [mode], 10
    je .fail
    cmp rax, 3
    jne .second
    cmp qword [sync_count], 1
    je .fail
.second:
    cmp qword [sync_count], 2
    jne .real
    cmp rax, 4
    je .fail
    cmp rax, 5
    jne .real
    FRAME_BEGIN 0, 0
    ; Simulate a torn inactive superblock, flush and terminate.
    mov r10, CybouDB_SB_PAGE_A + CybouDB_SB_PAGE_B
    sub r10, [ctx + DB_SB_PAGE]
    shl r10, CybouDB_PAGE_SHIFT
    add r10, [ctx + DB_BASE]
    mov dword [r10], 0
    call vfs_sync
    xor ARG1, ARG1
    call os_exit
.real:
    jmp vfs_sync
.fail:
    mov rax, -1
    ret
