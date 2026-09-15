; Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
; SPDX-License-Identifier: Apache-2.0
; =============================================================================
;  crypto/seal_dir.asm - the seal directory, and the tree that makes it trusted
; =============================================================================
;  docs/ENCRYPTED_FORMAT.md, Decisions 3 and 3b. include/crypto.inc holds the
;  byte map.
;
;  The thing being built here is not storage for tags. Storage for tags is the
;  easy half and does not authenticate anything: an adversary who restores an
;  old page together with its old entry presents a pair the AEAD accepts
;  without hesitation, because the pair is genuine - it simply belongs to last
;  week. What makes an entry trusted state is that a leaf's MAC covers the
;  entry array as it was published, a node's MAC covers its children's MACs,
;  and the root's MAC is in the superblock, which is authenticated under the
;  key. Restoring last week's page and last week's entry then fails at the
;  leaf, which no longer matches what its parent says it should be.
;
;  The MAC is SHAKE256 keyed by prefix: the key first, then a label that says
;  which kind of page this is, then the page's own bytes. A sponge absorbing a
;  fixed-length secret prefix is a MAC (this is KMAC's construction without
;  its encodings), the length is fixed so no message can be confused with a
;  longer one, and the two labels are what stop a leaf from ever being read as
;  a node. The key comes from KDF_SEAL_TREE - one purpose, one key, and not
;  the key that seals pages.
;
;  Sixteen bytes of it. A forgery has to be found online against a file whose
;  superblock is itself authenticated, and 2^-128 is not the number that
;  matters here; the number that matters is that there is no offline oracle.
; =============================================================================

%include "cyboudb.inc"
%include "crypto.inc"

BITS 64
default rel

global cyboudb_seal_geometry
global cyboudb_seal_leaf_init
global cyboudb_seal_node_init
global cyboudb_seal_entry
global cyboudb_seal_leaf_mac
global cyboudb_seal_node_mac
global cyboudb_seal_node_set_child
global cyboudb_seal_leaf_verify
global cyboudb_seal_node_verify
global cyboudb_seal_leaf_validate
global cyboudb_seal_node_validate

extern crc32c
extern cyboudb_shake256_init
extern cyboudb_shake256_update
extern cyboudb_shake256_final

section .rodata
; The labels are absorbed with their terminator, so "seal-leaf" followed by a
; node's bytes can never be the same input as "seal-node" followed by them.
lbl_leaf:  db "CybouDB/0.7/seal-leaf", 0
LBL_LEAF_LEN equ $ - lbl_leaf
lbl_node:  db "CybouDB/0.7/seal-node", 0
LBL_NODE_LEN equ $ - lbl_node

section .text

; -----------------------------------------------------------------------------
;  seal_crc(rbx = page) - recompute and store the CRC. Internal.
; -----------------------------------------------------------------------------
seal_crc:
    push    rbp
    mov     rbp, rsp
    sub     rsp, 32 + SHADOW_SPACE
    mov     ARG1, rbx
    mov     ARG2, SLEAF_CRC             ; the same offset for both page kinds
    call    crc32c
    mov     [rbx + SLEAF_CRC], eax
    mov     rsp, rbp
    pop     rbp
    ret

; =============================================================================
;  cyboudb_seal_geometry(out, total_pages)
;
;  ARG1  uint64_t *out       CybouDB_SGEO_SIZE bytes: leaves, nodes, depth,
;                            and the pages both copies cost
;  ARG2  uint64_t  total_pages
;
;  The arithmetic of Decision 3b, in the only place it is allowed to live. A
;  file that computed its geometry in two places would eventually compute it
;  two ways, and the second way would be discovered by a reader who could not
;  find the directory.
; =============================================================================
cyboudb_seal_geometry:
    FRAME_BEGIN 64, 0
    mov     [rbp - 8], rbx
    mov     [rbp - 16], r12

    mov     rbx, ARG1                   ; out
    mov     r10, ARG2                   ; total_pages

    ; leaves = ceil(total_pages / 100)
    mov     rax, r10
    add     rax, CybouDB_SEAL_ENTRIES_PER_LEAF - 1
    xor     rdx, rdx
    mov     rcx, CybouDB_SEAL_ENTRIES_PER_LEAF
    div     rcx
    mov     [rbx + SGEO_LEAVES], rax

    ; Then a level of nodes above the leaves, and above that another, until a
    ; level holds one page. That page is the root.
    mov     r11, rax                    ; how many children the next level has
    xor     r12, r12                    ; nodes so far
    xor     r8, r8                      ; depth
