; Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
; SPDX-License-Identifier: Apache-2.0
; =============================================================================
;  core/database.asm - Core: create, validate, open, allocate and commit
; =============================================================================
;  The layer between the CLI and the OS layer. There is not a single system
;  call and not a single line of output here: only work on the file format
;  through the VFS interface. That is what lets this module build unchanged
;  across operating systems - any OS whose platform layer provides the VFS
;  entry points.
;
;  It is NOT architecture-neutral, and must not be described as such: this is
;  x86-64 NASM assembly. What is portable is the design - the on-disk format,
;  the page semantics and the db_* contract. An AArch64 build needs its own
;  implementation of this file in AArch64 assembly, built with a different
;  assembler, since NASM targets x86 only.
;
;  Public interface:
;      db_create(path, pages, force)   -> RAX = CybouDB_OK or an error code
;      db_create_cow(path, pages, force) -> creates immutable COW capability
;      db_open(path, ctx, writable, exhaustive) -> RAX = CybouDB_OK or error
;      db_alloc_page(ctx, out_page)    -> RAX = CybouDB_OK or an error code
;      db_free_page(ctx, page)         -> RAX = CybouDB_OK or an error code
;      db_commit(ctx)                  -> RAX = CybouDB_OK or an error code
;      db_close(ctx)                   -> drops the mapping and closes the file
;
;  ctx points at an CybouDB_DB structure (CybouDB_DB_SIZE bytes) that the caller
;  owns. Allocation and freeing only change that structure and the free-list
;  records inside the shared mapping. These writes can persist before commit;
;  only descriptor metadata waits for superblock publication.
;
;  db_open is deliberately paranoid. A storage engine that accepts a damaged
;  file and reports "OK" is worse than one that refuses to open it, so every
;  field the format defines is checked before the database is handed back:
;  signature, version, page size, header checksum, feature bits, both
;  superblock copies and the agreement between the page counts and the actual
;  size of the file on disk.
; =============================================================================

%include "cyboudb.inc"

BITS 64
default rel

extern vfs_create_new, vfs_create_truncate, vfs_open_ro, vfs_open_rw
extern vfs_size, vfs_resize, vfs_map_rw, vfs_map_ro, vfs_unmap
extern vfs_sync, vfs_close
extern vfs_lock_writer, vfs_lock_reader
%ifdef CybouDB_TEST_COMMIT_HOOK
extern test_commit_hook
%endif
extern crc32c
extern db_cow_alloc_page
extern db_bitmap_init, db_bitmap_validate, db_bitmap_seal
extern db_bitmap_leaves, db_bitmap_recount

global db_create, db_open, db_alloc_page, db_free_page, db_commit, db_rollback, db_close
global db_create_tombstones
global db_create_default
global db_create_cow
global db_create_catalog
global db_create_pax, db_create_pax_multi
global db_create_large, db_create_compressed

section .data
; Pages handed to the flush at commit. The commit flushes one contiguous
; range, so this is the distance between the lowest and highest page a
; transaction touched - not the number it actually wrote.
global pages_flushed
pages_flushed: dq 0

section .text

; -----------------------------------------------------------------------------
;  db_create(ARG1 = path, ARG2 = page count, ARG3 = force) -> RAX: result code
;
;  Creates the file, sizes it to pages * PAGE_SIZE, then lays out the metadata
;  straight in the mapping: the immutable header on page 0 and two identical
;  copies of generation 1 of the superblock on pages 1 and 2.
;
;  Creating is non-destructive. With force = 0 an existing path is refused, so
;  a mistyped database name cannot wipe out a database; force = 1 is the
;  caller saying it really means to replace the file.
;
;  The refusal comes from vfs_create_new itself rather than from a preceding
;  existence check, so there is no window between looking and creating.
;
;  Local slots: [rbp-8]=path, [rbp-16]=pages, [rbp-24]=handle,
;               [rbp-32]=size, [rbp-40]=base, [rbp-48]=force,
;               [rbp-56]=why the OS refused, [rbp-64]=creation capabilities,
;               [rbp-64-CybouDB_DB_SIZE .. rbp-65] = a temporary descriptor used
;               only to feed write_superblock
; -----------------------------------------------------------------------------
%define CREATE_CTX (-64 - CybouDB_DB_SIZE)

db_create:
    xor     eax, eax
    jmp     create_common
db_create_cow:
    mov     eax, CybouDB_FEATURE_COW
    jmp     create_common
db_create_catalog:
    mov     eax, CybouDB_FEATURE_COW | CybouDB_FEATURE_CATALOG
    jmp     create_common
; Databases created from here on carry CybouDB_FEATURE_PAX_RUNS. One written by
; an older build does not, keeps the sparser leaf layout, and still opens: the
; bit is what tells pax_capacity which arithmetic that file was written with.
db_create_pax_multi:
    mov eax, CybouDB_FEATURE_COW | CybouDB_FEATURE_CATALOG | CybouDB_FEATURE_PAX | CybouDB_FEATURE_PAX_MULTI | CybouDB_FEATURE_PAX_RUNS | CybouDB_FEATURE_PAX_TREE | CybouDB_FEATURE_ZONE_MAPS
    jmp create_common
db_create_pax:
    mov     eax, CybouDB_FEATURE_COW | CybouDB_FEATURE_CATALOG | CybouDB_FEATURE_PAX
    jmp     create_common
db_create_large:
    mov eax, CybouDB_FEATURE_COW | CybouDB_FEATURE_CATALOG | CybouDB_FEATURE_PAX | CybouDB_FEATURE_PAX_MULTI | CybouDB_FEATURE_MAP_SPAN | CybouDB_FEATURE_PAX_RUNS | CybouDB_FEATURE_PAX_TREE | CybouDB_FEATURE_ZONE_MAPS | CybouDB_FEATURE_VARLEN | CybouDB_FEATURE_VECTOR | CybouDB_FEATURE_INDEX | CybouDB_FEATURE_QUEUE | CybouDB_FEATURE_STREAM
    jmp create_common
db_create_compressed:
    mov eax, CybouDB_FEATURE_COW | CybouDB_FEATURE_CATALOG | CybouDB_FEATURE_PAX | CybouDB_FEATURE_PAX_MULTI | CybouDB_FEATURE_PAX_RUNS | CybouDB_FEATURE_PAX_TREE | CybouDB_FEATURE_ZONE_MAPS | CybouDB_FEATURE_MAP_SPAN | CybouDB_FEATURE_COMPRESSION
    jmp create_common
; Everything create-large has, plus the per-row tombstone reservation. A
; separate creator rather than a bit added to create-large: the reservation
; changes how many rows a leaf holds, so it would move every existing
; database's layout out from under files that already exist.
;
; This is also the profile a caller who was not asked gets: db_create_default
; is the same entry point, and cyboudb_create uses it. The reservation can only
; be made at creation - docs/TOMBSTONES.md, there is no in-place upgrade - so a
; library creating files without it would hand every one of its users a
; database whose DELETE can only ever rewrite the table. The other creators
; exist to test the format at the stages it grew through; this one is what a
; user should get.
db_create_default:
db_create_tombstones:
    mov eax, CybouDB_FEATURE_COW | CybouDB_FEATURE_CATALOG | CybouDB_FEATURE_PAX | CybouDB_FEATURE_PAX_MULTI | CybouDB_FEATURE_MAP_SPAN | CybouDB_FEATURE_PAX_RUNS | CybouDB_FEATURE_PAX_TREE | CybouDB_FEATURE_ZONE_MAPS | CybouDB_FEATURE_VARLEN | CybouDB_FEATURE_VECTOR | CybouDB_FEATURE_TOMBSTONES | CybouDB_FEATURE_INDEX | CybouDB_FEATURE_QUEUE | CybouDB_FEATURE_STREAM
    jmp create_common
