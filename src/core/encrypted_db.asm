; Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
; SPDX-License-Identifier: Apache-2.0
; =============================================================================
;  core/encrypted_db.asm - opening an encrypted database as a database
; =============================================================================
;  db_open produces a context the whole engine reads: how many pages there are,
;  which ones are allocated, where the map and the catalog root live, and a
;  pointer to the superblock that said so. Everything above it - the allocator,
;  the catalog, the executor - reads those fields and nothing else about how
;  the file was opened.
;
;  This produces the same context for an encrypted file. It is a second entry
;  point rather than a branch inside db_open because the two differ in the one
;  place that cannot be a branch: *when* the superblock is chosen. A plain open
;  picks the newest copy whose checksum verifies and then validates its map. An
;  encrypted open cannot: a checksum cannot tell a torn commit from a forgery,
;  so the choice needs a key, and the key arrives here.
;
;      1. open and lock the file            as db_open does
;      2. its size                          the geometry is checked against it
;      3. attach with the private key       header, both superblocks, crypto
;                                           root, key slot, the key hierarchy,
;                                           the tag, the seal-tree root - and
;                                           the choice between the two copies
;      4. the superblock, copied            it is authenticated by then, and
;                                           there is no mapping to leave it in
;      5. the geometry it claims            the same checks db_open makes
;      6. the allocation map                through the resolver, page by page
;
;  **DB_BASE is left null, deliberately.** An encrypted database has no useful
;  mapping: the bytes in the file are ciphertext, and a module that has not yet
;  been converted to read through DB_PAGE_HERE would read them and find a page
;  that looks like nothing. A null base makes that a fault at the point of use
;  instead, which is the same bargain the resolver makes when it returns zero
;  for a page that did not verify. docs/ENCRYPTED_ENGINE.md.
;
;  Steps 3 and 6 both choose, and they have to be able to disagree. Step 3
;  falls back from a superblock that does not *authenticate*; step 6 can find
;  that the generation it picked has an allocation map that does not
;  *validate*, and only then, because the map is read through the cache step 3
;  sets up. So the open runs twice when it has to: the second time it tells
;  attach which copy it has already ruled out, and attach picks the next one
;  that authenticates. That keeps one list of candidates in one place instead
;  of two, and it is why db_encrypted_attach has an `avoid`.
; =============================================================================

%include "cyboudb.inc"

BITS 64
default rel

global db_open_encrypted

extern vfs_open_rw
extern vfs_open_ro
extern vfs_lock_reader
extern vfs_lock_writer
extern vfs_close
extern vfs_size
extern vfs_read_at
extern db_encrypted_attach_avoiding
extern db_bitmap_validate
extern db_bitmap_recount
extern db_close
extern oserr_to_code

section .text

; =============================================================================
;  db_open_encrypted(ARG1 = const uint8_t *args) -> RAX: result code
;
;  The arguments arrive as a struct because there are seven of them and
;  because the public open this will one day sit under has to be able to grow
;  a recovery credential, a keystore handle and a cache budget without
;  changing its shape. include/cyboudb.inc lays it out as EOPEN_*.
;
;  Frame:
;    [rbp - 8]  args      [rbp - 16] ctx      [rbp - 24] size
;    [rbp - 32] why the OS refused           [rbp - 40] a result being carried
;    [rbp - 48] a superblock copy already ruled out, or zero
;    [rbp - 56] the header's capability bits
; =============================================================================
db_open_encrypted:
    FRAME_BEGIN 64, 2
    mov     [rbp - 8], ARG1
    mov     r11, ARG1
    mov     rax, [r11 + EOPEN_CTX]
    mov     [rbp - 16], rax

    ; --- reset the descriptor so db_close is safe in every case --------------
    mov     r10, rax
    xor     eax, eax
    mov     ecx, CybouDB_DB_SIZE / 8
.zero_ctx:
    mov     [r10], rax
    add     r10, 8
    dec     ecx
    jnz     .zero_ctx
    mov     r10, [rbp - 16]
    mov     qword [r10 + DB_HANDLE], -1
    mov     r11, [rbp - 8]
    mov     rax, [r11 + EOPEN_WRITABLE]
    mov     [r10 + DB_WRITABLE], rax
    mov     rax, [r11 + EOPEN_VERIFY]
    mov     [r10 + DB_VERIFY], rax

    ; --- 1. the file ---------------------------------------------------------
    mov     qword [rbp - 32], CybouDB_OSERR_NONE
    mov     r11, [rbp - 8]
    mov     ARG1, [r11 + EOPEN_PATH]
    lea     ARG2, [rbp - 32]
    cmp     qword [r11 + EOPEN_WRITABLE], 0
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
    mov     r11, [rbp - 8]
    cmp     qword [r11 + EOPEN_WRITABLE], 0
    je      .lock_reader
    mov     ARG1, rax
    call    vfs_lock_writer
    cmp     rax, -1
    je      .e_busy
    jmp     .locked
