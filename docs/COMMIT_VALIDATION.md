# Incremental commit validation — design

**Status:** implemented, under release validation. Target `0.5.0-preview.2`.
**Measured baseline:** [benchmarks/results/2026-09-14-commit-baseline.md](../benchmarks/results/2026-09-14-commit-baseline.md)

A commit must prove that what it is about to publish is a well-formed graph. It
currently proves that by walking the graph it publishes — all of it. That makes
the cost of a commit a function of what the database has kept rather than of
what the transaction changed:

```text
one ENQUEUE changes one slot in one segment

          depth 0   ->  2.14 segments visited
          depth 10000  -> 163.41 segments visited
```

This document says what should replace that, in enough detail to be argued with
before any of it is written in assembly.

---

## 1. The principle is not new

CybouDB already inherits proofs. `db_bitmap_deep(ctx, candidate_sb, page_generation)`
answers *does this page have to be checked byte for byte*, and the answer is no
unless the page carries the candidate's own generation or `DB_VERIFY` is set:

> A page is written once, by the generation that created it, and copy-on-write
> never touches it again. The commit that published it checked it in full, so
> every later open and every later commit that inherits it would only be
> repeating that work.

The catalog, the indexes, PAX storage, the varlen chain and the zone maps all
follow that rule today. It is why opening a database costs the change rather
than the file.

So the question for preview.2 is not *may a proof be inherited* — that is
settled policy with a settled justification. It is **at what granularity**.
Today inheritance is per page and answers "do I read these 4 KiB". It needs to
become per edge and answer "do I go there at all".

```text
now:        visit every node, read the bytes only of new ones
wanted:     visit only the edges this transaction changed
```

The baseline says why the first is not good enough: the earlier experiment that
gated segment checksums on `db_bitmap_deep` bought nothing measurable, because
the cost is the visit and not the sum over the bytes.

---

## 2. Vocabulary

The terms below are used precisely for the rest of this document.

**Base generation.** The generation currently published — the one a reader
would select right now. It was proved by the commit that published it.

**Base proof.** The fact that the base generation was accepted by a commit, or
by `db_open`'s validation. It is not a stored object; it is an induction
hypothesis. The induction is: the first generation was proved exhaustively, and
every generation since was published only after this procedure accepted it.

**Candidate generation.** `base + 1`, the graph the current transaction is
staging. Its pages carry the candidate's generation stamp.

**Inherited subtree.** A subgraph reachable from the candidate root by an edge
whose target page id is identical to the edge in the base graph. Since
copy-on-write forbids in-place mutation, a page the engine did not rewrite has
the content it had when it was proved. The subtree therefore carries its proof
forward without being visited.

**Dirty object.** A catalog object — table, index, queue, stream — whose root
page id differs between base and candidate, or which the transaction created or
dropped. Exactly the objects the transaction touched.

**Allocation transition.** A single page changing state in the allocation map
during this transaction, recorded as `(page id, from, to)`.

**Retired page.** A page that belonged to the base graph and is replaced in the
candidate. It must stay readable until no reader is pinned to the base
generation, which is why `RETIRED` is a state rather than a return to `FREE`.

---

## 3. Three guarantees that were one mechanism

The first draft of this document said a commit's narrowed responsibility moves
to `cyboudb check`. That was checked, and it was false - and false before any
of this work, not because of it. `check` was an ordinary open with deep
verification, and an ordinary open *recovers*: when the newest generation did
not validate it fell back to the one before it and reported success. So damage
to the newest generation printed `Status: OK`.

Three questions had one answer between them. They now have three:

```text
recovery    an ordinary open finds the newest generation that validates and
            falls back to the one before it. Falling back is success, and
            nothing here changes that.

commit      proves that what this transaction publishes is a well-formed
            graph: every page it wrote, every edge it changed, every
            allocation transition it registered - and inherits the proof of
            everything it did not touch.

integrity   `cyboudb check` reports damage, including damage recovery would
            hide. A superblock whose own checksum verifies while the graph it
            published does not is damage, not the residue of an interrupted
            publication - a torn superblock fails its own checksum and is
            reported as the ordinary thing it is.
```

