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

`DB_PAGE_HERE`'s encrypted branch is now compiled in: every build defines
`CybouDB_ENCRYPTED_PAGES`, and the resolver, the page cache and the seal and
AEAD modules it needs are linked into the engine rather than only into the
crypto harnesses.

The allocator is the first module ported all the way through. Every page
address in `core/bitmap.asm` now goes through `DB_PAGE_HERE`, every site reads
a null as a refusal, and `tests/encrypted_map_test.c` drives
`db_bitmap_validate` over a real sealed database: the whole map validates
through the seal tree, a leaf with one byte changed does not, and the other
copy being damaged does not stop this one.

What a null means depends on which side of the map it happens on. On the
reading side it is simply "no": `span_valid` rejects the candidate,
`db_bitmap_is_payload` says no, `db_bitmap_is_fresh` says not-fresh. On the
writing side there is no honest answer at all - the allocator's next word
would be a guess about which pages are free, and a guess that says "free"
hands out a page that is not - so `map_unreadable` poisons the handle exactly
the way an uncertain durability barrier poisons it. `db_commit`,
`db_alloc_page` and `db_rollback` already refuse a poisoned handle, so the
refusal does not depend on anyone reading `DB_MODE` promptly.

### Opening one

`db_open_encrypted` is that open, in `core/encrypted_db.asm`. It produces the
same context `db_open` produces - page counts, allocation state, map root,
catalog root, capability bits, a superblock pointer - for a sealed file:

```text
1. open and lock the file            as db_open does
2. its size                          the geometry is checked against it
3. attach with the private key       header, both superblocks, crypto root,
                                     key slot, key hierarchy, tag, tree root,
                                     and the choice between the two copies
4. the superblock, copied            authenticated by then, and there is no
                                     mapping to leave it in
5. the geometry it claims            the same checks db_open makes
6. the allocation map                through the resolver, page by page
```

It is a second entry point rather than a branch inside `db_open` because the
two differ in the one place that cannot be a branch: *when* the superblock is
chosen. A plain open picks the newest copy whose checksum verifies and then
validates its map; an encrypted open cannot, because a checksum cannot tell a
torn commit from a forgery.

Its arguments arrive as a struct (`EOPEN_*`) for the reason create's do: the
public open this will sit under has to grow a recovery credential, a keystore
handle and a cache budget without changing shape.

**`DB_BASE` is left null, deliberately.** An encrypted database has no useful
mapping - the bytes in the file are ciphertext - and a module not yet reading
through `DB_PAGE_HERE` would read them and find a page that looks like
nothing. A null base makes that a fault at the point of use instead, the same
bargain the resolver makes when it returns zero. The authenticated superblock
therefore lives in the context, at `DB_SB_COPY`, rather than in a mapping.

`tests/encrypted_open_db_test.c` links the whole engine and walks the chain
end to end: `db_open` refuses the file by name for want of a key,
`db_open_encrypted` opens it, the map resolves, a page is written, the
generation commits into the copy that was not live, a reopen finds it and
reads the page back as plaintext, a rewritten map leaf makes the open fail, a
forged newest superblock falls back to the generation before it, and an open
asking about integrity is told what recovery papered over while an ordinary
one is not.

What it does not do yet: fall back **at the map**. Step 3 falls back from a
superblock that does not authenticate, which is the recovery contract; if the
generation it chose has a map that does not validate, this refuses rather than
trying the one before it. The plain open does try, because it can validate a
candidate before choosing it. Doing the same here means attach taking a "not
this one" argument.

The remaining boundary is the public C API, which still has no key-bearing
entry point, and the other modules - catalog, PAX, index, the SQL cursors -
which are ported the way the allocator was: every page address through
`DB_PAGE_HERE`, every site reading a null as a refusal, each one exercised by
a suite run against a sealed database rather than imagined by a reviewer.

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

3.  DB_CACHE, and the encrypted branch, for reads. *(branch compiled in;
    its call sites do not yet read a null as a refusal)*
    Verified by: root-to-leaf MAC traversal, AEAD open, repaired-CRC attacks,
    depth-two close/reopen tests, and every plain suite with the branch live.

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

The plain path gains a compare and a perfectly predicted branch per page
address, at 81 sites. The benchmarks that must not move are the ones with the
most page addresses per unit of work: the sequential scan and the selective
predicate.

Measured by building the engine twice from the same tree, once with
`CybouDB_ENCRYPTED_PAGES` and once without, and running the two binaries
interleaved against one 126,976-row table, nine rounds each, best of nine:

| scenario | delta |
| :--- | ---: |
| full scan | +0.90% |
| int32 equality | -5.11% |
| int32 range | +3.00% |
| int64 range | -2.46% |

The deltas scatter symmetrically around zero and the negative ones are as large
as the positive ones, which says the effect is below this machine's noise floor
rather than that it is zero. That is the honest reading and it is also what the
shape of the change predicts: page addressing happens once per page while the
kernels run once per row, so two predicted instructions per page cannot show up
against per-row work. A number small enough to resolve one percent belongs on
the benchmark hardware in `benchmarks/results/`, not on a developer laptop, and
this table will be replaced by it rather than defended.
