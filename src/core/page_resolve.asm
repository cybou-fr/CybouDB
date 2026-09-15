; Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
; SPDX-License-Identifier: Apache-2.0
; =============================================================================
;  core/page_resolve.asm - a page of an encrypted database, as an address
; =============================================================================
;  docs/ENCRYPTED_ENGINE.md, step 3. The engine asks for a page address 128
;  times; when DB_CACHE is set, this is what answers.
;
;      cached already        the frame it is in
;      not cached            read it, open it, and the frame it went into
;      it does not verify    zero, and DB_ENC_ERROR says what happened
;
;  Zero rather than a refusal in a register, because the sites that call this
;  are 128 pieces of code written around an address that could not fail. They
;  will each have to learn to see a null - that is the work step 3 is made of -
;  and until they do, a null is at least a fault at the point of use rather
;  than a plaintext page that was never verified.
;
;  The seal directory leaf is read on every miss. That is one extra read per
;  miss and it is deliberate for now: the leaf is a page like any other, and
;  caching it properly means deciding whether metadata and payload share a
;  cache - which is a measurement, not a preference, and step 19 is where it
;  belongs.
; =============================================================================

%include "cyboudb.inc"
%include "crypto.inc"

BITS 64
default rel

global db_page_resolve
global db_page_for_write
global db_page_new
global db_context_bytes
global db_page_number
global db_page_blank
global db_pages_flush

extern cyboudb_pcache_lookup
extern cyboudb_pcache_admit
extern cyboudb_pcache_invalidate
extern cyboudb_page_open
extern cyboudb_seal_level
extern cyboudb_seal_leaf_validate
extern cyboudb_seal_leaf_verify
extern cyboudb_seal_node_validate
extern cyboudb_seal_node_verify
extern vfs_read_at
extern vfs_write_at
extern cyboudb_pcache_mark_dirty
extern cyboudb_pcache_frames
extern cyboudb_pcache_dirty_at
extern cyboudb_pcache_clean_at
extern cyboudb_page_seal
extern cyboudb_pcache_frame
extern cyboudb_pcache_type_at
extern cyboudb_pcache_page_of
extern cyboudb_pcache_set_type
extern crc32c

; Frame:
;   [rbp - 8..32]  saved rbx, r12, r13
;   [rbp - 40] ctx    [rbp - 48] page    [rbp - 56] frame
;   [rbp - 64] the evicted page the cache reported
;   [rbp - 128] the page seal arguments, CybouDB_PSEAL_ARGS_SIZE
;   [rbp - 96] expected child MAC   [rbp - 104] tree level
;   [rbp - 120] level divisor      [rbp - 144] level layout pair
;   [rbp - 4288] the seal directory leaf, read on every miss
;   [rbp - 8384] one internal seal node
; The arguments start at 192 and not at 128 because the flush below needs
; nine slots above them and the first draft had it needing ten - an array that
; ends where the slots begin is correct right until someone adds a slot, which
; is the same lesson the ML-KEM frames and the KMAC block taught.
%define PR_ARGS   192                  ; [rbp-192, rbp-128)
%define PR_LEAF   4288                 ; [rbp-4288, rbp-192)
%define PR_NODE   8384                 ; [rbp-8384, rbp-4288)
%define PR_FRAME  8448

section .text

; =============================================================================
;  db_page_resolve(ctx, page) -> uint8_t *plaintext, or 0
; =============================================================================
db_page_resolve:
    FRAME_BEGIN PR_FRAME, 0
    mov     [rbp - 8], rbx
    mov     [rbp - 16], r12
    mov     [rbp - 24], r13

    mov     rbx, ARG1                   ; ctx
    mov     r12, ARG2                   ; the page wanted
    mov     [rbp - 40], rbx
    mov     [rbp - 48], r12

    ; A context with no cache has not been attached to an encrypted file. The
    ; page macro never calls this in that state - it branches on exactly this
    ; field - but a direct caller can, and did: a test ignored an attach that
    ; had failed and passed the context on, which turned a refusal into a null
    ; dereference inside the cache.
    cmp     qword [rbx + DB_CACHE], 0
    je      .no_cache

    ; --- already decrypted? ---------------------------------------------------
    mov     ARG1, [rbx + DB_CACHE]
    mov     ARG2, r12
    call    cyboudb_pcache_lookup
    test    rax, rax
    jz      .miss

    ; A hit clears the error as a miss does. Leaving the last failure in place
    ; would let a caller read a stale reason after a resolve that succeeded -
    ; and the first test written against this did exactly that, and believed
    ; it.
    mov     rbx, [rbp - 40]
    mov     qword [rbx + DB_ENC_ERROR], 0
    jmp     .done
