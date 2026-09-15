; Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
; SPDX-License-Identifier: Apache-2.0
; =============================================================================
;  crypto/recovery.asm - the second door into a database
; =============================================================================
;  docs/RECOVERY_PHRASE.md. Twenty-four words of eleven bits: 256 bits of
;  secret and eight of checksum, wrapping the same root key the ML-KEM slots
;  wrap.
;
;  This file speaks in indices rather than in words, and the document says why:
;  a wordlist with one wrong word in it is a phrase nobody can restore, so the
;  list arrives as a checked-in file with a digest beside it and not as
;  something typed from memory.
;
;  The checksum is SHAKE256 under this format's own tag, which makes a CybouDB
;  phrase invalid BIP-39 on purpose - a database recovery phrase and a wallet
;  seed should not be interchangeable enough to be confused for one another.
; =============================================================================

%include "cyboudb.inc"
%include "crypto.inc"

BITS 64
default rel

global cyboudb_recovery_new
global cyboudb_recovery_encode
global cyboudb_recovery_decode
global cyboudb_recovery_seal_root
global cyboudb_recovery_open_root

extern os_random
extern cyboudb_shake256
extern cyboudb_kdf
extern cyboudb_key_wrap
extern cyboudb_key_unwrap

section .rodata
ck_label:  db "CybouDB/0.7/recovery-checksum", 0
CK_LABEL_LEN equ $ - ck_label
; Eight bytes, matching the KEM slot's context shape: a fixed-length label so
; a key id can never be read as part of it.
rec_label: db "recovery"

section .text

; -----------------------------------------------------------------------------
;  rec_checksum(rbx = secret) -> al = the eight checksum bits
;
;  Internal. SHAKE256 of the label and the secret, first byte.
; -----------------------------------------------------------------------------
rec_checksum:
    push    rbp
    mov     rbp, rsp
    sub     rsp, 128 + SHADOW_SPACE

    ; label | secret, contiguous
    lea     r10, [ck_label]
    xor     rcx, rcx
.copy_label:
    mov     al, [r10 + rcx]
    mov     [rsp + SHADOW_SPACE + rcx], al
    inc     rcx
    cmp     rcx, CK_LABEL_LEN
    jb      .copy_label
.copy_secret:
    mov     al, [rbx + rcx - CK_LABEL_LEN]
    mov     [rsp + SHADOW_SPACE + rcx], al
    inc     rcx
    cmp     rcx, CK_LABEL_LEN + 32
    jb      .copy_secret

    lea     ARG1, [rsp + SHADOW_SPACE + 64]
    mov     ARG2, 1
    lea     ARG3, [rsp + SHADOW_SPACE]
    mov     ARG4, CK_LABEL_LEN + 32
    call    cyboudb_shake256

    movzx   eax, byte [rsp + SHADOW_SPACE + 64]
    mov     rsp, rbp
    pop     rbp
    ret

; =============================================================================
;  cyboudb_recovery_encode(indices, secret)
;
;  ARG1  uint16_t      *indices   24 values in [0, 2048)
;  ARG2  const uint8_t *secret    32 bytes
;
;  264 bits, most significant first: the secret, then the checksum. The bit
;  order is the one BIP-39 uses, because the structure is worth keeping even
;  where the checksum is not.
; =============================================================================
cyboudb_recovery_encode:
    FRAME_BEGIN 64, 0
    mov     [rbp - 8], rbx
    mov     [rbp - 16], r12
    mov     [rbp - 24], r13

    mov     r12, ARG1                   ; indices
    mov     rbx, ARG2                   ; secret
    call    rec_checksum
    mov     r13d, eax                   ; the checksum byte

    ; A rolling bit buffer: bytes go in at the bottom, eleven bits come out at
    ; the top. No shift by a computed amount and no branch on the secret.
    xor     r8, r8                      ; the buffer
    xor     r9, r9                      ; how many bits it holds
    xor     r10, r10                    ; byte index, 0..32
    xor     r11, r11                    ; word index

