; Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
; SPDX-License-Identifier: Apache-2.0
; =============================================================================
;  crypto/crypto_root.asm - the page feature_root points at, and its validator
; =============================================================================
;  include/crypto.inc holds the byte map. This file is the only thing that
;  writes it and the only thing that judges it, for the reason page_seal.asm
;  gives about associated data: two writers that lay a structure out slightly
;  differently do not produce a warning, they produce a file that a build which
;  is not wrong cannot open.
;
;  The validator answers exactly one question - is this a crypto root this
;  build can work with - and it answers it before any key exists. That is what
;  keeps the three refusals apart:
;
;    CROOT_E_MAGIC     this is not a crypto root page
;    CROOT_E_CRC       this page is damaged
;    (unwrap failure)  this key does not open this file
;
;  The last one is not in this file at all, and cannot be: it is not a
;  property of the bytes. A validator that tried to report it would have to
;  guess, and guessing about keys is how an engine ends up telling a user
;  their database is corrupt when they simply typed the wrong passphrase.
;
;  Nothing here is secret and nothing here keeps a secret: the wrapped keys
;  carry their own tags, and CROOT_MAC - written and checked once the root key
;  is in hand, which is a later step - is what authenticates the geometry. A
;  CRC is a disk check. It is not a defence and does not pretend to be one.
; =============================================================================

%include "cyboudb.inc"
%include "crypto.inc"

BITS 64
default rel

global cyboudb_crypto_root_init
global cyboudb_crypto_root_add_slot
global cyboudb_crypto_root_find
global cyboudb_crypto_root_validate

extern crc32c

section .text

; =============================================================================
;  croot_crc(rbx = page) - recompute and store the CRC over [0, CROOT_CRC)
;
;  Internal. Preserves rbx, because crc32c does.
; =============================================================================
croot_crc:
    push    rbp
    mov     rbp, rsp
    sub     rsp, 32 + SHADOW_SPACE
    mov     ARG1, rbx
    mov     ARG2, CROOT_CRC_LEN
    call    crc32c
    mov     [rbx + CROOT_CRC], eax
    mov     rsp, rbp
    pop     rbp
    ret

; =============================================================================
;  cyboudb_crypto_root_init(page, seal_epoch, seal_dir_first, seal_dir_pages,
;                           seal_tree_root, total_pages) -> int
;
;  Writes a complete crypto root into a page and returns what the validator
;  makes of it, so a caller that asks for an impossible geometry finds out
;  here rather than when the file is next opened.
; =============================================================================
cyboudb_crypto_root_init:
    FRAME_BEGIN 64, 0
    mov     [rbp - 8], rbx
    mov     [rbp - 16], r12

    mov     rbx, ARG1                   ; page
    mov     [rbp - 24], ARG2            ; seal_epoch
    mov     [rbp - 32], ARG3            ; seal_dir_first
    mov     [rbp - 40], ARG4            ; seal_dir_pages
    mov     rax, IN_ARG5
    mov     [rbp - 48], rax             ; seal_tree_root
    mov     rax, IN_ARG6
    mov     [rbp - 56], rax             ; total_pages

    ; A crypto root is written whole or not at all: everything this build does
    ; not set is zero, so a later build that learns to read a field this one
    ; never wrote reads the absence rather than a leftover.
    xor     eax, eax
    xor     r12, r12
.zero:
    mov     [rbx + r12], rax
    add     r12, 8
    cmp     r12, CybouDB_PAGE_SIZE
    jb      .zero

    mov     dword [rbx + CROOT_MAGIC], CybouDB_CROOT_MAGIC
    mov     dword [rbx + CROOT_VERSION], CybouDB_CROOT_VERSION
    mov     dword [rbx + CROOT_AEAD_ID], CROOT_AEAD_XCHACHA20_POLY1305
    mov     dword [rbx + CROOT_KDF_ID], CROOT_KDF_SHAKE256

    mov     rax, [rbp - 24]
    mov     [rbx + CROOT_SEAL_EPOCH], rax
    mov     rax, [rbp - 32]
    mov     [rbx + CROOT_SEAL_DIR_FIRST], rax
    mov     rax, [rbp - 40]
    mov     [rbx + CROOT_SEAL_DIR_PAGES], rax
    mov     rax, [rbp - 48]
    mov     [rbx + CROOT_SEAL_TREE_ROOT], rax
    mov     rax, [rbp - 56]
    mov     [rbx + CROOT_TOTAL_PAGES], rax

    call    croot_crc

    mov     ARG1, rbx
    call    cyboudb_crypto_root_validate

    mov     rbx, [rbp - 8]
    mov     r12, [rbp - 16]
    FRAME_END
    ret