.miss:

    ; --- which leaf covers this page, and where the entry is -----------------
    ;  One leaf holds CybouDB_SEAL_ENTRIES_PER_LEAF pages, and the directory
    ;  starts at the page the crypto root named.
    mov     rax, r12
    xor     rdx, rdx
    mov     rcx, CybouDB_SEAL_ENTRIES_PER_LEAF
    div     rcx                         ; rax = which leaf, rdx = which entry
    mov     r13, rdx                    ; the entry index, wanted later
    mov     [rbp - 72], rax             ; requested leaf index

    add     rax, [rbx + DB_SEAL_DIR]
    shl     rax, CybouDB_PAGE_SHIFT     ; the leaf's byte offset in the file

    mov     ARG1, [rbx + DB_HANDLE]
    lea     ARG2, [rbp - PR_LEAF]
    mov     ARG3, CybouDB_PAGE_SIZE
    mov     ARG4, rax
    call    vfs_read_at
    cmp     rax, CybouDB_PAGE_SIZE
    jne     .no_entry

    ; Authenticate the complete path named by the superblock before trusting
    ; an entry in the leaf. Depth zero exists only for the small standalone
    ; resolver harness; every context produced by encrypted attach has a root.
    mov     rbx, [rbp - 40]
    mov     rax, [rbx + DB_SEAL_DEPTH]
    test    rax, rax
    jz      .tree_verified
    mov     [rbp - 104], rax
    mov     rax, [rbx + DB_SEAL_ROOT]
    mov     [rbp - 96], rax
    mov     rax, [rbx + DB_SEAL_ROOT + 8]
    mov     [rbp - 88], rax

.tree_level:
    ; divisor = 251^level. It identifies both the node containing the wanted
    ; leaf and the child slot inside that node.
    mov     rcx, [rbp - 104]
    mov     rax, 1