create_common:
    FRAME_BEGIN 64 + CybouDB_DB_SIZE, 0
    mov     [rbp - 64], rax
    mov     [rbp - 8], ARG1
    mov     [rbp - 16], ARG2
    mov     [rbp - 48], ARG3

    test    eax, eax
    jz      .legacy_size
    test    eax, CybouDB_FEATURE_MAP_SPAN
    jnz     .span_size
    cmp     ARG2, CybouDB_COW_MIN_PAGES
    jb      .e_cow_pages
    cmp     ARG2, CybouDB_COW_MAX_PAGES
    ja      .e_cow_pages
    jmp     .legacy_size
.span_size:
    mov     r10, CybouDB_SPAN_MAX_PAGES
    cmp     ARG2, r10
    ja      .e_cow_pages
    mov     ARG1, ARG2
    call    db_bitmap_leaves
    shl     rax, 1
    add     rax, CybouDB_MIN_PAGES         ; both map copies plus the fixed pages
    mov     ARG1, [rbp - 8]
    mov     ARG2, [rbp - 16]
    cmp     ARG2, rax
    jbe     .e_cow_pages                ; nothing would be left for payload
.legacy_size:

    ; --- validate the page count --------------------------------------------
    cmp     ARG2, CybouDB_MIN_PAGES
    jb      .e_pages                    ; header plus two superblocks at least
    mov     r10, CybouDB_MAX_PAGES
    cmp     ARG2, r10
    ja      .e_pages                    ; else pages * 4096 overflows 64 bits

    mov     rax, ARG2
    PAGES_TO_BYTES rax
    mov     [rbp - 32], rax

    ; --- create the file, unless something is already there ------------------
    mov     qword [rbp - 56], CybouDB_OSERR_NONE
    mov     ARG1, [rbp - 8]
    lea     ARG2, [rbp - 56]
    cmp     qword [rbp - 48], 0
    jne     .create_forced
    call    vfs_create_new              ; refuses a path that is taken
    jmp     .created
.create_forced:
    call    vfs_create_truncate         ; destructive, asked for explicitly
.created:
    cmp     rax, -1
    je      .e_create
    mov     [rbp - 24], rax

    ; --- give the file its size, then map it ---------------------------------
    mov     ARG1, [rbp - 24]
    mov     ARG2, [rbp - 32]
    call    vfs_resize
    cmp     rax, -1
    je      .e_create_close

    mov     ARG1, [rbp - 24]
    mov     ARG2, [rbp - 32]
    call    vfs_map_rw
    test    rax, rax
    jz      .e_map_close
    mov     [rbp - 40], rax

    ; --- page 0: the immutable file header ----------------------------------
    mov     r10, rax
    xor     eax, eax
    mov     ecx, CybouDB_HDR_SIZE / 8      ; zero the defined header bytes, the
.zero_hdr:                              ; reserved field included
    mov     [r10], rax
    add     r10, 8
    dec     ecx
    jnz     .zero_hdr

    mov     r10, [rbp - 40]
    mov     dword [r10 + HDR_MAGIC],       CybouDB_MAGIC
    mov     dword [r10 + HDR_HEADER_SIZE], CybouDB_HDR_SIZE
    mov     dword [r10 + HDR_VERSION],     CybouDB_VERSION
    mov     dword [r10 + HDR_PAGE_SIZE],   CybouDB_PAGE_SIZE
    mov     qword [r10 + HDR_SB_PAGE_A],   CybouDB_SB_PAGE_A
    mov     qword [r10 + HDR_SB_PAGE_B],   CybouDB_SB_PAGE_B
    mov     rax, [rbp - 64]
    mov     [r10 + HDR_FLAGS_INCOMPAT], rax
    ; UUID and reserved stay zero.

    mov     ARG1, r10
    mov     ARG2, HDR_CRC_LEN
    call    crc32c
    mov     r10, [rbp - 40]
    mov     [r10 + HDR_CRC], eax

    ; --- describe the fresh database, then stamp both superblock copies ------
    lea     r10, [rbp + CREATE_CTX]
    xor     eax, eax
    mov     ecx, CybouDB_DB_SIZE / 8
.zero_tmp:
    mov     [r10], rax
    add     r10, 8
    dec     ecx
    jnz     .zero_tmp
    lea     r10, [rbp + CREATE_CTX]
    mov     rax, [rbp - 16]
    mov     [r10 + DB_PAGES], rax
    mov     qword [r10 + DB_ALLOC], CybouDB_MIN_PAGES   ; 0, 1 and 2 are in use
    mov     qword [r10 + DB_FREELIST], 0
    mov     rax, [rbp - 64]
    mov     [r10 + DB_FEATURES], rax
    test    rax, rax
    jz      .map_ready
    mov     qword [r10 + DB_BITMAP], CybouDB_MIN_PAGES
    mov     ARG1, [rbp - 40]
    mov     ARG2, [rbp - 16]
    mov     ARG3, [rbp - 64]
    call    db_bitmap_init
    lea     r10, [rbp + CREATE_CTX]
    mov     [r10 + DB_ALLOC], rax
.map_ready:

    mov     ARG1, [rbp - 40]
    add     ARG1, CybouDB_SB_PAGE_A * CybouDB_PAGE_SIZE
    lea     ARG2, [rbp + CREATE_CTX]
    mov     ARG3, 1                     ; generation
    call    write_superblock

    mov     ARG1, [rbp - 40]
    add     ARG1, CybouDB_SB_PAGE_B * CybouDB_PAGE_SIZE
    lea     ARG2, [rbp + CREATE_CTX]
    mov     ARG3, 1
    call    write_superblock

    ; --- push the metadata out before reporting success ---------------------
    mov     ARG1, [rbp - 24]
    mov     ARG2, [rbp - 40]
    mov     ARG3, [rbp - 32]
    call    vfs_sync

    mov     [rbp - 48], rax            ; preserve sync status across cleanup

    mov     ARG1, [rbp - 40]
    mov     ARG2, [rbp - 32]
    call    vfs_unmap
    mov     ARG1, [rbp - 24]
    call    vfs_close

    mov     eax, CybouDB_OK
    cmp     qword [rbp - 48], -1
    jne     .create_done
    mov     eax, CybouDB_E_SYNC
.create_done:
    FRAME_END
    ret

.e_map_close:
    mov     ARG1, [rbp - 24]
    call    vfs_close
    mov     eax, CybouDB_E_MAP
    FRAME_END
    ret
.e_create_close:
    mov     ARG1, [rbp - 24]
    call    vfs_close
    mov     eax, CybouDB_E_CREATE
    FRAME_END
    ret
.e_create:
    mov     ARG1, [rbp - 56]            ; say what the OS actually objected to
    mov     ARG2, CybouDB_E_CREATE
    call    oserr_to_code
    FRAME_END
    ret
.e_pages:
    mov     eax, CybouDB_E_PAGES
    FRAME_END
    ret