.pump:
    cmp     r9, 11
    jae     .emit

    ; feed one byte: the secret's 32, then the checksum
    cmp     r10, 32
    jb      .secret_byte
    movzx   eax, r13b
    jmp     .feed
.secret_byte:
    movzx   eax, byte [rbx + r10]
.feed:
    shl     r8, 8
    or      r8, rax
    add     r9, 8
    inc     r10
    jmp     .pump

.emit:
    mov     rax, r8
    mov     rcx, r9
    sub     rcx, 11
    shr     rax, cl                     ; cl is a bit count, not data
    and     eax, 0x7FF
    mov     [r12 + r11 * 2], ax

    ; drop the eleven bits that were just taken
    mov     rcx, r9
    sub     rcx, 11
    mov     r9, rcx
    mov     rax, 1
    shl     rax, cl
    dec     rax
    and     r8, rax

    inc     r11
    cmp     r11, 24
    jb      .pump

    mov     rbx, [rbp - 8]
    mov     r12, [rbp - 16]
    mov     r13, [rbp - 24]
    FRAME_END
    ret

; =============================================================================
;  cyboudb_recovery_decode(secret, indices) -> 0 or CybouDB_E_PHRASE
;
;  A phrase that does not checksum is a typo, and a typo is decidable without
;  the file. That is why it has its own code: CybouDB_E_PHRASE means "that is
;  not a phrase this build wrote", where CybouDB_E_KEY means "that phrase is
;  well formed and does not open this file".
; =============================================================================
cyboudb_recovery_decode:
    FRAME_BEGIN 96, 0
    mov     [rbp - 8], rbx
    mov     [rbp - 16], r12
    mov     [rbp - 24], r13

    mov     rbx, ARG1                   ; secret out
    mov     r12, ARG2                   ; indices

    xor     r8, r8                      ; bit buffer
    xor     r9, r9                      ; bits held
    xor     r10, r10                    ; byte index
    xor     r11, r11                    ; word index
    xor     r13, r13                    ; the checksum byte as read

.word:
    cmp     r11, 24
    jae     .starved
    movzx   eax, word [r12 + r11 * 2]
    cmp     eax, 2048
    jae     .bad_index
    shl     r8, 11
    or      r8, rax
    add     r9, 11
    inc     r11

.drain:
    cmp     r9, 8
    jb      .word

    mov     rax, r8
    mov     rcx, r9
    sub     rcx, 8
    shr     rax, cl
    movzx   eax, al

    cmp     r10, 32
    jae     .take_checksum
    mov     [rbx + r10], al
    jmp     .dropped
.take_checksum:
    mov     r13d, eax
.dropped:
    mov     rcx, r9
    sub     rcx, 8
    mov     r9, rcx
    mov     rax, 1
    shl     rax, cl
    dec     rax
    and     r8, rax

    inc     r10
    cmp     r10, 33
    jae     .finish
    ; Back to the drain and not to the next word: a word is eleven bits and a
    ; byte is eight, so taking one word per byte leaves three bits behind every
    ; time and the buffer grows until it overflows. Drain first, refill after.
    jmp     .drain

.finish:
    ; The checksum is over the secret that was just decoded, so a phrase that
    ; decodes to something else fails here rather than at the unwrap.
    call    rec_checksum
    cmp     al, r13b
    jne     .bad_phrase

    xor     eax, eax
    jmp     .done

.starved:
    ; Twenty-four words are exactly thirty-three bytes, so there is no phrase
    ; that runs out of bits. Refusing here rather than looping is what makes
    ; that a statement instead of an assumption.
    jmp     .bad_phrase

.bad_index:
.bad_phrase:
    ; Leave nothing that looks like a secret behind.
    xor     rax, rax
    mov     [rbx], rax
    mov     [rbx + 8], rax
    mov     [rbx + 16], rax
    mov     [rbx + 24], rax
    mov     eax, CybouDB_E_PHRASE
