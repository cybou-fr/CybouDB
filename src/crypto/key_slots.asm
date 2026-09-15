; Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
; SPDX-License-Identifier: Apache-2.0
; =============================================================================
;  crypto/key_slots.asm - sealing a database to a public key, and opening it
; =============================================================================
;  docs/PQ_KEM.md, and include/crypto.inc for the byte map. This is step 5:
;  the arrow between the KEM and the key hierarchy, and it is one arrow wide.
;
;      encapsulation key --encaps--> shared secret
;                                        |  KDF(METADATA_KEK, ss,
;                                        |      "kem-slot" | id)
;                                        v
;                                      a KEK --wraps--> the database root key
;
;  Opening runs it backwards with a decapsulation key. Nothing below the KDF
;  knows a KEM was involved, which is the property the design was chosen for:
;  if ML-KEM is replaced, what changes is the first arrow.
;
;  Two things this file does that the primitive deliberately does not:
;
;    It draws the KEM message itself, with os_random. cyboudb_mlkem_encaps
;    takes m as an argument so that a test can run it against a value another
;    implementation used - but at this level a caller supplying m is a caller
;    who can supply a weak one, and there is no reason to offer that.
;
;    It reports a failure to open as CybouDB_E_KEY and never as damage. A
;    decapsulation cannot fail, so the AEAD tag is the only thing that decides
;    whether a key was right, exactly as docs/KEY_HIERARCHY.md requires.
; =============================================================================

%include "cyboudb.inc"
%include "crypto.inc"

BITS 64
default rel

global cyboudb_kem_key_id
global cyboudb_kem_seal_root
global cyboudb_kem_open_root
global cyboudb_keypage_init
global cyboudb_keypage_add
global cyboudb_keypage_find
global cyboudb_keypage_validate

extern crc32c
extern os_random
extern cyboudb_sha3_256
extern cyboudb_kdf
extern cyboudb_key_wrap
extern cyboudb_key_unwrap
extern cyboudb_mlkem_encaps
extern cyboudb_mlkem_decaps

section .rodata
; Eight bytes, so the context is a fixed length and a key id cannot be read as
; part of the label.
kem_label: db "kem-slot"

section .text

; =============================================================================
;  cyboudb_kem_key_id(out, ek) -> uint64
;
;  ARG1  uint8_t       *out    8 bytes, may be NULL
;  ARG2  const uint8_t *ek     1184
;
;  The first eight bytes of H(ek). A hint, not an authority: two keys that
;  collided here would both be tried and one of them would fail to unwrap,
;  which is the same thing that happens when the wrong key is offered.
; =============================================================================
cyboudb_kem_key_id:
    FRAME_BEGIN 96, 0
    mov     [rbp - 8], rbx
    mov     rbx, ARG1

    mov     ARG1, rbp
    sub     ARG1, 64                    ; a 32-byte digest at [rbp-64, rbp-32)
    mov     ARG3, CybouDB_MLKEM_EK_BYTES
    ; ARG2 is still ek: it arrived there and nothing above has touched it.
    call    cyboudb_sha3_256

    mov     rax, [rbp - 64]
    test    rbx, rbx
    jz      .no_out
    mov     [rbx], rax
.no_out:
    mov     rbx, [rbp - 8]
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  kem_context(rbx = out 16 bytes, r12 = key_id) - "kem-slot" then the id.
;  Internal, and the only place the context is laid out: two callers that
;  built it differently would derive two different KEKs from one secret and
;  discover it at the unwrap.
; -----------------------------------------------------------------------------
kem_context:
    lea     rax, [kem_label]
    mov     rcx, [rax]
    mov     [rbx], rcx
    mov     [rbx + 8], r12
    ret