docs/RECOVERY.md is normative for the first and the third.
`tests/integrity_tests.py` holds them to it.

**The narrowing is deliberate, and it is only safe because the third of those
now exists.** Inheritance was not allowed to land until it did.

### 3.1 The queue is currently an exception, and the exception is tested

Every other object type already declines to re-check pages older than the
candidate. The queue does not: `db_queue_segments_valid` runs `crc32c` over
every segment of every validated queue on every commit, and the code says why —
gating it was tried, was reverted, and the revert is recorded in a comment.

`tests/queue_page_test.c` depends on that. It damages a byte inside a segment
belonging to queue `700010`, then commits an unrelated change — creating queue
`700011` — and requires the commit to refuse. Seven of its ten damage cases
target a segment rather than the queue page.

Under proof inheritance those seven stop being caught **at commit time**,
because queue `700010`'s directory is not touched by that transaction and is
therefore inherited.

There is no option where the commit both skips the visit and catches the
damage. The narrowing is accepted: the queue joins the policy the whole rest of
the engine already follows, and those cases become assertions that the
integrity check refuses the file.

That is only an honest trade because the integrity check now exists. It did
not when this section was first written, and the wrong version of this
paragraph would have quietly deleted a guarantee rather than moved it.

A second thing that suite was doing wrong, found the same way: every case
reused one queue id, so the moment a commit was allowed through, the id
existed and every later case reported "refused" because of that rather than
because of the damage. Fixed separately, before any of this.

---

## 4. The transaction change-set

Commit cannot ask "what changed" until the transaction records it. The
requirement is central registration: **no mutation may reach a page except
through the change-set.** A hidden mutation is not a performance bug here, it is
a correctness hole — the validator would inherit a proof for something that was
in fact modified.

What the transaction must accumulate:

| | |
| :--- | :--- |
| `dirty_pages` | pages this transaction wrote, already implied by `DB_DIRTY_LO`/`DB_DIRTY_HI` but needed as a set rather than a range |
| `dirty_objects` | catalog ids whose root changed, plus created and dropped ids |
| `changed_catalog_entries` | directory slots that differ from base |
| `allocation_transitions` | `(page, from, to)` triples |
| `retired_pages` | the subset transitioning to `RETIRED` |
| `changed_map_leaves` | map leaves containing any transition |

The range `DB_DIRTY_LO..DB_DIRTY_HI` is not a substitute: it is a hull, and a
hull says a page may have been written when it was not. Inheritance decisions
made from a hull are conservative in the safe direction but give back most of
the win, since one page near the end of the file widens the hull to everything.

That is not hypothetical, and the flush found it first: once the allocator
reuses pages from the bottom of a file that has reached its high-water, the
hull becomes the whole file. `DB_RUNS` now keeps the same pages as a small set
of contiguous runs, with the hull left in place as the fallback when there are
more runs than fit and as the answer to "did this transaction write anything".
[benchmarks/results/2026-09-14-flush.md](../benchmarks/results/2026-09-14-flush.md)

---

## 5. Incremental structural validation

### 5.1 The catalog

Today `db_catalog_validate` walks the directory and calls `page_valid` on every
entry. Incrementally:

```text
for each directory slot i:
    if candidate.entry[i].page == base.entry[i].page
    and candidate.entry[i].id   == base.entry[i].id:
            inherit            (no visit, no map lookup, no read)
    else:
            validate fully, and recurse into the object
```

The directory page itself is always validated: it is written by this
transaction whenever anything changed, so it carries the candidate generation
and is proved byte for byte as it is today.

Two properties have to survive, because they are what the current walk
establishes globally rather than per entry:

* **ids strictly increasing** — checked across the whole directory. It reads
  only the directory page, which is already in hand, so it stays exhaustive and
  costs nothing extra.
