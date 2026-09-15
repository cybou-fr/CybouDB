# The post-quantum key path

*Step 3.5 of `0.7`. What lets a private key open a database, and why that key
is an ML-KEM key.*

Nothing here is implemented yet. This document is the decision record that the
implementation is held to, written before the assembly for the reason every
crypto document in this project is: the wrong structure built correctly is
worse than the right structure built slowly, because it looks finished.

---

## What problem this solves

[KEY_HIERARCHY.md](KEY_HIERARCHY.md) ends at a root key. Everything below it -
the metadata KEK, the page seal keys, the seal tree key, the scoped KEKs -
derives from that root, and the file holds none of them in the clear. What it
does not say is where the root comes from when a person opens the file.

A passphrase is one answer and a bad one to be the only answer: it is
guessable, it is typed into things, and it cannot be given to a service without
being given away. The answer this release wants is the one an operator already
understands:

> **The file is sealed to a public key. Opening it needs the private key, and
> the private key never enters the file, the process image of anyone else, or
> a backup of the database.**

A key encapsulation mechanism is exactly that shape. The holder of the public
key produces a ciphertext and a shared secret; the holder of the private key
recovers the shared secret from the ciphertext and nothing else does. The file
stores the ciphertext - it is not secret - and the shared secret is what
unwraps the root.

## Decision 1 - a KEM, not public-key encryption of the root

The temptation is to encrypt the 32-byte root directly under a public key and
be done. Two reasons not to:

* **ML-KEM is a KEM and not an encryption scheme.** FIPS 203 standardises
  encapsulation. Building an encryption scheme on top of its internal PKE is
  exactly the sort of improvisation that produces something that passes its own
  tests. The KEM's own security argument - the Fujisaki-Okamoto transform, with
  implicit rejection - is what the standard analyses, and it is not the thing
  being analysed if the internal PKE is used directly.
* **A KEM composes with what is already here.** The shared secret goes through
  the existing KDF and the existing AEAD wrap: nothing about the key hierarchy
  changes, and the post-quantum part of the system ends at one 32-byte value.

```text
ML-KEM ciphertext (in the crypto root, not secret)
        │
        │ decapsulate with the holder's private key
        ▼
   shared secret (32 bytes)
        │  KDF(KDF_METADATA_KEK, shared_secret, "kem-slot" | slot id)
        ▼
      a KEK ──unwraps──▶ the database root key ──▶ everything in KEY_HIERARCHY
```

The post-quantum surface is one arrow wide. That is the property worth having:
if ML-KEM is replaced in five years, what changes is what produces the shared
secret, and not one thing below it.

## Decision 2 - ML-KEM-768

| | ek | dk | ct | category |
| :--- | ---: | ---: | ---: | :--- |
| ML-KEM-512 | 800 | 1632 | 768 | 1 |
| **ML-KEM-768** | **1184** | **2400** | **1088** | **3** |
| ML-KEM-1024 | 1568 | 3168 | 1568 | 5 |

768. Category 3 is the level at which the interesting comparison is against
AES-192 rather than AES-128, the sizes are nothing next to a 4 KiB page - a
1088-byte ciphertext fits in the crypto root's slot area with room for several
- and it is the parameter set the rest of the world is defaulting to, which
matters for a file format that other tools may one day have to read.

1024 buys a margin the threat model does not ask for and costs a 1568-byte
ciphertext and a slower open. 512 is category 1 and is not what a database
sealed for a decade should pick.

## Decision 3 - ML-KEM alone, for now, and what that risks

The alternative is hybrid: derive the KEK from an ML-KEM secret **and** an
X25519 secret, so a break in either leaves the other standing. It is what
TLS deployed (`X25519MLKEM768`), and the argument for it is real: ML-KEM is
young, and a structural break would be a bad way to find out.

This release ships ML-KEM alone, and the reasons are specific rather than
dismissive:

* **The failure mode is not what it is in TLS.** A TLS handshake that turns out
  to be breakable was breakable at the moment it happened, and the recording
  already exists. A database key can be rotated: `0.7` has key epochs and
  rewrapping as steps 15 and 16 precisely so that a key decision is not
  permanent.
* **There is a second, independent path to the same root** - step 6's
  twenty-four words - which is not post-quantum at all in the sense that
  matters here: it is a high-entropy secret the user holds, not a public-key
  problem an adversary can attack offline. A total break of ML-KEM does not
  lock anyone out, and does not make that path weaker.
* **A hybrid needs X25519, which this project does not have**, and adding a
  second asymmetric primitive to get a hedge is a larger and less honest
  increment than saying which one is carrying the weight.

What that risks, stated plainly: an adversary who records an encrypted database
today and breaks ML-KEM later recovers the KEK of the slots sealed to a public
key, and through it the root and the file. The mitigations are rotation and the
recovery path, not a second primitive. **If hybrid becomes the right answer it
arrives as a new slot kind with its own number, not as a reinterpretation of
this one** - the same rule the format applies everywhere else.

