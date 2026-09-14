# The crypto backend

Step 3 of `0.7`. The threat model said what must be protected, the format
design said what the file looks like and left step 3 an *acceptance
requirement* rather than a free choice of primitive, and the
[measurement](../benchmarks/results/2026-09-15-crypto-primitives.md) says what
each candidate costs. This decides what CybouDB implements, where the code
comes from, and what it is held to.

Nothing here is implemented yet. The measured implementations in
`benchmarks/crypto_probe.c` are a probe, not the backend.

---

## The constraint that decides most of it

**The ciphertext must not depend on the machine that wrote it.**

A `.cdb` file written on a laptop must open on a server, on a CPU a decade
older, on the other operating system. That single sentence eliminates the
obvious cheap answer — *use whatever the platform provides* — because Windows
CNG and Linux's kernel crypto do not offer the same set of constructions, and
a file sealed with one of them would be readable only where that one exists.

It also means the choice of AEAD is a **format decision, not a runtime one**.
A build may choose how fast it computes the primitive; it may not choose which
primitive the bytes are under. That distinction is the spine of everything
below.

---

## Decision 1 — CybouDB implements the primitives, and does not invent any

The engine has no libc, no CRT, and a platform surface it can list on one hand.
Linking a crypto library would bring a C runtime with it and end that property;
calling the OS would break the constraint above. So the primitives live in this
repository.

That is a dangerous sentence, and the danger is answered by what it is *not*:

* **nothing is invented.** Every primitive is a published construction with
  published test vectors. The project's contribution is an implementation, not
  a design, and a novel construction here would be a reason to stop;
* **every primitive ships with official known-answer vectors, in CI.** The
  probe already holds ChaCha20 and Poly1305 to RFC 8439 sections 2.3.2 and
  2.5.2, copied from the RFC rather than from another implementation;
* **the fallback path is tested on machines that do not need it.** The engine
  already forces its POPCNT and BMI2 fallbacks independently of the host CPU
  ([HARDENING.md](HARDENING.md)), and a crypto backend inherits that discipline
  rather than inventing a new one;
* **the random source is the operating system's**, never ours — `os_random`,
  decided in [ENCRYPTED_FORMAT.md](ENCRYPTED_FORMAT.md#decision-8--a-cryptographic-random-source-and-what-it-costs-to-have-one).

If any of those four stops being true, the decision should be revisited rather
than defended.

---

## Decision 2 — the page AEAD is XChaCha20-Poly1305

It satisfies the step 2 acceptance requirement by its second route: a **192-bit
random nonce per write**, so a repeat needs a birthday collision across 2⁹⁶
writes rather than a counter that has to survive every crash path. The seal
directory already reserves 24 bytes for a nonce, which is not a coincidence —
the format was sized for this shape before the primitive was chosen.

Three reasons it wins here, and the one thing it loses:

**It is the same speed for everyone, and the same bytes.** ChaCha20 is ARX:
adds, rotates, xors. There is no table, so there is no data-dependent memory
access, so a machine without hardware support runs *slower* but not
*differently* — and, importantly, not with a cache-timing side channel. An
implementation may be scalar or vectorised, and the output is identical either
way. Speed becomes a build detail; the ciphertext stays a format fact.

**AES without AES-NI is the trap.** Table-driven AES leaks through the cache,
and constant-time software AES is bitsliced, several times slower than this
ChaCha20, and considerably harder to write correctly. Choosing AES for the
format means either requiring AES-NI — which the compatibility promise does not
let us do to a file — or owning a bitsliced implementation. Measured hardware
AES at 14 GB/s is a real attraction, and it is an attraction to a cliff.

**A 24-byte nonce is what the crash model needs.** The rolled-back-transaction
problem in
[Decision 4](ENCRYPTED_FORMAT.md#decision-4--the-nonce-is-stored-because-deriving-it-is-unsafe-here)
is solved by randomness of a size that makes the argument statistical rather
than procedural.

**What it loses: throughput on hardware that has AES-NI**, which is most x86-64
sold since 2010. 9.3 µs per page against ~0.7 µs is not a rounding error, and
pretending otherwise would be the kind of claim this project does not make. The
answer is Decision 3, not a shrug.

---

## Decision 3 — the implementation is dispatched; the format is not

```
                 XChaCha20-Poly1305            (what the file says)
                          │
        ┌─────────────────┴─────────────────┐
   AVX2 / SSE                            scalar
   chosen by CPUID                    always correct
        └─────────────── identical bytes ───┘
```

The engine already dispatches on CPUID in three places and tests both sides.
The crypto backend does the same, and gains something the existing dispatches
do not have: **the two paths must produce identical output**, which is a
property a test can assert directly rather than a benchmark's opinion.

Measured, the scalar path costs 9.3 µs per page. A vectorised ChaCha20 is
expected to reach single-digit GB/s and bring a sealed page to roughly 2 µs —
comparable to the 3.3 µs a page miss costs on NTFS. **That expectation is not
yet a measurement, and step 3 is not finished until it is one.** If a vectorised
implementation does not get there, the honest options are to accept that an
encrypted database is slower by a stated factor, or to revisit Decision 2 with
the cost of a bitsliced AES in hand — and not to quietly ship the slow one with
the fast one's description.

---

## Decision 4 — the file records which AEAD sealed it

One byte in the crypto root, not an assumption. `XChaCha20-Poly1305` is
identifier 1 and the only one `0.7` implements; a reader that meets an
identifier it does not know refuses the file by name, exactly as it refuses an
unknown feature bit.

This costs nothing now and buys the thing this document cannot otherwise have:
a way to add AES-256-GCM-SIV later — for a deployment that knows every reader
has AES-NI — without a format break and without a migration. It also means the
decision above can be *wrong* without being fatal, which is worth a byte.

---

## Decision 5 — the key hierarchy's primitives are chosen later, and separately

ML-KEM and ML-DSA run when a database is opened, when a key is granted, when a
manifest is signed. They do not run per page. They are therefore a different
acceptance question with a different budget — a millisecond at open is
invisible, a millisecond per page is not — and nothing in this document decides
them. Steps 4 through 6 do, with their own vectors and their own measurement.

What this document does fix for them: they are implemented under the same four
rules as Decision 1, and a post-quantum primitive that cannot be held to
official vectors does not ship.

---

## What step 3 still owes

| | |
| :--- | :--- |
| a vectorised ChaCha20, measured | Decision 3 rests on an expectation |
| XChaCha20's own vectors | the HChaCha20 construction has published test vectors of its own; ChaCha20's do not cover it |
| a Poly1305 one-time-key derivation check | the AEAD derives its MAC key from the cipher; that wiring has its own vector in RFC 8439 section 2.8.2 |
| constant-time review of Poly1305's final reduction | the probe's version branches on nothing, but that is an assertion until someone checks the generated code |
| the cost of `os_random` per page | a 24-byte nonce per write is a syscall unless it is buffered, and a buffered CSPRNG is a design with a crash story |

The last one is the sort of thing that looks like an implementation detail and
is not: a nonce that comes from a buffer refilled on a schedule has to be
correct across a crash in the middle of the refill, and that is a small design
rather than a small function.
