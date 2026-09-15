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

**What the bit permits, and only it.** Two fields that v1 requires to be inert
become meaningful when `ENCRYPTION` is set, and stay inert without it:

| Field | Without the bit | With it |
| :--- | :--- | :--- |
| header `reserved_uuid` (+48, 16 bytes) | zero, as v1 requires | the database identity, 128 bits from the platform CSPRNG, written once at creation and never rewritten |
| superblock `feature_root` (+56) | non-zero is refused | points at the crypto root page |

A file carrying either one *without* the bit is refused rather than tolerated -
that is what v1 already says about both, and encryption does not soften it.

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

Before changing the inactive copy, the engine brings it forward from the
active one. The depth-one implementation compares the child MACs in the two
authenticated nodes and copies only leaves that differ. Publication never
changes the copy named by the live superblock.

The transaction records a bitmap of leaves represented by its dirty cache
frames before flush invalidates those frames. The new root node inherits the
active node and recomputes only those child MACs, so pages in one leaf cost one
leaf read no matter how many of them changed.

**One entry per page: 24-byte nonce, 16-byte tag, and the 8-byte generation
under which the page was sealed: 48 bytes.** With a 64-byte page header and
the CRC in its usual place, an entry page covers
`floor((4092 - 64) / 48) = 83` pages. So `S = ceil(total_pages / 83)`, in two
copies:

Counting the nodes of Decision 3b as well, and stating the overhead against
the *finished* file rather than against the pages it protects - for every 83
protected pages the file carries about 2 seal pages:

| File | Pages | Seal leaves | Nodes | Depth | Both copies | Overhead |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 4 MiB | 1,000 | 13 | 1 | 1 | 28 pages | 2.72% |
| 240 MiB | 60,000 | 723 | 4 | 2 | 1,454 pages | 2.37% |
| 4 GiB | 1,048,576 | 12,634 | 52 | 2 | 25,372 pages | 2.36% |
| 24 GiB | 6,300,000 | 75,904 | 306 | 3 | 152,420 pages | 2.36% |

About 2.4 per cent, flat, and known before a line is written. That number
is the price of not touching a single existing page layout.

**Seal pages have no seal entries of their own.** A seal leaf is authenticated
by its parent node, a node by its parent, and the root by the superblock - so
the directory does not index itself and there is no recursion to terminate. The
entry array therefore covers payload and the allocation map, and skips the
range the directory occupies.

**What it costs in writes is not known and must be measured.** A commit that
rewrites five scattered payment pages may touch five different seal pages,
turning a 5-page commit into a 10-page one. The engine already has the
instrument for this — the flush measurement of `preview.2` counted exactly this
kind of amplification — and step 19 has to run it before anyone claims the
design is cheap. If locality turns out to be bad, the answer is a different
entry layout, not a different story about the cost.

---

## Decision 3b — what authenticates the seals

A tag proves a page was not altered *by whoever does not have the key*. It does
not prove the page is the **current** one, and the seal directory makes that
gap concrete:

```text
page 817     ciphertext_old        seal[817] = nonce_old + tag_old
                 ... rewritten ...
page 817     ciphertext_new        seal[817] = nonce_new + tag_new
```

An adversary who restores *both halves of the old pair* presents something the
AEAD accepts without hesitation, because it is genuine - it simply belongs to
last week. **An external tag is an authenticator only while the seal entry is
itself trusted state**, and nothing said so far makes it trusted state.

So the seals are authenticated by a keyed tree whose root is inside the
superblock:

```text
authenticated superblock                     (the trust anchor)
        │  seal_root MAC + seal geometry
        ▼
   seal node            MAC over its children's MACs, its own node id,
        │               the generation and the seal epoch
        ├── seal leaf   MAC over its 83 entries, its leaf index,
        │               the generation and the seal epoch
        │        └── nonce + tag for page N
        │                    └── sealed page N
        └── ...
```

Each level authenticates the level below, and the top is authenticated by the
superblock, which is authenticated by the key. Substituting an old page **and**
its old entry now fails at the leaf: the leaf's MAC covers the entry array as
it was published, so an entry from a different generation makes the leaf
disagree with its parent, the parent disagree with the root, and the root
disagree with the superblock.