## Decision 4 - what the file stores, and what it does not

A slot in the crypto root, for each public key the database is sealed to:

```text
kem slot: key id | ML-KEM ciphertext (1088) | wrapped root key (72)
```

* **Not the public key.** It is not secret, but storing it invites an opener to
  believe the file about which key it needs, and the answer to *which key opens
  this* is *try yours*. A key id - a hash of the encapsulation key, truncated -
  is enough to say *this slot is probably yours* without being an authority on
  it.
* **Not the private key, in any form, ever.** This is the claim the whole
  design exists to make, and it is falsifiable: nothing in the write path takes
  a decapsulation key as an argument.
* **The ciphertext, in the clear.** It is public by construction. Its integrity
  is covered by the crypto root's MAC, and an altered ciphertext produces a
  shared secret that does not unwrap the root - which is
  `CybouDB_E_KEY`, *this key does not open this file*, and not damage.

## Decision 5 - implicit rejection is kept, and what it means here

FIPS 203's decapsulation never fails. A ciphertext that does not re-encrypt to
itself yields a shared secret derived from a per-key secret `z` instead of an
error, so an attacker learns nothing about *why* a ciphertext was rejected.

The temptation is to "improve" this by reporting a decapsulation failure,
because a database that says *this ciphertext is wrong* is friendlier than one
that says *this key does not open this file*. It is not kept for friendliness:
the engine gets a 32-byte value either way, it tries to unwrap the root with
it, and the unwrap fails. The user sees the sentence that is true in both
cases. **Nothing in the engine may branch on a KEM result**, and the AEAD's tag
is the only thing that decides whether a key was right.

## What has to be constant time, and what does not

| | |
| :--- | :--- |
| the NTT and pointwise multiply | secret polynomials pass through them - no data-dependent branches or memory indices |
| centred binomial sampling | operates on PRF output that is secret |
| compression and decompression | the message polynomial is secret; the division by q must not be a real division on secret data |
| the FO re-encryption in decapsulation | it handles the recovered message |
| **rejection sampling of the matrix A** | **public**: A is derived from the public seed rho, so its variable-time loop leaks nothing |

The last row is not an exception being granted, it is the one place where
variable time is provably harmless, and stating which is which up front is what
stops the question being reopened per function.

## How this gets tested

The project has no network, and this is the first primitive where writing a
second implementation to check the first would mean writing ML-KEM twice.
There is a better witness on the machine: **OpenSSL 3.5 implements ML-KEM-768**,
so the test is interoperation in both directions rather than a table of
constants.

0. **Same seed, same key pair.** OpenSSL stores the 64-byte `(d, z)` seed and
   will print it, so key generation is checkable directly rather than only
   through its consequences: from their seed our `ek` and `dk` must be theirs,
   byte for byte. This is the strongest of the five, because it pins every
   internal step - the matrix sampling, the noise sampling, the NTT and the
   encodings - instead of pinning only the composition that survives them.
1. **They encapsulate, we decapsulate.** OpenSSL generates a key pair and a
   ciphertext; our decapsulation must recover their shared secret.
2. **We encapsulate, they decapsulate.** Against their public key, and their
   decapsulation must recover ours.
3. **Round trip against ourselves**, for every path that the two above do not
   reach.
4. **Implicit rejection**: a flipped bit in the ciphertext must give a shared
   secret that is stable, unequal to the true one, and produced without any
   error being reported.
5. **The pieces, separately**: the NTT against its inverse, the samplers'
   distribution, and compression round trips at every coefficient - because a
   KEM that interoperates can still have a component that is wrong in a way
   the composition hides.

A fixture generated by OpenSSL is checked into the repository so that the suite
does not need OpenSSL installed to run, and the generator is checked in beside
it so the fixture can be regenerated and is not a magic file.

---

## What step 3.5 owes

| | |
| :--- | :--- |
| the arithmetic | Zq, the NTT, pointwise multiplication, and a test that the forward and inverse transforms are inverses |
| sampling | rejection sampling from SHAKE128 for A, centred binomial from SHAKE256 for the secrets |
| serialisation | byte encoding and the compression of `du = 10`, `dv = 4`, round-tripped per coefficient |
| the PKE, then the KEM | K-PKE, then the FO transform with implicit rejection |
| interoperation | both directions against OpenSSL 3.5, with a checked-in fixture |
| constant time | no secret-dependent branch or index, argued per function against the table above |

ML-DSA is the other half of step 3.5 and is **not** in it: signatures are what
step 10's access manifest needs, and nothing before step 10 uses one. It gets
its own document when its step arrives, and the sponge it needs is already
here.