.tree_power:
    imul    rax, rax, CybouDB_SEAL_CHILDREN_PER_NODE
    jo      .tree_bad
    dec     rcx
    jnz     .tree_power
    mov     [rbp - 120], rax

    lea     ARG1, [rbp - 144]
    mov     ARG2, [rbx + DB_PAGES]
    mov     ARG3, [rbp - 104]
    call    cyboudb_seal_level
    test    eax, eax
    jnz     .tree_bad

    mov     rax, [rbp - 72]
    xor     rdx, rdx
    div     qword [rbp - 120]            ; node index at this level
    cmp     rax, [rbp - 136]             ; layout count
    jae     .tree_bad
    mov     [rbp - 112], rax
    add     rax, [rbp - 144]             ; layout offset
    add     rax, [rbx + DB_SEAL_DIR]
    shl     rax, CybouDB_PAGE_SHIFT
    mov     ARG1, [rbx + DB_HANDLE]
    lea     ARG2, [rbp - PR_NODE]
    mov     ARG3, CybouDB_PAGE_SIZE
    mov     ARG4, rax
    call    vfs_read_at
    cmp     rax, CybouDB_PAGE_SIZE
    jne     .tree_bad

    lea     ARG1, [rbp - PR_NODE]
    call    cyboudb_seal_node_validate
    test    eax, eax
    jnz     .tree_bad
    mov     rax, [rbp - 104]
    cmp     [rbp - PR_NODE + SNODE_LEVEL], rax
    jne     .tree_bad
    mov     rax, [rbp - 112]
    cmp     [rbp - PR_NODE + SNODE_INDEX], rax
    jne     .tree_bad
    mov     rbx, [rbp - 40]
    lea     ARG1, [rbx + DB_TREE_KEY]
    lea     ARG2, [rbp - PR_NODE]
    lea     ARG3, [rbp - 96]
    call    cyboudb_seal_node_verify
    test    eax, eax
    jnz     .tree_bad

    mov     rax, [rbp - 120]
    xor     rdx, rdx
    mov     rcx, CybouDB_SEAL_CHILDREN_PER_NODE
    div     rcx                         ; divisor for the child level
    mov     rcx, rax
    mov     rax, [rbp - 72]
    xor     rdx, rdx
    div     rcx
    xor     rdx, rdx
    mov     rcx, CybouDB_SEAL_CHILDREN_PER_NODE
    div     rcx                         ; rdx = child slot
    cmp     rdx, [rbp - PR_NODE + SNODE_CHILD_COUNT]
    jae     .tree_bad
    shl     rdx, 4
    mov     rax, [rbp - PR_NODE + SNODE_CHILDREN + rdx]
    mov     [rbp - 96], rax
    mov     rax, [rbp - PR_NODE + SNODE_CHILDREN + rdx + 8]
    mov     [rbp - 88], rax

    dec     qword [rbp - 104]
    jnz     .tree_level

    lea     ARG1, [rbp - PR_LEAF]
    call    cyboudb_seal_leaf_validate
    test    eax, eax
    jnz     .tree_bad
    mov     rax, [rbp - 72]
    cmp     [rbp - PR_LEAF + SLEAF_INDEX], rax
    jne     .tree_bad
    mov     rbx, [rbp - 40]
    lea     ARG1, [rbx + DB_TREE_KEY]
    lea     ARG2, [rbp - PR_LEAF]
    lea     ARG3, [rbp - 96]
    call    cyboudb_seal_leaf_verify
    test    eax, eax
    jnz     .tree_bad

.tree_verified:

    ; --- a frame to read the page into ---------------------------------------
    mov     rbx, [rbp - 40]
    mov     ARG1, [rbx + DB_CACHE]
    mov     ARG2, [rbp - 48]
    lea     ARG3, [rbp - 64]
    call    cyboudb_pcache_admit
    test    rax, rax
    jz      .no_entry
    mov     [rbp - 56], rax

    ; The evicted page is reported and, for now, must not have been dirty:
    ; writing back belongs to step 4 with the commit order, and a dirty page
    ; quietly dropped would be a lost write rather than a slow one.
    ;
    ; "Nothing was evicted" is all ones, and all ones has bit 63 set - which is
    ; also how the cache says "this one was dirty". So the sentinel is checked
    ; first, and the order is not optional: testing the bit first makes every
    ; admission into an empty set look like a dirty eviction, which is exactly
    ; what the first version of this did.
    mov     rax, [rbp - 64]
    cmp     rax, -1
    je      .nothing_evicted
    bt      rax, 63
    jc      .dirty_victim
.nothing_evicted:

    ; --- read the ciphertext into that frame ---------------------------------
    mov     rax, [rbp - 48]
    shl     rax, CybouDB_PAGE_SHIFT
    mov     ARG1, [rbx + DB_HANDLE]
    mov     ARG2, [rbp - 56]
    mov     ARG3, CybouDB_PAGE_SIZE
    mov     ARG4, rax
    call    vfs_read_at
    cmp     rax, CybouDB_PAGE_SIZE
    jne     .short_read

    ; --- open it -------------------------------------------------------------
    mov     rbx, [rbp - 40]
    lea     r10, [rbp - PR_ARGS]

    lea     rax, [rbx + DB_SEAL_KEY]
    mov     [r10 + PSEAL_KEY], rax
    mov     rax, [rbp - 56]
    mov     [r10 + PSEAL_PAGE], rax

    ; the entry inside the leaf this page belongs to
    mov     rax, r13
    imul    rax, rax, SENTRY_SIZE
    lea     rcx, [rbp - PR_LEAF]
    add     rax, rcx
    add     rax, SLEAF_ENTRIES
    mov     [r10 + PSEAL_ENTRY], rax

    lea     rax, [rbx + DB_UUID]
    mov     [r10 + PSEAL_UUID], rax
    mov     rax, [rbp - 48]
    mov     [r10 + PSEAL_PAGE_NO], rax
    ; Neither of these is passed on the way in: open takes the generation out
    ; of the entry and the type out of the nonce, both of which the leaf's MAC
    ; covers. Passing the database's current generation here is what made a
    ; page unreadable after the first commit that did not rewrite it.
    mov     qword [r10 + PSEAL_GENERATION], 0
    mov     qword [r10 + PSEAL_PAGE_TYPE], 0
    mov     rax, [rbx + DB_SEAL_EPOCH]
    mov     [r10 + PSEAL_EPOCH], rax

    lea     ARG1, [rbp - PR_ARGS]
    call    cyboudb_page_open
    test    eax, eax
    jnz     .refused

    mov     qword [rbx + DB_ENC_ERROR], 0
    mov     rax, [rbp - 56]
    jmp     .done

