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

* **The flush grows with the size of the file**, and is now the larger term in
  a commit - about 99% of it on the hardware measured. The instrumentation
  added in `preview.2` found this; nothing has been done about it, and nothing
  should be until it is understood.
* **A retired page with no shared header cannot be attributed to an owner.**
  The continuation pages of a multi-page run rest on a separate invariant - a
  run is retired whole, header included - and the negative control for that
  does not exist yet. See
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
| **0.7** | ARM64 / Apple Silicon | No rewrite of the portable format |
| **0.8** | SQL and storage depth | Not becoming PostgreSQL |
| **0.9** | Vector, index and concurrency depth | Nothing without measurements first |
| **1.0** | Stable ABI and a stable product contract | No experimental semantics |

---

## 0.6 — Application-grade embedded workflows

**The guarantee: an application can use CybouDB without building SQL by hand,
and a worker can take a job without holding a transaction open while it does
the work.**

Two gaps, and they are the two that stop CybouDB being reached for. Everything
in `0.5` was about the engine being right; this is about it being usable.

Unlike `preview.2`, this release changes the public surface: new C entry
points, new SQL syntax, and a new incompatible feature bit. It does not change
what format v1 means for anything already written.

### Before either feature: the debts from preview.2

These come first because they are cheap now and expensive later, and because
both are load-bearing for a proof the engine already depends on.

1. **A negative control for continuation pages.** An internal hook that retires
   only the continuation page of a multi-page run, leaving the header
   `PAYLOAD` and the owning object inherited. The commit must refuse it. If
   that state cannot be constructed at all, that is an answer too, and the
   invariant gets written down as enforced by construction rather than by
   test.
2. **Measure the flush before proposing anything.** The lesson of `preview.2`
   was that the assumed cause of a cost was worth 7% and the real one was
   elsewhere. So: what does `FlushFileBuffers` / `fsync` actually scale with -
   file size, dirty page count, the extent map, the filesystem? The deliverable
   is a measurement and a cause, not a fix. Whether a fix belongs in `0.6` at
   all is a decision that measurement makes, not this document.

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

This is the format's own philosophy meeting its first real test: a new
capability becomes a new `flags_incompat` bit, an older reader refuses what it
does not understand, a newer reader reads both. A database that never claims a
message never sets the bit and stays readable by `0.5`.

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

## 0.7 — ARM64 / Apple Silicon

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

## After that

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

AVX-512, FMA experiments, encryption, ML-KEM, a daemon, multi-writer
concurrency, ANN, `VACUUM`, REPL history, queue priorities and delayed
delivery.

Not because they are bad. Because none of them answers the question the project
has to answer next:

> Can CybouDB become a predictable, pleasant embedded engine that a person can
> trust with their data?

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