* **the zero tail past `CAT_COUNT`** — likewise on the directory page itself.

### 5.2 Queues and streams

The object's page carries a directory of segment entries. The comparison is
between the base object page and the candidate object page:

```text
base queue page            candidate queue page
   entries[0..n-1]   ==      entries[0..n-1]     ->  inherited, not visited
   entries[n]        !=      entries[n]          ->  validated
                            entries[n+1] (new)   ->  validated
```

An `ENQUEUE` appends into the tail segment, or allocates a new one. Either way
one or two entries differ and the rest are identical, so the visit count becomes
`O(1)` in retained depth. A `DEQUEUE` retires from the front and changes the
first entry and `QSV_FIRST_SEG`; also `O(1)`.

`TRIM` is the case that is not `O(1)` and should not be forced to be: it
deliberately releases many segments, and its cost is proportional to what it
releases — which is a cost that follows the change, not the retention.

The invariants the current loop checks per entry — magic, version, `page_id`
matching the entry, `owner` matching the object, `QSEG_FIRST` matching the
position arithmetic, reserved fields zero — are checked for validated entries
exactly as now. For inherited entries they are not rechecked, which is the
narrowing of §3.1.

The **position arithmetic must still be checked globally**: `QSV_HIGH`,
`QSV_FIRST_SEG` and `QSV_SEGMENTS` must agree, and that check reads only the
object page. It stays.

### 5.3 Tables, indexes, PAX

These already inherit at page granularity. Extending them to edge granularity
is the same transformation and should follow the queue, not precede it: they do
not show the defect in the baseline — PAX leaves validated per commit is 0.00
and catalog pages 2.00, flat across every depth — so there is nothing to
demonstrate against.

---

## 6. The allocation map

This is the part where the obvious rule is wrong, and the baseline already
showed why.

`db_bitmap_candidate_payload` tests membership in the **candidate** map, which
changes on every transaction. "Old page, skip it" is therefore not available:
the question is not whether the page changed but whether the *map entry* did.

The map is proved as a delta:

```text
base allocation state  +  this transaction's transitions  =  candidate state
```

and what is validated is the legality of each transition:

```text
FREE     -> PAYLOAD          allocation
FREE     -> METADATA         a gap the map reserves as it grows
PAYLOAD  -> RETIRED          copy-on-write replacement
METADATA -> RETIRED          copy-on-write replacement
RETIRED  -> PAYLOAD          reuse, once no reader is pinned to the generation
                             that still reaches it
```

A page does not pass back through `FREE` on its way to being reused:
`span_reuse` finds a `RETIRED` page in both the published and the staged map
and the caller marks it `PAYLOAD` directly. An earlier draft of this document
listed `RETIRED -> FREE` as the reclamation step, which is what the state names
suggest and not what the code does.

Anything else is a refused commit. Which gives the invariant this rests on:

> **The candidate allocation map may differ from the base map only by
> transitions this transaction registered. An entry that differs for any other
> reason is a refused commit.**

That is a stronger statement than the current walk makes, and it is cheap: it
compares changed leaves against the change-set rather than counting the
population of every leaf.

The leaf checks that are not per page — `MAP_MAGIC`, `MAP_HEADER_SIZE`,
`MAP_PAGE_ID`, `MAP_GENERATION` not ahead of the superblock, `MAP_TOTAL`
agreeing, `MAP_SPAN` matching the index, the reserved fields — apply to leaves
the transaction wrote. Unwritten leaves are inherited.

`SB_ALLOC_PAGES` is a whole-file quantity and must still agree. It can be
maintained incrementally from the transitions rather than recomputed, and then
**checked** against the sum on the leaves this transaction wrote plus the base
total. If maintenance and recomputation ever disagree, the commit is refused:
that disagreement is the signal that a mutation escaped the change-set.

---

## 6a. Implemented: the change-set (step 4)

The recording half exists, as of the commit that added this section. It is
inert - nothing reads it to make a decision yet - and that is deliberate: what
had to be established first is that it is **complete**.

