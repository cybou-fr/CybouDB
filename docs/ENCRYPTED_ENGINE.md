# Porting the engine to encrypted pages

*The encrypted page path, its completed pieces, and the remaining engine port.*

The internal engine path now creates an encrypted file, attaches with an
ML-KEM private key, resolves and writes encrypted pages through a private
cache, commits with two durability barriers, and reopens the published
generation. Seal trees of more than one internal level are created, traversed
and committed as well. Attaching chooses between the two superblock copies
itself, with the key rather than with a checksum.

`cyboudb_encrypted_create` now writes a canonical CybouDB database rather than
a container: the full feature profile in the header, the paired `MAP_SPAN`
allocation map where every CybouDB file keeps it, and both map copies sealed
under the same seal tree as everything else.

Two boundaries remain, and they are both integration rather than cryptography.
The first is the ordinary `db_open` and public C API path: they still have no
credential-bearing entry point and therefore return `CybouDB_E_NEEDS_KEY` for
an encrypted header. The second is the allocator itself: it reaches the map
through `DB_PAGE_HERE`, whose encrypted branch is compiled out because no build
defines `CybouDB_ENCRYPTED_PAGES`, and each of those sites still has to learn
to see the null the resolver returns for a page that did not verify.

### The layout an encrypted database has

With `K = ceil(pages / 16112)` map pages per copy and `S` pages in one
seal-tree copy:

```text
page 0              the header, plaintext: identity and the feature bits
pages 1, 2          superblock A and B, plaintext, each with a tag
pages 3 .. 3+K      allocation map copy A        sealed
pages 3+K .. 3+2K   allocation map copy B        sealed
page 3+2K           the crypto root
page 3+2K+1         the key slots
pages 3+2K+2 ..     seal-tree copy A, S pages, then copy B
then                everything the database holds
```

The map keeps the position the plain format gives it and the crypto pages move
to make room, which is the only way round that works: the map is at 3 and 3+K
in every CybouDB file and `span_valid` refuses any other position in as many
words, while the crypto root is reached through `SB_FEATURE_ROOT` and the key
slots and the directory through pointers inside it. Moving what is pointed at
costs nothing.

The map pages are sealed like any other page - AEAD under the page seal key,
nonce and tag in the seal leaf that covers them, that leaf under the tree the
superblock's tag publishes. So a map an attacker rewrites does not open, a map
from an earlier generation does not replay, and a map from another database of
the same shape does not splice in. They are also the only pages the creator
seals: a fresh database has nothing else in it.

---

## The measurement

Every page address in the engine has the same shape, and there is only one:

```text
    shl  <register>, CybouDB_PAGE_SHIFT      ; page number to byte offset
    add  <register>, [ctx + DB_BASE]         ; plus the mapping's base
```

| | |
| ---: | :--- |
| 128 | sites computing a page address this way |
| 1 | field they all derive from, `DB_BASE` |
| 9 | sites using the `PAGE_ADDR` macro instead, all in one file |

```text
    33  src/core/pax.asm          10  src/core/index.asm
    21  src/core/catalog.asm       6  src/sql/executor.asm
    13  src/core/bitmap.asm        6  src/core/cow.asm
    11  src/core/database.asm      5  src/sql/binder.asm
     9  src/console/repl.asm       4  src/core/zonemap.asm
                                   3  src/core/varlen.asm, src/main.asm
```

That uniformity is the good news and the bad news. Good, because there is one
transformation rather than 128 special cases. Bad, because the transformation
cannot be made invisible: today a page address costs a shift and an add, with
no register clobbered and no call, and every one of those 128 sites was
written knowing that.

## Why the obvious options are wrong

**Decrypt the whole file into anonymous memory at open.** One line changes -
`DB_BASE` points at a private buffer instead of a mapping - and all 128 sites
keep working unmodified. It is also a promise that a database is smaller than
memory, which is exactly the promise an embedded storage engine exists not to
make. Rejected, but worth stating, because it is the option that will look
attractive at the end of a long day.

**Fault pages in under the mapping.** Keep the arithmetic, and populate pages
on demand with `userfaultfd` on Linux and a structured-exception handler on
Windows. Two platform mechanisms, neither portable to the other, and a page
fault handler that has to do AEAD work - a decryption failure inside a fault
handler has nowhere to report to. Rejected.

**Convert every site to a call.** Correct, and the honest cost: a call clobbers
the volatile registers, and 128 sites written around pure arithmetic would each
need their live values audited. That is where most of the risk of this release
sits.

## The shape chosen

A macro with a runtime branch, so the plain path stays arithmetic and the
encrypted path is a call:

