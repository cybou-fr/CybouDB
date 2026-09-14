# The encrypted read path, measured before it is built

Step 2.5 of `0.7`. [ENCRYPTED_FORMAT.md](../../docs/ENCRYPTED_FORMAT.md)
Decision 7 says an encrypted database cannot use the shared mapping the engine
reads through today, because plaintext in a shared mapping is plaintext on the
disk. This is what the alternatives cost.

It is a spike, not the engine: `benchmarks/io_spike.c` measures page *access*
on a file of the same shape, with the same access patterns, and no CybouDB in
it. The point is to find out whether the architecture is affordable before
committing the engine to it — and, if it is not, to find out now rather than at
step 19.

```
sh build.sh --io-spike
./build/io_spike <pages> <touches> <path> <cache %>
```

## What was measured

| | |
| :--- | :--- |
| **A** shared | `MAP_SHARED` / `FILE_MAP_WRITE`, read as `base + page × 4096`. What the engine does today. |
| **A′** dispatch | The same, reached through a function pointer — an encrypted build needs two read paths, and the plaintext one must not pay for the choice. |
| **B** private | `MAP_PRIVATE` / `FILE_MAP_COPY`. Stores cannot reach the file. |
| **C** cache | Explicit `pread`/`ReadFile` into a bounded plaintext cache, 8-way set associative with clock eviction inside the set. Measured without and with a transform. |

The transform is a keystream xor, not a cipher, and it is a **floor**: a real
AEAD does at least this much work and then authenticates as well. A conclusion
that survives the floor being raised is a conclusion; one that depends on it is
not.

Two access shapes, because the engine has two: **point** — 8 bytes of a page
header, jumping between pages, as index descent and queue lookup do; **scan** —
one read per cache line, page after page, as a table scan does.

## Linux, 240 MiB file, three runs each

Nanoseconds per page access. `tmpfs`-backed `/tmp` inside WSL2, so the file is
in RAM and the miss path is a syscall and a copy, without a device under it.

**Cache budget 100% of the file** (measured hit rate 76.8%):

| | A shared | A′ dispatch | B private | C cache | C + transform |
| :--- | ---: | ---: | ---: | ---: | ---: |
| point | 14.5 – 15.4 | 14.8 – 15.0 | 12.7 – 14.9 | 76 – 82 | 108 – 125 |
| scan | 137 – 142 | – | 137 – 147 | 478 – 496 | 883 – 907 |

**Cache budget 10% of the file** (measured hit rate 10.9%):

| | A shared | A′ dispatch | B private | C cache | C + transform |
| :--- | ---: | ---: | ---: | ---: | ---: |
| point | 14.4 – 17.0 | 14.9 – 19.9 | 15.0 – 18.7 | 848 – 859 | 1450 – 1505 |
| scan | 138 – 146 | – | 137 – 148 | 650 – 682 | 1324 – 1448 |

## Windows, 240 MiB file, NTFS, three runs each

| Budget | A shared | A′ dispatch | B private | C cache | C + transform |
| :--- | ---: | ---: | ---: | ---: | ---: |
| 100% | 11.7 – 14.3 | 14.4 – 19.6 | 14.0 – 17.6 | 206 – 214 | 236 – 343 |
| 10% | 10.3 – 15.9 | 14.3 – 19.0 | 14.0 – 18.0 | 3284 – 3468 | 3935 – 4031 |

A real filesystem rather than RAM, and the miss path costs an order of
magnitude more than it does on `tmpfs`. **The two platforms are not compared to
each other here** — different storage under the file, different durability
semantics — only each to its own baseline.

## What the numbers say

**1. The dispatch is free.** A′ is A through a function pointer, and across six
configurations the difference never leaves the run-to-run noise of A itself.
The plaintext zero-regression requirement — a database without the encryption
bit must not pay for the existence of the other path — is satisfiable, and
`PAGE_ADDR` does not have to stay a macro to get it.

**2. B is eliminated, and for the reason it was listed.** A private mapping
reads *exactly* like a shared one — 12.7 to 18.7 ns against A's 14.4 to 17.0 —
because for reads it **is** a shared mapping. It stops stores from reaching the
file, which is half of what encryption needs, and does nothing whatever about
the other half: the page still arrives holding the file's bytes, and something
must turn those into plaintext before the first dereference. The measurement
confirms it has no cost *and* no benefit. It is not the architecture.

**3. C is affordable on hits and expensive on misses, and that is the whole
finding.** The hit path costs **~2× to ~5× a pointer dereference** — 76 to 82
ns against 15 on Linux at a 77% hit rate, 206 to 214 against 14 on Windows —
and a miss costs **850 ns on tmpfs and 3.3 µs on NTFS**, before any
cryptography. So the design question for `0.7` is not *how fast is the cipher*;
it is **what fraction of accesses miss**, which is a memory-budget question.