.tree_bad:
    mov     rbx, [rbp - 40]
    mov     qword [rbx + DB_ENC_ERROR], CybouDB_E_SEAL
    xor     eax, eax
    jmp     .done

.refused:
    ; The frame holds a page that did not verify. It must not stay in the
    ; cache looking like a page that did - a later lookup would hit it and
    ; hand out bytes nothing vouched for.
    mov     [rbx + DB_ENC_ERROR], rax
    mov     ARG1, [rbx + DB_CACHE]
    mov     ARG2, [rbp - 48]
    call    cyboudb_pcache_invalidate
    xor     eax, eax
    jmp     .done

.short_read:
    mov     rbx, [rbp - 40]
    mov     qword [rbx + DB_ENC_ERROR], CybouDB_E_SEAL
    mov     ARG1, [rbx + DB_CACHE]
    mov     ARG2, [rbp - 48]
    call    cyboudb_pcache_invalidate
    xor     eax, eax
    jmp     .done

.dirty_victim:
    mov     qword [rbx + DB_ENC_ERROR], CybouDB_E_STATE
    xor     eax, eax
    jmp     .done

.no_cache:
    mov     qword [rbx + DB_ENC_ERROR], CybouDB_E_STATE
    xor     eax, eax
    jmp     .done

.no_entry:
    mov     rbx, [rbp - 40]
    mov     qword [rbx + DB_ENC_ERROR], CybouDB_E_SEAL
    xor     eax, eax

.done:
    mov     rbx, [rbp - 8]
    mov     r12, [rbp - 16]
    mov     r13, [rbp - 24]
    FRAME_END
    ret



; =============================================================================
;  db_page_for_write(ctx, page, page_type) -> uint8_t *plaintext, or 0
;
;  A page the caller is about to change. It resolves exactly as a read does and
;  then marks the frame dirty, so the commit can find it again.
;
;  **The page must be one this generation allocated.** Copy-on-write is what
;  makes that true, and it is what makes writing a dirty frame back in place
;  safe: a page an older generation still references is never dirtied, so
;  nothing a crash could fall back to is ever overwritten. An engine that
;  dirtied a live page of an older generation would destroy that generation
;  here, silently, and no barrier ordering would save it.
; =============================================================================
db_page_for_write:
    FRAME_BEGIN 64, 0
    mov     [rbp - 8], rbx
    mov     [rbp - 16], r12

    mov     rbx, ARG1
    mov     r12, ARG2
    mov     [rbp - 32], ARG3            ; the page type, for the commit

    mov     ARG1, rbx
    mov     ARG2, r12
    call    db_page_resolve
    test    rax, rax
    jz      .done
    mov     [rbp - 24], rax

    mov     ARG1, [rbx + DB_CACHE]
    mov     ARG2, r12
    call    cyboudb_pcache_mark_dirty
    test    eax, eax
    jnz     .lost

    ; The type goes with it. Only the caller knows what kind of page this is,
    ; and the commit that seals it will be running long after the caller has
    ; gone.
    mov     ARG1, [rbx + DB_CACHE]
    mov     ARG2, r12
    mov     ARG3, [rbp - 32]
    call    cyboudb_pcache_set_type
    test    eax, eax
    jnz     .lost

    mov     rax, [rbp - 24]
    jmp     .done

