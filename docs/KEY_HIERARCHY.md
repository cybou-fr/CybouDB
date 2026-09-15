# The key hierarchy

Step 4 of `0.7`. The page seal works and is measured
([CRYPTO_BACKEND.md](CRYPTO_BACKEND.md)); what it does not have is a key. This
says where keys come from, what each one is allowed to open, and what happens
when one of them has to change.

Nothing here is implemented. Where a decision belongs to step 5 or 6 — how a
post-quantum private key or twenty-four words reach the root — this states the
requirement and stops.

---

## The shape

```text
                     PQ private key            24 words
                           │                      │
                           ▼                      ▼
                     unwrap KEK  ◄────────────►  recovery KEK
                           │                      │
                           └──────────┬───────────┘
                                      ▼
                            ROOT KEY, 32 bytes
                                      │
                       KDF, one label per purpose
                                      │
        ┌──────────────┬──────────────┼──────────────┬──────────────┐
        ▼              ▼              ▼              ▼              ▼
   metadata KEK   page seal key   scope KEK     manifest key    seal-tree key
   (wraps DEKs)   (per epoch)     (per scope)   (step 10)       (Decision 3b)
```

Four rules give that picture its meaning, and each one is a refusal of
something simpler:

**1. The root key is never used to encrypt anything.** It exists to derive and
to be wrapped. A key that both protects data and sits at the top of a hierarchy
cannot be rotated without rewriting everything under it.

**2. Every derived key has exactly one purpose, named in its derivation.** The
page seal key cannot be used to unwrap a DEK, because the KDF was given a
different label — not because the code declines to. Domain separation that
depends on the code being careful is a comment, not a boundary.

**3. Two independent paths reach the root, and neither can reach the other.**
A compromised post-quantum key does not force a new mnemonic, and a new
mnemonic does not invalidate the key. Both wrap the same root; neither is
derived from the other.

**4. Nothing in the file can produce the root.** The file holds the root
wrapped, twice, under two key-encryption keys it does not contain. That is the
claim [ENCRYPTION.md](ENCRYPTION.md) makes testable: no key material is
derivable from the file alone.

---

## Decision 1 — the KDF is SHAKE256, and the reason is not cryptographic

The obvious choice is HKDF-SHA256: boring, universal, RFC 5869, official
vectors. It would need SHA-256 and HMAC — two constructions, both new to this
repository.

SHAKE256 needs one: Keccak-f[1600]. And **the same permutation is what ML-KEM
and ML-DSA are built on** — FIPS 203 and 204 use SHA3-256, SHA3-512, SHAKE128
and SHAKE256 throughout. Steps 5 and 3.5 need Keccak whatever this document
decides; choosing it here means the key hierarchy and the post-quantum key
agreement share a single audited primitive instead of carrying SHA-2 alongside
it for one purpose.

```text
HKDF-SHA256        SHA-256 + HMAC construction + HKDF        two new pieces,
                                                             unused later

SHAKE256           Keccak-f[1600] + sponge                   one new piece,
                                                             ML-KEM needs it
                                                             anyway
```

So: **derivation is SHAKE256**, in the form NIST SP 800-56C calls a one-step
KDF — the derived key is the sponge output of a fixed label, the root key, and
the context. Not an invention: a hash-based one-step KDF is exactly what that
document specifies, and SHAKE is an approved auxiliary function for it.

Held to the NIST SHA-3 and SHAKE known-answer vectors, like everything else in
this backend. If those vectors cannot be made to pass, this decision is wrong
and HKDF-SHA256 is the fallback, at the cost of the second primitive.

---

## Decision 2 — derivation is by label, and the labels are a closed list

```text
key = SHAKE256( "CybouDB/0.7/" ‖ purpose ‖ 0x00 ‖ root ‖ context , length )
```

| purpose | context | what it opens |
| :--- | :--- | :--- |
| `metadata-kek` | *(empty)* | wraps the data encryption keys |
| `page-seal` | `seal_epoch` as 8 bytes | seals pages, one key per epoch |
| `seal-tree` | `seal_epoch` | the keyed tree over the seal directory |
| `scope-kek` | the scope id | wraps one namespace's DEKs |
| `manifest` | `manifest_epoch` | signs and verifies the access manifest |

Two properties this buys:

* **an epoch change is a key change, for free.** Rotating `seal_epoch` derives
  a different page seal key from the same root, so a rotation writes a number
  into the crypto root rather than rewriting a key hierarchy;