; =============================================================================
;  cyboudb_crypto_root_add_slot(page, key_id, purpose, wrapped) -> int
;
;  Appends one wrapped scoped key. Refuses a zero or duplicate key id and a
;  purpose outside the closed list, because a slot table that contradicts
;  itself is what the validator would later refuse the whole file for.
; =============================================================================
cyboudb_crypto_root_add_slot:
    FRAME_BEGIN 64, 0
    mov     [rbp - 8], rbx
    mov     [rbp - 16], r12
    mov     [rbp - 24], r13

    mov     rbx, ARG1                   ; page
    mov     r12, ARG2                   ; key_id
    mov     r13, ARG3                   ; purpose
    mov     [rbp - 32], ARG4            ; wrapped

    test    r12, r12
    jz      .refuse
    test    r13, r13
    jz      .refuse
    cmp     r13, KDF_PURPOSE_MAX
    ja      .refuse

    mov     r8d, [rbx + CROOT_SLOT_COUNT]
    cmp     r8d, CybouDB_CROOT_SLOT_MAX
    jae     .refuse

    ; No duplicate key ids: two slots claiming one id is an ambiguity the
    ; opener would have to resolve by picking, and picking is guessing.
    xor     r9, r9
.dup:
    cmp     r9d, r8d
    jae     .append
    mov     rax, r9
    imul    rax, rax, CROOT_SLOT_SIZE
    mov     r10, [rbx + rax + CROOT_SLOTS + CSLOT_KEY_ID]
    cmp     r10, r12
    je      .refuse
    inc     r9
    jmp     .dup

.append:
    mov     eax, r8d
    imul    rax, rax, CROOT_SLOT_SIZE
    lea     r9, [rbx + rax + CROOT_SLOTS]
    mov     [r9 + CSLOT_KEY_ID], r12
    mov     [r9 + CSLOT_PURPOSE], r13d
    mov     dword [r9 + CSLOT_FLAGS], 0
    mov     qword [r9 + CSLOT_RESERVED], 0

    mov     r10, [rbp - 32]             ; wrapped
    xor     rax, rax
.copy:
    mov     r11, [r10 + rax]
    mov     [r9 + CSLOT_WRAPPED + rax], r11
    add     rax, 8
    cmp     rax, CybouDB_WRAPPED_KEY_SIZE
    jb      .copy

    inc     r8d
    mov     [rbx + CROOT_SLOT_COUNT], r8d

    call    croot_crc
    xor     eax, eax
    jmp     .done

.refuse:
    mov     eax, CROOT_E_SLOTS
.done:
    mov     rbx, [rbp - 8]
    mov     r12, [rbp - 16]
    mov     r13, [rbp - 24]
    FRAME_END
    ret

; =============================================================================
;  cyboudb_crypto_root_find(page, key_id) -> const uint8_t *slot, or NULL
; =============================================================================
cyboudb_crypto_root_find:
    mov     r10, ARG1
    mov     r11, ARG2
    mov     ecx, [r10 + CROOT_SLOT_COUNT]
    xor     r8, r8
.scan:
    cmp     r8d, ecx
    jae     .miss
    mov     rax, r8
    imul    rax, rax, CROOT_SLOT_SIZE
    lea     rax, [r10 + rax + CROOT_SLOTS]
    mov     r9, [rax + CSLOT_KEY_ID]
    cmp     r9, r11
    je      .found
    inc     r8
    jmp     .scan
.miss:
    xor     eax, eax
.found:
    ret

; =============================================================================
;  cyboudb_crypto_root_validate(page) -> CROOT_OK or a CROOT_E_* code
;
;  Structural only. Every refusal here is answerable without a key, and none
;  of them means the key was wrong.
; =============================================================================
cyboudb_crypto_root_validate:
    FRAME_BEGIN 48, 0
    mov     [rbp - 8], rbx
    mov     [rbp - 16], r12
    mov     [rbp - 24], r13

    mov     rbx, ARG1

    cmp     dword [rbx + CROOT_MAGIC], CybouDB_CROOT_MAGIC
    jne     .e_magic
    cmp     dword [rbx + CROOT_VERSION], CybouDB_CROOT_VERSION
    jne     .e_version

    ; The disk check comes before every interpretation below it: a torn write
    ; can produce any field value at all, and reporting the first field it
    ; happens to contradict would name the wrong fault.
    mov     ARG1, rbx
    mov     ARG2, CROOT_CRC_LEN
    CALL_ABI crc32c
    cmp     eax, [rbx + CROOT_CRC]
    jne     .e_crc

    cmp     dword [rbx + CROOT_AEAD_ID], CROOT_AEAD_XCHACHA20_POLY1305
    jne     .e_aead
    cmp     dword [rbx + CROOT_KDF_ID], CROOT_KDF_SHAKE256
    jne     .e_kdf

    ; Reserved means reserved: a build that wrote something here meant it, and
    ; this build does not know what. docs/ENCRYPTED_FORMAT.md refuses by name
    ; rather than ignoring, at every level of the format.
    cmp     dword [rbx + CROOT_RESERVED], 0
    jne     .e_reserved
    mov     rax, [rbx + CROOT_RESERVED_TAIL]
    test    rax, rax
    jnz     .e_reserved
    mov     rax, [rbx + CROOT_RESERVED_PAD]
    or      rax, [rbx + CROOT_RESERVED_PAD + 8]
    or      rax, [rbx + CROOT_RESERVED_PAD + 16]
    or      rax, [rbx + CROOT_RESERVED_PAD + 24]
    or      rax, [rbx + CROOT_RESERVED_PAD + 32]
    jnz     .e_reserved
    cmp     dword [rbx + CROOT_RESERVED_PAD + 40], 0
    jne     .e_reserved

    ; --- geometry: the seal directory has to fit in the file it describes ---
    mov     r12, [rbx + CROOT_TOTAL_PAGES]
    cmp     r12, CybouDB_MIN_PAGES
    jb      .e_geometry

    mov     rax, [rbx + CROOT_SEAL_DIR_FIRST]
    cmp     rax, CybouDB_MIN_PAGES
    jb      .e_geometry
    mov     r13, [rbx + CROOT_SEAL_DIR_PAGES]
    test    r13, r13
    jz      .e_geometry
    mov     rdx, r13
    shl     rdx, 1                      ; two copies, A and B
    jc      .e_geometry
    add     rax, rdx
    jc      .e_geometry
    cmp     rax, r12
    ja      .e_geometry

    mov     rax, [rbx + CROOT_SEAL_TREE_ROOT]
    test    rax, rax
    jz      .e_geometry
    cmp     rax, r12
    jae     .e_geometry

    ; The manifest arrives in step 10; zero until then, and a page of this
    ; file once it does.
    mov     rax, [rbx + CROOT_MANIFEST_ROOT]
    test    rax, rax
    jz      .kem_root
    cmp     rax, r12
    jae     .e_geometry

