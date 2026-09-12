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

## Inspecting a file

```sh
cyboudb info  app.cdb     # header, chosen generation, page counts
cyboudb check app.cdb     # validate the live generation
```

`check` reports `Status: OK` when the selected generation validates, including
the case where it had to fall back to the older copy — falling back is a
successful recovery, not a warning.
