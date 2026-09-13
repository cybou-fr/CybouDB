# What a commit costs, and what it spends it on — baseline before preview.2

**Date:** 2026-09-14
**Build:** `v0.5.0-preview.1` plus the commit counters (`268d331`..)
**Harness:** `benchmarks/commit_probe.c`, `sh build.sh --commit-probe` /
`build.bat --commit-probe`
**Machine:** x86-64, rdtsc 3.30 GHz; Windows 11 on NTFS, WSL2 Linux on ext4
(a virtual disk) and on tmpfs.

This is step 2 of 0.5.0-preview.2: instrumentation before optimisation. It
exists so that a later "it got faster" can be told apart from "it stopped
proving something", and so that the size of the prize is known before the work
is done rather than after.

Method: create a database, fill one queue (or one stream) to `depth` records,
then measure 200 further single-record commits on top of it. The fill is not
measured. Every column is per commit.

---

## The structural finding — confirmed, and exactly as predicted

Structural visits are identical on every platform, because they are a property
of the algorithm rather than of the operating system:

| depth | queue segments walked | catalog pages | PAX leaves | map leaves | pages flushed |
| ----: | --------------------: | ------------: | ---------: | ---------: | ------------: |
| 0 | 2.14 | 2.00 | 0.00 | 4.00 | 12.00 |
| 500 | 10.20 | 2.00 | 0.00 | 4.00 | 12.00 |
| 1000 | 18.26 | 2.00 | 0.00 | 4.00 | 12.00 |
| 2000 | 34.38 | 2.00 | 0.00 | 4.00 | 12.00 |
| 10000 | **163.41** | 2.00 | 0.00 | 4.00 | 12.00 |

One `ENQUEUE` changes one slot in one segment. At depth 10,000 the commit
visits 163 of them — `depth / QUEUE_SEG_SLOTS`, which is 156, plus the tail.
**The defect named in the preview.1 release notes is real, and this is its
shape: the commit proves what the database has kept.**

Everything else is flat. Catalog pages, allocation-map leaves and flushed
pages do not move at all between depth 0 and depth 10,000. Streams produce
numbers identical to queues, as they should: one page shape, one validator.

Validation CPU follows the visits exactly:

```text
validation time ≈ 13 us + 0.63 us per retained segment
```

so 15 us at depth 0 and 165 us at depth 10,000 — an 11x growth in the CPU cost
of proving a one-slot change.

---

## The part that was assumed and is wrong

The premise behind "fix incremental validation and commit cost becomes
predictable" was that validation is what makes a deep queue slow. On durable
storage it is not. Per commit, queue workload:

### Windows 11, NTFS

| depth | valid us | sync us | commit us | validation share |
| ----: | -------: | ------: | --------: | ---------------: |
| 0 | 17.2 | 682.2 | 765.2 | 2.3% |
| 500 | 30.9 | 856.3 | 951.3 | 3.2% |
| 1000 | 43.7 | 1015.7 | 1121.7 | 3.9% |
| 2000 | 78.9 | 1541.4 | 1693.0 | 4.7% |
| 10000 | 366.2 | 5538.9 | 6014.9 | **6.1%** |

### Linux, ext4

| depth | valid us | sync us | commit us | validation share |
| ----: | -------: | ------: | --------: | ---------------: |
| 0 | 15.5 | 2347.8 | 2423.5 | 0.6% |
| 500 | 20.8 | 2485.8 | 2607.6 | 0.8% |
| 1000 | 26.8 | 2271.1 | 2360.5 | 1.1% |
| 2000 | 38.1 | 1699.8 | 1816.1 | 2.1% |
| 10000 | 164.9 | 6458.7 | 6745.4 | **2.4%** |

The commit does grow with depth — on Windows 765 us to 6,015 us, 7.9x. But
decomposing that growth:

```text
Windows, depth 0 -> 10000

  commit      +5,250 us
     of which
  sync        +4,857 us     93%
  validation    +349 us      7%
  everything else ~44 us     1%
```

**The flush is 92% of a commit and 93% of its growth with depth.** Both
barriers end in a whole-file operation — `FlushFileBuffers` on Windows,
`fsync` on Linux — and their cost tracks the size of the file, which grows as
the queue is retained. The range handed to `FlushViewOfFile`/`msync` is
constant: `pages flushed` is 12.00 at every depth.

So incremental validation removes about **7% of the depth scaling on Windows
and 2-3% on Linux**, not the depth scaling.

---

## The measurement that shows why the work is still worth doing

Running the same probe on tmpfs, where a sync costs 0.5 us — the test-only
no-sync measurement the plan asked for, obtained without adding an unsafe mode
to the engine:

| depth | valid us | sync us | commit us | validation share |
| ----: | -------: | ------: | --------: | ---------------: |
| 0 | 12.6 | 0.5 | 43.8 | 28.7% |
| 2000 | 29.6 | 0.7 | 71.3 | 41.5% |
| 10000 | 107.0 | 0.8 | 147.6 | **72.5%** |

With the flush out of the way, validation is three quarters of a commit at
depth 10,000 and the whole depth curve is validation. This is the honest
statement of the prize:

- **CPU-side, the win is large**: 147.6 us to about 56 us at depth 10,000, and
  a flat line instead of a rising one.
- **On this hardware's durable storage, the win is a few per cent**, because
  the two barriers dominate and they are not being changed.
- On storage where a flush costs tens of microseconds rather than milliseconds
  — a fast NVMe with a power-loss-protected cache, or a workload batching many
  records per transaction — the two numbers converge and the win is most of
  the remaining cost.

---

## What this changes

1. **The structural goal stands.** `O(1)` segment visits per commit is a real
   defect fixed by a real change, and the counters above are the acceptance
   test. It should be stated as what it is — an algorithmic fix — rather than
   as the thing that will make deep queues fast.
2. **The preview.1 release note overstates the cause.** It says commit
   validation scaling with retained segments is why a deep queue is slow. It is
   *a* reason, worth 7% at depth 10,000 on Windows. The dominant reason is that
   a whole-file flush costs more as the file grows.
3. **A new question is now open and was not before:** the flush growing with
   retained size. Nothing here proposes an answer; it is recorded because it is
   the larger term and the instrumentation found it.
4. **Acceptance metrics should be counter-based, not clock-based.** Wall time
   at these depths is dominated by a component preview.2 does not touch, so a
   wall-clock target would measure the disk, not the change.

---

## Reproducing

```sh
sh build.sh --commit-probe
./build/commit_probe --depths 0,500,1000,2000,10000 --rounds 200
```

```cmd
build.bat --commit-probe
build\commit_probe.exe --depths 0,500,1000,2000,10000 --rounds 200
```

Run it from a directory on the filesystem being measured: the probe writes its
database in the working directory, and the first Linux run of this baseline was
invalidated by tmpfs before that was noticed.

The counters it reads are `queue_segments_walked`, `catalog_pages_validated`,
`pax_leaves_validated`, `bitmap_leaves_validated`, `commit_validations`,
`commit_validate_ticks`, `pages_flushed` and `sync_ticks`. The engine never
resets them; a caller reads one before and after and subtracts.