```text
DB_PAGE <dst>, <ctx>, <page>

    cmp   qword [ctx + DB_CACHE], 0
    jne   .through_the_cache          ; encrypted: a call, and it may fail
    mov   dst, page
    shl   dst, CybouDB_PAGE_SHIFT
    add   dst, [ctx + DB_BASE]        ; plain: what the code does today
```

* **A plain database pays one compare and one predictable branch** per page
  address. That cost is not assumed to be free - it is measured below, against
  the same benchmarks `0.5` and `0.6` were measured with, and if it shows up
  the design changes rather than the claim.
* **`DB_CACHE` is zero for every database that is not encrypted**, which is
  every database that exists today, so the branch predicts perfectly.
* **The encrypted path can fail.** A page whose tag does not verify is
  `CybouDB_E_SEAL`, and a caller that cannot see that is a caller reading
  something the file does not vouch for. This is the part that makes the port
  large: the 128 sites do not currently have an error path at that point.

## The order of work

Each step leaves the tree green and the plain path unchanged, and each is
verifiable on its own:

```text
1.  DB_PAGE exists, plain path only, no call. Convert one module. *(done)*
    Verified by: every existing suite, plus a benchmark showing the plain
    path did not get slower.

2.  Convert the rest, module by module, still plain-only. *(done)*
    Verified by: the same suites after each module.

3.  DB_CACHE, and the encrypted branch, for reads. *(internal path done)*
    Verified by: root-to-leaf MAC traversal, AEAD open, repaired-CRC attacks,
    and depth-two close/reopen tests.

4.  Writes, dirty pages and the commit order of Decision 6b. *(done)*
    Verified by: production-path first- and second-barrier failures, poisoned
    handles after uncertain durability, paired-tree fallback, and multi-level
    commit/reopen.

5.  cyboudb check over an encrypted graph.

6.  Only then: the encryption bit in the normative format header, and a CLI
    that can create one.
```

**The bit stays out of `include/format.inc` until step 6.** A file with
`ENCRYPTION = 131072` in its header is a public commitment, and the first one
that exists must already be a file every later build can open. Until then the
only encrypted files are the ones the two harnesses write into `build/`, which
no CLI can produce and no test leaves behind.

### Commit cost

A commit at any depth now costs what the transaction changed, and it gets
there in two halves.

*Catching the inactive copy up.* It can be two generations behind, so it has
to be brought level with the active copy before this transaction is applied on
top of it. A depth-one tree compares the two root nodes and copies the leaves
whose MACs differ. A deeper tree does the same thing recursively: it descends
from the root and stops at the first node whose bytes already match its
opposite number, because a node's child MACs cover everything beneath it. A
worklist of 256 divergent nodes bounds the descent; past that it falls back to
copying the whole tree, which is slow and never wrong.

*Rebuilding.* `db_pages_flush` writes down the index of every seal leaf it
changes, because by the time the commit runs the ciphertext frames it would
have read that back from have been invalidated. The commit then rebuilds one
root-ward path per journalled leaf instead of one pass per level. The journal
holds 256 entries and reports its own overflow; on overflow the commit walks
every leaf, which again is slow and never wrong.

The journal's capacity is its own. An earlier version sized it to the page
cache and then refused to attach to a cache with more frames than it held,
which made an internal scratch array the ceiling on the one setting that
matters most to an encrypted database's speed. A cache budget is a first-class
setting; nothing internal gets to cap it.

What is still true: an encrypted transaction's dirty working set cannot exceed
the cache, because dirty eviction is a refusal rather than a writeback. That
is a real limit and a separate piece of work.

### Recovery

`db_encrypted_attach` reads both superblock copies, keeps every one whose
checksum verifies, and then tries them newest first. A candidate is accepted
only when its tag and the seal-tree root it publishes both authenticate under
the key the caller supplied, so a torn commit that left a perfect CRC over a
forged or half-written generation is rejected rather than opened. Falling back
to the copy before it is a success, and it is also damage: `DB_DAMAGED` records
the generation that failed, which is what lets an open return the older
database while a check still says what was lost.

One failure is not retried. A wrong key is refused immediately, because both
copies name the same key slots and a second attempt would spend another
decapsulation to reach the same answer.

## What "did not get slower" means here

The plain path gains a compare and a branch per page address. The benchmarks
that must not move are the ones with the most page addresses per unit of work:
the sequential scan and the point lookup, both already measured in
`benchmarks/results/`. A regression under one percent is noise on this
hardware; anything above that is a result, and this document is where it would
be recorded rather than explained away.