.lost:
    ; The frame resolved and then could not be marked. That cannot happen
    ; unless the cache and this code disagree about what is in it, and a write
    ; the commit will not find is a lost write, so it is a refusal.
    mov     qword [rbx + DB_ENC_ERROR], CybouDB_E_STATE
    xor     eax, eax
.done:
    mov     rbx, [rbp - 8]
    mov     r12, [rbp - 16]
    FRAME_END
    ret

; =============================================================================
;  db_context_bytes() -> how large a database context is
;
;  Tests allocate one and index into it by hand, and the offsets they use are
;  spelled twice - once here and once in C. Growing the context has already
;  silently overrun a buffer once in this project (the sponge), so the size
;  is answered by the assembly that defines it rather than guessed.
; =============================================================================
db_context_bytes:
    mov     eax, CybouDB_DB_SIZE
    ret

; =============================================================================
;  db_page_blank(ctx, page) -> a zeroed, writable address for a page that has
;  just been allocated, or zero
;
;  The allocator hands out a page and the caller expects to find zeroes at it.
;  In a plain database that is the mapping, cleared. In an encrypted one it
;  cannot be a resolve: nobody has sealed that page, so there is nothing at it
;  to open and asking would fail a tag check against bytes nobody wrote. It is
;  a fresh frame instead, which is what db_page_new is for.
;
;  This is the one place in the engine where "a page" and "a page that exists"
;  come apart, and it comes apart only under encryption, which is why the two
;  answers live behind one name rather than behind a branch at every allocator.
; =============================================================================
db_page_blank:
    FRAME_BEGIN 32, 0
    mov     [rbp - 8], ARG1
    mov     [rbp - 16], ARG2
    mov     r10, ARG1
    cmp     qword [r10 + DB_CACHE], 0
    jne     .fresh_frame
    mov     rax, ARG2
    shl     rax, CybouDB_PAGE_SHIFT
    add     rax, [r10 + DB_BASE]
    mov     [rbp - 24], rax
    mov     r10, rax
    xor     rax, rax
    xor     rcx, rcx
.zero:
    mov     [r10 + rcx], rax
    add     rcx, 8
    cmp     rcx, CybouDB_PAGE_SIZE
    jb      .zero
    mov     rax, [rbp - 24]
    FRAME_END
    ret
.fresh_frame:
    mov     ARG1, [rbp - 8]
    mov     ARG2, [rbp - 16]
    mov     ARG3, CybouDB_PTYPE_DATA
    call    db_page_new
    FRAME_END
    ret

; =============================================================================
;  db_page_number(ctx, addr) -> the page that address belongs to, or -1
;
;  The inverse of a page address, which the engine asks for in a few places:
;  a page that carries its own id has to be stamped with one, and the code
;  holding the address is not always the code that knew the number.
;
;  A plain database subtracts the mapping base and shifts, which is exact
;  because the mapping is the file. An encrypted one cannot: a frame is
;  wherever there was room, and the relation between an address and a page is
;  something only the cache knows. So it is asked.
; =============================================================================
db_page_number:
    FRAME_BEGIN 16, 0
    mov     r10, ARG1
    cmp     qword [r10 + DB_CACHE], 0
    jne     .cached
    mov     rax, ARG2
    sub     rax, [r10 + DB_BASE]
    shr     rax, CybouDB_PAGE_SHIFT
    FRAME_END
    ret
.cached:
    mov     ARG1, [r10 + DB_CACHE]
    call    cyboudb_pcache_page_of
    FRAME_END
    ret

