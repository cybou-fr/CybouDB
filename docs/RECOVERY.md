# Recovery

There is no recovery pass, no log to replay and no repair step. Opening a
database *is* the recovery: `db_open` selects the newest generation that proves
itself sound and refuses the file otherwise. This document says what "proves
itself" means, in the order the checks actually run.

## Open

**1. Lock.** A writable open takes an exclusive advisory lock on byte 0; a
read-only open takes a shared one and pins byte 1. A conflict is
`CybouDB_E_BUSY` and the file is closed again.

**2. Map the file.** A file shorter than the three metadata pages is
`CybouDB_E_SMALL`.

**3. The header, page 0.** Magic, `header_size`, `format_version`, `page_size`
and the CRC over `[0, 124)`, each with its own error code
(`E_MAGIC`, `E_VERSION`, `E_PAGESIZE`, `E_HDR_CRC`). The header is immutable, so
a header that does not verify is not a crash — it is a foreign or damaged file.

**4. Feature bits.** Every bit in `flags_incompat` must be one this build
implements, and every dependency must be satisfied (see
[FORMAT.md](FORMAT.md#feature-bits)). A dependent bit without its prerequisite
is `CybouDB_E_FEATURES`, as is any unknown bit. The superblock locations must
be the ones version 1 fixes, or `CybouDB_E_GEOMETRY`.

**5. Choose a superblock.** Both copies are examined independently. A copy is a
candidate only if all of the following hold:

- magic and `sb_size` are right;
- the reserved tail is entirely zero;
- `staged` is zero — an on-disk superblock that claims to be a work in progress
  is not a publication;
- the CRC over `[0, 124)` verifies;
- the allocation map that copy names validates, which for a file with feature
  bits means walking the typed graph it roots.

The candidate with the higher generation wins. If neither qualifies, the open
fails with `CybouDB_E_SUPERBLOCK`.

This is the whole of crash recovery. A commit interrupted between steps leaves
a half-written copy that fails one of the checks above, and the other copy —
the previous generation, untouched by definition — is selected instead.

**6. Geometry.** The chosen superblock must agree with the file: `total_pages`
within the maximum and exactly matching the file size,
`MIN_PAGES <= allocated_pages <= total_pages`, and the free-list and catalog
roots either zero or inside the allocated range. Anything else is
`CybouDB_E_GEOMETRY`. A non-zero `feature_root` is `CybouDB_E_FEATURES`.

A checksummed superblock alone is not evidence that the pages it names are
valid, which is why the map validation in step 5 and the geometry checks here
are not optional shortcuts.

## The allocation floor

Both superblocks' `allocated_pages` values are noted before either is chosen,
and the higher becomes the floor below which the reopened writer will not
allocate — even when the copy it came from was rejected. A rejected copy can
still have had pages written under it, and handing those page ids out again
would let an unpublished generation reappear inside a live one.

## What survives a crash

- **Committed generations.** Whatever was published before the crash is what
  the next open sees.
- **The previous generation.** One generation back is recoverable by
  construction, since a commit never writes the live copy. With the span
  layout, that older generation ends when a writer first allocates rather than
  at commit, because the writer mutates the inactive map copy in place.
- **Nothing uncommitted.** Staged pages are unreachable from either superblock
  and are simply reclaimed.

## What is not defended against

Recovery answers the question "which published generation is intact". It does
not answer "is this file the one I think it is", and it cannot:

- a failed sync means the outcome is genuinely unknown — the engine poisons the
  handle and requires a reopen precisely because reopening is the only way to
  find out which generation actually landed;
- storage that acknowledges a flush without performing it defeats the protocol,
  as it defeats every journalling scheme;
- two processes writing the same file at once is prevented by the advisory
  lock, not survived by recovery;
- a page damaged in a way that keeps its checksum consistent is caught only if
  it also breaks a structural invariant the graph walk checks.

## Three questions, three answers

These were one mechanism for a long time, and they are not one question:

```text
recovery    an ordinary open finds the newest generation that validates,
            and falls back to the one before it when the newest does not.
            Falling back is success.

commit      proves that what this transaction is about to publish is a
            well-formed graph. See docs/COMMIT_VALIDATION.md.

integrity   says whether the file is damaged - including damage an
            ordinary open recovers from, which by construction is the
            damage recovery cannot report.
```

`cyboudb check` is the third. It used to be the first, which meant it answered
"a valid state could be recovered from this file" while appearing to answer
"this file is healthy". A damaged newest generation reported `Status: OK`
because an older one was intact, which is precisely the case where a person
needs to be told: the database keeps working, quietly on the older state.

## Inspecting a file

```sh
cyboudb info  app.cdb     # header, chosen generation, page counts
cyboudb check app.cdb     # is this file damaged?
```

`check` opens with `CybouDB_VERIFY_DEEP | CybouDB_VERIFY_INTEGRITY`: every page
is proved from scratch, and a superblock whose *own checksum verifies* while
the graph it publishes does not is reported as damage, with a non-zero exit
status.

The distinction that makes this usable is between damage and residue:

```text
the superblock itself is torn or fails its checksum
    -> the ordinary residue of an interrupted publication.
       This is what the two copies are for. Status: OK.

the superblock verifies, and the graph it published does not
    -> pages the engine had already proved have been damaged since.
       Status: damaged, and a non-zero exit.
```

Nothing about an ordinary open changed. It still recovers, still silently, and
still reports success — that is the right answer to the question it is asked.
`tests/integrity_tests.py` holds both halves to that.