; =============================================================================
;  cyboudb_kem_seal_root(slot, ek, root_key, key_id, aad, aad_len) -> int
;
;  ARG1  uint8_t       *slot      KSLOT_SIZE bytes, filled in
;  ARG2  const uint8_t *ek        1184
;  ARG3  const uint8_t *root_key  32
;  ARG4  uint64_t       key_id
;  ARG5  const uint8_t *aad       binds the slot to its database
;  ARG6  uint64_t       aad_len
;
;  Frame:
;    [rbp - 8..32]  saved rbx, r12, r13
;    [rbp - 40] slot  [rbp - 48] root_key  [rbp - 56] aad  [rbp - 64] aad_len
;    [rbp - 128] m, the KEM message, 32 bytes drawn here
;    [rbp - 192] ss, the shared secret
;    [rbp - 256] kek
;    [rbp - 288] context, 16 bytes
; =============================================================================
%define SR_M       128
%define SR_SS      192
%define SR_KEK     256
%define SR_CTX     288
%define SR_FRAME   320

cyboudb_kem_seal_root:
    FRAME_BEGIN SR_FRAME, 2
    mov     [rbp - 8], rbx
    mov     [rbp - 16], r12
    mov     [rbp - 24], r13

    mov     [rbp - 40], ARG1            ; slot
    mov     r13, ARG2                   ; ek
    mov     [rbp - 48], ARG3            ; root_key
    mov     r12, ARG4                   ; key_id
    mov     rax, IN_ARG5
    mov     [rbp - 56], rax
    mov     rax, IN_ARG6
    mov     [rbp - 64], rax

    ; The message is drawn here and nowhere else.
    mov     ARG1, rbp
    sub     ARG1, SR_M
    mov     ARG2, 32
    call    os_random
    test    eax, eax
    jnz     .no_randomness

    mov     rbx, [rbp - 40]
    mov     [rbx + KSLOT_KEY_ID], r12
    mov     dword [rbx + KSLOT_FLAGS], 0
    mov     dword [rbx + KSLOT_RESERVED], 0

    mov     ARG1, rbx
    add     ARG1, KSLOT_KEM_CT
    mov     ARG2, rbp
    sub     ARG2, SR_SS
    mov     ARG3, r13
    mov     ARG4, rbp
    sub     ARG4, SR_M
    call    cyboudb_mlkem_encaps

    mov     rbx, rbp
    sub     rbx, SR_CTX
    call    kem_context

    mov     ARG1, rbp
    sub     ARG1, SR_KEK
    mov     ARG2, 32
    mov     ARG3, KDF_METADATA_KEK
    mov     ARG4, rbp
    sub     ARG4, SR_SS
    mov     rax, rbp
    sub     rax, SR_CTX
    PASS_ARG5 rax
    mov     rax, KEM_CONTEXT_LEN
    PASS_ARG6 rax
    call    cyboudb_kdf
    test    eax, eax
    jnz     .refused

    mov     rbx, [rbp - 40]
    mov     ARG1, rbx
    add     ARG1, KSLOT_WRAPPED
    mov     ARG2, rbp
    sub     ARG2, SR_KEK
    mov     ARG3, [rbp - 48]
    mov     ARG4, [rbp - 56]
    mov     rax, [rbp - 64]
    PASS_ARG5 rax
    call    cyboudb_key_wrap
    test    eax, eax
    jnz     .refused

    xor     eax, eax
    jmp     .done

.no_randomness:
    mov     eax, CybouDB_E_STATE        ; the OS would not give us randomness
    jmp     .done
.refused:
    mov     eax, CybouDB_E_KEY
.done:
    ; The shared secret and the KEK are secrets of this frame, and the frame is
    ; about to become somebody else's stack.
    push    rax
    lea     r10, [rbp - SR_CTX]         ; everything secret in this frame
    xor     rax, rax
    xor     rcx, rcx
.wipe:
    mov     [r10 + rcx], rax
    add     rcx, 8
    cmp     rcx, SR_CTX - 96
    jb      .wipe
    pop     rax

    mov     rbx, [rbp - 8]
    mov     r12, [rbp - 16]
    mov     r13, [rbp - 24]
    FRAME_END
    ret

