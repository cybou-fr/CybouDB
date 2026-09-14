# The 0.6 release gate: what a released 0.5 does with a lease file

`0.6` adds a capability that changes what a queue page may legally contain, and
the format's promise about that is not *0.5 understands it* but *0.5 refuses it
and says why*. That promise was tested throughout development against
`build.sh --no-leases`, a build of this tree with the bit dropped from the mask
of what it understands. That model is good and it is not a released binary:
it shares every bug this tree has, including any bug in the refusal itself.

So it was asked of the real ones, once, before tagging.

## What was run

Four executables, downloaded from the GitHub release page on 2026-09-14 and
verified against the `SHA256SUMS` published beside them:

```
9a679d1af360901b827094705378788b5138948fcc79ab2cb36d2fd5cb83c379  cyboudb-0.5.0-preview.1-linux-x86_64.tar.gz
330675c8d4677588b376b1cf78719a4b61f1618b605a7743955ccdf7d9d5e62b  cyboudb-0.5.0-preview.1-windows-x64.zip
685004fb73e01a363c83cafa01d745bf6df6a50e5c75e01e35d43a5f699cf37d  cyboudb-0.5.0-preview.2-linux-x86_64.tar.gz
8d4858110a6c9b4e58eda949f35fd5e83d483d65030a2eadefba394fa9236955  cyboudb-0.5.0-preview.2-windows-x64.zip
```

against a fixture made by the build under test at `cae4bd3`: a `create-leases`
database with a queue, a message, and **a lease actually outstanding** rather
than merely the capability bit set - so a reader that ignored the bit would
meet a `CLAIMED` slot and a non-zero `QSEG_READY_AT`, which is the state that
would read as damage.

The script is `tests/release_gate_leases.sh`. It is not part of the suite: it
needs binaries that are not in this repository, and it answers a question that
only has to be answered once per release.

```sh
sh tests/release_gate_leases.sh ./cyboudb <released>...
```

## What it asserts

1. `info`, `check` and a statement against the lease file **all fail**, and all
   say *incompatible features*. The wording is the assertion, not just the
   failure: a `0.5` that called this a damaged queue would send an operator
   looking for a broken disk, and would be wrong in the one direction that
   costs a day.
2. The same three against an ordinary `create` database **succeed** - the
   refusal is about the capability, not about the release.
3. The lease file is **byte-identical afterwards**. A refusal that stamped a
   generation, or tried a repair, would be a `0.5` binary editing a file it has
   just said it does not understand.
4. The build under test still accepts the file the released ones refused, so a
   green run cannot be a fixture that is simply broken.

## The result

Linux, under WSL:

```
.../cyboudb-0.5.0-preview.1-linux-x86_64/cyboudb
  reports: CybouDB 0.5.0-preview.1
  info on a lease file is refused            ok
  check on a lease file is refused           ok
  query on a lease file is refused           ok
  and an ordinary file still works           ok
.../cyboudb-0.5.0-preview.2-linux-x86_64/cyboudb
  reports: CybouDB 0.5.0-preview.2
  info on a lease file is refused            ok
  check on a lease file is refused           ok
  query on a lease file is refused           ok
  and an ordinary file still works           ok
  the lease file is untouched                ok
  this build still accepts it                ok
release gate: ok
```

Windows:

```
.../cyboudb-0.5.0-preview.1-windows-x64/cyboudb.exe
  reports: CybouDB 0.5.0-preview.1
  info on a lease file is refused            ok
  check on a lease file is refused           ok
  query on a lease file is refused           ok
  and an ordinary file still works           ok
.../cyboudb-0.5.0-preview.2-windows-x64/cyboudb.exe
  reports: CybouDB 0.5.0-preview.2
  info on a lease file is refused            ok
  check on a lease file is refused           ok
  query on a lease file is refused           ok
  and an ordinary file still works           ok
  the lease file is untouched                ok
  this build still accepts it                ok
release gate: ok
```

The message in full, from all four:

```
error: file requires incompatible features this build does not implement
```

with exit status `2`, which is what the command line uses for a refusal it
understands rather than a crash.

## And that it is not vacuous

Pointing the gate at the build under test - as though `0.6` were the released
reader - fails it, on the three assertions it should and on no others:

```
./cyboudb.exe
  reports: CybouDB 0.5.0-preview.2
  info on a lease file is refused            FAIL - it succeeded
  check on a lease file is refused           FAIL - it succeeded
  query on a lease file is refused           FAIL - it succeeded
  and an ordinary file still works           ok
  the lease file is untouched                FAIL - it was rewritten
  this build still accepts it                ok
release gate: FAILED
```

The third failure is worth reading: a build that *does* understand leases
rewrote the file, because `DEQUEUE` on it is a real operation. That is the
assertion earning its place - it can tell the difference between a reader that
declined and a reader that acted.

> The `reports:` line above says `0.5.0-preview.2` for the build under test,
> which is not a typo and is not what it looks like: the version string in
> `src/main.asm` had not been moved off the last release. It says `0.6.0-dev`
> now, and `tools/package.sh` and `tools/package.bat` refuse to build a package
> whose name and whose binary disagree. The transcript is left as it was run -
> a record that is edited to look better afterwards is not a record.

## The model was right

The same gate, pointed at `build/cyboudb_nolease` - the `--no-leases` build that
stood in for a released reader all through development - passes identically.
That is the result worth keeping: the model was not merely convenient, it was
accurate, and the development-time check it backs can be trusted to keep being
accurate between releases. Had it differed, the interesting work would have
started here.

## What is still not proved

That a `0.5` binary refuses **every** `0.6` file, rather than this one. The
refusal is driven by a single bit in the header's incompatible-feature mask, so
the general claim rests on `tests/lease_format_tests.py` asserting that the
creator sets exactly that mask, and on the mask being checked before anything
else is read. This gate proves the other half: that the check is really there,
in a binary nobody can rebuild.
