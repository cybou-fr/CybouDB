# CybouDB Roadmap

Before the first release this file was a list of phases, and the phases were
features. After `v0.5.0-preview.1` that is the wrong shape: there are files in
the world now, the format is a public commitment, and the most valuable thing
to build next is not a feature at all — it is a cost model that holds.

So this roadmap is organised around releases and the **guarantees** each one
makes. The phase history, including the experiments that failed and why, has
moved to [docs/HISTORY.md](docs/HISTORY.md).

> Before `preview.1` the project was building features.
> After `preview.1` it is building guarantees.

---

## Where the project is

`v0.6.0` is released: Linux x86-64 and Windows x64, on-disk format v1, tables
with secondary indexes, exact vector search, durable queues with leases,
append-only streams, and one transaction over all of them. `main` is now
`0.7.0-dev` and carries unreleased encryption work - a binary built from it
says so.

What `preview.2` added before it is not a feature. A commit proves the
transition from the generation already validated to the one being published,
rather than proving the retained graph again - so an `ENQUEUE`, which changes
one slot in one segment, visits one segment whatever the queue is holding,
instead of 163 at depth 10,000.

Ten databases are frozen under `tests/compat/`, five from each release, and
are never regenerated. They are the contract every later release is held to,
and both sets are read by both platforms in CI.

Three things are open and named rather than implied:

* **The flush grows with how much of the file has been written**, and is the
  larger term in a commit - about 99% of it on the hardware measured. Measured
  in [benchmarks/results/2026-09-14-flush.md](benchmarks/results/2026-09-14-flush.md):
  not the flushed range, not dirty state the engine is holding, and not the
  file's length. Reducing it means writing less of the file.
* **A retired page with no shared header cannot be attributed to an owner.**
  A continuation page of a multi-page run, retired on its own, is accepted by
  the commit and refused by `cyboudb check`. No engine path produces it - a
  run is retired whole, header included - and both halves are now tested. See
  [docs/COMMIT_VALIDATION.md](docs/COMMIT_VALIDATION.md).
* **The change-set is trusted where it is written.** `cs_leaf_explained` proves
  the history it tells is consistent with both maps; it cannot prove that
  `span_mark` handed it the right states to begin with, only that what it
  recorded adds up.

---

## The compatibility promise

Any future build that claims support for on-disk format v1 must read every file
written by an earlier released format-v1 build. The promise is attached to the
format version, not to the product version, so it does not lapse at 0.6 or at
1.0. A capability that v1 cannot express becomes format v2 with a migration
path and a v1 reader that keeps working — never a quiet break.

