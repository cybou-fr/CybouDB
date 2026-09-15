# The recovery phrase

*Step 6 of `0.7`. The second way into a database, and the reason the first one
can fail without anybody losing anything.*

`docs/RECOVERY.md` is about a database recovering from a crash. This is about a
person recovering from a lost key, which is a different problem with a
different failure mode: a crash is survived by checking what the file says, and
a lost key is survived only by having arranged something beforehand.

---

## Why there are two doors

[PQ_KEM.md](PQ_KEM.md) seals the root key to an ML-KEM public key and says
plainly what that risks: someone who records an encrypted database today and
breaks ML-KEM later recovers the KEK. One of the two mitigations named there is
this document.

The recovery path is **not a backup of the private key**. It is an independent
secret, 256 bits of it, that wraps the same root:

```text
           ML-KEM slot ────decaps + KDF────┐
                                           ├──▶ a KEK ──unwraps──▶ root key
   recovery secret ────────────KDF─────────┘
```

Two consequences worth stating rather than implying:

* **A total break of ML-KEM does not lock anyone out.** The recovery path is
  not a public-key problem at all - there is nothing in the file for an
  adversary to attack offline except a 256-bit secret nobody stored.
* **The recovery path is exactly as strong as the file's weakest door.** Both
  doors open the same root, so the phrase is not a lesser credential to be
  kept somewhere convenient. It is the key, written down.

## What the phrase encodes, and what it does not

Twenty-four words, eleven bits each: 264 bits, being 256 bits of secret and an
8-bit checksum. That is the structure BIP-39 uses, and the structure is where
the resemblance stops.

* **The secret is the secret.** BIP-39 stretches its entropy into a seed with
  PBKDF2; there is nothing to stretch here, because the 256 bits are drawn from
  the operating system's random generator rather than from anything a person
  chose. Stretching a uniform 256-bit secret buys nothing and would mean
  carrying HMAC-SHA512 to buy it.
* **The checksum is SHAKE256, not SHA-256**, and it is domain-separated with
  this format's own tag. A phrase written by CybouDB is therefore *not* a valid
  BIP-39 phrase, and that is deliberate: a database recovery phrase and a
  wallet seed should not be interchangeable enough that someone types one into
  the other. A wallet will reject ours, which is the correct outcome, and it
  costs nothing because the phrase was never meant to travel.

**A mistyped phrase is its own error and not a wrong key.** The checksum makes
one decidable without touching the file: `CybouDB_E_PHRASE` means *that is not
a phrase this build wrote*, where `CybouDB_E_KEY` means *this phrase is
well formed and does not open this file*. Those are different sentences for
the same reason damage and a wrong key are, and the second one is what a person
gets when they hold a perfectly good phrase for a different database.

## What the file stores

One slot in the crypto root's existing table, flagged as a recovery slot:

```text
key_id (8) | flags = recovery | wrapped root key (72)
```

* **The key id is random, not derived from the secret.** Deriving it - a
  truncated hash, say - would publish a function of the secret in the file, and
  a published function of a secret is a thing an adversary can test guesses
  against. 256 bits makes that infeasible rather than possible, which is an
  argument for not caring; not publishing it is an argument for not needing to
  care.
* **No salt, no iteration count, no parameters.** There is nothing to tune
  because there is no password-based derivation. A file that recorded a work
  factor would be recording a decision it never made.

## What is in this step and what is not

Built: the 264-bit encoding and its checksum, the recovery secret, the slot,
and sealing and opening the root through it. Tested the way the rest of the
crypto is - the phrase round-trips, a single altered word is caught by the
checksum, a well formed phrase for another database is `CybouDB_E_KEY` and not
damage.

**Not built: the English words.** The encoding produces twenty-four indices in
`[0, 2048)` and stops there, because the wordlist is the one part of this that
must not be improvised. A list with one wrong word in it is a phrase that
cannot be restored by anybody, including us, and the machine this was written
on has no copy of the BIP-39 wordlist to check against. So the indices are the
interface for now, the wordlist arrives as a checked-in file with a generator
and a digest beside it the way every other table in this project does, and
until then `cyboudb_recovery_*` speaks in numbers.

That is a real gap and it is named here rather than papered over: a user cannot
write down twenty-four numbers and call it a recovery phrase. What they can do
is hold the 256-bit secret, which is what the engine actually uses, and what
the words are a spelling of.