.level:
    mov     rax, r11
    add     rax, CybouDB_SEAL_CHILDREN_PER_NODE - 1
    xor     rdx, rdx
    mov     rcx, CybouDB_SEAL_CHILDREN_PER_NODE
    div     rcx                         ; nodes at this level
    add     r12, rax
    inc     r8
    mov     r11, rax
    cmp     r11, 1
    ja      .level

    mov     [rbx + SGEO_NODES], r12
    mov     [rbx + SGEO_DEPTH], r8

    ; What the file pays: leaves and nodes, in two copies.
    mov     rax, [rbx + SGEO_LEAVES]
    add     rax, r12
    shl     rax, 1
    mov     [rbx + SGEO_PAGES], rax

    mov     rbx, [rbp - 8]
    mov     r12, [rbp - 16]
    FRAME_END
    ret

; =============================================================================
;  cyboudb_seal_leaf_init(page, leaf_index, generation, seal_epoch)
;
;  first_page follows from the index, so it is derived here rather than passed
;  in: two callers that disagreed about which pages a leaf covers would produce
;  a directory that indexes nothing.
; =============================================================================
cyboudb_seal_leaf_init:
    FRAME_BEGIN 64, 0
    mov     [rbp - 8], rbx
    mov     [rbp - 16], r12
    mov     [rbp - 24], r13

    mov     rbx, ARG1
    mov     r12, ARG2                   ; leaf_index
    mov     [rbp - 32], ARG3            ; generation
    mov     [rbp - 40], ARG4            ; seal_epoch

    xor     rax, rax
    xor     rcx, rcx
.zero:
    mov     [rbx + rcx], rax
    add     rcx, 8
    cmp     rcx, CybouDB_PAGE_SIZE
    jb      .zero

    mov     dword [rbx + SLEAF_MAGIC], CybouDB_SEAL_LEAF_MAGIC
    mov     dword [rbx + SLEAF_VERSION], CybouDB_SEAL_VERSION
    mov     [rbx + SLEAF_INDEX], r12
    mov     rax, r12
    mov     rcx, CybouDB_SEAL_ENTRIES_PER_LEAF
    mul     rcx
    mov     [rbx + SLEAF_FIRST_PAGE], rax
    mov     rax, [rbp - 32]
    mov     [rbx + SLEAF_GENERATION], rax
    mov     rax, [rbp - 40]
    mov     [rbx + SLEAF_SEAL_EPOCH], rax

    call    seal_crc

    mov     rbx, [rbp - 8]
    mov     r12, [rbp - 16]
    mov     r13, [rbp - 24]
    FRAME_END
    ret

; =============================================================================
;  cyboudb_seal_node_init(page, node_index, level, generation, seal_epoch)
; =============================================================================
cyboudb_seal_node_init:
    FRAME_BEGIN 64, 0
    mov     [rbp - 8], rbx

    mov     rbx, ARG1
    mov     [rbp - 16], ARG2            ; node_index
    mov     [rbp - 24], ARG3            ; level
    mov     [rbp - 32], ARG4            ; generation
    mov     rax, IN_ARG5
    mov     [rbp - 40], rax             ; seal_epoch

    xor     rax, rax
    xor     rcx, rcx
.zero:
    mov     [rbx + rcx], rax
    add     rcx, 8
    cmp     rcx, CybouDB_PAGE_SIZE
    jb      .zero

    mov     dword [rbx + SNODE_MAGIC], CybouDB_SEAL_NODE_MAGIC
    mov     dword [rbx + SNODE_VERSION], CybouDB_SEAL_VERSION
    mov     rax, [rbp - 16]
    mov     [rbx + SNODE_INDEX], rax
    mov     rax, [rbp - 24]
    mov     [rbx + SNODE_LEVEL], rax
    mov     rax, [rbp - 32]
    mov     [rbx + SNODE_GENERATION], rax
    mov     rax, [rbp - 40]
    mov     [rbx + SNODE_SEAL_EPOCH], rax

    call    seal_crc

    mov     rbx, [rbp - 8]
    FRAME_END
    ret

