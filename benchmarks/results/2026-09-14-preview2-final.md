# 0.5.0-preview.2, measured on the frozen engine

**Date:** 2026-09-14
**Engine:** `dcca104`, the commit the release is cut from. No engine change
after this measurement.
**Harness:** `benchmarks/commit_probe.c`, one record per transaction, 60,000-page
file, rdtsc 3.30 GHz.
**Machines:** Linux on ext4 (WSL2, virtual disk), Windows 11 on NTFS.

## The claim

> CybouDB proves the transition from the previously validated generation to the
> candidate generation, instead of re-proving the retained graph on every
> commit.

## Structural visits per commit

Identical on both platforms and for both object types, because this is a
property of the algorithm:

| depth | before | after |
| ----: | -----: | ----: |
| 0 | 2.14 | **1.00** |
| 500 | 10.20 | **1.00** |
| 1000 | 18.26 | **1.00** |
| 2000 | 34.38 | **1.00** |
| 10000 | **163.41** | **1.00** |

One `ENQUEUE` changes one slot in one segment, and the commit now visits one
segment, at every depth. `APPEND` to a stream is the same, as it should be:
one page shape, one validator.

Everything that was already flat is exactly where it was — catalog pages 2.00,
map leaves 4.00, flushed pages 12.00, PAX leaves 0.00, before and after, on
both platforms.

**The "before" column is `18fb79c`**, which is `v0.5.0-preview.1` plus the
counters and nothing else: no commit-path change had been made yet. The
released `preview.1` binary cannot be measured directly, because the counters
did not exist in it. Full baseline:
[2026-09-14-commit-baseline.md](2026-09-14-commit-baseline.md).

## Validation time per commit

Linux, ext4:

| depth | queue | stream | before (queue) |
| ----: | ----: | -----: | -------------: |
| 0 | 17.2 us | 15.0 us | 13.3 us |
| 500 | 16.1 us | 15.6 us | 17.8 us |
| 1000 | 15.7 us | 15.8 us | 23.1 us |
| 2000 | 16.2 us | 16.1 us | 31.7 us |
| 10000 | **31.7 us** | 31.9 us | **115.7 us** |

Windows, NTFS:

| depth | queue | stream |
| ----: | ----: | -----: |
| 0 | 14.5 us | 20.6 us |
| 500 | 15.3 us | 20.7 us |
| 2000 | 16.3 us | 21.0 us |
| 10000 | **38.5 us** | 38.1 us |

Flat from depth 0 to 2,000 and rising at 10,000 — and the rise is not the
segment walk, which the counter puts at 1.00 either way. It is unattributed,
and saying so is better than drawing a horizontal line through numbers that
are not horizontal.

## What this does not claim

Commit wall time is dominated by the two durability barriers, which were not
touched and will not be:

```text
Linux,   depth 10000:  commit 6071 us,  of which sync 5933 us,  validation 0.5%
Windows, depth 10000:  commit 5626 us,  of which sync 5475 us,  validation 0.7%
```

So a deep queue is still slow to commit, and this release does not make it
fast. What it removes is the term that grew with what the database had kept.
The acceptance test for that is the counter, not the clock: at these depths a
wall-clock target would be measuring the disk.

The flush growing with retained file size is the larger term and remains open.
It is recorded in the baseline as the question the instrumentation found.

## The fallback, measured

A change-set that overflows must take the long proof rather than inherit on
the strength of a log that has lost entries. Built with a capacity of one
(`build.sh --cs-overflow`), at depth 2,000:

| | segments visited per commit |
| :--- | ---: |
| ordinary build | 1.00 |
| change-set overflowing | **33.42** |

That is what says the fallback is a different path and not a flag nobody
reads. Every suite passes on that build, on both platforms, and hosted CI runs
it.

## Reproducing

```sh
sh build.sh --commit-probe
./build/commit_probe --depths 0,500,1000,2000,10000 --rounds 200
```

Run it from a directory on the filesystem being measured. The first Linux
baseline of this work was taken on tmpfs by accident, where a sync costs half
a microsecond and the whole picture inverts.