`span_mark` is the only place a live transaction changes a page's state in the
span layout, so it is the only place that records, and it gets the outgoing
state for free from the `map_locate` it already does. The log is a flat array
of `(page, from, to)` allocated once per descriptor. If it cannot be allocated,
or a transaction makes more transitions than it holds, `DB_CS_OVERFLOW` is set
and stays set for that transaction: an incomplete log must never be mistaken
for a complete one.

Completeness is proved rather than asserted. `cs_audit` walks the published and
the staged map in full and requires every page whose state differs to be
explained by an entry in the log. It is off in a normal build - it costs
exactly the walk this work exists to remove - and `sh build.sh --audit` /
`build.bat --audit` builds the command line with it armed.

That makes every existing suite a test of the change-set, which is how it was
checked: the storage, SQL, queue, stream, transaction, delete, tombstone,
crash, REPL and compatibility suites were all run against the audit build on
both platforms, plus a stress workload that forces page reuse - 120 inserts,
enqueues and appends, 60 dequeues, a ranged `DELETE`, an `UPDATE`, a `TRIM`,
`DROP INDEX` and `DROP QUEUE`. Nothing escaped the log.

The negative control matters more than any of that: with the single
`call cs_record` commented out, the audit build refuses its first commit with
*staged allocation map or root is inconsistent*. A check that has never been
seen to fail is not evidence.

The flat (non-span) layout does not route through `span_mark` and is excluded
from the audit rather than pretended about. It is the legacy allocator, it is
not what `create` makes, and incremental validation is not planned for it.

---

## 6b. Implemented: the inheritance (steps 5, 7-9)

Two levels, and the first is what makes the second correct.

**At the catalog.** `db_catalog_validate` asks, for each directory entry,
whether the published directory named this same id at this same page. If it
did, the whole object is inherited: not walked, not read into. The object's own
page is still checked, which is one page and grows with nothing.

**Inside an object the transaction did touch.** Its page has changed, so the
published entries and the candidate entries are different memory, and they are
compared entry by entry: an entry naming the same page at the same absolute
position is inherited, one that moved or is new is validated. `QSV_BASE_ENTRIES`
carries the published side; zero there means there is nothing to compare
against and everything is validated.

The order matters, and getting it wrong is instructive. The first attempt did
only the second level. For an object the transaction had *not* touched, the
published and candidate directory entries name the same page - so the
comparison ran the array against itself, always found equality, and inherited
everything including a forged entry. A proof that compares memory with itself
is not a proof. The catalog level is what removes that case, by never entering
the object at all.

Both levels stand down entirely under `DB_VERIFY`, which is how
`cyboudb check` stays exhaustive.

Measured: [benchmarks/results/2026-09-14-commit-inheritance.md](../benchmarks/results/2026-09-14-commit-inheritance.md).

---

## 6c. Implemented: the map, proved as a delta (step 6)

The expensive half of the map proof was already incremental before this work
began, and measuring said so: `span_valid` gates the leaf checksum and the
entry scan on `db_bitmap_deep`, so a leaf an older generation stamped is
skipped. What remains per untouched leaf is a handful of header fields, and
raising a file from 60,000 to 4,000,000 pages takes the leaf count from 4 to
249 per commit while validation time stays at 15-18 us. There was no speed
left to win, and chasing it anyway would have been optimising a number rather
than a cost.

What was missing was the invariant. `cs_leaf_explained` now runs on every
commit, on the leaves the transaction stamped with its own generation, and
requires every entry that differs from the published copy to be one the
change-set registered:

> The candidate allocation map may differ from the base map only by transitions
> this transaction registered. An entry that differs for any other reason is a
> refused commit.

It is bounded by the change rather than the file, which is what makes it
affordable outside an `--audit` build - and the two leaves are compared eight
bytes at a time on a page the checksum has just pulled into cache. `DB_CS_PROVE`
scopes it to a commit proving its own candidate: `db_open` looks at generations
this process did not write, where the two map copies differ for reasons no
change-set describes.