.e_cow_pages:
    mov     eax, CybouDB_E_COW_PAGES
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  oserr_to_code(ARG1 = CybouDB_OSERR_* value, ARG2 = code to use otherwise)
;      -> RAX: the CybouDB_E_* code to report
;
;  Internal. The platform layer says what kind of thing went wrong; this turns
;  that into the error the caller sees. Anything the layer could not classify
;  falls back to the caller's own code, so "cannot open file" survives as the
;  answer for the cases nobody has a better word for.
; -----------------------------------------------------------------------------
oserr_to_code:
    mov     rax, ARG2                   ; the fallback, unless we know better
    cmp     ARG1, CybouDB_OSERR_NOENT
    je      .noent
    cmp     ARG1, CybouDB_OSERR_ACCESS
    je      .access
    cmp     ARG1, CybouDB_OSERR_EXISTS
    je      .exists
    cmp     ARG1, CybouDB_OSERR_BUSY
    je      .busy
    ret
.noent:
    mov     eax, CybouDB_E_NOENT
    ret
.access:
    mov     eax, CybouDB_E_ACCESS
    ret
.exists:
    mov     eax, CybouDB_E_EXISTS
    ret
.busy:
    mov     eax, CybouDB_E_BUSY
    ret

; -----------------------------------------------------------------------------
;  write_superblock(ARG1 = destination address, ARG2 = descriptor,
;                   ARG3 = generation)
;  Internal. Lays out one superblock copy from a descriptor and seals it with
;  its checksum. Both db_create and db_commit go through here, so there is
;  exactly one place that knows how a superblock is built.
;
;  Local slots: [rbp-8]=destination, [rbp-16]=descriptor, [rbp-24]=generation
; -----------------------------------------------------------------------------
write_superblock:
    FRAME_BEGIN 32, 0
    mov     [rbp - 8], ARG1
    mov     [rbp - 16], ARG2
    mov     [rbp - 24], ARG3

    mov     r10, ARG1
    xor     eax, eax
    mov     ecx, CybouDB_SB_SIZE / 8
.zero:
    mov     [r10], rax
    add     r10, 8
    dec     ecx
    jnz     .zero

    mov     r10, [rbp - 8]
    mov     r11, [rbp - 16]
    mov     dword [r10 + SB_MAGIC], CybouDB_SB_MAGIC
    mov     dword [r10 + SB_SIZE],  CybouDB_SB_SIZE
    mov     rax, [rbp - 24]
    mov     [r10 + SB_GENERATION], rax
    mov     rax, [r11 + DB_PAGES]
    mov     [r10 + SB_TOTAL_PAGES], rax
    mov     rax, [r11 + DB_ALLOC]
    mov     [r10 + SB_ALLOC_PAGES], rax
    mov     rax, [r11 + DB_FREELIST]
    mov     [r10 + SB_FREELIST_ROOT], rax
    mov     rax, [r11 + DB_ROOT]
    mov     [r10 + SB_ROOT_PAGE], rax
    mov     rax, [r11 + DB_BITMAP]
    mov     [r10 + SB_BITMAP_ROOT], rax
    ; Reserved fields stay zero in format v1.

    mov     ARG1, [rbp - 8]
    mov     ARG2, SB_CRC_LEN
    call    crc32c
    mov     r10, [rbp - 8]
    mov     [r10 + SB_CRC], eax

    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  sb_valid(ARG1 = address) -> RAX: 1 when this superblock copy verifies
;  Internal. Checks the signature, the declared size, the reserved region and
;  the checksum. The staged marker lives inside that region, so a superblock
;  claiming to be a writer's scratch candidate cannot come off the disk.
;
;  Local slots: [rbp-8]=address
; -----------------------------------------------------------------------------
sb_valid:
    FRAME_BEGIN 16, 0
    mov     [rbp - 8], ARG1

    mov     r10, ARG1
    cmp     dword [r10 + SB_MAGIC], CybouDB_SB_MAGIC
    jne     .bad
    cmp     dword [r10 + SB_SIZE], CybouDB_SB_SIZE
    jne     .bad
    mov     ecx, SB_RESERVED_TAIL_SIZE / 8
    lea     r11, [r10 + SB_RESERVED_TAIL]
.reserved:
    cmp     qword [r11], 0
    jne     .bad
    add     r11, 8
    dec     ecx
    jnz     .reserved
    cmp     dword [r10 + SB_STAGED], 0
    jne     .bad

    mov     ARG1, [rbp - 8]
    mov     ARG2, SB_CRC_LEN
    call    crc32c
    mov     r10, [rbp - 8]
    cmp     [r10 + SB_CRC], eax
    jne     .bad

    mov     eax, 1
    FRAME_END
    ret
