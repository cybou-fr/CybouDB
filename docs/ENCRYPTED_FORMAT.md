# The encrypted format

Step 2 of the `0.7` work. The threat model
([ENCRYPTION.md](ENCRYPTION.md)) said what must be protected and what cannot
be; this says **what the file looks like**, and it is where the roadmap's first
real question gets answered: format v1 with new bits, or format v2.

Nothing here is implemented. Where a decision belongs to a later step — which
AEAD, which KEM, what the manifest contains — this document states the
*requirement* the choice has to satisfy and stops.

---

## Decision 1 — this is format v1 with an incompatible bit

```
CybouDB_FEATURE_ENCRYPTION = 131072     (the next free bit)
    requires COW, CATALOG, MAP_SPAN
    creation-time only, like QUEUE_LEASES
```

The argument, and the condition that makes it honest:

**The structure does not change.** Page 0 is still the header at the same
offsets. Superblocks are still pages 1 and 2 with the same fields. The
allocation map still sits at a fixed position, a PAX leaf still declares its
page id at +8 and its generation at +16, a queue page still holds its head and
tail where it held them. What changes is a transformation applied to the bytes
of a page *between the file and the engine*, and a small amount of new metadata
that lives in pages of its own.

A format version exists to answer "can a reader that knows v1 make sense of
this file's structure". For an encrypted file the answer is still yes — it can
read page 0, find the feature mask, see a bit it does not know, and refuse.
That refusal is the format working, and it is exactly what `QUEUE_LEASES` did
one release ago.