; =============================================================================
;  cyboudb_kem_open_root(root_out, slot, dk, aad, aad_len) -> int
;
;  ARG1  uint8_t       *root_out   32 bytes, zeroed on refusal
;  ARG2  const uint8_t *slot
;  ARG3  const uint8_t *dk         2400
;  ARG4  const uint8_t *aad
;  ARG5  uint64_t       aad_len
;
;  Returns CybouDB_E_KEY for every failure, without inspecting which. That is
;  not laziness: decapsulation cannot fail, so the tag is the only evidence
;  there is, and it says the same thing about a wrong key, a damaged
;  ciphertext and an altered wrapping.
;
;  Frame: as above, minus the message.
; =============================================================================
%define OR_SS      128
%define OR_KEK     192
%define OR_CTX     224
%define OR_FRAME   256

cyboudb_kem_open_root:
    FRAME_BEGIN OR_FRAME, 2
    mov     [rbp - 8], rbx
    mov     [rbp - 16], r12
    mov     [rbp - 24], r13

    mov     [rbp - 40], ARG1            ; root_out
    mov     r13, ARG2                   ; slot
    mov     [rbp - 48], ARG3            ; dk
    mov     [rbp - 56], ARG4            ; aad
    mov     rax, IN_ARG5
    mov     [rbp - 64], rax

    mov     ARG1, rbp
    sub     ARG1, OR_SS
    mov     ARG2, r13
    add     ARG2, KSLOT_KEM_CT
    mov     ARG3, [rbp - 48]
    call    cyboudb_mlkem_decaps

    mov     r12, [r13 + KSLOT_KEY_ID]
    mov     rbx, rbp
    sub     rbx, OR_CTX
    call    kem_context

    mov     ARG1, rbp
    sub     ARG1, OR_KEK
    mov     ARG2, 32
    mov     ARG3, KDF_METADATA_KEK
    mov     ARG4, rbp
    sub     ARG4, OR_SS
    mov     rax, rbp
    sub     rax, OR_CTX
    PASS_ARG5 rax
    mov     rax, KEM_CONTEXT_LEN
    PASS_ARG6 rax
    call    cyboudb_kdf
    test    eax, eax
    jnz     .refused

    mov     ARG1, [rbp - 40]
    mov     ARG2, rbp
    sub     ARG2, OR_KEK
    mov     ARG3, r13
    add     ARG3, KSLOT_WRAPPED
    mov     ARG4, [rbp - 56]
    mov     rax, [rbp - 64]
    PASS_ARG5 rax
    call    cyboudb_key_unwrap
    test    eax, eax
    jnz     .refused

    xor     eax, eax
    jmp     .done

.refused:
    ; cyboudb_key_unwrap already zeroes the caller's buffer when it refuses;
    ; this covers the paths that never reached it.
    mov     r10, [rbp - 40]
    xor     rax, rax
    mov     [r10], rax
    mov     [r10 + 8], rax
    mov     [r10 + 16], rax
    mov     [r10 + 24], rax
    mov     eax, CybouDB_E_KEY

.done:
    push    rax
    lea     r10, [rbp - OR_CTX]
    xor     rax, rax
    xor     rcx, rcx
.wipe:
    mov     [r10 + rcx], rax
    add     rcx, 8
    cmp     rcx, OR_CTX - 64
    jb      .wipe
    pop     rax

    mov     rbx, [rbp - 8]
    mov     r12, [rbp - 16]
    mov     r13, [rbp - 24]
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  keypage_crc(rbx = page) - recompute and store. Internal.
; -----------------------------------------------------------------------------
keypage_crc:
    push    rbp
    mov     rbp, rsp
    sub     rsp, 32 + SHADOW_SPACE
    mov     ARG1, rbx
    mov     ARG2, KPAGE_CRC
    call    crc32c
    mov     [rbx + KPAGE_CRC], eax
    mov     rsp, rbp
    pop     rbp
    ret