.lock_reader:
    mov     ARG1, rax
    call    vfs_lock_reader
    cmp     rax, -1
    je      .e_busy
.locked:

    ; --- 2. how long it is ---------------------------------------------------
    mov     r10, [rbp - 16]
    mov     ARG1, [r10 + DB_HANDLE]
    call    vfs_size
    cmp     rax, -1
    je      .e_size
    mov     [rbp - 24], rax
    mov     r10, [rbp - 16]
    mov     [r10 + DB_SIZE], rax
    cmp     rax, CybouDB_HDR_SIZE
    jb      .e_small

    ; --- 3. the key ----------------------------------------------------------
    ;  Everything a reader has to believe before it can read a page: the
    ;  header, both superblock copies, the crypto root, a key slot, the key
    ;  hierarchy, the tag and the seal-tree root. And the choice between the
    ;  two generations, which is what needs the key and is why this is not a
    ;  branch inside db_open.
    mov     qword [rbp - 48], 0         ; no copy ruled out yet
.attach:
    mov     r11, [rbp - 8]
    mov     ARG1, [rbp - 16]
    mov     ARG2, [r11 + EOPEN_DK]
    mov     ARG3, [r11 + EOPEN_CACHE]
    mov     ARG4, [r11 + EOPEN_CACHE_BYTES]
    mov     rax, [r11 + EOPEN_FRAMES]
    PASS_ARG5 rax
    mov     rax, [rbp - 48]
    PASS_ARG6 rax
    call    db_encrypted_attach_avoiding
    test    eax, eax
    jnz     .attach_failed

    ; --- 4. the superblock, copied ------------------------------------------
    mov     r10, [rbp - 16]
    mov     rax, [r10 + DB_SB_PAGE]
    shl     rax, CybouDB_PAGE_SHIFT
    mov     ARG1, [r10 + DB_HANDLE]
    lea     ARG2, [r10 + DB_SB_COPY]
    mov     ARG3, CybouDB_SB_SIZE
    mov     ARG4, rax
    call    vfs_read_at
    cmp     rax, CybouDB_SB_SIZE
    jne     .e_superblock
    mov     r10, [rbp - 16]
    lea     rax, [r10 + DB_SB_COPY]
    mov     [r10 + DB_SB_PTR], rax

    ; --- 5. the geometry it claims ------------------------------------------
    ;  The same questions db_open asks, in the same order and for the same
    ;  reasons. They are asked again rather than shared because the answers
    ;  come out of a copy here and out of a mapping there, and a helper taking
    ;  either would be a helper that could be given the wrong one.
    mov     r11, rax                    ; the superblock copy
    mov     rax, [r11 + SB_TOTAL_PAGES]
    mov     rcx, CybouDB_MAX_PAGES
    cmp     rax, rcx
    ja      .e_geometry
    PAGES_TO_BYTES rax
    cmp     rax, [rbp - 24]
    jne     .e_geometry                 ; the file is not the size it claims

    mov     rax, [r11 + SB_ALLOC_PAGES]
    cmp     rax, CybouDB_MIN_PAGES
    jb      .e_geometry
    cmp     rax, [r11 + SB_TOTAL_PAGES]
    ja      .e_geometry

    mov     rax, [r11 + SB_FREELIST_ROOT]
    test    rax, rax
    jz      .freelist_ok
    cmp     rax, CybouDB_MIN_PAGES
    jb      .e_geometry
    cmp     rax, [r11 + SB_ALLOC_PAGES]
    jae     .e_geometry
.freelist_ok:
    mov     rax, [r11 + SB_ROOT_PAGE]
    test    rax, rax
    jz      .root_ok
    cmp     rax, CybouDB_MIN_PAGES
    jb      .e_geometry
    cmp     rax, [r11 + SB_ALLOC_PAGES]
    jae     .e_geometry