**The condition:** page 0 must stay plaintext, and the bit must be in
`flags_incompat`. If either fails, an older reader sees noise where the magic
should be and reports *not a CybouDB file* rather than *a CybouDB file needing
something I do not have*. [ENCRYPTION.md](ENCRYPTION.md#what-an-encrypted-file-still-tells-you)
already names the leak this costs, and pays it deliberately.

**Rejected: format v2.** It would be the right answer if page *bodies* had to
shrink to make room for a tag — that changes how many rows a leaf holds, which
changes every capacity table and every file already written. Decision 3 avoids
needing it. A v2 with a migration path stays available for something that
genuinely cannot be expressed in v1; spending it here would be spending it
early.

---

## Decision 2 — what is sealed

| Pages | Sealed? | Why |
| :--- | :--- | :--- |
| 0 — file header | **No** | Identity and geometry. A reader without keys must be able to refuse intelligibly. |
| 1, 2 — superblocks | **Authenticated, not encrypted** | Recovery has to pick the newer valid generation *before* any key is available for the pages it names. |
| allocation map | **Authenticated, not encrypted** | Same reason: the free/used shape is what a recovering writer needs first. The leak — how much of the file is in use — is named in the threat model. |
| seal directory (Decision 3) | **Authenticated** | It is the authentication. |
| everything else | **Encrypted and authenticated** | Catalog, PAX leaves, varlen, vector, index, queue and stream pages — all payload or structure that describes payload. |

The line is drawn at *what recovery must read before it has a key*. Everything
on the wrong side of that line is a leak stated in the threat model rather than
a decision made here for convenience.

**Zone maps are inside PAX leaves and are therefore encrypted**, which is the
threat model's requirement and costs what it costs: a reader without the key
cannot prune, because pruning is reading.

---

## Decision 3 — the seal directory, not a shrunken page

Every sealed page needs a nonce and an authentication tag. There are three
places to put them:

1. **In the page**, shrinking its body by 40 bytes. Every capacity table
   changes — a `1 x BOOL` leaf drops from 3520 rows, a queue segment holds
   fewer messages, `MAP_CRC` moves. This is format v2, for a reason with
   nothing to do with cryptography.
2. **Derived, and stored nowhere.** A nonce computed from page number and
   generation needs no space at all. Decision 4 explains why it is unsafe.
3. **In pages of their own.** A *seal directory*: fixed-position metadata
   pages, two copies, one entry per page of the file, indexed by page number.
   Chosen.

```
page 0                 file header               plaintext
pages 1, 2             superblock A, B           authenticated
pages 3 .. 3+K-1       allocation map copy A     authenticated
pages 3+K .. 3+2K-1    allocation map copy B     authenticated
pages 3+2K .. +S-1     seal directory copy A     authenticated
pages 3+2K+S .. +2S-1  seal directory copy B     authenticated
pages 3+2K+2S ..       payload                   sealed
```

Copy A belongs to whichever generation superblock A publishes, exactly as the
span map already works. That is deliberate reuse rather than a new idea: the
map's two-copy discipline is the thing that makes a half-written commit
recoverable, and the seals have precisely the same requirement.

**One entry per page: 24-byte nonce, 16-byte tag, 40 bytes.** With a 64-byte
page header and the CRC in its usual place, an entry page covers
`(4092 - 64) / 40 = 100` pages. So `S = ceil(total_pages / 100)`, in two
copies:

| File | Pages | Seal directory, both copies | Overhead |
| ---: | ---: | ---: | ---: |
| 4 MiB | 1,000 | 20 pages | 2.0% |
| 240 MiB | 60,000 | 1,200 pages | 2.0% |
| 4 GiB | 1,048,576 | 20,972 pages | 2.0% |

Two per cent of the file, flat, and known before a line is written. That number
is the price of not touching a single existing page layout.

**What it costs in writes is not known and must be measured.** A commit that
rewrites five scattered payment pages may touch five different seal pages,
turning a 5-page commit into a 10-page one. The engine already has the
instrument for this — the flush measurement of `preview.2` counted exactly this
kind of amplification — and step 19 has to run it before anyone claims the
design is cheap. If locality turns out to be bad, the answer is a different
entry layout, not a different story about the cost.

---

## Decision 4 — the nonce is stored, because deriving it is unsafe here

A nonce derived from `(page number, generation)` looks obviously correct and is
obviously correct for the pages that a commit publishes. It is wrong for the
pages a commit *does not* publish, and the reason is worth writing down because
it is invisible from the format alone:

```
transaction 1   writes page 412 with plaintext P1, at generation 7
                fails, or the process dies, or the caller rolls back
                generation 7 is never published

transaction 2   writes page 412 with plaintext P2, at generation 7
                commits
```

Same key, same page, same generation, two different plaintexts — and for a
counter-mode AEAD that is the one failure that is total: the keystream repeats,
the plaintexts xor together, and the authentication key can be recovered for
GCM. Nothing in the file is corrupt; nothing fails a check; the data is simply
readable afterwards.

This is the mistake the roadmap named as *silent, total and unrecoverable*, and
it is reachable in this engine by a rolled-back transaction, which is an
ordinary event rather than an attack.

**Requirement on step 3, stated here so the primitive is chosen with it:** the
construction must be one of

* an AEAD where a repeated nonce is not catastrophic — a misuse-resistant mode,
  or an extended-nonce construction with a random 192-bit nonce per write;
* or a nonce that provably never repeats **including across writes that were
  never published** — which in practice means a counter that survives the death
  of the process that incremented it, and that is a durable write of its own.

The first is cheaper and is the working assumption. Either way **the nonce is
stored in the seal directory rather than recomputed**, because a stored nonce is
a fact and a derived nonce is an argument that has to keep being true.

---

## Decision 5 — what the tag covers

Encrypting a page proves nobody can read it. The associated data is what proves
nobody can move it, and every field below is here because leaving it out
enables a specific attack:

```
AAD = file_uuid ‖ page_number ‖ generation ‖ page_type ‖ seal_epoch
```

| Field | Without it |
| :--- | :--- |
| `file_uuid` | A page from *another* database of the same shape can be spliced in. The header's `reserved_uuid` at +48 exists and is zero today; encryption is what makes it load-bearing. |
| `page_number` | A valid page can be moved to a different page number - a queue segment presented as a catalog page, or one table's leaf presented as another's. |
| `generation` | A page from an earlier generation of *this* file can be replayed into the current one: a balance from before a transfer, re-authenticating perfectly. |
| `page_type` | Type confusion within a generation, which the validator catches structurally today only because the plaintext header says what it is. |
| `seal_epoch` | A page encrypted under a rotated-away key could be accepted after rotation. |

The page already carries `page_id` and `generation` in its own plaintext header
for the validator's benefit. Under encryption those become *claims inside the
ciphertext* that must equal the AAD the reader supplied — which is how a
mismatch becomes a refusal instead of a silently accepted page.

**The superblock is the exception and needs its own argument.** Its tag lives
in its own reserved bytes at +64 - 56 free, 40 needed - so it cannot cover
itself: authentication runs over bytes `[0, 124)` **with the 40-byte seal slot
read as zero**, the same trick the CRC uses by sitting outside its own range.
`generation` is in the AAD, and `staged` at +120 is inside the authenticated
range, which is what stops an attacker clearing the marker to promote a
half-built graph. It cannot be
encrypted: recovery reads both superblocks, compares generations and picks the
newer valid one, and it has to do that before it knows which key any page is
under. So an attacker who can write the file may still choose *between
superblock A and superblock B* — both genuine — and that is the smallest form
of the rollback the threat model already refuses to claim it can prevent.

---

## Decision 6 — where the keys live, and what the superblock points at

`SB_FEATURE_ROOT` at +56 has been reserved since v1 was frozen, refused when
non-zero, and documented as *an extension this build does not implement*. This
is that extension:

```
superblock
  └─ feature_root ──▶ crypto root page          (sealed under the root KEK)
                       ├─ KDF parameters and salt
                       ├─ seal_epoch
                       ├─ wrapped database root key
                       ├─ wrapped scoped DEKs, by key id
                       ├─ access manifest root   (step 10)
                       └─ seal directory geometry: first page, S
```

Consequences worth stating now:

* **The header carries the salt, not the key.** Page 0 gains the KDF salt in
  its reserved bytes and the file UUID in `reserved_uuid`. Neither is secret,
  and both must be legible before anything can be unwrapped.
* **No key material is derivable from the file alone.** The root key is stored
  wrapped under a KEK the file does not contain. This is one of the eleven
  falsifiable claims in the threat model, and it is a property of this layout
  rather than a promise about implementation care.
* **`feature_root` non-zero without the encryption bit stays refused**, which is
  what v1 already says. The bit is what makes the pointer legal.

---

## Decision 7 — encrypted mode does not use the shared mapping

This is the decision with the largest engineering cost and the least choice
about it.

Today the file is mapped once and every page read is `[DB_BASE + page × 4096]`.
A write is a store into that mapping, and a commit flushes ranges of it. That
is incompatible with encryption at rest for a reason that has nothing to do
with performance: **the bytes the engine works on and the bytes the file holds
are the same bytes.** The operating system writes that mapping back whenever it
likes. Plaintext in the mapping is plaintext on the disk.

So an encrypted database needs:

* **explicit I/O.** `vfs_pread` and `vfs_pwrite`, which do not exist: the
  platform layer exports `vfs_create_new`, `vfs_create_truncate`, `vfs_open_rw`,
  `vfs_open_ro`, `vfs_size`, `vfs_resize`, `vfs_map_rw`, `vfs_map_ro`,
  `vfs_unmap`, `vfs_sync`, `vfs_close`, `vfs_flush_range`, `vfs_lock_writer`,
  `vfs_lock_reader`, `vfs_reclaim_safe` - and nothing at all that moves bytes
  without a mapping;
* **a plaintext page cache** the engine reads through, with pinning, eviction
  and a budget. `DB_BASE + page × 4096` becomes a lookup, at 156 call sites;
* **an encrypt-on-eviction and encrypt-on-commit path**, with the seal
  directory updated in the same commit that publishes the pages it seals;
* **a policy for the plaintext cache itself** — it is process memory, and the
  threat model already puts a compromised process out of scope, but *swap* is
  not the process. Locking cache pages where the platform allows belongs here.

Two honest consequences:

1. **This is the expensive part of `0.7`, not the cryptography.** A reference
   AEAD is a bounded piece of work with official test vectors. A page cache
   under the engine's hottest operation is an architectural change that every
   existing suite has an opinion about.
2. **Plaintext databases must keep the mapping.** Whatever the cache costs, a
   file without the encryption bit must not pay it. That means the read path
   has two shapes, chosen at open, and the cost of *that* is a branch in the
   hottest code in the engine — which is itself a thing to measure before
   believing.

**Step 2 does not get to hand-wave this.** The measurement that decides whether
the cache is acceptable belongs before step 7 (authenticated page encryption),
not at step 19 with everything else, because if it is unacceptable the shape of
the release changes.

---

## What does not change

* A file without `CybouDB_FEATURE_ENCRYPTION` is byte-for-byte what `0.6`
  wrote, read by the same mapping, at the same speed. The frozen fixtures from
  every earlier release keep reading, and `tests/compat_tests.py` is what will
  say so.
* `cyboudb check` still verifies every page of the retained graph. On an
  encrypted file it needs a key to do it, and *that* is a change to the tool's
  contract worth a line in its own documentation: an operator who can check a
  database can read it.
* CRC-32C stays on every page, under the ciphertext. A tag failure and a
  checksum failure mean different things — *somebody lied* against *the disk
  lied* — and the threat model keeps them separate deliberately.

---

## Open, and named

* **Does the seal directory need two copies?** It must be consistent with the
  generation that published it, which the map solves by pairing. Whether seals
  can instead be recovered from the pages they seal (they cannot — that is what
  a tag is for) or reconstructed on a rekey is worth one paragraph and one
  experiment, because 2% of the file is a real number.
* **Write amplification per commit shape**, measured with the existing flush
  instrument, on the queue and stream paths where a commit touches scattered
  pages.
* **What happens to the mapping-based instruments** — `db_bitmap_headroom` and
  the change-set audit both read the file directly. They stay correct on
  plaintext files; on encrypted ones they need the same read path as everything
  else.
* **Whether `staged` still works.** The in-memory candidate superblock carries
  `staged = 1` and is rejected on disk. With authentication, a staged
  superblock is authenticated too, and the design must make sure the marker
  cannot be stripped by an attacker to promote a half-built graph.

Steps 3 onward answer these in order; nothing below step 2 starts until the
measurement in Decision 7 exists.