; =============================================================================
;  db_page_new(ctx, page, page_type) -> uint8_t *plaintext, or 0
;
;  A page this generation has just allocated. It is not read first, and that is
;  the whole difference from db_page_for_write: there is nothing on the disk at
;  that page number worth reading, and trying to open it would fail a tag check
;  against bytes nobody ever sealed.
;
;  The frame comes back zeroed, because a fresh page in this engine is a zeroed
;  page and because whatever the frame held before belonged to somebody else.
; =============================================================================
db_page_new:
    FRAME_BEGIN 64, 0
    mov     [rbp - 8], rbx
    mov     [rbp - 16], r12

    mov     rbx, ARG1
    mov     r12, ARG2
    mov     [rbp - 32], ARG3

    cmp     qword [rbx + DB_CACHE], 0
    je      .no_cache

    mov     ARG1, [rbx + DB_CACHE]
    mov     ARG2, r12
    lea     ARG3, [rbp - 40]
    call    cyboudb_pcache_admit
    test    rax, rax
    jz      .no_cache
    mov     [rbp - 24], rax

    ; the victim, if there was one, must not have been dirty
    mov     rax, [rbp - 40]
    cmp     rax, -1
    je      .clear
    bt      rax, 63
    jc      .dirty_victim

.clear:
    mov     r10, [rbp - 24]
    xor     rax, rax
    xor     rcx, rcx
.zero:
    mov     [r10 + rcx], rax
    add     rcx, 8
    cmp     rcx, CybouDB_PAGE_SIZE
    jb      .zero

    mov     ARG1, [rbx + DB_CACHE]
    mov     ARG2, r12
    call    cyboudb_pcache_mark_dirty
    test    eax, eax
    jnz     .no_cache
    mov     ARG1, [rbx + DB_CACHE]
    mov     ARG2, r12
    mov     ARG3, [rbp - 32]
    call    cyboudb_pcache_set_type
    test    eax, eax
    jnz     .no_cache

    mov     qword [rbx + DB_ENC_ERROR], 0
    mov     rax, [rbp - 24]
    jmp     .out

.dirty_victim:
    mov     qword [rbx + DB_ENC_ERROR], CybouDB_E_STATE
    xor     eax, eax
    jmp     .out
.no_cache:
    mov     qword [rbx + DB_ENC_ERROR], CybouDB_E_STATE
    xor     eax, eax
.out:
    mov     rbx, [rbp - 8]
    mov     r12, [rbp - 16]
    FRAME_END
    ret

; =============================================================================
;  db_pages_flush(ctx) -> int
;
;  Steps 1 and 2 of Decision 6b: seal every dirty page under the current
;  generation, write it, and put its nonce and tag into the seal directory leaf
;  that covers it. Leaves are written after the pages they describe.
;
;  What this does NOT do, and the caller must: the seal tree nodes above those
;  leaves, the barrier, the superblock, and the second barrier. They are left
;  out because the tree's shape and the superblock's layout belong to the
;  engine's own metadata, which this half of the port has not reached yet - and
;  leaving them out loudly is better than doing half of them quietly.
;
;  Frame:
;    [rbp - 8..32]  saved rbx, r12, r13, r14
;    [rbp - 40] ctx    [rbp - 48] slot    [rbp - 56] frames
;    [rbp - 64] the leaf currently held   [rbp - 72] its page number
;    [rbp - 128] the page seal arguments
;    [rbp - 4224] the leaf itself
; =============================================================================
db_pages_flush:
    FRAME_BEGIN PR_FRAME, 0
    mov     [rbp - 8], rbx
    mov     [rbp - 16], r12
    mov     [rbp - 24], r13
    mov     [rbp - 32], r14

    mov     rbx, ARG1
    mov     [rbp - 40], rbx
    mov     qword [rbp - 72], -1        ; no leaf held yet
    mov     qword [rbx + DB_DIRTY_LEAF_N], 0
    mov     qword [rbx + DB_DIRTY_LEAF_OVF], 0

    mov     ARG1, [rbx + DB_CACHE]
    call    cyboudb_pcache_frames
    mov     [rbp - 56], rax

    xor     r12, r12                    ; the slot being looked at
