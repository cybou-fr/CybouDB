# Proof inheritance: the commit stops visiting what it did not change

**Date:** 2026-09-14
**Before:** `18fb79c` — [the baseline](2026-09-14-commit-baseline.md)
**After:** this commit
**Harness:** `benchmarks/commit_probe.c`, 200 measured commits at each depth,
one record per transaction, Linux ext4, rdtsc 3.30 GHz.

## Structural visits per commit — the acceptance test

One `ENQUEUE` changes one slot in one segment. What the commit visited:

| depth | before | after |
| ----: | -----: | ----: |
| 0 | 2.14 | **1.00** |
| 500 | 10.20 | **1.00** |
| 1000 | 18.26 | **1.00** |
| 2000 | 34.38 | **1.00** |
| 10000 | **163.41** | **1.00** |

Flat. Streams are identical, as they should be — one page shape, one
validator. Everything that was already flat stayed flat: catalog pages 2.00,
map leaves 4.00, flushed pages 12.00, PAX leaves 0.00, at every depth, before
and after.

## Validation time per commit

| depth | before | after |
| ----: | -----: | ----: |
| 0 | 13.3 us | 14.8 us |
| 500 | 17.8 us | 15.4 us |
| 1000 | 23.1 us | 16.4 us |
| 2000 | 31.7 us | 17.2 us |
| 10000 | 115.7 us | **32.4 us** |

3.6x at depth 10,000, and the shape is what matters: the term proportional to
retained depth is gone. What remains is not flat — 14.8 us to 32.4 us — and
that residue is not the segment walk, which the counter says is 1.00 either
way. It is unattributed, and saying so is better than pretending the line is
horizontal when the number is not.

## What it does not change

Commit wall time is unchanged within noise, and that was predicted: the
baseline measured validation at 0.6% of a commit on Linux and 6.1% on Windows,
with 93% of the growth with depth being the flush. This was an algorithmic fix
and it is reported as one. The counters are the acceptance test; the clock at
these depths measures the disk.

```text
depth 10000, before -> after
  segments visited     163.41 -> 1.00
  validation            115.7 -> 32.4 us
  commit wall           ~165   -> ~160 us   (tmpfs, no flush)
  commit wall          ~6700   -> ~6400 us  (ext4, flush-dominated)
```

## What it cost

A narrowing, taken deliberately and only after `cyboudb check` was made to
report damage rather than recover from it silently
([39a9a58](../../docs/RECOVERY.md)). A commit no longer reads into an object
whose directory entry has not moved, so damage to a page an earlier generation
wrote is no longer a commit-time refusal. `tests/queue_page_test.c` covers all
four cases now — the segment this transaction wrote (commit must refuse), an
old segment of the same queue being written to (commit accepts, check
reports), an untouched queue (same), and a forged allocation transition, which
is the change-set audit.

Case B did not exist before this work and is the one that proves the guarantee
moved rather than vanished: every earlier case damaged a queue nobody was
touching.
