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
  ok   Poly1305 is the same tag whatever the chunking
```

Both passed on the first run on both platforms. The two chunking checks are
there because an implementation that is right only when the caller hands it
whole blocks is a bug waiting for a 4095-byte page.

The AES-NI and PCLMULQDQ numbers below are **throughput only and unvalidated**.
They answer *how much does hardware change the decision*, and nothing else. If
AES becomes the shipped primitive it arrives with RFC 8452's vectors attached.

## The numbers, per 4096-byte page

Both machines report AES-NI, PCLMULQDQ, SHA-NI, AVX2 and RDSEED present.

| | Linux (gcc -O2) | Windows (cl /O2) |
| :--- | ---: | ---: |
| ChaCha20, portable C | 7,207 ns · 0.57 GB/s | 7,444 ns · 0.55 GB/s |
| Poly1305, portable C | 1,989 ns · 2.06 GB/s | 1,716 ns · 2.39 GB/s |
| **ChaCha20-Poly1305, sealing one page** | **9,300 ns** | **9,161 ns** |
| AES-128-CTR, AES-NI | 286 ns · 14.3 GB/s | 280 ns · 14.6 GB/s |
| carry-less multiply chain, PCLMULQDQ | 403 ns · 10.2 GB/s | 369 ns · 11.1 GB/s |
| **hardware AEAD, the two terms together** | **~690 ns** | **~650 ns** |

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

## Two things this does not say

**It does not say ChaCha20 is slow.** It says *this* ChaCha20 is 0.57 GB/s: a
straightforward scalar implementation at `-O2`, with no SIMD. A vectorised
ChaCha20 reaches several GB/s, and the gap to AES-NI narrows accordingly. What
the measurement bounds is the cost of the implementation a project writing its
own backend ships **first** — and the decision about what to ship first is
exactly what step 3 is for.

Hoisting the cipher state out of the per-block loop changed nothing (7,439 ns
against 7,326 ns), which is how the measurement was confirmed to be timing the
twenty rounds rather than the setup around them.

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