**The geometry, with the arithmetic rather than an adjective.** A node page
holds `(4092 - 64) / 16 = 251` child MACs, so one node covers
`251 x 83 = 20,833` pages - which means **depth 1 for any file up to about
81 MiB and depth 2 for anything up to about 20 GiB**. A commit that rewrites *k* pages
updates at most *k* leaves, at most *k* nodes, one root and the superblock:
bounded, and independent of how large the database is.

Levels are stored consecutively inside each copy: all leaves at level zero,
then their parents, through the single root as the copy's final page.
`cyboudb_seal_level` is the shared resolver for a level's offset and count, so
create, open and commit do not acquire separate versions of this arithmetic.

### The invariant this establishes

> **What is current is exactly what a valid superblock says is current.**
> A page, a seal entry, a seal leaf and a seal node have no standing of their
> own: each is reachable, or it is not, from a superblock that authenticates
> under the key. An attempt that was never published has no valid superblock,
> and therefore has no authenticated existence - which is what stops a
> crashed generation-7 attempt from being spliced into the published
> generation 7.

### What the MAC actually is

`src/crypto/seal_dir.asm`, and the byte map in `include/crypto.inc`. The MAC is
**KMAC256** - NIST SP 800-185 - keyed with the seal tree key, customized by the
kind of page, over the page's own bytes:

```text
leaf MAC = KMAC256( key, X = leaf[8 .. 4064), L = 128,
                    S = "CybouDB/0.7/seal-leaf" )
node MAC = KMAC256( key, X = node[8 .. 4080), L = 128,
                    S = "CybouDB/0.7/seal-node" )
```

It was a prefix construction of this project's own - `SHAKE256(key | label |
bytes)` - described in this document as "KMAC's construction without its
encodings". That description was the argument against it. There is no attack
here to report; what changed is a scope decision this project had already made
elsewhere and had not applied to itself:

> A cryptographic **primitive** implemented here can be checked against another
> implementation, and has been - ML-KEM against OpenSSL, ChaCha20 and Poly1305
> against RFC 8439, Keccak against FIPS 202. A cryptographic **construction**
> invented here can be checked against nothing.

KMAC is standardised for exactly these two jobs, it is a MAC and a PRF, and its
encodings are what make the domain separation unambiguous rather than merely
careful. `tests/kmac_test.c` checks the implementation against OpenSSL 3 and
against the sample vector printed in SP 800-185 itself.

The key is the one `KDF_SEAL_TREE` derives, not the one that seals pages. The
covered range starts at byte 8 and so takes in the index, the generation and
the seal epoch along with the array; it stops before the CRC, which is a disk
check that anyone who writes the page recomputes.

**Neither a leaf nor a node holds a MAC of itself.** Its parent holds it, and
the root's is in the superblock. That is the structure rather than a saving: a
page carrying the MAC of itself would be attesting to its own honesty, which is
exactly what Decision 3b says an external tag cannot do. It is also what makes
the arithmetic above come out - 83 entries and 251 children are what fits once
nothing is reserved for a self-MAC.

This is also why `generation` alone was never going to be the anti-replay
identity. It is one field in the associated data, and it is not a claim that
*this* is the live version of the page; the seal root is that claim, and it is
the only one.

### What it still does not stop

Two superblocks exist so that a half-written commit is recoverable, and
recovery picks the newer *valid* copy. An adversary who can write the file can
therefore damage the newer one and force the reader back to the older - a
rollback of exactly one published generation, by destruction rather than
forgery. It is detectable as damage, not as forgery, and it is the smallest
member of the whole-file rollback family that
[ENCRYPTION.md](ENCRYPTION.md#rollback-to-an-older-internally-consistent-file)
already refuses to claim it can prevent. Naming it here keeps the seal tree's
promise honest: **it stops an old page being presented as current; it does not
stop an old database being presented as current.**

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

There are two separate failures in that picture and they need two separate
fixes, which is worth separating because fixing one looks like fixing both:

* **confidentiality** breaks because the keystream repeats. Only the primitive
  can fix that - see the requirement below;
* **replay** would let the unpublished attempt be presented as current. That is
  fixed by [Decision 3b](#decision-3b--what-authenticates-the-seals), not by the
  nonce, and it is fixed for every page rather than for this one case.

**Acceptance requirement on step 3**, written now so the primitive is chosen
against the engine's crash model rather than against a benchmark:

```text
Either
  A. the AEAD tolerates an accidental nonce repeat without a catastrophic
     loss of confidentiality or of the authentication key;