.slot:
    cmp     r12, [rbp - 56]
    jae     .flush_leaf

    mov     rbx, [rbp - 40]
    mov     ARG1, [rbx + DB_CACHE]
    mov     ARG2, r12
    call    cyboudb_pcache_dirty_at
    cmp     rax, -1
    je      .next_slot
    mov     r13, rax                    ; the page in that slot

    mov     ARG1, [rbx + DB_CACHE]
    mov     ARG2, r12
    call    cyboudb_pcache_type_at
    mov     [rbp - 88], rax             ; what kind of page it is

    ; which leaf covers it
    mov     rax, r13
    xor     rdx, rdx
    mov     rcx, CybouDB_SEAL_ENTRIES_PER_LEAF
    div     rcx
    mov     r14, rdx                    ; the entry index
    mov     [rbp - 96], rax             ; leaf index, retained past the flush
    ; Dirty entries go to the copy the inactive superblock owns. The active
    ; directory must remain byte-for-byte available until publication.
    mov     r10, [rbx + DB_SEAL_DIR]
    mov     rcx, [rbx + DB_SEAL_PAGES]
    test    rcx, rcx
    jnz     .flush_have_stride
    mov     rcx, [rbx + DB_SEAL_LEAVES]
    inc     rcx                         ; legacy standalone depth-one harness
.flush_have_stride:
    cmp     qword [rbx + DB_SB_PAGE], CybouDB_SB_PAGE_A
    je      .flush_to_b
    cmp     qword [rbx + DB_SB_PAGE], CybouDB_SB_PAGE_B
    jne     .flush_copy_ready           ; standalone resolver harness
    sub     r10, rcx                    ; B active: prepare A
    jmp     .flush_copy_ready
.flush_to_b:
    add     r10, rcx                    ; A active: prepare B
.flush_copy_ready:
    add     rax, r10                    ; the inactive leaf's page number

    ; a different leaf than the one in hand? write the one in hand first
    cmp     rax, [rbp - 72]
    je      .leaf_ready
    mov     [rbp - 64], rax
    call    flush_held_leaf
    test    eax, eax
    jnz     .failed
    mov     rbx, [rbp - 40]
    mov     rax, [rbp - 64]
    mov     [rbp - 72], rax

    ; A deeper commit needs the dirty leaf set after this routine invalidates
    ; the ciphertext frames it would otherwise read it back from. Past the
    ; journal's capacity the commit is told to walk every leaf instead: the
    ; transaction is still published, it just costs what it used to.
    cmp     qword [rbx + DB_SEAL_DEPTH], 1
    jbe     .leaf_journaled
    mov     rcx, [rbx + DB_DIRTY_LEAF_N]
    cmp     rcx, CybouDB_DIRTY_LEAF_MAX
    jae     .leaf_journal_full
    mov     rax, [rbp - 96]
    mov     [rbx + DB_DIRTY_LEAVES + rcx * 8], rax
    inc     qword [rbx + DB_DIRTY_LEAF_N]
    jmp     .leaf_journaled
.leaf_journal_full:
    mov     qword [rbx + DB_DIRTY_LEAF_OVF], 1
.leaf_journaled:

    mov     ARG1, [rbx + DB_HANDLE]
    lea     ARG2, [rbp - PR_LEAF]
    mov     ARG3, CybouDB_PAGE_SIZE
    mov     rax, [rbp - 72]
    shl     rax, CybouDB_PAGE_SHIFT
    mov     ARG4, rax
    call    vfs_read_at
    cmp     rax, CybouDB_PAGE_SIZE
    jne     .failed

