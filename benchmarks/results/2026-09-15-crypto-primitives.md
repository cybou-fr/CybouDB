# What sealing a page actually costs

Step 3 of `0.7`. The [I/O spike](2026-09-15-encrypted-io.md) measured the
architecture with a stand-in transform and concluded that *the cache decides
and the cryptography is amortised*. It also said, in as many words, that any
conclusion depending on the floor being low was not a conclusion.

**This raises the floor, and one of those conclusions does not survive it.**

`benchmarks/crypto_probe.c`, on both platforms:

```
sh build.sh --crypto-probe && ./build/crypto_probe
build.bat --crypto-probe  && build\crypto_probe.exe
```

## Correctness first

ChaCha20 and Poly1305 are implemented here in portable C and checked against
the test vectors printed in **RFC 8439** — section 2.3.2 for the ChaCha20 block
function, section 2.5.2 for the Poly1305 tag — copied from the RFC rather than
from memory or from another implementation.

```
  ok   ChaCha20 block matches RFC 8439 section 2.3.2
  ok   Poly1305 tag matches RFC 8439 section 2.5.2
  ok   ChaCha20 is the same stream whatever the chunking
  ok   and the hoisted implementation agrees with the clear one
  ok   SSE2 ChaCha20 is byte-identical to scalar, every length 1..200
  ok   four-block SSE2 agrees too, every length 1..400
  ok   and AVX2 agrees, every length 1..700
  ok   Poly1305 is the same tag whatever the chunking
```

Both RFC vectors passed on the first run on both platforms. The chunking checks
are there because an implementation that is right only when the caller hands it
whole blocks is a bug waiting for a 4095-byte page, and the three equality
checks are [Decision 3](../../docs/CRYPTO_BACKEND.md) made testable: the machine
may choose how fast, never what.

The AES-NI and PCLMULQDQ numbers below are **throughput only and unvalidated**.
They answer *how much does hardware change the decision*, and nothing else. If
AES becomes the shipped primitive it arrives with RFC 8452's vectors attached.

## The numbers, per 4096-byte page

Both machines report AES-NI, PCLMULQDQ, SHA-NI, AVX2 and RDSEED present.

| | Linux (gcc -O2) | Windows (cl /O2) |
| :--- | ---: | ---: |
| ChaCha20, scalar C | 7,213 ns · 0.57 GB/s | 7,582 ns · 0.54 GB/s |
| ChaCha20, SSE2, one block | 4,665 ns · 0.88 GB/s | 4,653 ns · 0.88 GB/s |
| ChaCha20, SSE2, four blocks | 2,746 ns · 1.49 GB/s | 2,965 ns · 1.38 GB/s |
| ChaCha20, AVX2, eight blocks | 1,822 ns · 2.25 GB/s | 1,935 ns · 2.12 GB/s |
| Poly1305, 26-bit limbs | 1,839 ns · 2.23 GB/s | 2,521 ns · 1.62 GB/s |
| Poly1305, 64-bit limbs | 1,822 ns · 2.25 GB/s | 1,590 ns · 2.58 GB/s |
| Poly1305, four chains | 1,146 ns · 3.58 GB/s | 1,097 ns · 3.74 GB/s |
| **sealing a page, scalar** | **9,120 ns** | **9,537 ns** |
| **sealing a page, SSE2 four-block cipher** | **4,615 ns** | **5,480 ns** |
| **sealing a page, AVX2 cipher** | **3,464 ns** | **4,509 ns** |
| **sealing a page, SSE2 cipher + 4-chain MAC** | **3,722 ns** | **3,995 ns** |
| **sealing a page, AVX2 cipher + 4-chain MAC** | **2,620 ns** | **3,023 ns** |
| AES-128-CTR, AES-NI | 280 ns · 14.6 GB/s | 284 ns · 14.4 GB/s |
| carry-less multiply chain, PCLMULQDQ | 427 ns · 9.6 GB/s | 354 ns · 11.6 GB/s |
| **hardware AEAD, the two terms together** | **~700 ns** | **~640 ns** |

**Every vector path is byte-identical to the scalar one**, asserted at every
length from 1 to 700 rather than at a convenient multiple of 64 — the tail is
where a four-at-a-time implementation goes wrong. That assertion is what lets
the format name a primitive without naming instructions.

The hardware line is a floor: a real GCM or GCM-SIV adds the field reduction
and the key schedule, and GCM-SIV derives per-message keys. Call it under a
microsecond and not 300 ns.

## The finding

**A software AEAD costs more than the I/O it protects. A hardware one does
not.**

Put beside the I/O spike's miss costs:

| | cost of one page miss |
| :--- | ---: |
| read from tmpfs (Linux) | 850 ns |
| read from NTFS (Windows) | 3,300 ns |
| **+ portable ChaCha20-Poly1305** | **+9,300 ns** |
| **+ hardware AES + PCLMUL** | **+~690 ns** |

So on a CPU with AES-NI the spike's conclusion stands: the cipher is a minority
of the miss, the cache decides, and the design question is the hit rate. **On a
CPU without AES-NI the conclusion is false** — the cipher is three to eleven
times the I/O it accompanies, and every cache miss costs ten microseconds
instead of one.