**4. The cryptography is amortised; the architecture is not.** At a 96.6% hit
rate on a 31 MiB file, the transform added 2 to 3 ns per access — 32.5 to 35.4
ns on Windows, 23.8 to 24.9 on Linux — because it runs only on a miss. At a
10.9% hit rate it added ~650 ns. The same code, a factor of 200 apart in what
it costs, decided entirely by the hit rate. **Anyone who benchmarks the cipher
and reports that number as the cost of encryption will be measuring the cache.**

**5. A 100% budget is not a 100% hit rate.** 60,000 slots for 60,000 pages gave
76.8%, because an 8-way set-associative cache with a multiplicative hash
overflows some sets while others sit empty. On the 31 MiB file the same
structure reached 96.6%. Associativity and hashing are worth their own
experiment before the engine's cache is written — this one was not designed to
answer it, and 77% is not a property of the idea, only of this structure.

**6. Scans are where the copy hurts.** A scan under C costs 478 to 496 ns per
page against 137 to 147 for the mapping, at the *same* hit rate that makes
point access cost 80. A sequential sweep evicts what it just brought in, and
clock eviction has nothing to work with. A scan-resistant policy, or reading
scans through a different door entirely, is a real design question for the
engine and not a tuning knob.

## The commit side

Writing *k* scattered pages and making them durable:

| k | Linux, `pwrite` + `fsync` | Windows, `WriteFile` + `FlushFileBuffers` |
| ---: | ---: | ---: |
| 1 | 8.6 – 9.3 µs | 747 µs – 6.3 ms |
| 8 | 4.7 – 9.2 µs | 1.0 – 2.0 ms |
| 64 | 32.6 – 52.8 µs | 3.1 – 4.3 ms |

Again, not a cross-platform comparison: `FlushFileBuffers` on NTFS asks the
device to flush, and `fsync` on a tmpfs-backed file has no device to ask. What
matters for the design is the shape — the cost is dominated by the durability
barrier rather than by the number of pages — which is the same conclusion the
`preview.2` flush measurement reached from the other side, and it means the
seal directory's extra pages (Decision 3b) will show up in the *page* term
rather than in the barrier.

## Two defects in the probe, found by disbelieving its output

Recorded because both produced plausible numbers, and a benchmark that is wrong
in a plausible direction is worse than one that crashes.

* **The cache could not find what it had stored.** The first version was open
  addressed with one global clock hand: a lookup probed eight slots from the
  page's hash, and an insert went wherever the hand happened to point. It
  reported a **0.1% hit rate on a cache holding a tenth of the file** — which
  is not a cache result, it is a measurement of `pread` with extra steps. Fixed
  by making eviction choose a victim *within the set the page hashes to*.
* **The first architecture measured paid for everyone's page faults.** Without
  a warm pass, A looked slower than A′ — the same code behind a pointer. With a
  warm pass that sampled a quarter of the pages at random, a 240 MiB file on
  NTFS still reported A at **138 ns against A′'s 14 ns**. The warm pass now
  sweeps every page in order before anything is timed, and A and A′ agree.

Both were caught by asking why a result was impossible rather than by reading
the code, which is the only reason they were caught at all.

## What this does not measure

* **Pinning.** A real cache holds a page while the engine is using it; this one
  can evict a page a caller still has a pointer to. C's numbers are therefore
  optimistic.
* **Authentication.** The floor transform has no tag. A real AEAD adds a MAC
  over 4 KiB per miss.
* **The engine's actual access pattern.** Point and scan are stylised. What a
  `SELECT` with a predicate does to a cache is a question for the engine, not
  for this.
* **Concurrency.** One thread, no locking, no contention on the cache.
* **The seal directory's own reads.** Decision 3b's leaves and nodes are pages
  too, and they are read on the miss path. That is write and read amplification
  this spike does not include.

## Verdict for step 2.5

**C is the architecture.** B is eliminated on evidence, A cannot be kept for an
encrypted file for the reason that started all this, and C's hit path is 2–5×
a pointer dereference, which is a cost a release can carry.

**The release's risk is the miss rate, not the cipher**, and that moves two
things into the design that were not there before: a page-cache budget as a
first-class setting, and a scan path that does not evict everything it touches.

Nothing here says the engine's *existing* performance is safe — that is a
measurement against the real executor, on the real suites, and it belongs with
the first encrypted build rather than with this spike.

## Reproducing

```
sh build.sh --io-spike
./build/io_spike 60000 200000 /tmp/io_spike.dat 100     # budget = whole file
./build/io_spike 60000 200000 /tmp/io_spike.dat 10      # budget = a tenth

build.bat --io-spike
build\io_spike.exe 60000 200000 build\io_spike.dat 100
```

Put the file on the platform's own filesystem. Running the Linux binary against
a path under `/mnt/c` measures WSL's 9p bridge and nothing else — the first
attempt at this did exactly that and had to be stopped.