or
  B. CybouDB proves nonce uniqueness across crash and retry, independently of
     the transaction's generation and of whether it was ever published.
```

**A is strongly preferred**, because B is a durable, fsynced counter on the
commit path - a write whose whole purpose is to be slower than the thing it
protects - and because a proof that survives every crash path is a proof this
project would have to keep re-earning at every change to the commit.

NIST SP 800-38D makes a unique IV per key a *requirement* of GCM rather than a
recommendation, so plain AES-GCM only satisfies A by satisfying B. A
nonce-misuse-resistant AEAD - AES-GCM-SIV (RFC 8452) is the obvious candidate,
and is a candidate and not a choice - satisfies A directly. **Step 3 decides,
against official known-answer vectors; step 2 only refuses to let that decision
be made by accident.**

Either way **the nonce is stored in the seal directory rather than recomputed**,
because a stored nonce is a fact and a derived nonce is an argument that has to
keep being true.

### What step 3 actually chose, and which of A or B that is

Neither, and the honest thing is to say so rather than to let a 24-byte nonce
be mistaken for misuse resistance.

Step 3 chose XChaCha20-Poly1305 ([CRYPTO_BACKEND.md](CRYPTO_BACKEND.md)), for a
reason that had nothing to do with this gate: the ciphertext must not depend on
the machine that wrote it. **XChaCha20-Poly1305 is not nonce-misuse-resistant.**
A repeated nonce under one key is as bad here as it is for any stream cipher -
the keystream repeats, and the Poly1305 one-time key repeats with it. The
24-byte nonce does not change that; it changes how likely a repeat is.

So the contract is neither A nor B but a third thing, and it is written here so
that it can be held to:

```text
Nonce uniqueness in CybouDB is probabilistic, not proven.

  * every nonce is 192 bits drawn from the operating system's CSPRNG,
    per seal, at the moment of sealing;
  * no nonce is derived from page number, generation, epoch or time;
  * no nonce is cached, reused, or reconstructed after a crash - a page
    resealed after a crash is sealed under a new nonce, because it is
    sealed by the same code path as any other seal;
  * the page seal key changes with seal_epoch, so the count below is per
    epoch key and not per database lifetime.
```

**The bound.** With uniformly random 192-bit nonces, the chance that any two of
`n` seals under one key collide is about `n^2 / 2^193`:

| seals under one key | probability of any collision |
| ---: | ---: |
| 2^32 (4 billion) | about 2^-129 |
| 2^48 (280 trillion) | about 2^-97 |
| 2^51 - a million pages a second for a century | about 2^-90 |
| 2^64 | about 2^-65 |

For comparison, an uncorrected bit error on a disk is somewhere around 2^-50
per sector read. The nonce is not the weakest thing in this system by a very
long way, and that is the argument - not that a collision is impossible.

**What this costs if it is ever wrong.** If the CSPRNG is broken or the same
`os_random` output is returned twice - a virtual machine restored from a
snapshot is the realistic way - then two pages sealed under one key share a
keystream. That is a confidentiality break for those two pages and a forgery
risk under that key, and no part of this design would detect it. `os_random`
failing is treated as a fatal refusal rather than a fallback for exactly this
reason: there is no second source of randomness in this engine, on purpose,
because a fallback that is weaker than the primary is just the primary being
weaker.

**What is tested.** That a nonce is drawn per seal and never derived: sealing
the same page, at the same generation, under the same key, twice, gives two
different nonces; and a large batch of seals produces no repeat. Those are weak
tests of a strong claim, which is what a probabilistic contract permits - the
strength is in the 192 bits, and the tests only check that the 192 bits are
actually being drawn.

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

**What the file identity buys, exactly.** With `file_uuid` in the associated
data:

| | |
| :--- | :--- |
| a page from another database, spliced in | **detected** |
| a page moved within this file | **detected** |
| a page from an earlier generation of this file | **detected** (Decision 3b) |
| modified ciphertext | **detected** |
| the whole file replaced by an older copy of itself | **not detected** |

The last line is not a gap in the identity; it is the identity working. An old
copy of this database has this database's UUID, because it is this database.
Detecting it needs state the attacker does not control, and a single local file
has none.

**The superblock is the exception and needs its own argument.** Its tag lives
in its own reserved bytes at +64 - 56 free, 40 needed - so it cannot cover
itself: authentication runs over bytes `[0, 124)` **with the 40-byte seal slot
read as zero**, the same trick the CRC uses by sitting outside its own range.
`generation` is in the AAD, and `staged` at +120 is inside the authenticated
range, which is what stops an attacker clearing the marker to promote a
half-built graph.

The order is fixed, because the dependencies have to be acyclic:

```text
write                                     read
  1. prepare the superblock's fields        1. CRC over [0, 124)
  2. choose a fresh nonce                        -> a torn write is rejected
  3. zero the 16 tag bytes                          cheaply, before any key
  4. authenticate [0, 124)                          is involved
  5. write the tag                          2. authenticate [0, 124) with the
  6. CRC over the final [0, 124)                    tag bytes read as zero
  7. write the CRC at +124                       -> a trusted superblock