.leaf_ready:
    ; seal the page into that leaf's entry, in the frame it already occupies
    mov     rbx, [rbp - 40]
    mov     ARG1, [rbx + DB_CACHE]
    mov     ARG2, r13
    call    cyboudb_pcache_frame
    test    rax, rax
    jz      .failed
    mov     [rbp - 80], rax             ; the plaintext frame

    lea     r10, [rbp - PR_ARGS]
    lea     rax, [rbx + DB_SEAL_KEY]
    mov     [r10 + PSEAL_KEY], rax
    mov     rax, [rbp - 80]
    mov     [r10 + PSEAL_PAGE], rax
    mov     rax, r14
    imul    rax, rax, SENTRY_SIZE
    lea     rcx, [rbp - PR_LEAF]
    add     rax, rcx
    add     rax, SLEAF_ENTRIES
    mov     [r10 + PSEAL_ENTRY], rax
    lea     rax, [rbx + DB_UUID]
    mov     [r10 + PSEAL_UUID], rax
    mov     [r10 + PSEAL_PAGE_NO], r13
    mov     rax, [rbx + DB_GENERATION]
    inc     rax                         ; the generation being published
    mov     [r10 + PSEAL_GENERATION], rax
    mov     rax, [rbp - 88]             ; the type the writer recorded
    mov     [r10 + PSEAL_PAGE_TYPE], rax
    mov     rax, [rbx + DB_SEAL_EPOCH]
    mov     [r10 + PSEAL_EPOCH], rax

    lea     ARG1, [rbp - PR_ARGS]
    call    cyboudb_page_seal
    test    eax, eax
    jnz     .failed

    ; the ciphertext is in the frame now; write it where it belongs
    mov     rbx, [rbp - 40]
    mov     ARG1, [rbx + DB_HANDLE]
    mov     ARG2, [rbp - 80]
    mov     ARG3, CybouDB_PAGE_SIZE
    mov     rax, r13
    shl     rax, CybouDB_PAGE_SHIFT
    mov     ARG4, rax
    call    vfs_write_at
    cmp     rax, CybouDB_PAGE_SIZE
    jne     .failed

    ; The frame now holds ciphertext, not the page. It must not be handed to a
    ; reader as though it were plaintext, so it leaves the cache: a commit
    ; costs the pages it wrote out of the cache, which is a price worth paying
    ; over handing out bytes that are no longer what they claim.
    mov     ARG1, [rbx + DB_CACHE]
    mov     ARG2, r13
    call    cyboudb_pcache_invalidate

.next_slot:
    inc     r12
    jmp     .slot

.flush_leaf:
    call    flush_held_leaf
    test    eax, eax
    jnz     .failed
    xor     eax, eax
    jmp     .out

.failed:
    mov     rbx, [rbp - 40]
    mov     qword [rbx + DB_ENC_ERROR], CybouDB_E_SEAL
    mov     eax, CybouDB_E_SEAL
.out:
    mov     rbx, [rbp - 8]
    mov     r12, [rbp - 16]
    mov     r13, [rbp - 24]
    mov     r14, [rbp - 32]
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  flush_held_leaf - write the leaf in [rbp - PR_LEAF] to the page number in
;  [rbp - 72], if there is one. Uses the caller's frame on purpose: it is part
;  of db_pages_flush and exists only so the "write the previous leaf" step is
;  not written twice.
; -----------------------------------------------------------------------------
flush_held_leaf:
    push    rbp
    mov     rbp, rsp
    sub     rsp, 32 + SHADOW_SPACE
    mov     r10, [rbp]                  ; the caller's rbp
    cmp     qword [r10 - 72], -1
    je      .success

    ; The leaf changed, so its CRC is no longer its CRC. A leaf written with a
    ; stale checksum reads as damage on the next open - the seal tree would
    ; have caught it, but as a torn page rather than as the mistake it is.
    push    r10
    lea     ARG1, [r10 - PR_LEAF]
    mov     ARG2, SLEAF_CRC
    CALL_ABI crc32c
    pop     r10
    mov     [r10 - PR_LEAF + SLEAF_CRC], eax

    mov     rax, [r10 - 40]             ; ctx
    mov     ARG1, [rax + DB_HANDLE]
    lea     ARG2, [r10 - PR_LEAF]
    mov     ARG3, CybouDB_PAGE_SIZE
    mov     rax, [r10 - 72]
    shl     rax, CybouDB_PAGE_SHIFT
    mov     ARG4, rax
    call    vfs_write_at
    cmp     rax, CybouDB_PAGE_SIZE
    jne     .write_failed
.success:
    xor     eax, eax
    jmp     .done
.write_failed:
    mov     eax, CybouDB_E_SEAL
.done:
    mov     rsp, rbp
    pop     rbp
    ret

%ifdef CybouDB_LINUX
section .note.GNU-stack noalloc noexec nowrite progbits
%endif