; =============================================================================
;  cyboudb_seal_entry(leaf_page, page_number) -> uint8_t *entry, or NULL
;
;  NULL means this leaf does not cover that page - a caller that reached for
;  the wrong leaf, which is a bug rather than a fact about the file, and one
;  worth finding at the call site instead of at the tag comparison.
; =============================================================================
cyboudb_seal_entry:
    mov     r10, ARG1
    mov     r11, ARG2
    sub     r11, [r10 + SLEAF_FIRST_PAGE]
    jb      .miss
    cmp     r11, CybouDB_SEAL_ENTRIES_PER_LEAF
    jae     .miss
    mov     rax, r11
    imul    rax, rax, SENTRY_SIZE
    lea     rax, [r10 + rax + SLEAF_ENTRIES]
    ret
.miss:
    xor     eax, eax
    ret

; -----------------------------------------------------------------------------
;  seal_mac(rbx = page, r12 = key, r13 = out, r14 = label, r15 = label_len,
;           r10 = how many bytes of the page to cover)
;
;  Internal, and the only place either MAC is computed. Leaf and node differ
;  by a label and a length, so giving them two implementations would be two
;  chances to disagree about the construction.
; -----------------------------------------------------------------------------
seal_mac:
    push    rbp
    mov     rbp, rsp
    sub     rsp, CybouDB_SHCTX_SIZE + 32 + SHADOW_SPACE
    lea     r11, [rsp + SHADOW_SPACE]   ; the sponge context

    mov     [rsp + SHADOW_SPACE + CybouDB_SHCTX_SIZE], r11
    mov     [rsp + SHADOW_SPACE + CybouDB_SHCTX_SIZE + 8], r10

    mov     ARG1, r11
    call    cyboudb_shake256_init

    mov     ARG1, [rsp + SHADOW_SPACE + CybouDB_SHCTX_SIZE]
    mov     ARG2, r12                   ; the key, first and fixed-length
    mov     ARG3, CybouDB_AEAD_KEY_SIZE
    call    cyboudb_shake256_update

    mov     ARG1, [rsp + SHADOW_SPACE + CybouDB_SHCTX_SIZE]
    mov     ARG2, r14                   ; which kind of page this is
    mov     ARG3, r15
    call    cyboudb_shake256_update

    mov     ARG1, [rsp + SHADOW_SPACE + CybouDB_SHCTX_SIZE]
    lea     ARG2, [rbx + SLEAF_MAC_FROM]
    mov     ARG3, [rsp + SHADOW_SPACE + CybouDB_SHCTX_SIZE + 8]
    call    cyboudb_shake256_update

    mov     ARG1, [rsp + SHADOW_SPACE + CybouDB_SHCTX_SIZE]
    mov     ARG2, r13
    mov     ARG3, CybouDB_SEAL_MAC_SIZE
    call    cyboudb_shake256_final

    mov     rsp, rbp
    pop     rbp
    ret

; =============================================================================
;  cyboudb_seal_leaf_mac(out, key, leaf_page)
;  cyboudb_seal_node_mac(out, key, node_page)
;
;  ARG1  uint8_t       *out       16 bytes
;  ARG2  const uint8_t *key       32, from KDF_SEAL_TREE
;  ARG3  const uint8_t *page
;
;  The fields the MAC covers are read from the page, never from arguments: a
;  MAC computed over what the caller believes the page says would authenticate
;  the belief rather than the page.
; =============================================================================
cyboudb_seal_leaf_mac:
    FRAME_BEGIN 64, 0
    mov     [rbp - 8], rbx
    mov     [rbp - 16], r12
    mov     [rbp - 24], r13
    mov     [rbp - 32], r14
    mov     [rbp - 40], r15

    mov     r13, ARG1
    mov     r12, ARG2
    mov     rbx, ARG3
    lea     r14, [lbl_leaf]
    mov     r15, LBL_LEAF_LEN
    mov     r10, SLEAF_MAC_TO - SLEAF_MAC_FROM
    call    seal_mac

    mov     rbx, [rbp - 8]
    mov     r12, [rbp - 16]
    mov     r13, [rbp - 24]
    mov     r14, [rbp - 32]
    mov     r15, [rbp - 40]
    FRAME_END
    ret

cyboudb_seal_node_mac:
    FRAME_BEGIN 64, 0
    mov     [rbp - 8], rbx
    mov     [rbp - 16], r12
    mov     [rbp - 24], r13
    mov     [rbp - 32], r14
    mov     [rbp - 40], r15

    mov     r13, ARG1
    mov     r12, ARG2
    mov     rbx, ARG3
    lea     r14, [lbl_node]
    mov     r15, LBL_NODE_LEN
    mov     r10, SNODE_MAC_TO - SNODE_MAC_FROM
    call    seal_mac

    mov     rbx, [rbp - 8]
    mov     r12, [rbp - 16]
    mov     r13, [rbp - 24]
    mov     r14, [rbp - 32]
    mov     r15, [rbp - 40]
    FRAME_END
    ret