.done:
    mov     rbx, [rbp - 8]
    mov     r12, [rbp - 16]
    mov     r13, [rbp - 24]
    FRAME_END
    ret

; =============================================================================
;  cyboudb_recovery_new(secret, indices) -> int
;
;  Draws 256 bits and spells them. The secret comes from the operating system
;  and from nowhere else: there is no passphrase here to stretch, and a
;  recovery secret a person chose would be the weakest door into the file.
; =============================================================================
cyboudb_recovery_new:
    FRAME_BEGIN 48, 0
    mov     [rbp - 8], rbx
    mov     [rbp - 16], r12

    mov     rbx, ARG1
    mov     r12, ARG2

    mov     ARG1, rbx
    mov     ARG2, 32
    call    os_random
    test    eax, eax
    jnz     .no_randomness

    mov     ARG1, r12
    mov     ARG2, rbx
    call    cyboudb_recovery_encode
    xor     eax, eax
    jmp     .done

.no_randomness:
    mov     eax, CybouDB_E_STATE
.done:
    mov     rbx, [rbp - 8]
    mov     r12, [rbp - 16]
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  rec_context(rbx = out 16 bytes, r12 = key_id)
; -----------------------------------------------------------------------------
rec_context:
    lea     rax, [rec_label]
    mov     rcx, [rax]
    mov     [rbx], rcx
    mov     [rbx + 8], r12
    ret

; =============================================================================
;  cyboudb_recovery_seal_root(slot, secret, root_key, key_id, aad, aad_len)
;
;  ARG1  uint8_t       *slot      CROOT_SLOT_SIZE bytes, in the crypto root's
;                                 own table - a recovery slot needs no
;                                 ciphertext, so it needs no page of its own
;  ARG2  const uint8_t *secret    32
;  ARG3  const uint8_t *root_key  32
;  ARG4  uint64_t       key_id    drawn by the caller, not derived from the
;                                 secret: a published function of a secret is
;                                 something guesses can be tested against
;
;  Frame:
;    [rbp - 8..24]  saved rbx, r12, r13
;    [rbp - 40] slot  [rbp - 48] root  [rbp - 56] aad  [rbp - 64] aad_len
;    [rbp - 128] kek
;    [rbp - 160] context
; =============================================================================
%define RS_KEK   128
%define RS_CTX   160
%define RS_FRAME 192

cyboudb_recovery_seal_root:
    FRAME_BEGIN RS_FRAME, 2
    mov     [rbp - 8], rbx
    mov     [rbp - 16], r12
    mov     [rbp - 24], r13

    mov     [rbp - 40], ARG1
    mov     r13, ARG2                   ; secret
    mov     [rbp - 48], ARG3
    mov     r12, ARG4                   ; key_id
    mov     rax, IN_ARG5
    mov     [rbp - 56], rax
    mov     rax, IN_ARG6
    mov     [rbp - 64], rax

    mov     rbx, [rbp - 40]
    mov     [rbx + CSLOT_KEY_ID], r12
    mov     dword [rbx + CSLOT_PURPOSE], KDF_METADATA_KEK
    mov     dword [rbx + CSLOT_FLAGS], CSLOT_FLAG_RECOVERY
    mov     qword [rbx + CSLOT_RESERVED], 0

    mov     rbx, rbp
    sub     rbx, RS_CTX
    call    rec_context

    mov     ARG1, rbp
    sub     ARG1, RS_KEK
    mov     ARG2, 32
    mov     ARG3, KDF_METADATA_KEK
    mov     ARG4, r13
    mov     rax, rbp
    sub     rax, RS_CTX
    PASS_ARG5 rax
    mov     rax, KEM_CONTEXT_LEN
    PASS_ARG6 rax
    call    cyboudb_kdf
    test    eax, eax
    jnz     .refused

    mov     rbx, [rbp - 40]
    mov     ARG1, rbx
    add     ARG1, CSLOT_WRAPPED
    mov     ARG2, rbp
    sub     ARG2, RS_KEK
    mov     ARG3, [rbp - 48]
    mov     ARG4, [rbp - 56]
    mov     rax, [rbp - 64]
    PASS_ARG5 rax
    call    cyboudb_key_wrap
    test    eax, eax
    jnz     .refused

    xor     eax, eax
    jmp     .done