.kem_root:
    ; Zero when the database is sealed to no public key at all, which is a
    ; legal file and not an unfinished one.
    mov     rax, [rbx + CROOT_KEM_ROOT]
    test    rax, rax
    jz      .slots
    cmp     rax, CybouDB_MIN_PAGES
    jb      .e_geometry
    cmp     rax, r12
    jae     .e_geometry

.slots:
    mov     eax, [rbx + CROOT_SLOT_COUNT]
    cmp     eax, CybouDB_CROOT_SLOT_MAX
    ja      .e_slots
    mov     r12d, eax
    xor     r13, r13
.slot:
    cmp     r13, r12
    jae     .slots_tail
    mov     rax, r13
    imul    rax, rax, CROOT_SLOT_SIZE
    lea     r8, [rbx + rax + CROOT_SLOTS]

    mov     r9, [r8 + CSLOT_KEY_ID]
    test    r9, r9
    jz      .e_slots
    mov     r10d, [r8 + CSLOT_PURPOSE]
    test    r10d, r10d
    jz      .e_slots
    cmp     r10d, KDF_PURPOSE_MAX
    ja      .e_slots
    cmp     dword [r8 + CSLOT_FLAGS], 0
    jne     .e_slots
    cmp     qword [r8 + CSLOT_RESERVED], 0
    jne     .e_slots

    xor     r10, r10
.dup:
    cmp     r10, r13
    jae     .next
    mov     rax, r10
    imul    rax, rax, CROOT_SLOT_SIZE
    mov     r11, [rbx + rax + CROOT_SLOTS + CSLOT_KEY_ID]
    cmp     r11, r9
    je      .e_slots
    inc     r10
    jmp     .dup
.next:
    inc     r13
    jmp     .slot

    ; Past the count the table is zero, so a slot that was removed cannot be
    ; resurrected by a count that grows again.
.slots_tail:
    mov     r13, r12
.tail:
    cmp     r13, CybouDB_CROOT_SLOT_MAX
    jae     .ok
    mov     rax, r13
    imul    rax, rax, CROOT_SLOT_SIZE
    lea     r8, [rbx + rax + CROOT_SLOTS]
    xor     r9, r9
    xor     r10, r10
.tail_word:
    or      r9, [r8 + r10 * 8]
    inc     r10
    cmp     r10, CROOT_SLOT_SIZE / 8
    jb      .tail_word
    test    r9, r9
    jnz     .e_slots
    inc     r13
    jmp     .tail

.ok:
    xor     eax, eax
    jmp     .done
.e_magic:
    mov     eax, CROOT_E_MAGIC
    jmp     .done
.e_version:
    mov     eax, CROOT_E_VERSION
    jmp     .done
.e_crc:
    mov     eax, CROOT_E_CRC
    jmp     .done
.e_aead:
    mov     eax, CROOT_E_AEAD
    jmp     .done
.e_kdf:
    mov     eax, CROOT_E_KDF
    jmp     .done
.e_geometry:
    mov     eax, CROOT_E_GEOMETRY
    jmp     .done
.e_reserved:
    mov     eax, CROOT_E_RESERVED
    jmp     .done
.e_slots:
    mov     eax, CROOT_E_SLOTS
.done:
    mov     rbx, [rbp - 8]
    mov     r12, [rbp - 16]
    mov     r13, [rbp - 24]
    FRAME_END
    ret