; =============================================================================
;  cyboudb_seal_node_set_child(node_page, slot, mac) -> int
;
;  Writes one child's MAC and raises child_count if the slot is past it, so a
;  node always says how far its children reach.
; =============================================================================
cyboudb_seal_node_set_child:
    FRAME_BEGIN 48, 0
    mov     [rbp - 8], rbx

    mov     rbx, ARG1
    mov     r10, ARG2                   ; slot
    mov     r11, ARG3                   ; mac

    cmp     r10, CybouDB_SEAL_CHILDREN_PER_NODE
    jae     .refuse

    mov     rax, r10
    shl     rax, 4                      ; 16 bytes per child
    lea     r8, [rbx + rax + SNODE_CHILDREN]
    mov     rax, [r11]
    mov     [r8], rax
    mov     rax, [r11 + 8]
    mov     [r8 + 8], rax

    inc     r10
    cmp     r10, [rbx + SNODE_CHILD_COUNT]
    jbe     .counted
    mov     [rbx + SNODE_CHILD_COUNT], r10
.counted:
    call    seal_crc
    xor     eax, eax
    jmp     .done
.refuse:
    mov     eax, SEAL_E_FIELDS
.done:
    mov     rbx, [rbp - 8]
    FRAME_END
    ret

; =============================================================================
;  cyboudb_seal_leaf_verify(key, leaf_page, expected_mac) -> SEAL_OK or
;                                                            SEAL_E_MAC
;  cyboudb_seal_node_verify(key, node_page, expected_mac)
;
;  The comparison is constant time for the same reason the AEAD's is: a
;  comparison that stops at the first wrong byte tells an attacker how many
;  bytes were right.
; =============================================================================
cyboudb_seal_leaf_verify:
    FRAME_BEGIN 64, 0
    mov     [rbp - 8], rbx
    mov     [rbp - 16], r12

    mov     rbx, ARG3                   ; the MAC the parent published
    mov     r12, ARG1                   ; key
    mov     ARG3, ARG2                  ; page
    mov     ARG2, r12
    lea     ARG1, [rbp - 48]
    call    cyboudb_seal_leaf_mac

    mov     rax, [rbp - 48]
    xor     rax, [rbx]
    mov     rdx, [rbp - 40]
    xor     rdx, [rbx + 8]
    or      rax, rdx
    jnz     .bad
    xor     eax, eax
    jmp     .done
.bad:
    mov     eax, SEAL_E_MAC
.done:
    mov     rbx, [rbp - 8]
    mov     r12, [rbp - 16]
    FRAME_END
    ret

cyboudb_seal_node_verify:
    FRAME_BEGIN 64, 0
    mov     [rbp - 8], rbx
    mov     [rbp - 16], r12

    mov     rbx, ARG3
    mov     r12, ARG1
    mov     ARG3, ARG2
    mov     ARG2, r12
    lea     ARG1, [rbp - 48]
    call    cyboudb_seal_node_mac

    mov     rax, [rbp - 48]
    xor     rax, [rbx]
    mov     rdx, [rbp - 40]
    xor     rdx, [rbx + 8]
    or      rax, rdx
    jnz     .bad
    xor     eax, eax
    jmp     .done
.bad:
    mov     eax, SEAL_E_MAC
.done:
    mov     rbx, [rbp - 8]
    mov     r12, [rbp - 16]
    FRAME_END
    ret

