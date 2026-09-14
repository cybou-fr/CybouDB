# Encryption: the threat model

This is step 1 of the `0.7` work listed in [ROADMAP.md](../ROADMAP.md#the-order-of-work).
It says **what an encrypted CybouDB file must protect, from whom, and what it
cannot protect** — before any of it is a format, a key schedule or a line of
assembly.

It is deliberately not the format design. Where a decision belongs to step 2
this document says so and stops, because the value of writing a threat model
first is lost the moment it starts justifying a layout someone already has in
mind.

Nothing described here is implemented. `0.6` has no encryption and no key
material of any kind; a `0.6` file is plaintext and says so.

---

## The guarantee, and the shape of it

> **Possession of a `.cdb` file is not possession of its data, and a process
> can be given only the cryptographic authority it actually needs.**

Two halves, and they fail differently. The first is about a file at rest and is
answered by encryption. The second is about a running system and is answered by
which keys a component is handed — an arrangement encryption makes *possible*
and does not itself provide.

The second half is the reason this release is not "add AES to the page writer".
A permission list over readable bytes is advice; a component that was never
given a data encryption key cannot read that data with the file in hand and
this repository open beside it.

---

## The adversaries

Each one is stated as a capability, not as a person, because the design owes
something different to each.

### A1 — someone who has the bytes

A copied file, an old backup, a decommissioned disk, a snapshot of a container
volume. Offline, unlimited time, any number of copies, no ability to influence
what was written.

**Owed:** payload and structure unreadable without keys. This is the adversary
the release is named for, and the only one whose defeat is unconditional.

### A2 — a medium that lies

Bit rot, a torn write, a controller that reorders. Not malicious.

**Owed:** nothing new. `0.5` already answers this with CRC-32C per page and two
superblocks, and encryption must not quietly take that job over. An
authentication tag proves *someone did not lie to me*; a checksum proves *the
disk did not lie to me*. They are different questions and both stay.

### A3 — someone who can write the bytes back

Everything A1 has, plus the ability to hand the engine a modified file: flip
bits, truncate, splice a page from elsewhere in the file, move a page to a
different page number, restore an older superblock, or present a wholly older
copy of the database.

**Owed:** every one of those detected and refused — *except the last*, which is
discussed under [What cannot be promised](#what-cannot-be-promised) and must
not be quietly counted as solved.

### A4 — a holder of some of the keys

A worker that may `CLAIM` and `ACK` on one queue; a service that may `APPEND`
to one stream; an operator who may run `cyboudb check`. Each has real keys and
real authority, and wants more than it was given.

**Owed:** authority is bounded by what it was handed, not by what it asks for.
A key that unwraps one scope does not unwrap another, and the engine does not
have a mode where holding *a* key means holding *the* key.

### A5 — a process that is already compromised

Debugger attached, memory read, a core dump, keys swapped to disk.

**Owed:** honesty, and nothing else. Once keys are in a process's address space
the data is readable by anything with that address space. What the design can
do — keep key material out of long-lived allocations, avoid writing it to
temporary files, lock pages where the platform allows — is hygiene worth doing
and is not a defence. **This adversary is out of scope, and any sentence that
implies otherwise is a bug in the documentation.**

### A6 — the component that writes

The process that performs an `ENQUEUE` or an `APPEND`, holding whatever
structural authority that takes.

**Owed:** it must be possible to give it what it needs to mutate the file
without giving it the ability to read payloads. This is the whole content of
architecture **A** in the roadmap, and it is a real reduction: *the thing
writing your queue cannot read your queue*. It is not the stronger claim that
the writer holds nothing — see the roadmap's [honest limit](../ROADMAP.md#public-key-only-writes-and-the-honest-limit),
which an earlier draft got wrong and which this document must not recover.

---

## What an encrypted file still tells you

Done perfectly, with every payload byte sealed, a `.cdb` file is not opaque.
These are consequences of the format, not oversights, and they belong in the
threat model rather than in a footnote after someone notices:

* **Page 0 stays readable.** The magic, format version, page size and feature
  bits have to be legible to a reader that does not have keys, or "this is a
  CybouDB file you cannot open" becomes "this is not a CybouDB file". A reader
  that cannot tell those apart cannot give a useful error.
* **The size and shape of the database.** File length, page count, and — if the
  allocation map stays legible — how much is in use. Row counts are bounded by
  it. Whether the allocation map can be sealed without making recovery
  impossible is a step 2 question, but the file's *length* leaks regardless.
* **That something changed, and roughly how much.** A generation number that
  advances and a set of pages that differ between two snapshots. An observer
  watching a file over time learns the write pattern even if every page is
  ciphertext.
* **Everything outside the file.** Modification times, file names, directory
  layout, process arguments, the query text a caller passed. CybouDB cannot
  encrypt its own filename.

The rule this document sets: **a leak that follows from the format is named
here; a leak that follows from a choice is not allowed to be discovered later.**

---

## What the engine's own shape forces

This is the part a threat model written from first principles would miss, and
it is why this one was written against the source.

### Reading a page is pointer arithmetic on a mapping

`db_open` maps the file once, and every read in the engine is
`[DB_BASE + page × 4096]` — 156 sites across the source. There is no read path
to intercept, because there is no read path: there is a pointer.

Three ways out, and they are different products:

1. **Decrypt the mapping in place.** Fast, and it defeats the purpose: the
   plaintext is written back to the file by the operating system whenever it
   feels like it. Rejected here, not in step 2.
2. **Decrypt into a cache of plaintext pages** and make `DB_BASE + page` become
   a lookup. Correct, and it is an architectural change to the engine's hottest
   operation, with eviction, pinning and a memory budget that `0.6` does not
   have.
3. **Encrypt only some things** — payload but not structure. Cheaper, and it
   hands A1 the shape of the data. The zone-map problem below is the reason to
   be suspicious of this one.

**Step 2 must choose between 2 and 3 explicitly, with the cost measured rather
than assumed.** The project's own habit applies: instrument before optimising,
and keep the negative result.

### Zone maps are the data's minima and maxima

`ZSTAT` is 24 bytes per column per leaf — flags, minimum, maximum — and it
lives *inside* the leaf page it describes. Two consequences:

* sealing a leaf seals its statistics, so **pruning requires the key**. A
  process that may not read a column may not skip pages by it either, which is
  correct and costs performance;
* leaving statistics legible so that pruning works without keys would publish
  the smallest and largest value of every column **per leaf** - and a leaf holds
  between 4 and 3,520 rows depending on the schema
  ([PAX_CAPACITY.md](PAX_CAPACITY.md)). On a narrow table that is a coarse
  range; on a wide one, where a leaf holds four rows, the minimum and the
  maximum are very close to the values themselves.

**The design may not expose plaintext zone maps for an encrypted column.** If
step 2 wants pruning without decryption, it must invent something that does not
reveal the values, and prove it does not.

### Copy-on-write leaves old ciphertext lying in the file

A superseded page is freed and reused later. Until it is reused, its bytes are
still there. Key rotation encrypts *new* writes; it does not reach back into
pages that have not been overwritten. This is the same forward-secrecy-only
statement the roadmap makes about revocation, arriving from a second direction,
and a `cyboudb rekey` that claims to have re-encrypted a database will have to
say what it did about free space.

### Compression and encryption on the same bytes

The engine has a compression profile. Compressing before encrypting makes
ciphertext length a function of plaintext content, which is a well-understood
way to lose data across a trust boundary. The threat model's position: **either
the two are not combined, or the leak is stated where the feature is chosen.**
Not a step 2 question so much as a step 2 obligation.

### A commit publishes through one superblock write

The recovery story is a generation number and two checksummed superblocks. Once
the superblock is authenticated rather than merely checksummed, the tag has to
cover *what generation is being published*, or an attacker gets to choose which
of two valid states the engine sees — which is the rollback problem in its
smallest form.

---

## What cannot be promised

Stated here so that no later document has to discover it, and so that a reader
looking for the weakness finds it named rather than hidden.

### Rollback to an older, internally consistent file

An adversary with A3's powers can keep a complete copy of the file from last
week and put it back. Every page authenticates, every checksum matches, the
generation is coherent — because it *was* a real state of the database.
Cryptography inside the file cannot distinguish "the database as it was" from
"the database as it is", because both are genuine.

Detecting it needs an anchor the attacker does not control: a monotonic counter
kept elsewhere, a signed generation receipt held by a client, secure hardware.
All of those are outside an embedded database that is one file. **`0.7` will
detect splicing, relocation, truncation and page-level replay, and will not
claim to detect whole-file rollback.**

### Access already granted

A reader that has held a data encryption key can keep it. Rotating the key
protects what is written afterwards. This is in the roadmap and is repeated
here because it is the single claim most likely to be softened by accident.

### A compromised process

See A5.

### Anything about who wrote what, before the manifest

Authenticated writer identity is step 13. Until then, "the file was modified by
someone with the key" is the strongest available statement, and a document that
says otherwise before step 13 lands is wrong.

---

## How each of these gets tested

The roadmap puts the attack suite at step 18, which is late enough that the
tests it should contain are worth naming now, while the claims are fresh. Each
line is a claim above turned into something that can fail:

| Claim | The test that would falsify it |
| :--- | :--- |
| Payload is unreadable without keys | No plaintext row value, column name or message body appears anywhere in the file's bytes |
| No key material is in the file | The root key, any DEK and the recovery secret do not appear in the file, in any wrapping the file itself can unwrap without a password |
| A bit flip is detected | Flip one byte of a payload page; the read is refused, and the message says authentication rather than corruption |
| A page cannot be moved | Copy a valid encrypted page over a different page number; refused |
| A page cannot be replayed | Restore one page from an earlier generation into the current file; refused |
| Truncation is detected | Cut the file short at several boundaries; refused rather than misread |
| The wrong key is refused cleanly | Open with a key that is not the file's; one error, no partial read, no crash |
| A scope is a boundary | A key for scope X cannot decrypt an object in scope Y, asserted against the bytes and not only against the API |
| Zone maps leak nothing | For an encrypted column, minima and maxima do not appear in the file |
| Rotation is forward-only | After rotation, the old key cannot read new writes, and the documentation does not claim it cannot read old ones |
| A `0.6` file still opens | The frozen fixtures from every earlier release still read, unencrypted, under a build that has encryption |

Two of those — *no key material in the file* and *zone maps leak nothing* —
should be written as a test that greps the file for values the test itself
chose, because that is the version that keeps working when the format changes
underneath it.

And the project's usual demand applies to all of them: each must be confirmed
by breaking the thing it tests and watching it fail. A crypto test suite that
has never failed is decoration.

---

## What step 2 has to decide, and this document does not

* format v1 with new incompatible bits, or format v2 with a migration;
* which of *decrypt into a cache* and *encrypt only some things* the engine
  does, with the cost of the first one measured;
* what a page's authentication tag covers, and where it lives, given that a
  4096-byte page is already full;
* whether the allocation map and the free list can be sealed while keeping
  crash recovery possible;
* how a nonce is derived so that it never repeats across a copy-on-write
  rewrite of the same page number at the same generation — the one mistake in
  this whole area that is silent, total and unrecoverable.

That last one is the reason step 3 is a reference backend tested against
official known-answer vectors before step 4 exists.