; =============================================================================
;  cyboudb_keypage_init(page, page_index, generation)
; =============================================================================
cyboudb_keypage_init:
    FRAME_BEGIN 48, 0
    mov     [rbp - 8], rbx
    mov     rbx, ARG1
    mov     r10, ARG2
    mov     r11, ARG3

    xor     rax, rax
    xor     rcx, rcx
.zero:
    mov     [rbx + rcx], rax
    add     rcx, 8
    cmp     rcx, CybouDB_PAGE_SIZE
    jb      .zero

    mov     dword [rbx + KPAGE_MAGIC], CybouDB_KEYPAGE_MAGIC
    mov     dword [rbx + KPAGE_VERSION], CybouDB_KEYPAGE_VERSION
    mov     [rbx + KPAGE_INDEX], r10
    mov     [rbx + KPAGE_GENERATION], r11

    call    keypage_crc
    mov     rbx, [rbp - 8]
    FRAME_END
    ret

; =============================================================================
;  cyboudb_keypage_add(page, slot) -> int
;
;  Copies one prepared slot into the first free place on the page. Refuses a
;  full page and a duplicate key id - two slots claiming one id would both be
;  tried, and the second one's failure would look like a wrong key.
; =============================================================================
cyboudb_keypage_add:
    FRAME_BEGIN 48, 0
    mov     [rbp - 8], rbx
    mov     [rbp - 16], r12

    mov     rbx, ARG1
    mov     r12, ARG2                   ; the slot to copy in

    mov     r8, [rbx + KPAGE_SLOT_COUNT]
    cmp     r8, CybouDB_KEYPAGE_SLOTS
    jae     .refuse

    mov     r9, [r12 + KSLOT_KEY_ID]
    test    r9, r9
    jz      .refuse

    xor     r10, r10
.dup:
    cmp     r10, r8
    jae     .append
    mov     rax, r10
    imul    rax, rax, KSLOT_SIZE
    mov     r11, [rbx + rax + KPAGE_SLOTS + KSLOT_KEY_ID]
    cmp     r11, r9
    je      .refuse
    inc     r10
    jmp     .dup

.append:
    mov     rax, r8
    imul    rax, rax, KSLOT_SIZE
    lea     r10, [rbx + rax + KPAGE_SLOTS]
    xor     rcx, rcx
.copy:
    mov     rax, [r12 + rcx]
    mov     [r10 + rcx], rax
    add     rcx, 8
    cmp     rcx, KSLOT_SIZE
    jb      .copy

    inc     r8
    mov     [rbx + KPAGE_SLOT_COUNT], r8
    call    keypage_crc
    xor     eax, eax
    jmp     .done
.refuse:
    mov     eax, KEYPAGE_E_SLOTS
.done:
    mov     rbx, [rbp - 8]
    mov     r12, [rbp - 16]
    FRAME_END
    ret

; =============================================================================
;  cyboudb_keypage_find(page, key_id) -> const uint8_t *slot, or NULL
; =============================================================================
cyboudb_keypage_find:
    mov     r10, ARG1
    mov     r11, ARG2
    mov     r8, [r10 + KPAGE_SLOT_COUNT]
    xor     r9, r9
.scan:
    cmp     r9, r8
    jae     .miss
    mov     rax, r9
    imul    rax, rax, KSLOT_SIZE
    lea     rax, [r10 + rax + KPAGE_SLOTS]
    mov     rcx, [rax + KSLOT_KEY_ID]
    cmp     rcx, r11
    je      .found
    inc     r9
    jmp     .scan
.miss:
    xor     eax, eax
.found:
    ret