```

Only the **tag** bytes are zeroed for authentication, not the whole seal slot:
the nonce sits beside the tag and is an input the reader needs, so it is
authenticated like any other field. The CRC covers the final bytes including
the tag, which keeps the two guarantees in their usual order - *the disk did
not lie* first, and cheaply, then *nobody lied*. It cannot be
encrypted: recovery reads both superblocks, compares generations and picks the
newer valid one, and it has to do that before it knows which key any page is
under. So an attacker who can write the file may still choose *between
superblock A and superblock B* — both genuine — and that is the smallest form
of the rollback the threat model already refuses to claim it can prevent.

---

## Decision 5b - how a reader learns a page's type before it can verify it

Decision 5 binds five fields into the associated data, and one of them turned
out to be unavailable at the moment it is needed.

The engine computes a page address in 128 places
([ENCRYPTED_ENGINE.md](ENCRYPTED_ENGINE.md)), and in encrypted mode each of
those has to become a read, a decrypt and a tag check. The tag covers the
associated data, so the associated data has to be built **before** the page can
be verified - and three of its five fields are available at that moment: the
file's uuid, the page number being asked for, and the seal epoch the crypto
root records. The page's generation is stored in its seal entry, because a
commit may advance the database without rewriting that page. The fifth field,
the page's type, is known to the module that asked for the page and not to the
resolver that fetches it, and threading it through 128 call sites means 128
sites each carrying a fact about pages they only borrow.

Three ways out, and what each costs:

| | |
| :--- | :--- |
| thread the type through every access | 128 sites gain an argument, several of them read pages of more than one kind, and the mistake is silent |
| widen the seal entry to carry a type byte | 40 bytes becomes 48, a leaf holds 83 entries instead of 100, and the file's overhead goes from 1.97% to 2.4% |
| **put the type in the nonce** | eight bits of the nonce stop being random |

**The nonce carries it.** The last byte of a page's 24-byte nonce is its page
type; the other 23 bytes are drawn from the operating system's CSPRNG as
before:

```text
nonce = 184 bits of randomness | one byte of page type
```

The reader takes the type out of the nonce it already has to read, builds the
associated data with it, and verifies. Nothing else changes.

The reader likewise takes the generation out of the seal entry. Binding every
page to the database's current generation would make every untouched page
unreadable after a commit; binding it to the stored generation keeps copy-on-
write pages readable while the leaf MAC prevents that field being rewritten.

**Why this is not a weakening.** The nonce is an input to the AEAD, so a byte
changed there changes the keystream and fails the tag - the type is
authenticated exactly as strongly as the ciphertext is. And the entry that
holds the nonce is covered by its leaf's MAC, the leaf by its node, the node by
the superblock: an attacker cannot change the claimed type without breaking the
chain of Decision 3b first. A page sealed as one kind and offered as another
still fails, which is what Decision 5 asked for.

**What it does cost**, stated rather than waved past: the nonce is 184 random
bits instead of 192. Against the table in Decision 4, the collision bound at a
million seals a second for a century moves from about 2^-90 to about 2^-82.
Still far below every other failure this system has, and a hundred and eighty
four bits of randomness per seal remains an enormous margin - but it is a real
number that moved, and it moved because of an engineering constraint rather
than a cryptographic argument.

**What the seal and open calls do with it.** `cyboudb_page_seal` takes the page
type and puts it where it belongs. `cyboudb_page_open` reads it from the nonce
rather than being told, because the caller that needs to open a page is
precisely the one that does not know - and a caller who does know gains
nothing by repeating it, since the tag is what decides either way.

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

The byte map is now written down - `include/crypto.inc`, the `CROOT_*` block -
and `src/crypto/crypto_root.asm` is the only thing that writes it and the only
thing that judges it. Its validator is deliberately key-free: magic, version,
CRC, the algorithm ids, the reserved fields and the seal-directory geometry are
all decidable before anything is unwrapped, and each has its own refusal code.
That separation is what lets the engine tell a user three different things
truthfully - *this is not a CybouDB crypto root*, *this page is damaged*, and
*this key does not open this file* - where a single "bad file" would have
collapsed the third into the second and sent someone looking for a backup they
did not need.

---

## Decision 6b - the order of an encrypted commit, and what each barrier buys

A commit publishes a generation. In an encrypted file it also publishes the
only evidence that the generation's pages are what they claim to be, and those
two things have to become durable in the right order or the file can be
published while the evidence for it is still in a write cache.

The order, and it is not negotiable:

```text
1. write the new payload pages, sealed under the new generation
2. write the seal directory leaves that cover them
3. write the seal tree nodes above those leaves

   ---- barrier 1 ----------------------------------------------------
   everything the new generation needs, except the claim that it exists