.root_ok:
    ; The one feature root this build understands is the crypto root, and the
    ; attach above is what proved it is one. Anything else here was written by
    ; a build this one is not.
    cmp     qword [r11 + SB_FEATURE_ROOT], 0
    je      .feature_root_ok
    cmp     qword [r10 + DB_CACHE], 0
    je      .e_features                 ; only an attached file has one
.feature_root_ok:

    ; --- the context the rest of the engine reads ----------------------------
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

    ; The header's capabilities, which attach has already read and checked the
    ; encryption bit out of. They are read again here because the context
    ; carries them for everything above, and page 0 is plaintext. Eight bytes
    ; of it, not the whole header: nothing else here is asking page 0 anything.
    mov     ARG1, [r10 + DB_HANDLE]
    lea     ARG2, [rbp - 56]
    mov     ARG3, 8
    mov     ARG4, HDR_FLAGS_INCOMPAT
    call    vfs_read_at
    cmp     rax, 8
    jne     .e_geometry
    mov     r10, [rbp - 16]
    mov     rax, [rbp - 56]
    mov     [r10 + DB_FEATURES], rax
    test    rax, rax
    jz      .mode_known
    mov     qword [r10 + DB_MODE], 1
.mode_known:

    ; --- 6. the allocation map, through the resolver -------------------------
    mov     ARG1, r10
    mov     ARG2, [r10 + DB_SB_PTR]
    call    db_bitmap_validate
    test    eax, eax
    jnz     .map_valid

    ; This generation authenticated and its allocation map did not. That is
    ; damage, and it is also a reason to ask for the copy before it - once.
    mov     r10, [rbp - 16]
    mov     rax, [r10 + DB_GENERATION]
    cmp     rax, [r10 + DB_DAMAGED]
    jbe     .damage_kept
    mov     [r10 + DB_DAMAGED], rax
.damage_kept:
    cmp     qword [rbp - 48], 0
    jne     .e_superblock               ; the fallback failed too
    mov     rax, [r10 + DB_SB_PAGE]
    mov     [rbp - 48], rax
    jmp     .attach                     ; DB_DAMAGED survives: nothing wipes it
.map_valid:

    mov     ARG1, [rbp - 16]
    call    db_bitmap_recount

    ; An open asking about integrity is told what recovery papered over; an
    ; ordinary one is not. The same split the plain open makes, and the same
    ; reason: falling back to the generation before a damaged one is the
    ; recovery protocol working. docs/RECOVERY.md.
    mov     r10, [rbp - 16]
    test    qword [r10 + DB_VERIFY], CybouDB_VERIFY_INTEGRITY
    jz      .not_asking
    mov     rax, [r10 + DB_DAMAGED]
    test    rax, rax
    jz      .not_asking
    cmp     rax, [r10 + DB_GENERATION]
    ja      .e_damaged
.not_asking:
    mov     eax, CybouDB_OK
    FRAME_END
    ret

.attach_failed:
    ; Whatever attach decided, said in its own words: a wrong key is not
    ; damage, a torn header is not a wrong key, and a caller holding a key
    ; deserves to be told which.
    mov     [rbp - 40], rax
    jmp     .close_and_fail
.e_damaged:
    mov     qword [rbp - 40], CybouDB_E_DAMAGED
    jmp     .close_and_fail
.e_superblock:
    mov     qword [rbp - 40], CybouDB_E_SUPERBLOCK
    jmp     .close_and_fail
.e_geometry:
    mov     qword [rbp - 40], CybouDB_E_GEOMETRY
    jmp     .close_and_fail
.e_features:
    mov     qword [rbp - 40], CybouDB_E_FEATURES
    jmp     .close_and_fail
.e_small:
    mov     qword [rbp - 40], CybouDB_E_SMALL
    jmp     .close_and_fail
.e_size:
    mov     qword [rbp - 40], CybouDB_E_SIZE
.close_and_fail:
    mov     ARG1, [rbp - 16]
    call    db_close
    mov     eax, [rbp - 40]
    FRAME_END
    ret
.e_busy:
    mov     r10, [rbp - 16]
    mov     ARG1, [r10 + DB_HANDLE]
    call    vfs_close
    mov     r10, [rbp - 16]
    mov     qword [r10 + DB_HANDLE], -1
    mov     eax, CybouDB_E_BUSY
    FRAME_END
    ret
.e_open:
    mov     ARG1, [rbp - 32]
    mov     ARG2, CybouDB_E_OPEN
    call    oserr_to_code
    FRAME_END
    ret

%ifdef CybouDB_LINUX
section .note.GNU-stack noalloc noexec nowrite progbits
%endif
