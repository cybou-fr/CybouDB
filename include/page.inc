; Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
; SPDX-License-Identifier: Apache-2.0
; =============================================================================
;  page.inc - CybouDB page model
; =============================================================================
;  A database file is an array of fixed-size pages. Page 0 is reserved: its
;  first 128 bytes hold the database header (see format.inc).
;
;  4096 bytes is the LOGICAL page size of the database - a property of the
;  file format, not of the machine. It is chosen because it matches the most
;  common OS page size, so in the common case a database page boundary also
;  falls on an OS page boundary.
;
;  It must never be assumed to equal the OS page size:
;    * AArch64 Linux supports 4 KiB, 16 KiB and 64 KiB base page granules,
;      and macOS on Apple silicon uses 16 KiB;
;    * on Windows the offset of a mapped view must be a multiple of the
;      system allocation granularity (64 KiB), which is unrelated to this.
;
;  Today nothing depends on the difference, because the VFS maps whole files
;  from offset 0. Once windowed mapping of a large database arrives, the VFS
;  will have to query the real os_page_size and mapping_granularity and align
;  its windows to those - while this constant stays 4096.
; =============================================================================

%ifndef CybouDB_PAGE_INC
%define CybouDB_PAGE_INC

%define CybouDB_PAGE_SIZE    4096
%define CybouDB_PAGE_SHIFT   12            ; 1 << 12 == 4096
%define CybouDB_HEADER_PAGE  0             ; index of the reserved page

; Upper bound on the page count: anything larger would overflow the 64-bit
; file size in the pages * PAGE_SIZE product.
%define CybouDB_MAX_PAGES    ((1 << (64 - CybouDB_PAGE_SHIFT)) - 1)

; -----------------------------------------------------------------------------
;  PAGES_TO_BYTES <register> - convert a page count into a byte size.
;  A shift rather than a multiply: the page size is a power of two.
; -----------------------------------------------------------------------------
%macro PAGES_TO_BYTES 1
    shl     %1, CybouDB_PAGE_SHIFT
%endmacro

; -----------------------------------------------------------------------------
;  PAGE_ADDR <destination>, <mapping base>, <page index>
;  Address of the start of a page inside the mapped file.
; -----------------------------------------------------------------------------
%macro PAGE_ADDR 3
    mov     %1, %3
    PAGES_TO_BYTES %1
    add     %1, %2
%endmacro

; -----------------------------------------------------------------------------
;  DB_PAGE <destination>, <context>, <page number>
;
;  The address of a page, given the database context. Every page access in the
;  engine computes this, 128 of them, and all of them the same way - which is
;  what makes an encrypted mode possible at all: docs/ENCRYPTED_ENGINE.md.
;
;  Today this macro is exactly the instructions those sites already contain: a
;  shift and an add, no register clobbered and no call. Converting a site to it
;  changes no machine code, and that is checked by assembling the file before
;  and after and comparing the object.
;
;  When encrypted mode arrives, the branch goes in here and every converted
;  site inherits it at once, instead of 128 edits made on a later afternoon.
;
;  The page number may be a register or a memory operand; the destination must
;  not be the context register.
; -----------------------------------------------------------------------------
%macro DB_PAGE 3
    mov     %1, %3
    shl     %1, CybouDB_PAGE_SHIFT
    add     %1, [%2 + DB_BASE]
%endmacro

%ifdef CybouDB_ENCRYPTED_PAGES
; Declared here rather than in each of the files that use DB_PAGE_HERE: the
; macro is what calls it, so the macro's header is where the dependency
; belongs. An object that never expands the macro carries an unused extern,
; which costs a symbol-table entry and nothing else.
extern db_page_resolve
%endif

; -----------------------------------------------------------------------------
;  DB_PAGE_HERE <register>, <context>
;
;  The same thing for the shape that is already holding the page number in the
;  register it wants the address in - which is most of them.
; -----------------------------------------------------------------------------
%macro DB_PAGE_HERE 2
%ifdef CybouDB_ENCRYPTED_PAGES
    ; docs/ENCRYPTED_ENGINE.md, step 3. A plain database has DB_CACHE zero and
    ; pays one compare and one perfectly predicted branch; an encrypted one
    ; goes through the resolver, which reads the page, opens it and hands back
    ; the address of the plaintext in the cache.
    cmp     qword [%2 + DB_CACHE], 0
    jne     %%encrypted
    shl     %1, CybouDB_PAGE_SHIFT
    add     %1, [%2 + DB_BASE]
    jmp     %%done
%%encrypted:
    DB_PAGE_RESOLVE %1, %2
%%done:
%else
    shl     %1, CybouDB_PAGE_SHIFT
    add     %1, [%2 + DB_BASE]
%endif
%endmacro

; -----------------------------------------------------------------------------
;  DB_PAGE_RESOLVE <register>, <context>
;
;  The call the encrypted branch makes. It is a macro of its own so that the
;  register shuffling and the saving of whatever the caller had live happens in
;  one place rather than 81, and so that the branch above reads as a branch.
;
;  Returns the address in the register it was given, or zero - and zero is a
;  page that did not verify. Every site that will use this has to learn to see
;  that, which is the work step 3 of the port is made of.
; -----------------------------------------------------------------------------
%macro DB_PAGE_RESOLVE 2
    ; Every volatile register on either convention, saved in a frame rather
    ; than on the stack one push at a time - nine pushes would leave RSP eight
    ; bytes out of alignment for the call, and the result has to be written
    ; into %1 after the restores rather than before, because %1 may be one of
    ; the registers being restored.
    sub     rsp, 96
    mov     [rsp + 0], rax
    mov     [rsp + 8], rcx
    mov     [rsp + 16], rdx
    mov     [rsp + 24], r8
    mov     [rsp + 32], r9
    mov     [rsp + 40], r10
    mov     [rsp + 48], r11
    mov     [rsp + 56], rdi
    mov     [rsp + 64], rsi

    mov     ARG2, %1
    mov     ARG1, %2
    CALL_ABI db_page_resolve
    mov     [rsp + 72], rax             ; the address, or zero

    mov     rax, [rsp + 0]
    mov     rcx, [rsp + 8]
    mov     rdx, [rsp + 16]
    mov     r8,  [rsp + 24]
    mov     r9,  [rsp + 32]
    mov     r10, [rsp + 40]
    mov     r11, [rsp + 48]
    mov     rdi, [rsp + 56]
    mov     rsi, [rsp + 64]
    mov     %1,  [rsp + 72]
    add     rsp, 96
%endmacro

%endif ; CybouDB_PAGE_INC