The exhaustive form, `cs_audit`, stays: it walks every page and is what
`--audit` builds, which is how the recording itself is held to being complete.

---

## 7. What has to be attacked before this is believed

Happy-path tests prove nothing here. The suite must try to make the validator
inherit a proof that is not true:

Four corruption cases matter, and they are different from each other. The
second is the one that proves the guarantee actually moved rather than
vanished, and it did not exist before:

```text
A. damage a NEW segment, written by this ENQUEUE
      commit MUST refuse

B. damage an OLD segment of the SAME queue, then ENQUEUE into it
      commit MAY accept
      cyboudb check MUST report damage

C. damage an OLD segment of an UNTOUCHED queue, commit something else
      commit MAY accept
      cyboudb check MUST report damage

D. forge a directory edge or an allocation transition the change-set
   does not explain
      commit MUST refuse
```

| Attack | Must end as | Where |
| :--- | :--- | :--- |
| Damage a page this transaction wrote | commit refused | `queue_page_test` A |
| Damage an old page of an object being written | commit accepts, `check` reports | `queue_page_test` B |
| Damage a page of an object nobody is touching | commit accepts, `check` reports | `queue_page_test` C, `stream_page_test` |
| A map entry changed with no transition registered | commit refused | the `cs_record` negative control |
| **Retire a page still reachable through an inherited subtree** | **commit refused** | `validator_attack_test` |
| A retire of a page nothing reaches any more | commit accepted | `validator_attack_test` |
| A queue naming another queue's segment | commit refused | `validator_attack_test` |
| One page in two logical segment positions | commit refused | `validator_attack_test` |
| A change-set that overflowed | no inheritance; the long proof | `build.sh --cs-overflow` |
| A log whose hops do not follow from each other | commit refused | `validator_attack_test` |
| The same change with nothing forged | commit accepted | `validator_attack_test` |
| A damaged newest generation | open recovers, `check` reports | `integrity_tests` |
| A torn superblock | open recovers, `check` reports OK | the storage suite |

### What the retire attack found

It was a real hole, and it is the reason this section is not a formality.
Proof inheritance skips an object whose directory entry has not moved, and
nothing then stopped the same transaction retiring a page that object still
reaches - registered correctly, map leaf resealed, checksums verifying. The
candidate claimed both *this queue reaches page X* and *page X is retired*.
The build before inheritance refused it; inheriting the subtree stopped
anyone from asking.

`cs_retires_are_unreachable` closes it from the other end, once per retired
page rather than by walking the graph. Every page shape in the format writes
its owning object's id at offset 24 and its own page id at offset 8, so a
retired page can say which object held it - and a page that does not name
itself is the continuation of a multi-page run, where offset 24 is row data
rather than an owner. Reading that as an owner is how the first version of
this check refused an ordinary 128-row `INSERT`; the self-naming test is what
tells a header from a payload page.

What it does not cover, stated rather than implied: a retired page with no
header cannot be attributed, so a transaction that retires only such pages
while an inherited object reaches them would not be caught here. The pages of
a run are retired together with their header, which is what makes that
narrow.

### The chain, not just its end

Checking only where a page ends up accepts a history that never happened. An
entry claiming `RETIRED -> PAYLOAD` for a page the published map holds as
`PAYLOAD` ends in the right state and lies about how it got there, and the
whole point of the change-set is that a commit now believes it.

So `cs_leaf_explained` follows the whole story for every entry that differs:

```text
published map state
        =  first recorded from
           each hop legal
           each to  =  the next from
        =  last recorded to
staged map state
```

The legal hops are the ones the engine actually makes - `FREE` to `PAYLOAD` or
to the `METADATA` a growing map reserves, a live page to `RETIRED`, and
`RETIRED` back to `PAYLOAD` when `span_reuse` hands it out again. A page never
passes back through `FREE` on its way to being reused, which is what the code
does rather than what the state names suggest.