That is not an argument against a portable fallback. It is the reason the
fallback cannot be described as *slower*: it changes which term dominates, and
therefore changes what the engine should optimise on such a machine.

### Vectorising the cipher moves the bottleneck rather than removing it

`CRYPTO_BACKEND.md` Decision 3 rested on an expectation: that a vectorised
ChaCha20 would bring a sealed page to **about 2 µs**, comparable to a page miss
on NTFS. Measured, the expectation is **not met, and the reason is not the
cipher**.

```
scalar            cipher 7,213   MAC 2,137   page 9,142 ns
SSE2, 4 blocks    cipher 2,746   MAC 2,137   page 4,585 ns
AVX2, 8 blocks    cipher 1,822   MAC 2,137   page 3,517 ns
                          ^                        ^
                  4x faster, and now            still 5x the
                  the smaller half              hardware AEAD
```

The cipher came down 4x — 0.57 GB/s scalar to 2.25 GB/s with AVX2 — and
**Poly1305, untouched, is now 61% of the work**. Making the cipher faster again
cannot get to 2 µs, because 2.1 µs of MAC is already most of the budget.

So the honest position for step 3 is: **a sealed page costs 3.5 µs at best on
this hardware with this construction, and 4.6 µs on the SSE2 baseline that
needs no dispatch at all.** Against the I/O it accompanies — 850 ns on tmpfs,
3.3 µs on NTFS — sealing is comparable to a miss on NTFS and several times it
on tmpfs.

Reaching 2 µs needs a parallel Poly1305, which is real work: the MAC's
sequential Horner evaluation has to become a multi-lane one with precomputed
powers of the key.

### The parallel MAC, and the thing that was actually in the way

Poly1305 is a Horner evaluation — `h = (((h + m₁)r + m₂)r + m₃)r …` — so every
block waits for the one before it. Splitting the message four ways, each
accumulator advancing by `r⁴` and combined at the end with `r⁴, r³, r², r`,
gives four independent multiplies per group. Written that way it was **slower**:
2,065 ns against the serial version's 1,807.

That made no sense, and the reason it made no sense was not the algorithm.

```
load64le as eight byte loads and fourteen shifts:
    26-bit   1,839     64-bit   1,822     four chains   1,876

the same function as a memcpy of eight bytes:
    26-bit   1,849     64-bit   1,867     four chains   1,146
```

**The serial implementations did not care and the parallel one halved.** A
portable little-endian load costs about thirty operations per 16-byte block
against nine multiplies — and a serial Horner chain has so much multiply
latency to wait through that thirty extra operations hide inside it. Remove the
waiting, and the loads are all that is left.

So the four-chain decomposition works, and it was invisible until the code
around it stopped being the limit. The lesson is not about Poly1305: **a
parallel version of anything measures the overheads that a serial version was
concealing.**

Where that leaves a sealed page:

| | Linux | Windows |
| :--- | ---: | ---: |
| scalar cipher, serial MAC | 9,120 ns | 9,537 ns |
| SSE2 cipher, 4-chain MAC | 3,722 ns | 3,995 ns |
| **AVX2 cipher, 4-chain MAC** | **2,620 ns** | **3,023 ns** |

From 9.1 µs to 2.6 µs, a 3.5x improvement, and the cipher and the MAC are now
within 30% of each other — 1,486 ns against 1,146 — so neither is the obvious
next target. The 2 µs the design wanted is **close but not reached**, and it is
reached only with AVX2, which is a dispatch decision rather than a baseline.

## Two things this does not say

**It no longer guesses at the vectorised number.** The first version of this
document said a vectorised ChaCha20 "reaches several GB/s" and left it there.
It reaches 2.25 GB/s on this machine, which is several only by a generous
reading, and the four-fold improvement bought less than half of what the seal
costs. Guessing would have left Decision 3 resting on a number that is 1.75x
optimistic.

Hoisting the cipher state out of the per-block loop changed nothing (7,439 ns
against 7,326 ns), which is how the measurement was confirmed to be timing the
twenty rounds rather than the setup around them. The single-block SSE2 version
is in the table for the same reason: at 1.6x the scalar code it shows that the
win comes from having four independent dependency chains, not from the
registers being wider.

**It does not measure a key schedule, a KDF, or a KEM.** ML-KEM and ML-DSA
belong to the key hierarchy, not to the page path: they run when a database is
opened or a key is granted, not per page. They are a separate measurement with
a separate acceptance question, and they are not in this one.

## Defect found, and what it looked like

The carry-less multiply chain first reported **1.6 TB/s** — which is not a
result, it is what a loop the compiler deleted looks like from outside. The
accumulator was consumed only by a comparison the optimiser could see through.
Making it escape to a `volatile` sink brought back the 403 ns that the
instructions actually take.

It is the same class of mistake as the two in the I/O spike: a benchmark that
is wrong in a plausible direction. Three for three, all found by disbelieving a
number rather than by reading code.

## Reproducing

```
sh build.sh --crypto-probe && ./build/crypto_probe
build.bat --crypto-probe  && build\crypto_probe.exe
```

`-maes -mpclmul` enable the intrinsics on GCC; MSVC needs no switch. The probe
asks CPUID before executing either instruction set, the way the engine already
does for POPCNT and BMI2 — so the binary runs on a machine that has neither and
reports what it found.