.refused:
    mov     eax, CybouDB_E_KEY
.done:
    push    rax
    lea     r10, [rbp - RS_CTX]
    xor     rax, rax
    xor     rcx, rcx
.wipe:
    mov     [r10 + rcx], rax
    add     rcx, 8
    cmp     rcx, RS_CTX - 64
    jb      .wipe
    pop     rax

    mov     rbx, [rbp - 8]
    mov     r12, [rbp - 16]
    mov     r13, [rbp - 24]
    FRAME_END
    ret

; =============================================================================
;  cyboudb_recovery_open_root(root_out, slot, secret, aad, aad_len) -> int
;
;  CybouDB_E_KEY for every refusal, and zeroes in the output buffer. A phrase
;  that is well formed and belongs to another database is not a typo and not
;  damage, and this is where that distinction is spent.
; =============================================================================
%define RO_KEK   128
%define RO_CTX   160
%define RO_FRAME 192

cyboudb_recovery_open_root:
    FRAME_BEGIN RO_FRAME, 2
    mov     [rbp - 8], rbx
    mov     [rbp - 16], r12
    mov     [rbp - 24], r13

    mov     [rbp - 40], ARG1            ; root_out
    mov     r13, ARG2                   ; slot
    mov     [rbp - 48], ARG3            ; secret
    mov     [rbp - 56], ARG4            ; aad
    mov     rax, IN_ARG5
    mov     [rbp - 64], rax

    mov     r12, [r13 + CSLOT_KEY_ID]
    mov     rbx, rbp
    sub     rbx, RO_CTX
    call    rec_context

    mov     ARG1, rbp
    sub     ARG1, RO_KEK
    mov     ARG2, 32
    mov     ARG3, KDF_METADATA_KEK
    mov     ARG4, [rbp - 48]
    mov     rax, rbp
    sub     rax, RO_CTX
    PASS_ARG5 rax
    mov     rax, KEM_CONTEXT_LEN
    PASS_ARG6 rax
    call    cyboudb_kdf
    test    eax, eax
    jnz     .refused

    mov     ARG1, [rbp - 40]
    mov     ARG2, rbp
    sub     ARG2, RO_KEK
    mov     ARG3, r13
    add     ARG3, CSLOT_WRAPPED
    mov     ARG4, [rbp - 56]
    mov     rax, [rbp - 64]
    PASS_ARG5 rax
    call    cyboudb_key_unwrap
    test    eax, eax
    jnz     .refused

    xor     eax, eax
    jmp     .done

.refused:
    mov     r10, [rbp - 40]
    xor     rax, rax
    mov     [r10], rax
    mov     [r10 + 8], rax
    mov     [r10 + 16], rax
    mov     [r10 + 24], rax
    mov     eax, CybouDB_E_KEY
.done:
    push    rax
    lea     r10, [rbp - RO_CTX]
    xor     rax, rax
    xor     rcx, rcx
.wipe:
    mov     [r10 + rcx], rax
    add     rcx, 8
    cmp     rcx, RO_CTX - 64
    jb      .wipe
    pop     rax

    mov     rbx, [rbp - 8]
    mov     r12, [rbp - 16]
    mov     r13, [rbp - 24]
    FRAME_END
    ret

%ifdef CybouDB_LINUX
section .note.GNU-stack noalloc noexec nowrite progbits
%endif