[docs/FORMAT.md](docs/FORMAT.md#compatibility-promise) is normative.
`tests/compat_tests.py` is what makes it true rather than merely stated.

---

## Releases

| Version | The guarantee it adds | Explicitly not in it |
| :--- | :--- | :--- |
| ~~**0.5.0-preview.1**~~ | *released* — one file, one transaction | |
| ~~**0.5.0-preview.2**~~ | *released* — predictable commit cost | |
| **0.6** | Application-grade embedded workflows | No change to what format v1 means for data already written |
| **0.7** | Encrypted storage and cryptographic authority | Not a permission system bolted on top of readable bytes |
| **0.8** | ARM64 / Apple Silicon | No rewrite of the portable format |
| **0.9** | SQL, vector, index and concurrency depth | Nothing without measurements first |
| **1.0** | Stable ABI, stable security and product contract | No experimental semantics |

The order is deliberate:

```text
0.5  engine correctness
       ↓
0.6  application usability
       ↓
0.7  data security and cryptographic authority
       ↓
0.8  platform expansion
       ↓
0.9  depth
       ↓
1.0  stability
```

---

## 0.6 — Application-grade embedded workflows

**The guarantee: an application can use CybouDB without building SQL by hand,
and a worker can take a job without holding a transaction open while it does
the work.**

Three parts: the flush investigation `preview.2` left open, and the two gaps
that stop CybouDB being reached for. Everything in `0.5` was about the engine
being right; this is about it being usable.

```text
0.6
 ├─ flush investigation    done
 ├─ parameter binding      done
 └─ queue leases           done
```

Unlike `preview.2`, this release changes the public surface: new C entry
points, new SQL syntax, and a new incompatible feature bit. It does not change
what format v1 means for anything already written.

### Before either feature: the debts from preview.2

These come first because they are cheap now and expensive later, and because
both are load-bearing for a proof the engine already depends on.

1. ~~**A negative control for continuation pages.**~~ *(done.* The state is
   constructible, and the answer turned out to be the second half of the
   question rather than the first: the commit accepts it, and `cyboudb check`
   refuses the result - the same narrowing the queue's historical damage went
   through. What bounds it is that no engine path retires a continuation
   without its header. `tests/validator_attack_test.c` asserts both halves;
   [docs/COMMIT_VALIDATION.md](docs/COMMIT_VALIDATION.md) says why, including
   the rule that was tried and rejected because a legitimate harness retires
   bare pages on purpose.*)
2. **Measure the flush before proposing anything.** The lesson of `preview.2`
   was that the assumed cause of a cost was worth 7% and the real one was
   elsewhere. So: what does `FlushFileBuffers` / `fsync` actually scale with -
   file size, dirty page count, the extent map, the filesystem? The deliverable
   is a measurement and a cause, not a fix. Whether a fix belongs in `0.6` at
   all is a decision that measurement makes, not this document.

   *(done -
   [benchmarks/results/2026-09-14-flush.md](benchmarks/results/2026-09-14-flush.md).
   The range is not the cause: at a constant 13-page flush, sync grows 565 to
   5,983 us with what the database holds, and survives a close and reopen, so
   it is a property of the file once written rather than state the engine is
   holding. Reducing it means writing less of the file, which is a different
   question from the barrier - so nothing here promises to make a deep queue
   commit fast.*

   *It did find one thing that was the engine's own doing, and that is fixed:
   the flushed range was a hull, and once the allocator reused pages from the
   bottom of a file that had reached its high-water, the hull became the whole
   file - `[5, 8001)` in an 8,000-page file, 7,999 pages flushed to publish a
   change of a few. A transaction's writes are now kept as runs beside the
   hull, and a commit flushes those: **9.50 pages where it used to be
   7,999**.)**

### Parameter binding

The public C API has `prepare`, `step` and `reset` and no `bind`, which leaves
an application building SQL with `sprintf`. That is the wrong answer for
correctness, for performance and for safety, and it is the first thing anyone
embedding a database looks for.

Placeholders in the dialect, and:

```text
cyboudb_bind_null     cyboudb_bind_int32    cyboudb_bind_int64
cyboudb_bind_float    cyboudb_bind_bool     cyboudb_bind_text
cyboudb_bind_blob     cyboudb_bind_vector
```

**The design constraint is already written and already tested.** A prepared
plan is immutable across executions - `include/sql.inc` says so, and
`tests/prepared_rerun_test.c` holds the engine to it after a bug where an
`INSERT` re-run against a grown table silently wrote 154 rows of 205. Bound
values make that rule load-bearing rather than incidental: a bind writes into
execution-local state and never into the plan, and a bound statement re-run
with different values behaves exactly as a freshly prepared one. The re-run
matrix grows a bound-value axis rather than a new suite beside it.

Gates:

* every type above, bound, re-bound and re-run through the existing re-run
  matrix - `INT32`, `INT64`, `TEXT`, `BLOB`, `VECTOR`, NULL, empty, multi-row,
  inside a transaction, after a rollback, with the table grown in between;
* a bound statement and the equivalent literal statement give identical results
  and identical counters;
* the C ABI stays additive: a `0.5` program compiles and links unchanged.

**Done.** Ten functions, `?` in `INSERT ... VALUES`, and the engine copies the
bytes of variable-width values rather than keeping the caller's pointer - the
reasoning is in `CHANGELOG.md` and in `include/sql.inc`. The re-run matrix grew
its bound-value axis as planned, and the surface itself got a suite of its own
beside it rather than inside it, because what that holds - what a bind refuses,
and that the copy outlives the caller's buffer - is not a re-run question. Both
have grown since with the predicate work below: `tests/prepared_rerun_test.c`
is 67 checks and `tests/bind_test.c` is 117.

Two gates were met here and the middle one only in part - results were compared
between the bound and the literal form, counters were not. *It is met in full
now*, and by the predicate work rather than by a detour: the gate below reads
the zone-pruning counters and `index_lookups`, which is where comparing them is
load-bearing.

**Half done, and the other half stays in `0.6`.** `?` is accepted only in
`INSERT ... VALUES`. That leaves the release's own promise - *an application
can use CybouDB without building SQL by hand* - only half kept, because an
application still reaches for

```c
snprintf(sql, n, "SELECT ... WHERE id = %lld", id);
```

for every read, every conditional update and every delete. Shipping `0.6` like
that would mean either narrowing the promise or making the first thing anyone
notices be the thing that is missing. The promise stays; the work finishes:

```text
1. SELECT predicate parameters      done
2. UPDATE SET values                done
3. UPDATE predicate                 done
4. DELETE predicate                 done
5. the prepared re-run matrix x parameters   done
```

Steps 3 and 4 cost nothing: every predicate in the dialect is built by the same
`bind_expr`, so teaching it about placeholders taught `UPDATE` and `DELETE` at
the same time as `SELECT`. They still get tests - a thing that works by
accident is a thing that can stop working by accident.

**Parameter binding is closed**, and so is `0.6`: the queue-lease work below
shipped with it.

The CRUD path, not parameters everywhere. `?` in a projection list, in an
`ORDER BY`, in a `LIMIT` or as a table name is not part of this and is not
missed by an application writing ordinary queries.

**Step 1 is done, and two of the three things that looked hard were not.**
The note that used to stand here said a bound predicate value is read at bind
time by the kernel resolver and by zone pruning. Reading the code says
otherwise: `sql_kernel_resolve` takes the column's physical type and the
operator and never looks at the literal, and `sql_zone_eval` is called from the
scan and reads `BEXPR_LIT_VAL` when it runs. So both work unchanged once the
value is in the node before the scan opens, which is where it is now put - on
each execution, over the zero the binder left, at the two doors a predicate can
arrive through.

**The one that was real is the index seek, and it is done too.**
`plan_index_eq` turned the literal into key bounds at bind time, because the
plan is built once - and there is nothing to compute them from before the value
arrives. The split it wanted: which index, over which column, follows from the
operator and the column and stays in the plan; the arithmetic on the value
moves to execution. The arithmetic itself is now one routine, `sql_index_bounds`,
called by the binder for a literal and by the execution for a bound value, so
the two cannot drift into disagreeing about what range a comparison means.

Two gates, both counter-based and both guarded against being vacuous, in
`tests/bind_test.c`:

* **zone pruning** - the four `sql_zone_leaf_*` counters must match between the
  bound form and the literal one, after the literal form is required to have
  looked at more than one leaf and skipped at least one;
* **the index** - `index_lookups` must match, after the literal form is
  required to have used the index at all.

Both would pass trivially on a small table, so the fixtures are four thousand
rows and two thousand rows respectively. That is the counter comparison the
INSERT gates only half made, arriving where it is load-bearing.

### Asking for a capability from C — done

`cyboudb create-leases` makes a database with leases, and until this there was
no public way to ask for one: an embedded application would have had to shell
out to a command line to create the file it needed, in the release about
embedded workflows.

The answer is not `cyboudb_create_leases`. `0.7` brings encryption, which is
also decided when the file is made, and a function per creation-time capability
is a surface that grows without bound. One additive entry point instead, with
room to grow:

```c
typedef struct cyboudb_create_options {
    uint32_t struct_size;
    uint32_t flags;
} cyboudb_create_options;

#define CybouDB_CREATE_QUEUE_LEASES 0x0001

int cyboudb_create_with_options(const char *path, uint64_t pages,
                                const cyboudb_create_options *options,
                                cyboudb_db **out_db);
```

`cyboudb_create` stays forever as the shorthand for the canonical default, so
nothing that exists has to change - passing `NULL` options is exactly it.
`struct_size` is what lets `0.7` add fields without a third function, and a
flag this build does not implement is **refused rather than ignored**: a caller
asking for a capability and quietly receiving a database without it is the one
outcome worse than an error.

Execution-time errors reach `cyboudb_errmsg` now, which they did not: a failed
`ACK` and a syntax error both left it saying `ok` while bind-time errors came
through. The step path carries an error buffer of its own and copies what the
executor wrote into both the statement and the database, and the contract is
one sentence - **the message describes the most recent call, and is `ok` when
that call succeeded** - because an application that logs it after a later,
successful statement would otherwise get a message about something else with no
way to tell.

### Queue leases

`DEQUEUE` takes a message inside the transaction that commits the work. That
is the right shape when the work is a row; it is the wrong shape when the work
takes a minute and the worker can die in the middle. `CLAIM`, `ACK`, `NACK`
and `RENEW` turn a transactional FIFO into a work queue.
[docs/QUEUE.md](docs/QUEUE.md) already says why, and what the format reserves
for it.

Reserving bytes is not enough. `preview.1` and `preview.2` *require* the
per-message state, the deadline and the lease token to be zero, and
`queue_page_valid` refuses a queue whose claim cursor has moved ahead of its
head. A file with live leases is therefore one those builds must refuse -
cleanly, saying *unsupported feature* rather than *corrupt queue* - which is
what the next free incompatible bit is for:

| Bit | Name | Requires |
| --- | --- | --- |
| 65536 | `QUEUE_LEASES` | `QUEUE` |

**The bit is set when the database is created, not when the first `CLAIM`
happens.** Every other capability in this format works that way, and for the
same reason: `flags_incompat` lives in the file header, which is written once
and never rewritten, and a first `CLAIM` that had to promote a file in place
would be a format change disguised as an operation. So a database is created
with leases or without them - `cyboudb create --leases`, or the options struct
in C - and a file created without them stays readable by `0.5` forever rather
than until someone claims a message.

This is the format's own philosophy meeting its first real test: a new
capability becomes a new `flags_incompat` bit, an older reader refuses what it
does not understand, a newer reader reads both.

**The first question is the clock, and it is a design question.** A lease
deadline has to survive a crash and a restart, so it cannot be monotonic time -
a reboot resets that. It cannot be naive wall-clock either: a clock that jumps
backwards extends every lease and one that jumps forward expires them all at
once. What a deadline means when the file is opened on another machine, or a
year later, has to be answered in `docs/QUEUE.md` before any of it is assembly.

**The format contract is in** - bit 65536, its dependency, a creator, and a
reader built without the bit that refuses a leases file with the feature
message rather than a damage one (`tests/lease_format_tests.py`). And the
fixture has now gone against the actual released `preview.1` and `preview.2`
binaries on both platforms, because a build made from today's source with one
macro flipped models a `0.5` reader well and is not one. All four refuse it by
name, still read an ordinary database, and leave the file byte-identical:
[docs/RELEASE-GATE-0.6.md](docs/RELEASE-GATE-0.6.md), reproducible with
`tests/release_gate_leases.sh`.

**Both design questions are now answered there**, in *The clock a lease
deadline is measured on* and *The shape of CLAIM, ACK, NACK and RENEW*: a
deadline is wall-clock milliseconds floored by a high-water the queue carries,
so its clock never runs backwards; the lease token rather than the deadline is
what keeps an acknowledgement honest, so no clock error can cost the queue's
integrity; expiry is a predicate rather than an event, so a dead worker's
message costs zero writes to recover; and a reopen clears nothing, because the
engine does not know whether a lease holder is alive and guessing runs in the
dangerous direction.

**The assembly and the measurements are done too.** `CLAIM`, `ACK`, `NACK` and
`RENEW` are in the engine, in SQL and in C; head advancement retires what a
drained queue no longer names; and the claim search - the one part of this that
was a risk rather than a task - was measured before it was solved. A naive walk
costs the whole retained queue; the per-segment `QSEG_READY_AT` summary that
ships takes the slot term away and leaves the segment count, 480 at the
ceiling. A hierarchy over those summaries would take that to eight and is
modelled but **not in this release**:
[2026-09-14-lease-search.md](benchmarks/results/2026-09-14-lease-search.md) and
[2026-09-14-lease-ready-at-tree.md](benchmarks/results/2026-09-14-lease-ready-at-tree.md).

Gates, and what holds each:

* a claimed message is invisible to another claimant until its deadline passes
  or it is `NACK`ed - `tests/lease_ops_test.c`, which also holds the case that
  makes it safe: the reclaim raises the token, so the first worker's ticket is
  refused and the new holder's is honoured;
* a crash between `CLAIM` and `ACK` leaves the message claimable again once the
  deadline passes, and leaves no other trace - expiry is a predicate, so there
  is no trace to leave;
* `ACK` and the work it acknowledges commit together or not at all - the same
  suite, with `cyboudb check` after each operation;
* a `0.5` build refuses a leases file with *unsupported feature*, held to by a
  frozen fixture rather than asserted - **and, once, by the released binaries
  themselves**;
* the compatibility fixtures from both `0.5` releases still read -
  `tests/compat_tests.py`, unchanged.

What `0.6` does not carry is the hierarchical `ready_at` index. The release
notes say so rather than leaving the shape of the remaining cost to be
discovered from a graph.

### Explicitly not in 0.6

No change to what format v1 means for data already written. No ARM64 - that is
`0.8` and a whole release of its own. No WAL, no second writer, no encryption,
no ANN index, no daemon. No further commit-path optimisation unless the flush
measurement says otherwise, and then as its own release rather than folded
into this one.

---

## 0.7 — Encrypted storage and cryptographic authority

**The guarantee: possession of a `.cdb` file is not possession of its data, and
a process can be given only the cryptographic authority it actually needs.**

The model is not *has a key / has no key*. It is *which key, what can it
decrypt, and what is it allowed to do*:

```text
                      ROOT AUTHORITY
                           │
              ┌────────────┴────────────┐
              │                         │
       PQ private key            24-word mnemonic
              │                         │
              └──────────┬──────────────┘
                         ↓
                  database key hierarchy
                         │
          ┌──────────────┼───────────────┐
          │              │               │
      metadata DEK   table DEKs      queue/stream DEKs
```

A process is handed the wrapped keys for what it needs and a signed statement
of what it may do. It is not handed the root.

### Why this is more than an ACL

A permission list on readable bytes is advice. Here, a holder who is not given
a data encryption key cannot read that data even with the file in hand and the
engine's source in front of them. Finance holding a copy of the database
cannot read `secrets`, because no key it has unwraps that namespace.

That is the difference worth building, and it is the reason encryption and
permissions arrive together rather than as two releases.

### Capabilities, not levels

The format stores capability bits and a scope, never `LEVEL 1`, `LEVEL 2`.
Levels stop describing reality the first time someone needs an exception.

```text
READ  INSERT  UPDATE  DELETE  APPEND
QUEUE_ENQUEUE  QUEUE_CLAIM  QUEUE_ACK  QUEUE_NACK  QUEUE_RENEW
STREAM_APPEND  STREAM_READ
DDL  CREATE_INDEX
KEY_GRANT  KEY_REVOKE  KEY_ROTATE
BACKUP  VERIFY
```

Scoped to the whole database, a namespace, an object type, or one object id.
`READER`, `WRITER`, `WORKER` and `ADMIN` are names for common combinations and
nothing more — convenience at the edge, capability bits in the file.

### Public-key-only writes, and the honest limit

A holder of nothing but a recipient's public key can seal a record into the
database and never be able to read it back:

```text
recipient PUBLIC KEY
        ↓ ML-KEM encapsulation
     fresh secret
        ↓ KDF
  one-time payload key
        ↓ AEAD(payload)
    sealed record
```

**The promise is about who supplies the payload, not about who writes the
file**, and an earlier draft of this section got that wrong. It said that
append-shaped operations add without reading, and therefore that a process
holding nothing but a public key could perform them directly. The first half is
true of the *data* and false of the *engine*.

An `ENQUEUE` reads and rewrites the queue page, the tail position, the segment
directory, the allocation map, the copy-on-write path up through the catalog,
and the candidate superblock. An `APPEND` does the same. None of that is
payload, and all of it is structure - so if metadata is encrypted too, a
process with only an ML-KEM public key and a sealed ciphertext **cannot build
the next generation of the file at all.** Not because it is forbidden, but
because it cannot read what it must replace.

So the guarantee is stated this way instead:

> **A payload may be submitted by a party holding only the recipient's public
> key. The component that mutates CybouDB's structure needs structural metadata
> authority — and does not need authority to decrypt any payload.**

That is a weaker sentence about who touches the file and exactly as strong a
sentence about who can read the data, which is the part that matters. Three
architectures satisfy it, and they are different products rather than different
implementations:

**A — a structural metadata key.** The writer is given the metadata DEK, the
recipient's public payload key, and an `APPEND` capability. It can see the page
tree, queue positions, segment metadata and the allocation map; it cannot see
messages, or rows under a scoped payload DEK. This is the most natural fit for
an embedded engine, because the writer *is* the process, and it is still a
strong model: the thing writing your queue cannot read your queue.

**B — a broker.** The client holds only the public key and hands a sealed
ciphertext to a component that has structural authority. The client is then
mathematically incapable of reading the database, which is the strongest
statement available - at the cost of a second component, which is the thing an
embedded database exists to avoid.

**C — a blind-append inbox.** A separate structure designed so that adding to
it requires no structural reads at all, ingested later by the full engine. This
is a new storage primitive rather than a use of the existing one, and it should
not be adopted without deciding it is worth a primitive.

**A is the working assumption**, and the threat model in step 1 is where it is
argued properly rather than asserted here. What the threat model must not do is
recover the old sentence.

`UPDATE`, `DELETE` and `ALTER` stay outside the sealed-write story for the
separate and still-true reason: they rewrite payload the caller must be able to
read first, so no arrangement of structural authority makes them blind.

### The access manifest

A signed policy object in the file, rather than a convention in an
application:

```text
ACCESS MANIFEST
├─ epoch
├─ key IDs
├─ public identities
├─ permissions
├─ scopes
├─ wrapped DEKs
├─ revoked keys
├─ issuer
└─ PQ signature          (ML-DSA is the candidate)
```

So a manifest can say: key 17 may `APPEND` to stream `telemetry`; key 23 may
`CLAIM`/`ACK`/`RENEW` on queue `jobs`; key 41 may `READ` namespace `finance`.

### Revocation, said honestly

For a writer or a worker, revocation is clean: a new manifest epoch, and the
key's operations stop being accepted.

For a reader it is not, and pretending otherwise would be the kind of claim
this project does not make. A reader that already received a data encryption
key cannot be made to forget it, and data it could already read stays readable
to it. What revocation can do:

```text
revoke reader
        ↓
rotate the scoped DEK
        ↓
new epoch
        ↓
data written from here uses the new key
        ↓
the revoked key never receives it
```

Forward secrecy for future writes; nothing retroactive. That is the true
statement, and the documentation will make it before anyone relies on the
other one.

### The 24 words

A recovery slot of its own, not a textual spelling of the PQ private key:

```text
24 words → 256-bit recovery secret → domain-separated KDF
         → recovery KEK → unwraps the database root
```

Two independent paths to the root means either can be rotated without the
other: a compromised PQ key does not force a new mnemonic, and a new mnemonic
does not invalidate the key.

### The order of work

Crypto is the one area where building in the wrong order produces something
that looks finished and is not. Threat model first; the attack suite before
the release, not after it.

```text
 1. Threat model                     docs/ENCRYPTION.md          done
 2. Format design                    docs/ENCRYPTED_FORMAT.md    done
2.5 Encrypted I/O spike              done - benchmarks/results/
                                     2026-09-15-encrypted-io.md
 3. Reference crypto backend         docs/CRYPTO_BACKEND.md - decided:
                                     XChaCha20-Poly1305, implemented here,
                                     dispatched but not chosen by the machine.
                                     Vectorised ChaCha20 and a parallel
                                     Poly1305 are done and measured
3.5 Key-hierarchy primitives         ML-KEM-768 done, against OpenSSL 3.5's
                                     own seed. ML-DSA waits for step 10,
                                     which is the first step that signs
 4. Root key hierarchy               done - docs/KEY_HIERARCHY.md.
                                     SHAKE256, the closed-label KDF, wrap and
                                     unwrap, the crypto root page and its
                                     key-free validator, and three error codes
                                     so a wrong key is never called damage
 5. Opening with a PQ private key     done - ML-KEM-768 in assembly,
                                     interoperating with OpenSSL 3.5 both
                                     ways; key slot pages, and a root key
                                     sealed to a public key
 6. Independent 24-word recovery     the encoding, the checksum and the
                                     second door are done; the English
                                     wordlist is not, and
                                     docs/RECOVERY_PHRASE.md says why
 7. Authenticated page encryption     internal engine path done: encrypted
                                     create, private-key attach, page cache,
                                     sealed reads/writes, commit and reopen.
                                     The creator now writes the canonical
                                     layout - full feature profile, the paired
                                     MAP_SPAN allocation map in its usual
                                     place, both copies sealed under the seal
                                     tree. What remains is the allocator and
                                     catalog reaching it. DB_PAGE_HERE's
                                     encrypted branch is compiled in, the
                                     resolver is linked into the engine with no
                                     measurable cost to the plain path, the
                                     allocator, the catalog and PAX are
                                     ported, and db_open_encrypted builds the
                                     same context db_open builds - so create,
                                     open, CREATE TABLE, insert rows, commit,
                                     reopen and read the rows back is a chain
                                     that runs, with recovery at both the
                                     superblock and the map. What remains is
                                     the index, the queue, the stream and the
                                     SQL cursors ported the same way, and then
                                     the public C API
 8. Crash-safe encrypted transactions publication is implemented at every
                                     depth: paired seal-tree copies, two
                                     barriers, inactive-superblock update, and
                                     handle poisoning after uncertain I/O.
                                     Multi-level trees are created, traversed
                                     on open and published on commit, and the
                                     cost is proportional to what changed - the
                                     inactive copy is caught up by difference
                                     and only journalled dirty leaves have
                                     their paths rebuilt. Attach chooses
                                     between both superblocks with the key and
                                     falls back to the previous authenticated
                                     generation, recording DB_DAMAGED.
                                     What remains is dirty eviction as
                                     writeback rather than refusal
 9. Scoped DEKs
10. The signed access manifest
11. Permissions and scoped keys
12. Public-key-only sealed APPEND / ENQUEUE
13. Authenticated writer keys
14. Worker capabilities
15. Revocation and key epochs
16. Key rotation and rewrapping
17. Plain to encrypted migration
18. Attack suite
19. Performance measurement
20. Frozen encrypted fixtures
21. Release
```

Step 2 decided it: **format v1 with one new incompatible bit**, 131072, because
the structure does not change - page 0, the superblocks, the allocation map and
every page layout stay where they are, and what changes is a transformation
applied to a page's bytes between the file and the engine. v2 would have been
the answer if page bodies had to shrink to hold a tag; a seal directory in
pages of its own avoids that, at about 2.4% of the file. The reasoning, the
rejected alternatives and what each field of the authenticated data prevents
are in [docs/ENCRYPTED_FORMAT.md](docs/ENCRYPTED_FORMAT.md).

Step 2's review added one load-bearing answer: **the seal entries are
themselves authenticated**, by a keyed tree whose root sits in the superblock.
Without it an adversary restores an old page *and* its old seal entry, and the
AEAD accepts the pair because the pair is genuine - it is simply last week's.
The tree makes the rule one sentence - *what is current is exactly what a valid
superblock says is current*. With 83 entries per leaf it has depth 2 up to
about 20 GiB and depth 3 at 24 GiB.

It also found the expensive part of this release, and it is not the
cryptography: the engine reads every page as a pointer into one shared mapping,
and plaintext in a shared mapping is plaintext on the disk. An encrypted
database needs explicit I/O the platform layer does not have and a plaintext
page cache under the engine's hottest operation. **That measurement is step 2.5**,
ahead of the reference crypto backend, because a reference AEAD is bounded work
with official test vectors while the I/O architecture can change the shape of
the release rather than one of its steps.

Step 3 found the thing step 2.5 could not. The I/O spike measured the
architecture with a stand-in transform and concluded the cipher was amortised -
while saying that any conclusion depending on that floor was not one. Raising
the floor to real primitives breaks it in one direction: a page sealed with
portable ChaCha20-Poly1305 costs **9.3 us** against a page miss's 850 ns to
3.3 us, while hardware AES and PCLMULQDQ do the same work in **~690 ns**. So
the cipher is a minority of the miss where AES-NI exists and three to eleven
times the I/O where it does not.

The decision does not follow the fast number, and
[docs/CRYPTO_BACKEND.md](docs/CRYPTO_BACKEND.md) says why: the ciphertext must
not depend on the machine that wrote it, so the AEAD is a format decision. AES
without AES-NI is table-driven and leaks through the cache, or bitsliced and
slower than the alternative; ChaCha20 has no table, so a machine without
hardware support runs slower and not differently. What is dispatched is the
implementation, and both paths must produce identical bytes - a property a test
can assert rather than a benchmark's opinion.

**A note on size.** This is larger than `0.5` and `0.6` together, and the
project has one measurement-driven habit worth keeping here: nothing in the
list above is a promise about a date. If step 3 says the reference backend is
not something this project should carry, that is an answer, and it arrives
before step 4 rather than after step 20.

---

## 0.8 — ARM64 / Apple Silicon

A database that calls itself modern and embedded, and does not run natively on
Apple Silicon, has a product story with a hole in it. The architecture was
built for this: the on-disk format is portable and the ISA-specific work is
confined to the execution kernels.

Target platforms: Linux x86-64, Windows x64, Linux ARM64, macOS ARM64. The test
that matters is not a benchmark:

```text
create on x86-64  →  open and write on ARM64  →  open again on x86-64
```

---

## 0.9 — Depth

Order, not dates:

```text
SQL and API usability
        ↓
physical compression that actually shrinks the file
        ↓
TEXT and composite indexes
        ↓
richer aggregation, GROUP BY
        ↓
ANN — if users turn out to need it
        ↓
more concurrency — only if measurements and real use cases justify it
```

---

## Deliberately not now

AVX-512, FMA experiments, a daemon, multi-writer concurrency, ANN, `VACUUM`,
REPL history, queue priorities and delayed delivery.

Not because they are bad. Because none of them answers the question in front of
the project, which `0.6` and `0.7` divide between them: can CybouDB be pleasant
to use, and can it be trusted with data that matters?

**WAL in particular is not planned.** The two syncs are not an accidental
performance bug; they are the crash-safety design:

```text
durable data  →  sync  →  publication  →  sync  →  durable generation
```

Trading that away to win one benchmark column would be selling the strongest
part of the architecture for the weakest reason.

---

## Known gaps

* [ ] the double-free guard is a heuristic and will need a real allocation
      bitmap once pages carry data
* [ ] `cyboudb --help` still describes the engine as an "mmap-backed storage
      engine", which is the positioning the README has since moved away from.
      Left alone through two releases because changing a usage banner during a
      freeze is exactly the sort of harmless edit that turns out not to be

The full list, including everything already closed, is at the end of
[docs/HISTORY.md](docs/HISTORY.md).