4. write the superblock: the new generation, the new seal tree root,
   and the tag over both

   ---- barrier 2 ----------------------------------------------------
   the new generation exists
```

**What barrier 1 buys.** Without it, a crash can leave a superblock that
names a seal tree root whose node never reached the disk. The reader then has
a valid, authenticated superblock pointing at nothing - a *hybrid*: the new
generation published, the old generation's pages underneath it. Neither
"the old database" nor "the new database", which is the one outcome a storage
engine may never produce.

**What barrier 2 buys.** Only that the commit is acknowledged. A crash between
the superblock write and barrier 2 is indistinguishable from a crash before the
superblock write: either the superblock made it and the new generation is
current, or it did not and the old one is. Both are whole.

**The tag must cover every byte the reader uses.** A field that lives past the
tagged range is a field a torn write can change invisibly, and the fallback to
the other copy would never trigger for it. This is a requirement on the
engine's superblock layout and not a property of the crypto: the test that
found it was asserting that a tear in the untagged tail should fall back, which
was the wrong assertion - a tear there is harmless precisely because nothing
reads those bytes, and would stop being harmless the moment something did.

**Why the superblock's tag is what decides.** Recovery reads both superblocks,
verifies each tag under the metadata key, and takes the newest that verifies. A
superblock half-written by a crash does not verify - the tag covers the
generation and the tree root together - so a torn publication falls back to the
other copy rather than being read as a generation that never existed. That is
the same two-copy discipline `0.5` already uses for the allocation map, with
the tag doing what the CRC does there and more.

**The invariant.** For every prefix of that write sequence, a reader sees the
old generation whole or the new generation whole. `tests/encrypted_commit_test.c`
runs every prefix, and runs the sequence again with the superblock moved ahead
of the barrier to show that the ordering is what produces the invariant rather
than luck: in that version a prefix exists that publishes a generation whose
seal tree is not there, and the test demands that it exists.

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
   file without the encryption bit must not pay it - `PAGE_ADDR` stays a
   pointer, with no lookup and no branch. The dispatch belongs **above the hot
   inner loop**: a scan decides once which shape it is reading through and then
   runs, rather than asking *is this encrypted* per row, per cell or per page.
   Where exactly that boundary sits is what the spike below has to find, since
   putting it too high duplicates the executor and too low costs the branch
   this paragraph exists to avoid.

**Step 2 does not get to hand-wave this**, and the measurement has moved
earlier still: it is now step **2.5**, before the reference crypto backend
rather than before step 7. A reference AEAD is bounded engineering with
official test vectors; the I/O architecture is the one that can answer *the
storage engine needs a new page-access layer*, and that changes the release
rather than one of its steps.

### The spike, and the three architectures it compares

```text
A  MAP_SHARED, plaintext            the baseline that must not regress
B  MAP_PRIVATE + explicit writes    the address space cannot reach the file
C  read_at / write_at + a bounded plaintext page cache
```

**B was in the list to be eliminated on evidence rather than by argument**, and
it was: a private mapping reads *exactly* like a shared one, because for reads
it is one. It stops the engine's stores from reaching the file and does nothing
about the page arriving as the file's bytes, which is the half that matters
here. No cost, no benefit, not the architecture.

**The spike is done**, and C is the architecture:
[2026-09-15-encrypted-io.md](../benchmarks/results/2026-09-15-encrypted-io.md).
The results that change this document rather than confirm it:

* **the dispatch is free** - the same read behind a function pointer stays
  inside the run-to-run noise of the read itself, so a plaintext database pays
  nothing for the existence of the encrypted path;
* **the hit path costs 2x to 5x a pointer dereference**, which a release can
  carry; **a miss costs 850 ns on tmpfs and 3.3 us on NTFS**, which decides
  everything;
* **the cryptography is amortised and the architecture is not.** At a 96.6% hit
  rate the transform added 2 to 3 ns per access; at 10.9% it added 650. Same
  code, a factor of 200, decided by the cache. The cost of encryption in this
  engine is a memory-budget question wearing a cipher's clothes;
* **a scan costs 478 to 496 ns per page through the cache against 137 through
  the mapping**, at the hit rate that makes point access cost 80. A sequential
  sweep evicts what it just brought in.

So two things join the design that were not in it: **a page-cache budget as a
first-class setting**, and **a scan path that does not evict everything it
touches**. Neither is a tuning knob; both are shapes the engine has to have.

What it has to report, per architecture:

* the cost of a page access on a hot scan, against A as the baseline;
* the cost of a commit, including the seal pages of Decision 3b;
* cache behaviour under a working set larger than the budget - hit rate, and
  what a miss costs when it also has to authenticate;
* **plaintext zero-regression**: a database without the encryption bit must
  measure the same as it does today, which is the claim most likely to be
  quietly lost;
* where the dispatch boundary can sit without duplicating the executor.

Counters before conclusions, as everywhere else in this engine.

---

## Decision 8 — a cryptographic random source, and what it costs to have one

Stored nonces, the file UUID, every data encryption key and any KEM
encapsulation all need unpredictable bytes. The platform layer has no random
source at all today, so this design requires one:

```text
os_random(buffer, length)