.bad:
    xor     eax, eax
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  db_open(ARG1 = path, ARG2 = descriptor, ARG3 = writable,
;          ARG4 = check every page, not only the newest generation's)
;  -> RAX: result code
;
;  Opens an existing file, maps it whole and validates it. With
;  writable = 0 the OS is only asked for read permission, so a database the
;  user cannot write can still be inspected and a stray store into the mapping
;  faults instead of corrupting the file. On any failure it releases
;  everything it acquired, so the caller has nothing to clean up.
;
;  Local slots: [rbp-8]=path,   [rbp-16]=ctx,   [rbp-24]=base, [rbp-32]=size
;               [rbp-40]=sb A,  [rbp-48]=sb B,  [rbp-56]=chosen sb
;               [rbp-64]=chosen sb page, [rbp-72]=gen A, [rbp-80]=gen B
;               [rbp-88]=writable, [rbp-96]=why the OS refused,
;               [rbp-104]=exhaustive verification
; -----------------------------------------------------------------------------
db_open:
    FRAME_BEGIN 112, 0
    mov     [rbp - 8], ARG1
    mov     [rbp - 16], ARG2
    mov     [rbp - 88], ARG3
    mov     [rbp - 104], ARG4

    ; --- reset the descriptor so db_close is safe in every case --------------
    ;  The handle slot starts at -1, not 0: on Linux descriptor 0 is a
    ;  perfectly valid file if stdin was closed before the open, and treating
    ;  it as "nothing to close" would leak it.
    mov     r10, ARG2
    xor     eax, eax
    mov     ecx, CybouDB_DB_SIZE / 8
.zero_ctx:
    mov     [r10], rax
    add     r10, 8
    dec     ecx
    jnz     .zero_ctx
    mov     r10, ARG2
    mov     qword [r10 + DB_HANDLE], -1
    mov     rax, [rbp - 88]
    mov     [r10 + DB_WRITABLE], rax
    mov     rax, [rbp - 104]
    mov     [r10 + DB_VERIFY], rax

    mov     qword [rbp - 96], CybouDB_OSERR_NONE
    mov     ARG1, [rbp - 8]
    lea     ARG2, [rbp - 96]
    cmp     qword [rbp - 88], 0
    jne     .open_rw
    call    vfs_open_ro
    jmp     .opened
.open_rw:
    call    vfs_open_rw
.opened:
    cmp     rax, -1
    je      .e_open
    mov     r10, [rbp - 16]
    mov     [r10 + DB_HANDLE], rax
    cmp     qword [rbp - 88], 0
    je      .lock_reader
    mov     ARG1, rax
    call    vfs_lock_writer
    cmp     rax, -1
    je      .e_busy_close
    jmp     .writer_lock_ready
.lock_reader:
    mov     ARG1, rax
    call    vfs_lock_reader
    cmp     rax, -1
    je      .e_busy_close
.writer_lock_ready:
    mov     r10, [rbp - 16]
    mov     ARG1, [r10 + DB_HANDLE]
    call    vfs_size
    cmp     rax, -1
    je      .e_size
    mov     [rbp - 32], rax
    mov     r10, [rbp - 16]
    mov     [r10 + DB_SIZE], rax
    cmp     rax, CybouDB_HDR_SIZE
    jb      .e_small                    ; the header does not even fit

    mov     ARG1, [r10 + DB_HANDLE]
    mov     ARG2, rax
    cmp     qword [rbp - 88], 0
    jne     .map_rw
    call    vfs_map_ro
    jmp     .mapped
.map_rw:
    call    vfs_map_rw
.mapped:
    test    rax, rax
    jz      .e_map
    mov     [rbp - 24], rax
    mov     r10, [rbp - 16]
    mov     [r10 + DB_BASE], rax

    ; =========================== page 0: file header ========================
    mov     r10, [rbp - 24]
    cmp     dword [r10 + HDR_MAGIC], CybouDB_MAGIC
    jne     .e_magic
    cmp     dword [r10 + HDR_VERSION], CybouDB_VERSION
    jne     .e_version
    ; Version 1 pins the header to exactly CybouDB_HDR_SIZE bytes.
    cmp     dword [r10 + HDR_HEADER_SIZE], CybouDB_HDR_SIZE
    jne     .e_version
    cmp     dword [r10 + HDR_PAGE_SIZE], CybouDB_PAGE_SIZE
    jne     .e_pagesize

    mov     ARG1, r10
    mov     ARG2, HDR_CRC_LEN
    call    crc32c
    mov     r10, [rbp - 24]
    cmp     [r10 + HDR_CRC], eax
    jne     .e_hdr_crc

    ; A feature bit we do not know about may change the meaning of anything
    ; below, so refuse rather than guess.
    mov     rax, [r10 + HDR_FLAGS_INCOMPAT]
    test    rax, ~(CybouDB_FEATURE_COW | CybouDB_FEATURE_CATALOG | CybouDB_FEATURE_PAX | CybouDB_FEATURE_PAX_MULTI | CybouDB_FEATURE_MAP_SPAN | CybouDB_FEATURE_PAX_RUNS | CybouDB_FEATURE_PAX_TREE | CybouDB_FEATURE_ZONE_MAPS | CybouDB_FEATURE_COMPRESSION | CybouDB_FEATURE_VARLEN | CybouDB_FEATURE_VECTOR | CybouDB_FEATURE_TOMBSTONES | CybouDB_FEATURE_INDEX | CybouDB_FEATURE_QUEUE | CybouDB_FEATURE_STREAM)
    jne     .e_features

    ; Leaf runs are a choice about the multi-page PAX layout, so the bit means
    ; nothing without the directory that addresses those leaves. With it the
    ; bit is orthogonal to every combination below, so it is taken out before
    ; they are compared rather than doubling the list of accepted sets.
    test    rax, CybouDB_FEATURE_PAX_RUNS
    jz      .runs_checked
    test    rax, CybouDB_FEATURE_PAX_MULTI
    jz      .e_features
    and     rax, ~CybouDB_FEATURE_PAX_RUNS
.runs_checked:
    ; Two-level directories are likewise a multi-page PAX choice, and likewise
    ; orthogonal to everything else, so the same treatment.
    test    rax, CybouDB_FEATURE_PAX_TREE
    jz      .tree_checked
    test    rax, CybouDB_FEATURE_PAX_MULTI
    jz      .e_features
    and     rax, ~CybouDB_FEATURE_PAX_TREE
.tree_checked:
    ; Zone metadata is a property of a PAX table rather than of the directory
    ; that addresses its leaves, so it requires PAX and nothing more, and it is
    ; likewise taken out before the accepted sets are compared.
    test    rax, CybouDB_FEATURE_ZONE_MAPS
    jz      .zone_checked
    test    rax, CybouDB_FEATURE_PAX
    jz      .e_features
    and     rax, ~CybouDB_FEATURE_ZONE_MAPS
.zone_checked:
    ; Per-column compression is likewise a property of PAX tables.
    test    rax, CybouDB_FEATURE_COMPRESSION
    jz      .compression_checked
    test    rax, CybouDB_FEATURE_PAX
    jz      .e_features
    and     rax, ~CybouDB_FEATURE_COMPRESSION
.compression_checked:
    ; Varlen descriptors require PAX storage and full graph traversal.
    test    rax, CybouDB_FEATURE_VARLEN
    jz      .varlen_checked
    test    rax, CybouDB_FEATURE_PAX
    jz      .e_features
    and     rax, ~CybouDB_FEATURE_VARLEN
.varlen_checked:
    ; Vector extents require PAX storage and full graph traversal.
    test    rax, CybouDB_FEATURE_VECTOR
    jz      .vector_checked
    test    rax, CybouDB_FEATURE_PAX
    jz      .e_features
    and     rax, ~CybouDB_FEATURE_VECTOR
.vector_checked:
    ; Tombstones reserve part of a PAX leaf, so they mean nothing without one.
    test    rax, CybouDB_FEATURE_TOMBSTONES
    jz      .tomb_checked
    test    rax, CybouDB_FEATURE_PAX
    jz      .e_features
    and     rax, ~CybouDB_FEATURE_TOMBSTONES
.tomb_checked:
    ; An index over a table with no row storage is not a meaningful object.
    test    rax, CybouDB_FEATURE_INDEX
    jz      .index_checked
    test    rax, CybouDB_FEATURE_PAX
    jz      .e_features
    and     rax, ~CybouDB_FEATURE_INDEX
.index_checked:
    ; A queue needs somewhere to be named and nothing else: no rows, no leaf,
    ; no directory of its own beyond the catalog's. So the bit is orthogonal to
    ; every combination below and comes out before they are compared.
    ; A stream keeps its records in a queue's segments, so the bit means
    ; nothing without the bit that defines them. It is asked first because the
    ; queue bit is still here to be seen; a moment later it has been taken out.
    test    rax, CybouDB_FEATURE_STREAM
    jz      .stream_checked
    test    rax, CybouDB_FEATURE_QUEUE
    jz      .e_features
    and     rax, ~CybouDB_FEATURE_STREAM
.stream_checked:
    test    rax, CybouDB_FEATURE_QUEUE
    jz      .queue_checked
    test    rax, CybouDB_FEATURE_CATALOG
    jz      .e_features
    and     rax, ~CybouDB_FEATURE_QUEUE
.queue_checked:
    test    rax, CybouDB_FEATURE_MAP_SPAN
    jz      .flat_map_flags
    cmp     rax, CybouDB_FEATURE_COW | CybouDB_FEATURE_CATALOG | CybouDB_FEATURE_PAX | CybouDB_FEATURE_PAX_MULTI | CybouDB_FEATURE_MAP_SPAN
    jne     .e_features
    jmp     .pax_flags_known
.flat_map_flags:
    test    rax, CybouDB_FEATURE_PAX_MULTI
    jz      .single_pax_flags
    cmp     rax, CybouDB_FEATURE_COW | CybouDB_FEATURE_CATALOG | CybouDB_FEATURE_PAX | CybouDB_FEATURE_PAX_MULTI
    jne     .e_features
    jmp     .pax_flags_known
.single_pax_flags:
    test    rax, CybouDB_FEATURE_PAX
    jz      .pax_flags_known
    cmp     rax, CybouDB_FEATURE_COW | CybouDB_FEATURE_CATALOG | CybouDB_FEATURE_PAX
    jne     .e_features
.pax_flags_known:
    cmp     rax, CybouDB_FEATURE_CATALOG
    je      .e_features                 ; catalog requires allocation map
    mov     r11, [rbp - 16]
    ; The descriptor records what the file says, not the copy the combination
    ; checks above stripped the dense bit out of: the layout code downstream
    ; has to be able to see it.
    mov     rax, [r10 + HDR_FLAGS_INCOMPAT]
    mov     [r11 + DB_FEATURES], rax
    test    rax, rax
    jz      .features_known
    mov     qword [r11 + DB_MODE], 1
.features_known:

    ; --- the two metadata copies must exist inside the file ------------------
    mov     rax, [rbp - 32]
    cmp     rax, CybouDB_MIN_PAGES * CybouDB_PAGE_SIZE
    jb      .e_small

    mov     rax, [r10 + HDR_SB_PAGE_A]
    cmp     rax, CybouDB_SB_PAGE_A
    jne     .e_geometry                 ; version 1 fixes both locations
    mov     rax, [r10 + HDR_SB_PAGE_B]
    cmp     rax, CybouDB_SB_PAGE_B
    jne     .e_geometry

    mov     r11, [rbp - 24]
    lea     rax, [r11 + CybouDB_SB_PAGE_A * CybouDB_PAGE_SIZE]
    mov     [rbp - 40], rax
    lea     rax, [r11 + CybouDB_SB_PAGE_B * CybouDB_PAGE_SIZE]
    mov     [rbp - 48], rax

    ; ========================= pages 1 and 2: superblock =====================
    ;  Pick the highest generation whose checksum verifies. A torn commit
    ;  leaves one copy damaged; the other one is the state to fall back to.
    mov     qword [rbp - 56], 0         ; chosen superblock, none so far
    mov     qword [rbp - 64], 0
    mov     qword [rbp - 72], 0         ; generation of copy A
    mov     qword [rbp - 80], 0         ; generation of copy B

    mov     ARG1, [rbp - 40]
    call    sb_valid
    test    rax, rax
    jz      .check_b
    ; Protect every checksummed superblock's range, even if its map fails.
    ; Reusing that map could otherwise resurrect an unpublished generation.
    mov     r10, [rbp - 40]
    mov     r11, [rbp - 16]
    mov     rax, [r10 + SB_ALLOC_PAGES]
    mov     [r11 + DB_COW_FLOOR], rax
    mov     ARG1, [rbp - 16]
    mov     ARG2, [rbp - 40]
    call    db_bitmap_validate
    test    eax, eax
    jz      .check_b
    mov     r10, [rbp - 40]
    mov     rax, [r10 + SB_GENERATION]
    mov     [rbp - 72], rax
    mov     [rbp - 56], r10
    mov     qword [rbp - 64], CybouDB_SB_PAGE_A

.check_b:
    mov     ARG1, [rbp - 48]
    call    sb_valid
    test    rax, rax
    jz      .sb_chosen
    mov     r10, [rbp - 48]
    mov     r11, [rbp - 16]
    mov     rax, [r10 + SB_ALLOC_PAGES]
    cmp     rax, [r11 + DB_COW_FLOOR]
    jbe     .floor_known
    mov     [r11 + DB_COW_FLOOR], rax
.floor_known:
    mov     ARG1, [rbp - 16]
    mov     ARG2, [rbp - 48]
    call    db_bitmap_validate
    test    eax, eax
    jz      .sb_chosen
    mov     r10, [rbp - 48]
    mov     rax, [r10 + SB_GENERATION]
    mov     [rbp - 80], rax
    cmp     qword [rbp - 56], 0
    je      .take_b                     ; A did not verify, B wins by default
    cmp     rax, [rbp - 72]
    jbe     .sb_chosen                  ; A is newer or equal, keep A
.take_b:
    mov     r10, [rbp - 48]
    mov     [rbp - 56], r10
    mov     qword [rbp - 64], CybouDB_SB_PAGE_B

.sb_chosen:
    mov     r10, [rbp - 56]
    test    r10, r10
    jz      .e_superblock               ; neither copy verifies

    ; ============================ geometry checks ============================
    mov     rax, [r10 + SB_TOTAL_PAGES]
    mov     r11, CybouDB_MAX_PAGES
    cmp     rax, r11
    ja      .e_geometry
    PAGES_TO_BYTES rax
    cmp     rax, [rbp - 32]
    jne     .e_geometry                 ; the file is not the size it claims

    mov     rax, [r10 + SB_ALLOC_PAGES]
    cmp     rax, CybouDB_MIN_PAGES
    jb      .e_geometry                 ; the metadata pages are always in use
    cmp     rax, [r10 + SB_TOTAL_PAGES]
    ja      .e_geometry                 ; more pages used than the file holds

    ; The free list must at least point somewhere that could be a page.
    mov     rax, [r10 + SB_FREELIST_ROOT]
    test    rax, rax
    jz      .freelist_ok                ; an empty list is the normal case
    cmp     rax, CybouDB_MIN_PAGES
    jb      .e_geometry
    cmp     rax, [r10 + SB_ALLOC_PAGES]
    jae     .e_geometry
.freelist_ok:
    mov     rax, [r10 + SB_ROOT_PAGE]
    test    rax, rax
    jz      .root_ok
    cmp     rax, CybouDB_MIN_PAGES
    jb      .e_geometry
    cmp     rax, [r10 + SB_ALLOC_PAGES]
    jae     .e_geometry
.root_ok:
    ; An extension root can only have been written by a build that implements
    ; the extension, so refuse rather than ignore what it points at.
    cmp     qword [r10 + SB_FEATURE_ROOT], 0
    jne     .e_features

    ; ============================== hand it back =============================
    mov     r11, [rbp - 16]
    mov     rax, [r10 + SB_TOTAL_PAGES]
    mov     [r11 + DB_PAGES], rax
    mov     rax, [r10 + SB_ALLOC_PAGES]
    mov     [r11 + DB_ALLOC], rax
    mov     rax, [r10 + SB_GENERATION]
    mov     [r11 + DB_GENERATION], rax
    mov     rax, [r10 + SB_FREELIST_ROOT]
    mov     [r11 + DB_FREELIST], rax
    mov     rax, [r10 + SB_ROOT_PAGE]
    mov     [r11 + DB_ROOT], rax
    mov     rax, [r10 + SB_BITMAP_ROOT]
    mov     [r11 + DB_BITMAP], rax
    mov     rax, [rbp - 64]
    mov     [r11 + DB_SB_PAGE], rax
    mov     [r11 + DB_SB_PTR], r10

    mov     ARG1, r11
    call    db_bitmap_recount           ; what the live generation retired

    mov     eax, CybouDB_OK
    FRAME_END
    ret

    ; --- failures after the mapping exists: unmap and close ------------------
.e_magic:
    mov     eax, CybouDB_E_MAGIC
    jmp     .unmap_and_fail
.e_version:
    mov     eax, CybouDB_E_VERSION
    jmp     .unmap_and_fail
.e_pagesize:
    mov     eax, CybouDB_E_PAGESIZE
    jmp     .unmap_and_fail
.e_hdr_crc:
    mov     eax, CybouDB_E_HDR_CRC
    jmp     .unmap_and_fail
.e_features:
    mov     eax, CybouDB_E_FEATURES
    jmp     .unmap_and_fail
.e_superblock:
    mov     eax, CybouDB_E_SUPERBLOCK
    jmp     .unmap_and_fail
.e_geometry:
    mov     eax, CybouDB_E_GEOMETRY
.unmap_and_fail:
    mov     [rbp - 8], rax              ; the code would not survive the call
    mov     ARG1, [rbp - 16]            ; in a register, so park it in the frame
    call    db_close
    mov     rax, [rbp - 8]
    FRAME_END
    ret

    ; --- failures before the mapping exists: close only ----------------------
.e_map:
    mov     eax, CybouDB_E_MAP
    jmp     .close_and_fail
.e_small:
    mov     eax, CybouDB_E_SMALL
    jmp     .close_and_fail
.e_size:
    mov     eax, CybouDB_E_SIZE
.close_and_fail:
    mov     [rbp - 8], rax
    mov     r10, [rbp - 16]
    mov     ARG1, [r10 + DB_HANDLE]
    call    vfs_close
    mov     r10, [rbp - 16]
    mov     qword [r10 + DB_HANDLE], -1
    mov     rax, [rbp - 8]
    FRAME_END
    ret
.e_open:
    mov     ARG1, [rbp - 96]            ; say what the OS actually objected to
    mov     ARG2, CybouDB_E_OPEN
    call    oserr_to_code
    FRAME_END
    ret
.e_busy_close:
    mov     r10, [rbp - 16]
    mov     ARG1, [r10 + DB_HANDLE]
    call    vfs_close
    mov     r10, [rbp - 16]
    mov     qword [r10 + DB_HANDLE], -1
    mov     eax, CybouDB_E_BUSY
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  db_alloc_page(ARG1 = descriptor, ARG2 = address of a u64) -> RAX: result
;
;  Hands out one page. A page returned by db_free_page is reused first, which
;  keeps a database that churns pages from growing without bound; only when
;  the free list is empty does the high-water mark move up.
;
;  Legacy free-list writes may persist before commit. COW handles dispatch to
;  the append-only allocator without overwriting committed pages.
;
;  Local slots: [rbp-8]=ctx, [rbp-16]=out
; -----------------------------------------------------------------------------
db_alloc_page:
    cmp     qword [ARG1 + DB_MODE], 1
    je      db_cow_alloc_page
    cmp     qword [ARG1 + DB_MODE], -1
    je      mutation_state_error
    cmp     qword [ARG1 + DB_GENERATION], -1
    je      mutation_generation_error
    FRAME_BEGIN 16, 0
    mov     [rbp - 8], ARG1
    mov     [rbp - 16], ARG2

    mov     r10, ARG1
    cmp     qword [r10 + DB_WRITABLE], 0
    je      .e_readonly

    mov     rax, [r10 + DB_FREELIST]
    test    rax, rax
    jz      .from_high_water

    ; --- reuse the page at the head of the free list -------------------------
    cmp     rax, CybouDB_MIN_PAGES
    jb      .e_freelist                 ; the metadata pages are never free
    cmp     rax, [r10 + DB_ALLOC]
    jae     .e_freelist                 ; past the high-water mark

    mov     r11, rax
    PAGES_TO_BYTES r11
    add     r11, [r10 + DB_BASE]
    cmp     dword [r11 + FREE_MAGIC], CybouDB_FREE_MAGIC
    jne     .e_freelist                 ; the chain does not lead to a free page

    mov     rdx, [r11 + FREE_NEXT]
    mov     [r10 + DB_FREELIST], rdx
    ; Clear the marker so the page no longer looks free to db_free_page.
    mov     dword [r11 + FREE_MAGIC], 0
    mov     qword [r11 + FREE_NEXT], 0
    jmp     .give_it_out

.from_high_water:
    mov     rax, [r10 + DB_ALLOC]
    cmp     rax, [r10 + DB_PAGES]
    jae     .e_full                     ; the file has no room left
    inc     qword [r10 + DB_ALLOC]

.give_it_out:
    mov     r11, [rbp - 16]
    mov     [r11], rax
    mov     eax, CybouDB_OK
    FRAME_END
    ret

.e_readonly:
    mov     eax, CybouDB_E_READONLY
    FRAME_END
    ret
.e_freelist:
    mov     eax, CybouDB_E_FREELIST
    FRAME_END
    ret
.e_full:
    mov     eax, CybouDB_E_FULL
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  db_free_page(ARG1 = descriptor, ARG2 = page) -> RAX: result code
;
;  Pushes the page onto the free list, chained through the page itself.
;
;  The double-free guard is a heuristic: it refuses a page that already starts
;  with the free-page magic. Once real data lives in pages, a data page could
;  in principle begin with those four bytes, so this must not be mistaken for
;  a proof of correctness - it is a cheap way to catch the common mistake.
;
;  Local slots: [rbp-8]=ctx, [rbp-16]=page
; -----------------------------------------------------------------------------
db_free_page:
    cmp     qword [ARG1 + DB_MODE], 0
    jne     mutation_state_error
    cmp     qword [ARG1 + DB_GENERATION], -1
    je      mutation_generation_error
    FRAME_BEGIN 16, 0
    mov     [rbp - 8], ARG1
    mov     [rbp - 16], ARG2

    mov     r10, ARG1
    cmp     qword [r10 + DB_WRITABLE], 0
    je      .e_readonly

    mov     rax, ARG2
    cmp     rax, CybouDB_MIN_PAGES
    jb      .e_page                     ; the header and superblocks are fixed
    cmp     rax, [r10 + DB_ALLOC]
    jae     .e_page                     ; never handed out in the first place

    mov     r11, rax
    PAGES_TO_BYTES r11
    add     r11, [r10 + DB_BASE]
    cmp     dword [r11 + FREE_MAGIC], CybouDB_FREE_MAGIC
    je      .e_page                     ; looks free already

    mov     dword [r11 + FREE_MAGIC], CybouDB_FREE_MAGIC
    mov     dword [r11 + FREE_RESERVED], 0
    mov     rdx, [r10 + DB_FREELIST]
    mov     [r11 + FREE_NEXT], rdx
    mov     [r10 + DB_FREELIST], rax

    mov     eax, CybouDB_OK
    FRAME_END
    ret

.e_readonly:
    mov     eax, CybouDB_E_READONLY
    FRAME_END
    ret
.e_page:
    mov     eax, CybouDB_E_PAGE
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  sync_pages(ARG1 = descriptor, ARG2 = first page, ARG3 = page count)
;  -> RAX: whatever vfs_sync returned, -1 on failure
;
;  Flushes the byte range those pages occupy instead of the whole mapping.
;  In COW mode the allocator records every page it hands out in
;  [DB_DIRTY_LO, DB_DIRTY_HI), which is what a transaction can have written:
;  nothing else is writable. So the range is exact, and the cost of a commit
;  stops growing with the size
;  of the database - flushing a whole mapping makes the kernel walk every
;  page table entry of the file, which is what must not happen once the file
;  is large.
;
;  The range is widened to 64 KiB boundaries. msync(2) wants an address that
;  is a multiple of the system page size, which is 4 KiB only on some
;  platforms, and FlushViewOfFile treats a zero length as "the entire view".
;  Flushing slightly more than necessary is always safe.
;
;  Local slots: [rbp-8]=descriptor, [rbp-16]=start offset, [rbp-24]=end offset
; -----------------------------------------------------------------------------
%define CybouDB_SYNC_ALIGN 65536

sync_pages:
    add qword [rel pages_flushed], ARG3
    FRAME_BEGIN 32, 0
    mov     [rbp - 8], ARG1
    mov     rax, ARG2
    PAGES_TO_BYTES rax
    and     rax, -CybouDB_SYNC_ALIGN
    mov     [rbp - 16], rax
    mov     rax, ARG2
    add     rax, ARG3
    PAGES_TO_BYTES rax
    add     rax, CybouDB_SYNC_ALIGN - 1
    and     rax, -CybouDB_SYNC_ALIGN
    mov     r10, [rbp - 8]
    mov     r11, [r10 + DB_SIZE]
    cmp     rax, r11
    jbe     .end_known
    mov     rax, r11                    ; never flush past the end of the file
.end_known:
    mov     [rbp - 24], rax
    mov     ARG1, [r10 + DB_HANDLE]
    mov     ARG2, [rbp - 16]
    add     ARG2, [r10 + DB_BASE]
    mov     ARG3, rax
    sub     ARG3, [rbp - 16]
    call    vfs_sync
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  db_commit(ARG1 = descriptor) -> RAX: result code
;
;  Publishes the current state as a new generation. The order of the steps is
;  the whole point and must not be rearranged:
;
;    1. flush the data pages. The superblock about to be written points at
;       free-list records inside those pages, so they have to be on the disk
;       before anything references them. Only the range the transaction can
;       have touched is flushed - see sync_pages.
;    2. write the superblock copy that is NOT the live one, with generation
;       + 1 and a fresh checksum. Until this lands, the previous generation
;       is still the newest metadata copy. Shared page writes may persist.
;    3. flush that superblock page, which is the moment the new generation
;       becomes the one a reader would pick.
;    4. adopt the new copy in the descriptor.
;
;  A crash between 2 and 3 leaves a half-written copy behind, and the reader
;  rejects it on its checksum and falls back to the other one. That is what
;  the two copies are for.
;
;  Local slots: [rbp-8]=ctx, [rbp-16]=target address, [rbp-24]=target page
; -----------------------------------------------------------------------------
db_commit:
    cmp     qword [ARG1 + DB_MODE], -1
    je      mutation_state_error
    cmp     qword [ARG1 + DB_GENERATION], -1
    je      mutation_generation_error
    FRAME_BEGIN 32 + CybouDB_SB_SIZE, 0
    mov     [rbp - 8], ARG1

    mov     r10, ARG1
    cmp     qword [r10 + DB_WRITABLE], 0
    je      .e_readonly

    ; --- 1. the data pages first ---------------------------------------------
    mov     ARG1, r10
    call    db_bitmap_seal
    mov     r10, [rbp - 8]
    cmp     qword [r10 + DB_FEATURES], 0
    je      .state_checked
    ; Validate staged root and allocation state before publishing any metadata.
    lea     ARG1, [rbp - 32 - CybouDB_SB_SIZE]
    mov     ARG2, r10
    mov     ARG3, [r10 + DB_GENERATION]
    inc     ARG3
    call    write_superblock
    mov     ARG1, [rbp - 8]
    lea     ARG2, [rbp - 32 - CybouDB_SB_SIZE]
    call    db_bitmap_validate
    test    eax, eax
    jz      .e_bitmap
    ; db_bitmap_validate walks the typed graph as well, so the staged graph is
    ; proved here, before any of it can outlive the process. That is what lets
    ; appends inside the transaction stop walking it one at a time - see
    ; current_valid and db_pax_check_new.
.state_checked:
    mov     r10, [rbp - 8]
    cmp     qword [r10 + DB_MODE], 1
    je      .cow_range
    xor     ARG2, ARG2                  ; legacy mutation happens in place
    mov     ARG3, [r10 + DB_PAGES]
    jmp     .range_known
.cow_range:
    mov     ARG2, [r10 + DB_DIRTY_LO]
    mov     rax, [r10 + DB_DIRTY_HI]
    cmp     rax, ARG2
    jbe     .no_new_pages
    mov     ARG3, rax
    sub     ARG3, ARG2
    jmp     .range_known
.no_new_pages:
    xor     ARG2, ARG2                  ; nothing staged: still flush once
    mov     ARG3, CybouDB_MIN_PAGES
.range_known:
%ifdef CybouDB_TEST_COMMIT_HOOK
    mov     ARG1, 1
    call    test_commit_hook
    test    eax, eax
    jnz     .e_sync
    mov     r10, [rbp - 8]
    cmp     qword [r10 + DB_MODE], 1
    jne     .hook_legacy_range
    mov     ARG2, [r10 + DB_DIRTY_LO]
    mov     rax, [r10 + DB_DIRTY_HI]
    cmp     rax, ARG2
    jbe     .hook_no_new_pages
    mov     ARG3, rax
    sub     ARG3, ARG2
    jmp     .hook_range_ready
.hook_no_new_pages:
    xor     ARG2, ARG2
    mov     ARG3, CybouDB_MIN_PAGES
    jmp     .hook_range_ready
.hook_legacy_range:
    xor     ARG2, ARG2
    mov     ARG3, [r10 + DB_PAGES]
.hook_range_ready:
%endif
    mov     ARG1, r10
    call    sync_pages
    cmp     rax, -1
    je      .e_sync

    ; --- 2. the other superblock copy ----------------------------------------
    mov     r10, [rbp - 8]
    mov     rax, [r10 + DB_SB_PAGE]
    cmp     rax, CybouDB_SB_PAGE_A
    jne     .target_a
    mov     qword [rbp - 24], CybouDB_SB_PAGE_B
    jmp     .target_known
.target_a:
    mov     qword [rbp - 24], CybouDB_SB_PAGE_A
.target_known:
    mov     r11, [rbp - 24]
    PAGES_TO_BYTES r11
    add     r11, [r10 + DB_BASE]
    mov     [rbp - 16], r11

    mov     ARG1, r11
    mov     ARG2, r10
    mov     ARG3, [r10 + DB_GENERATION]
    inc     ARG3
    call    write_superblock

    ; --- 3. and out to the disk ----------------------------------------------
    ;  The superblock page just written, and with the span layout the map copy
    ;  it names: both carry their own checksums, so a torn map simply rejects
    ;  this candidate and they can share one barrier.
    mov     r10, [rbp - 8]
    mov     ARG3, CybouDB_MIN_PAGES
    test    qword [r10 + DB_FEATURES], CybouDB_FEATURE_MAP_SPAN
    jz      .publish_range
    mov     ARG1, [r10 + DB_PAGES]
    call    db_bitmap_leaves
    mov     r10, [rbp - 8]
    add     rax, [r10 + DB_BITMAP]
    mov     ARG3, rax
.publish_range:
%ifdef CybouDB_TEST_COMMIT_HOOK
    mov     ARG1, 2
    call    test_commit_hook
    test    eax, eax
    jnz     .e_sync
    mov     r10, [rbp - 8]
    mov     ARG3, CybouDB_MIN_PAGES
    test    qword [r10 + DB_FEATURES], CybouDB_FEATURE_MAP_SPAN
    jz      .hook_publish_range_ready
    mov     ARG1, [r10 + DB_PAGES]
    call    db_bitmap_leaves
    mov     r10, [rbp - 8]
    add     rax, [r10 + DB_BITMAP]
    mov     ARG3, rax
.hook_publish_range_ready:
%endif
    mov     ARG1, r10
    xor     ARG2, ARG2
    call    sync_pages
    cmp     rax, -1
    je      .e_sync

    ; --- 4. the new copy is now the live one ---------------------------------
    mov     r10, [rbp - 8]
    inc     qword [r10 + DB_GENERATION]
    mov     rax, [rbp - 24]
    mov     [r10 + DB_SB_PAGE], rax
    mov     rax, [rbp - 16]
    mov     [r10 + DB_SB_PTR], rax
    mov     rax, [r10 + DB_ALLOC]
    cmp     rax, [r10 + DB_COW_FLOOR]
    jbe     .floor_preserved
    mov     [r10 + DB_COW_FLOOR], rax
.floor_preserved:
    mov     qword [r10 + DB_DIRTY_HI], 0
    mov     qword [r10 + DB_VALIDATED], 0
    mov     ARG1, r10
    call    db_bitmap_recount           ; the pages this generation retired

    mov     eax, CybouDB_OK
    FRAME_END
    ret

.e_readonly:
    mov     eax, CybouDB_E_READONLY
    FRAME_END
    ret
.e_sync:
    mov     r10, [rbp - 8]
    mov     qword [r10 + DB_MODE], -1   ; outcome uncertain; reopen required
    mov     eax, CybouDB_E_SYNC
    FRAME_END
    ret
.e_bitmap:
    mov     eax, CybouDB_E_BITMAP
    FRAME_END
    ret

mutation_state_error:
    mov     eax, CybouDB_E_STATE
    ret
mutation_generation_error:
    mov     eax, CybouDB_E_GENERATION
    ret

; -----------------------------------------------------------------------------
;  db_rollback(ARG1 = descriptor) -> RAX: result code
;
;  Reverts staged copy-on-write allocations and restores the descriptor state
;  from the currently committed live superblock.
; -----------------------------------------------------------------------------
db_rollback:
    cmp     qword [ARG1 + DB_MODE], -1
    je      mutation_state_error
    cmp     qword [ARG1 + DB_MODE], 1
    jne     mutation_state_error
    cmp     qword [ARG1 + DB_WRITABLE], 0
    je      .e_readonly
    mov     r10, [ARG1 + DB_SB_PTR]
    test    r10, r10
    jz      mutation_state_error

    FRAME_BEGIN 64, 0
    mov     [rbp - 8], ARG1

    mov     r10, [rbp - 8]
    mov     r11, [r10 + DB_SB_PTR]

    ; Restore committed superblock fields
    mov     rax, [r11 + SB_TOTAL_PAGES]
    mov     [r10 + DB_PAGES], rax
    mov     rax, [r11 + SB_ALLOC_PAGES]
    mov     [r10 + DB_ALLOC], rax
    mov     [r10 + DB_COW_FLOOR], rax
    mov     rax, [r11 + SB_GENERATION]
    mov     [r10 + DB_GENERATION], rax
    mov     rax, [r11 + SB_FREELIST_ROOT]
    mov     [r10 + DB_FREELIST], rax
    mov     rax, [r11 + SB_ROOT_PAGE]
    mov     [r10 + DB_ROOT], rax
    mov     rax, [r11 + SB_BITMAP_ROOT]
    mov     [r10 + DB_BITMAP], rax

    mov     qword [r10 + DB_DIRTY_LO], 0
    mov     qword [r10 + DB_DIRTY_HI], 0
    mov     qword [r10 + DB_VALIDATED], 0

    ; In span layout, copy active leaves to inactive copy
    test    qword [r10 + DB_FEATURES], CybouDB_FEATURE_MAP_SPAN
    jz      .recount

    mov     ARG1, [r10 + DB_PAGES]
    call    db_bitmap_leaves
    mov     [rbp - 16], rax             ; K
    mov     r10, [rbp - 8]
    mov     r11, [r10 + DB_SB_PTR]
    mov     rax, [r11 + SB_BITMAP_ROOT]
    mov     [rbp - 24], rax             ; active_root
    cmp     rax, CybouDB_MIN_PAGES
    jne     .to_first
    mov     rax, [rbp - 16]
    add     rax, CybouDB_MIN_PAGES
    mov     [rbp - 32], rax             ; other_root
    jmp     .roots_ready
.to_first:
    mov     qword [rbp - 32], CybouDB_MIN_PAGES
.roots_ready:
    mov     qword [rbp - 40], 0         ; leaf_idx = 0
.leaf_copy_loop:
    mov     rax, [rbp - 40]
    cmp     rax, [rbp - 16]
    jae     .recount

    mov     r10, [rbp - 8]
    mov     rax, [r10 + DB_BASE]
    mov     rdx, [rbp - 24]
    add     rdx, [rbp - 40]
    shl     rdx, CybouDB_PAGE_SHIFT
    add     rdx, rax                    ; src leaf
    mov     r8, rdx

    mov     rdx, [rbp - 32]
    add     rdx, [rbp - 40]
    shl     rdx, CybouDB_PAGE_SHIFT
    add     rdx, rax                    ; dst leaf
    mov     r9, rdx

    mov     ecx, CybouDB_PAGE_SIZE / 8
.leaf_qwords:
    mov     rax, [r8]
    mov     [r9], rax
    add     r8, 8
    add     r9, 8
    dec     ecx
    jnz     .leaf_qwords

    inc     qword [rbp - 40]
    jmp     .leaf_copy_loop

.recount:
    mov     r10, [rbp - 8]
    mov     ARG1, r10
    call    db_bitmap_recount

    mov     r10, [rbp - 8]
    mov     qword [r10 + DB_TX_ACTIVE], 0

    mov     eax, CybouDB_OK
    FRAME_END
    ret

.e_readonly:
    mov     eax, CybouDB_E_READONLY
    ret

; -----------------------------------------------------------------------------
;  db_close(ARG1 = descriptor)
;  Idempotent, rolls back any uncommitted transaction, and releases resources.
; -----------------------------------------------------------------------------
db_close:
    FRAME_BEGIN 16, 0
    mov     [rbp - 8], ARG1

    mov     r10, ARG1
    cmp     qword [r10 + DB_TX_ACTIVE], 0
    je      .no_uncommitted_tx
    mov     ARG1, r10
    call    db_rollback
.no_uncommitted_tx:
    mov     r10, [rbp - 8]
    mov     rax, [r10 + DB_BASE]
    test    rax, rax
    jz      .no_map
    mov     ARG1, rax
    mov     ARG2, [r10 + DB_SIZE]
    call    vfs_unmap
    mov     r10, [rbp - 8]
    mov     qword [r10 + DB_BASE], 0
    mov     qword [r10 + DB_SB_PTR], 0
.no_map:
    mov     r10, [rbp - 8]
    mov     rax, [r10 + DB_HANDLE]
    cmp     rax, -1
    je      .no_file
    mov     ARG1, rax
    call    vfs_close
    mov     r10, [rbp - 8]
    mov     qword [r10 + DB_HANDLE], -1
.no_file:
    mov     r10, [rbp - 8]
    mov     qword [r10 + DB_WRITABLE], 0
    FRAME_END
    ret

%ifdef CybouDB_LINUX
section .note.GNU-stack noalloc noexec nowrite progbits
%endif