; =============================================================================
;  cyboudb_keypage_validate(page) -> KEYPAGE_OK or a KEYPAGE_E_* code
;
;  Structural, key-free, and for the same reason as everywhere else in this
;  format: a page that is damaged and a key that does not open the file are
;  different sentences.
; =============================================================================
cyboudb_keypage_validate:
    FRAME_BEGIN 48, 0
    mov     [rbp - 8], rbx
    mov     [rbp - 16], r12
    mov     rbx, ARG1

    cmp     dword [rbx + KPAGE_MAGIC], CybouDB_KEYPAGE_MAGIC
    jne     .e_magic
    cmp     dword [rbx + KPAGE_VERSION], CybouDB_KEYPAGE_VERSION
    jne     .e_version

    mov     ARG1, rbx
    mov     ARG2, KPAGE_CRC
    CALL_ABI crc32c
    cmp     eax, [rbx + KPAGE_CRC]
    jne     .e_crc

    mov     r12, [rbx + KPAGE_SLOT_COUNT]
    cmp     r12, CybouDB_KEYPAGE_SLOTS
    ja      .e_slots

    mov     rax, [rbx + KPAGE_RESERVED]
    or      rax, [rbx + KPAGE_RESERVED + 8]
    or      rax, [rbx + KPAGE_RESERVED + 16]
    jnz     .e_reserved

    ; Every live slot has an id and no flags this build does not know.
    xor     rcx, rcx
.slot:
    cmp     rcx, r12
    jae     .tail
    mov     rax, rcx
    imul    rax, rax, KSLOT_SIZE
    lea     r10, [rbx + rax + KPAGE_SLOTS]
    cmp     qword [r10 + KSLOT_KEY_ID], 0
    je      .e_slots
    cmp     dword [r10 + KSLOT_FLAGS], 0
    jne     .e_slots
    cmp     dword [r10 + KSLOT_RESERVED], 0
    jne     .e_slots

    mov     r8, rcx
    xor     r9, r9
.dup:
    cmp     r9, r8
    jae     .next
    mov     rax, r9
    imul    rax, rax, KSLOT_SIZE
    mov     r11, [rbx + rax + KPAGE_SLOTS + KSLOT_KEY_ID]
    mov     rax, [r10 + KSLOT_KEY_ID]
    cmp     r11, rax
    je      .e_slots
    inc     r9
    jmp     .dup
.next:
    inc     rcx
    jmp     .slot

.tail:
    ; Past the count the slots are zero, so a key removed by lowering the
    ; count cannot sit there still wrapping the root.
    mov     rcx, r12
    imul    rcx, rcx, KSLOT_SIZE
    xor     rax, rax
.tail_word:
    cmp     rcx, CybouDB_KEYPAGE_SLOTS * KSLOT_SIZE
    jae     .tail_done
    or      rax, [rbx + rcx + KPAGE_SLOTS]
    add     rcx, 8
    jmp     .tail_word
.tail_done:
    test    rax, rax
    jnz     .e_slots

    ; 500 bytes: 62 whole qwords and then a dword. Reading it as 63 qwords
    ; would read four bytes of the CRC field, and every valid page would fail
    ; its own reserved check - which is exactly what happened.
    xor     rcx, rcx
.pad:
    cmp     rcx, 496
    jae     .pad_tail
    or      rax, [rbx + KPAGE_RESERVED_TAIL + rcx]
    add     rcx, 8
    jmp     .pad
.pad_tail:
    or      eax, [rbx + KPAGE_RESERVED_TAIL + 496]
.ok:
    test    rax, rax
    jnz     .e_reserved
    xor     eax, eax
    jmp     .done

.e_magic:
    mov     eax, KEYPAGE_E_MAGIC
    jmp     .done
.e_version:
    mov     eax, KEYPAGE_E_VERSION
    jmp     .done
.e_crc:
    mov     eax, KEYPAGE_E_CRC
    jmp     .done
.e_reserved:
    mov     eax, KEYPAGE_E_RESERVED
    jmp     .done
.e_slots:
    mov     eax, KEYPAGE_E_SLOTS
.done:
    mov     rbx, [rbp - 8]
    mov     r12, [rbp - 16]
    FRAME_END
    ret

%ifdef CybouDB_LINUX
section .note.GNU-stack noalloc noexec nowrite progbits
%endif