This is not defence against a user: nothing outside the engine can reach the
log. It is defence against the engine. The change-set is part of what a commit
trusts now, so a mutation that records the wrong transition has to end as a
refused commit rather than a published one.

`tests/validator_attack_test.c` attacks it through `cs_record`, which is the
hook, and has the same drop without the forged entry beside it - otherwise the
refusal could be about the drop.

### The pages that cannot say who owns them

A leaf is a run of contiguous pages. The first carries the shared header - a
magic, its own id, its owner - and the rest are row data all the way down. So
a continuation page retired on its own cannot be attributed to an object, and
the check above cannot refuse it for reaching an inherited one.

That state **is** constructible, which was the open question. Retiring one
continuation page by hand, in a transaction that touches something else, is
accepted by the commit. What bounds it is that no engine path does that:
`db_cow_copy_run` retires a run in a loop over every page it holds, so a
continuation is only ever retired alongside its header, and the header is
attributed. Nothing in pax, varlen or zonemap retires a page at all; index,
queue and stream retire single pages that carry headers.

So the gap is the same narrowing the queue's historical damage went through
when inheritance landed, and it ends in the same place: the commit accepts,
and `cyboudb check` refuses the result. `tests/validator_attack_test.c`
asserts both halves, because asserting only the first would be recording that
the commit does not catch it, which proves nothing.

A rule was tried and rejected on the way: refuse a headerless retire unless
the page before it is retired too. It catches the run case and refuses a
legitimate one - `db_cow_alloc_page` hands out bare pages with no header at
all, and `tests/varlen_fragmentation_harness.asm` retires alternating ones on
purpose to make holes. That harness is what noticed.

What did come out of it is the magic. Attribution used to rest on a page
naming itself at offset 8, and a row can hold its own page id by accident;
every page shape in the format also opens with a magic whose low three bytes
are `ASQ`, so both are required now. The allocation map's own pages are
skipped outright: they are reached from the superblock rather than from any
catalog object, and `MAP_TOTAL` sits where an owner id would be read.

### Still open

Nothing else named here. The question this section used to ask has an answer.

Every outcome must be wholly the base generation or wholly the candidate. There
is no third state a reader can observe, and that is unchanged by any of this.

---

## 8. Acceptance

From [ROADMAP.md](../ROADMAP.md), measured with `benchmarks/commit_probe.c`:

| | preview.1 | target |
| :--- | ---: | ---: |
| Queue segments per `ENQUEUE` | 2.14 → 163.41 by depth | **flat** |
| Stream segments per `APPEND` | 2.14 → 163.41 by depth | **flat** |
| Validation time, depth 500 to 10,000 | 11.8x (Windows) | **near-flat** |
| Catalog pages per commit | 2.00 | **2.00** |
| Map leaves per commit | 4.00 | **4.00 or fewer** |
| Pages flushed per commit | 12.00 | **12.00** |
| `cyboudb check` | exhaustive | **exhaustive** |
| preview.1 compat fixtures | read | **read** |
| Format version | 1 | **1** |

**Acceptance is counter-based, not clock-based.** The baseline measured that on
durable storage validation is 2.4% of a commit on Linux and 6.1% on Windows,
and that 93% of a commit's growth with depth is the flush. A wall-clock target
at these depths would be measuring the disk rather than this change. The
no-sync figure — validation is 72% of a commit at depth 10,000 on tmpfs — is
the honest statement of the CPU-side prize.

---

## 9. Out of scope

Not in this work, and not to be smuggled in beside it: WAL, weakening either
durability barrier, `synchronous=NORMAL` or any equivalent, a second writer,
queue leases, any change to format v1 semantics, any change to the public SQL
surface or the C ABI, and any public unsafe or no-sync mode. The no-sync
measurement is a property of the filesystem the probe is run on, not a switch
in the engine.

The flush growing with retained file size is the larger term and is **not**
addressed here. It is recorded in the baseline as an open question.
