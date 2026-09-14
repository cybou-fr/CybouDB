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

`v0.5.0-preview.2` is released: Linux x86-64 and Windows x64, on-disk format
v1, tables with secondary indexes, exact vector search, durable queues,
append-only streams, and one transaction over all of them.

What `preview.2` added is not a feature. A commit proves the transition from
the generation already validated to the one being published, rather than
proving the retained graph again - so an `ENQUEUE`, which changes one slot in
one segment, visits one segment whatever the queue is holding, instead of 163
at depth 10,000.

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
 └─ queue leases
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

**Done.** Nine functions, `?` in `INSERT ... VALUES`, and the engine copies the
bytes of variable-width values rather than keeping the caller's pointer - the
reasoning is in `CHANGELOG.md` and in `include/sql.inc`. The re-run matrix grew
its bound-value axis as planned (`tests/prepared_rerun_test.c`, 50 checks now),
and the surface itself got a suite of its own beside it rather than inside it:
`tests/bind_test.c`, 39 checks, because what it holds - what a bind refuses,
and that the copy outlives the caller's buffer - is not a re-run question.

Two gates are met, and the middle one is met in part: results are compared
between the bound and the literal form, counters are not. Comparing counters
needs the probe harness, which reaches the engine below `cyboudb_bind_*`, and
that is worth doing when the counters are next being read anyway rather than
as a detour here.

`?` is accepted only in `INSERT ... VALUES`. A placeholder in a `WHERE` clause
is a syntax error that names the restriction; widening it is a separate piece
of work, because a predicate placeholder has to survive kernel resolution and
zone pruning, both of which read the literal at bind time.

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
with leases or without them, `cyboudb create` gains the choice, and a file
created without them stays readable by `0.5` forever rather than until someone
claims a message.

This is the format's own philosophy meeting its first real test: a new
capability becomes a new `flags_incompat` bit, an older reader refuses what it
does not understand, a newer reader reads both.

**The first question is the clock, and it is a design question.** A lease
deadline has to survive a crash and a restart, so it cannot be monotonic time -
a reboot resets that. It cannot be naive wall-clock either: a clock that jumps
backwards extends every lease and one that jumps forward expires them all at
once. What a deadline means when the file is opened on another machine, or a
year later, has to be answered in `docs/QUEUE.md` before any of it is assembly.

Gates:

* a claimed message is invisible to another claimant until its deadline passes
  or it is `NACK`ed;
* a crash between `CLAIM` and `ACK` leaves the message claimable again once the
  deadline passes, and leaves no other trace;
* `ACK` and the work it acknowledges commit together or not at all - which is
  the whole reason the queue lives in the same file;
* a `0.5` build refuses a leases file with *unsupported feature*, held to by a
  frozen fixture rather than asserted;
* the compatibility fixtures from both `0.5` releases still read.

### Explicitly not in 0.6

No change to what format v1 means for data already written. No ARM64 - that is
`0.7` and a whole release of its own. No WAL, no second writer, no encryption,
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

That covers `APPEND`, `ENQUEUE`, and a sealed `INSERT`.

**It does not cover `UPDATE`, `DELETE` or `ALTER`, and it will not be claimed
to.** A copy-on-write engine has to read the structural state it is about to
replace — the leaf it rewrites, the index entries it patches, the directory it
restages. A writer that cannot decrypt that state cannot produce a correct
successor to it. Append-shaped operations are exactly the ones that add without
reading, which is why the promise stops there.

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
 1. Threat model                     docs/ENCRYPTION.md
 2. Format design                    a v1 extension, or format v2
 3. Reference crypto backend         ML-KEM, ML-DSA candidate, AEAD, KDF,
                                     against official known-answer vectors
 4. Root key hierarchy
 5. Opening with a PQ private key
 6. Independent 24-word recovery
 7. Authenticated page encryption
 8. Crash-safe encrypted transactions
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

Step 2 decides whether this is format v1 with new incompatible bits or format
v2 with a migration. Either is allowed by
[the compatibility promise](#the-compatibility-promise); what is not allowed is
changing what v1 means for a file already written.

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