; =============================================================================
;  cyboudb_seal_leaf_validate(page) -> SEAL_OK or a SEAL_E_* code
;  cyboudb_seal_node_validate(page)
;
;  Structural, and key-free, for the same reason the crypto root's validator
;  is: damage and forgery are different sentences, and only the first of them
;  can be decided from the bytes. A page that passes here has still proved
;  nothing about being current - that is what the MAC is for.
; =============================================================================
cyboudb_seal_leaf_validate:
    FRAME_BEGIN 48, 0
    mov     [rbp - 8], rbx
    mov     rbx, ARG1

    cmp     dword [rbx + SLEAF_MAGIC], CybouDB_SEAL_LEAF_MAGIC
    jne     .e_magic
    cmp     dword [rbx + SLEAF_VERSION], CybouDB_SEAL_VERSION
    jne     .e_version

    mov     ARG1, rbx
    mov     ARG2, SLEAF_CRC
    CALL_ABI crc32c
    cmp     eax, [rbx + SLEAF_CRC]
    jne     .e_crc

    ; first_page follows from the index, and a leaf that says otherwise would
    ; hand out entries for pages it does not cover.
    mov     rax, [rbx + SLEAF_INDEX]
    mov     rcx, CybouDB_SEAL_ENTRIES_PER_LEAF
    mul     rcx
    jc      .e_fields
    cmp     rax, [rbx + SLEAF_FIRST_PAGE]
    jne     .e_fields

    mov     rax, [rbx + SLEAF_RESERVED]
    or      rax, [rbx + SLEAF_RESERVED + 8]
    or      rax, [rbx + SLEAF_RESERVED + 16]
    jnz     .e_reserved

    xor     rax, rax
    xor     rcx, rcx
.tail:
    or      rax, [rbx + SLEAF_RESERVED_TAIL + rcx]
    add     rcx, 8
    cmp     rcx, 24
    jb      .tail
    or      eax, [rbx + SLEAF_RESERVED_TAIL + 24]
    jnz     .e_reserved

    xor     eax, eax
    jmp     .done
.e_magic:
    mov     eax, SEAL_E_MAGIC
    jmp     .done
.e_version:
    mov     eax, SEAL_E_VERSION
    jmp     .done
.e_crc:
    mov     eax, SEAL_E_CRC
    jmp     .done
.e_fields:
    mov     eax, SEAL_E_FIELDS
    jmp     .done
.e_reserved:
    mov     eax, SEAL_E_RESERVED
.done:
    mov     rbx, [rbp - 8]
    FRAME_END
    ret

cyboudb_seal_node_validate:
    FRAME_BEGIN 48, 0
    mov     [rbp - 8], rbx
    mov     [rbp - 16], r12
    mov     rbx, ARG1

    cmp     dword [rbx + SNODE_MAGIC], CybouDB_SEAL_NODE_MAGIC
    jne     .e_magic
    cmp     dword [rbx + SNODE_VERSION], CybouDB_SEAL_VERSION
    jne     .e_version

    mov     ARG1, rbx
    mov     ARG2, SNODE_CRC
    CALL_ABI crc32c
    cmp     eax, [rbx + SNODE_CRC]
    jne     .e_crc

    cmp     qword [rbx + SNODE_LEVEL], 0
    je      .e_fields                   ; level 0 is a leaf, and leaves are not nodes
    mov     r12, [rbx + SNODE_CHILD_COUNT]
    cmp     r12, CybouDB_SEAL_CHILDREN_PER_NODE
    ja      .e_fields

    mov     rax, [rbx + SNODE_RESERVED]
    or      rax, [rbx + SNODE_RESERVED + 8]
    jnz     .e_reserved
    mov     rax, [rbx + SNODE_RESERVED_TAIL]
    or      eax, [rbx + SNODE_RESERVED_TAIL + 8]
    jnz     .e_reserved

    ; Past child_count the slots are zero, so a child dropped by a shrinking
    ; count cannot sit there being vouched for by nobody.
    mov     rcx, r12
    shl     rcx, 4
    xor     rax, rax
.tail:
    cmp     rcx, CybouDB_SEAL_CHILDREN_PER_NODE * 16
    jae     .tail_done
    or      rax, [rbx + SNODE_CHILDREN + rcx]
    add     rcx, 8
    jmp     .tail
.tail_done:
    test    rax, rax
    jnz     .e_fields

    xor     eax, eax
    jmp     .done
.e_magic:
    mov     eax, SEAL_E_MAGIC
    jmp     .done
.e_version:
    mov     eax, SEAL_E_VERSION
    jmp     .done
.e_crc:
    mov     eax, SEAL_E_CRC
    jmp     .done
.e_fields:
    mov     eax, SEAL_E_FIELDS
    jmp     .done
.e_reserved:
    mov     eax, SEAL_E_RESERVED
.done:
    mov     rbx, [rbp - 8]
    mov     r12, [rbp - 16]
    FRAME_END
    ret

%ifdef CybouDB_LINUX
section .note.GNU-stack noalloc noexec nowrite progbits
%endif
