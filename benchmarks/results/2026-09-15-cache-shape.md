# What shape the plaintext page cache should be

*2026-09-15. `benchmarks/cache_probe.c`, gcc 15.2 on Linux 6.18 (WSL2).*

The encrypted I/O spike left two questions open and said it had not been
designed to answer them:

> "77% is not a property of the idea, only of this structure."

> "A scan-resistant policy, or reading scans through a different door entirely,
> is a real design question for the engine and not a tuning knob."

This is that experiment, run before the cache is written rather than after,
because a cache is easy to write once and hard to change afterwards. It
simulates the index structure only: no I/O, no crypto, no timing. Hit rate is
the only number the structure controls, and what a miss costs was already
measured.

60,000 pages (a 240 MiB database), a cache of 8,192 (13.6%), two million
measured accesses after a 200,000-access warm-up.

## The answers, first

| | |
| :--- | :--- |
| **Associativity** | Four ways, and eight to be comfortable. Beyond eight is worth under a point. |
| **Index** | Low bits. It is never worse here and is much better when the working set is contiguous - and at eight ways the choice stops mattering, which is the real reason to pick eight. |
| **Eviction** | Promote on the second touch. Four points on a hot working set, six under a scan, and it needs no hint from the engine. |
| **Scans** | Do not need their own door. |

## Uniform random access - the sanity row

| ways | 1 | 2 | 4 | 8 | 16 | 32 |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: |
| every combination | 13.6% | 13.6% | 13.6% | 13.6% | 13.6% | 13.6% |

Uniform access over a cache holding 13.6% of the file has to hit 13.6% of the
time, whatever the structure does, because there is no locality for a structure
to exploit. Every policy, every hash and every associativity agrees to one
decimal place.

That row is in the table as an instrument check rather than a result, and it
earned its place: **the first run of this probe reported 1.7%**. The cache held
6,000 entries, the index masked with `sets - 1`, and 6,000 is not a power of
two - so most of the cache was aliased away. The number was impossible before
it was explained, which is the only reason the bug was found.

## A hot working set

Point queries with a heavy bias to a small set of pages.

| hash | policy | 1 | 2 | 4 | 8 | 16 | 32 |
| :--- | :--- | ---: | ---: | ---: | ---: | ---: | ---: |
| low bits | clock | 76.2% | 76.8% | 77.8% | 78.3% | 78.5% | 78.6% |
| low bits | lru | 76.2% | 77.4% | 77.6% | 77.7% | 77.7% | 77.8% |
| low bits | **probation** | 76.2% | 79.5% | **81.0%** | **82.1%** | 82.8% | 83.1% |
| mixed | clock | 59.7% | 73.0% | 77.6% | 78.3% | 78.5% | 78.6% |
| mixed | lru | 59.7% | 73.7% | 77.4% | 77.6% | 77.7% | 77.7% |
| mixed | probation | 59.7% | 75.6% | 80.9% | 82.1% | 82.8% | 83.1% |

**LRU is not better than clock here, and is slightly worse.** That is worth
saying because the opposite is the default assumption. Clock keeps a page that
was touched during the last sweep of its set; exact recency keeps the page
touched most recently, and on a workload with a broad warm tail those are
different pages and clock's is the better guess. The gap is half a point and
the reason to prefer clock is its cost, not its hit rate.

**Promote-on-second-touch is worth four points**, and more at low associativity.
It is the same structure a database buffer pool usually reaches for, arrived at
here from measurement rather than from convention.

## A working set allocated in runs

Reads that walk short runs of consecutive pages inside a working set the cache
could hold - which is what reading a table actually looks like.

| hash | policy | 1 | 2 | 4 | 8 | 16 | 32 |
| :--- | :--- | ---: | ---: | ---: | ---: | ---: | ---: |
| low bits | any | 99.6% | 99.6% | 99.6% | 99.6% | 99.6% | 99.6% |
| mixed | clock | 42.9% | 73.1% | 96.5% | 97.3% | 98.2% | 98.8% |
| mixed | probation | 42.9% | 73.6% | 96.6% | 97.5% | 98.4% | 98.9% |

This row is the one that settles the hash, and it settles it the other way
round from the guess in the spike. The worry there was that "page numbers share
low bits", so a mixing hash would spread them better. The opposite is true:
consecutive page numbers map to *consecutive sets* under a low-bits index,
which is conflict-free, while a multiply scatters them and collides by the
birthday bound. At one way that is 99.6% against 42.9%.

By four ways the mixing hash has recovered to within three points and by eight
to within two, which is the argument for eight ways stated from the other side:
**pick an associativity at which the index function stops mattering, and then
the cheapest index function is the right one.**

## A scan running through a point workload

One page of a sweep for every nine point queries. The number reported is the
hit rate of *the point queries only* - what the scan does to everything else is
the question, not how well the scan itself does.

| hash | policy | 1 | 2 | 4 | 8 | 16 | 32 |
| :--- | :--- | ---: | ---: | ---: | ---: | ---: | ---: |
| low bits | clock | 71.9% | 73.4% | 74.9% | 75.5% | 75.7% | 75.8% |
| low bits | lru | 71.9% | 73.6% | 74.3% | 74.4% | 74.4% | 74.5% |
| low bits | **probation** | 71.9% | 77.6% | 80.0% | **81.6%** | 82.7% | 83.1% |

Against the hot-set table, at eight ways: 78.3% → 75.5% under clock, a loss of
almost three points to the scan; 82.1% → 81.6% under probation, a loss of half
a point. **A scan costs the point workload almost nothing once a page has to be
touched twice to stay.**

So the answer to the spike's second question is that scans do not need their
own door. They need a cache that does not trust a page it has seen once, and
that is the same policy already chosen for a different reason.

**No hint is required, and that matters more than the half point.** The policy
works because a sweep touches each page once and therefore evicts itself - not
because the engine announced it was sweeping. An engine often does not know: a
sequential scan and a range read of the same width are the same sequence of
page numbers, and a cache that behaves differently on a flag will behave wrongly
whenever the flag is wrong.

## What this does not measure

* **Cost.** Hit rate is what the structure controls; nanoseconds per hit and per
  miss were measured by the I/O spike and do not change here. A policy that won
  by half a point and cost twice as much would be the wrong choice, which is
  part of why clock and not LRU.
* **Write-back.** Every access here is a read. Dirty pages, their ordering
  against the seal directory, and what a commit must flush are step 8's
  problem, and step 19 will have to measure the write amplification Decision 3b
  already warns about.
* **Real traces.** These are synthetic workloads chosen to be legible, not
  recordings of a real application. What they establish is the shape of the
  structure; what a particular database does to it will differ.
* **Anything about a calibrated Zipf.** The hot-set generator is a crude bias,
  and the document says so where it is defined rather than claiming a
  distribution it does not have.

## Two artefacts that were corrected before the table was believed

* **A cache of 6,000 with a mask of 5,999.** Reported 1.7% on uniform access,
  where the arithmetic demands 13.6%. The capacity is a power of two now, and
  the constant says why it is not negotiable.
* **A hot set that started at page zero.** The first corrected run reported
  low-bit indexing beating a mixing hash by sixteen points at one way - true,
  but for the wrong reason: a working set at page zero is perfectly spread
  across sets by a low-bit index for free. Moving it to an arbitrary offset
  keeps the conclusion (low bits still wins on contiguous working sets, for the
  consecutive-sets reason) while removing the flattery.

Both were found by asking why a number was too good rather than by reading the
code.