Linux     getrandom(2), blocking until the pool is initialised, no /dev/urandom
          file descriptor to exhaust and no fallback that silently weakens
Windows   BCryptGenRandom, BCRYPT_USE_SYSTEM_PREFERRED_RNG
```

This looked like it would break a rule the project has kept until now - the
Windows backend links kernel32 and nothing else, and `BCryptGenRandom` lives in
bcrypt.dll. **It turned out not to, and the reason is worth keeping.** The rule
was never about kernel32 as such; it was about a small, auditable platform
surface *with no dependency that can be absent*. So bcrypt is resolved at first
use through `LoadLibraryA` and `GetProcAddress`, which are themselves kernel32:
nothing new is linked, every consumer of the static library is unaffected, and
if bcrypt.dll is missing then `os_random` fails, encryption is unavailable, and
a plaintext database still opens.

**Implemented and measured.** A 24-byte draw - one page nonce - costs **186 ns
on Linux and 74 ns on Windows**, against roughly 3,700 ns to seal the page it is
drawn for. That is five per cent, which settles the question the next section
raised: a nonce is drawn directly from the system for every write, and there is
no buffer to refill and therefore no refill to make crash-safe.

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

* **The seal directory needs two copies.** A root generation binding cannot
  preserve the old generation when the only leaf and node pages are rewritten
  in place. Pairing is therefore part of publication, just as it is for the
  span map; the remaining question is how cheaply the inactive copy catches up.
* **Write amplification per commit shape**, measured with the existing flush
  instrument, on the queue and stream paths where a commit touches scattered
  pages. The seal tree bounds it at *k* leaves + *k* nodes + a root; what *k*
  is on a real `ENQUEUE` is a measurement, not an estimate.
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