* **the list is closed.** A purpose that is not in this table does not exist,
  and adding one is a format change with a version bump behind it — not a
  string a caller can pass in. A KDF whose label is caller-supplied is an
  oracle wearing a helpful interface.

---

## Decision 3 — wrapping is the AEAD that already exists

A wrapped key is a sealed key. `src/crypto/aead.asm` already does
authenticated encryption with associated data; a data encryption key is 32
bytes of plaintext, and the thing that must be bound to it is *which* key it
is:

```text
wrapped DEK = XChaCha20-Poly1305(
                  key   = metadata KEK,
                  nonce = 24 random bytes, stored beside it,
                  aad   = key_id ‖ scope_id ‖ purpose ‖ seal_epoch,
                  data  = the 32-byte DEK )
```

**No new construction, and therefore no new mistakes.** A dedicated key-wrap
algorithm — AES-KW and its relatives — exists because some systems need to wrap
without a nonce. This one has a nonce source and an AEAD that is already held
to published vectors, so the argument for a second construction is that it
would be more specialised, which is not an argument.

The associated data is what stops a wrapped key being moved: a DEK for scope A
presented as the DEK for scope B fails to unwrap, rather than unwrapping into
the wrong scope.

---

## Decision 4 — what the crypto root page holds

[ENCRYPTED_FORMAT.md Decision 6](ENCRYPTED_FORMAT.md#decision-6--where-the-keys-live-and-what-the-superblock-points-at)
put a pointer at `SB_FEATURE_ROOT`. This is what it points at:

```text
crypto root
├─ version and the AEAD identifier          (Decision 4 of the format)
├─ kdf_salt                 32 bytes, from os_random at creation
├─ seal_epoch               8
├─ manifest_epoch           8
├─ root wrapped under the unwrap KEK        nonce ‖ ciphertext ‖ tag
├─ root wrapped under the recovery KEK      nonce ‖ ciphertext ‖ tag
├─ wrapped DEKs, by key id                  each: id, scope, nonce, ct, tag
├─ manifest root                            (step 10)
└─ seal directory geometry                  first page, S
```

**The root appears twice and the plaintext root appears nowhere.** Losing both
wrappings is losing the database; that is the property being bought, and the
documentation will say so in those words rather than implying a recovery path
that does not exist.

---

## Decision 5 — what rotation can and cannot do

Rotation is a word that promises more than any storage engine can deliver, so
this states the four cases separately:

| what changed | what it costs | what it does not do |
| :--- | :--- | :--- |
| the **post-quantum key** | re-wrap the root under a new unwrap KEK: one page | nothing about data already written |
| the **mnemonic** | re-wrap the root under a new recovery KEK: one page | nothing about data already written |
| the **seal epoch** | new page seal key; pages are re-sealed as they are next written | old pages stay under the old key until rewritten |
| a **scope DEK** | re-wrap, and re-encrypt that scope's pages | a reader who already had the old DEK keeps what it could already read |

The last row is the one that matters and the one most likely to be softened
later. [ENCRYPTION.md](ENCRYPTION.md#access-already-granted) already says it:
rotation is forward secrecy for future writes and nothing retroactive. A
`cyboudb rekey` that claims to have re-encrypted a database must also say what
it did about the copy-on-write free space, where superseded ciphertext sits
until its page is reused.

---

## What step 4 owes

| | | |
| :--- | :--- | :--- |
| Keccak-f[1600] and SHAKE256 in assembly | against the NIST SHA-3 and SHAKE known-answer vectors, both platforms | done |
| the derivation function | one entry point, the closed label list, and a test that two purposes never produce the same key | done - `src/crypto/kdf.asm`, all ten pairs |
| wrap and unwrap | over the existing AEAD, with a test that a DEK for one scope does not unwrap in another | done - a refused unwrap leaves zeroes, not a plausible key |
| the crypto root's byte layout | a `%define` map like every other page in this format, and a validator that refuses a malformed one | done - `include/crypto.inc`, `src/crypto/crypto_root.asm`, 39 checks |
| what happens when unwrapping fails | a database that cannot be opened must say *this key does not open this file*, not *corrupt* - the same distinction `0.6` drew between a capability refusal and damage | next |

Steps 5 and 6 then attach the two paths to the root: a post-quantum private key
and twenty-four words. Neither changes anything above.
