# The language bindings, and what their version numbers mean

CybouDB ships official bindings for Rust, Python and Node. This document says
how they are versioned and what CI does and does not check about them, because
"official" is a claim that has to be backed by a policy rather than by a word
in a README.

## Versioning: they follow the engine

| | |
| :--- | :--- |
| engine and CLI | `0.7.0-dev` |
| `cyboudb` / `cyboudb-sys` (Rust) | `0.7.0-dev` |
| `cyboudb` (Python) | `0.7.0.dev0` |
| `@cyboudb/cyboudb` (Node) | `0.7.0-dev` |

**A binding package embeds the engine**, statically: installing one does not
fetch a separate library, and the assembly inside a wheel is the assembly of
the engine at that version. A package numbered independently would therefore be
claiming something it cannot mean - `0.5.0` of a package containing a
`0.7.0-dev` engine says a thing about the file format and the C ABI that is
simply false.

So the rule is the one with the fewest ways to be wrong:

> A binding's version is the engine version it contains. Python spells a
> development release `0.7.0.dev0` because PEP 440 requires it; the number is
> the same number.

A binding may of course need a release of its own for a binding-only fix. That
is a patch on the same number, not a divergence from it.

## What CI checks today, and what it does not

The engine's CI matrix builds and tests the engine on Linux and Windows, runs
the compatibility corpus, the fault injection, the SQL and C API suites and the
crypto suites. **It does not yet build or test the bindings.**

That is a real gap and it is written here rather than left to be discovered:
three packages are called official, and nothing in continuous integration
compiles them. Before the next public package release the bindings need their
own matrix - separate from the engine jobs, which are already large - covering
at minimum:

```text
Rust     cargo build, cargo test, on Linux and Windows
Python   build the wheel, import it, run the examples
Node     napi build, run the TypeScript type tests and the examples
```

Until that exists, the packages in this repository should be treated as source
that is known to have worked when it was written, and not as something a green
badge is vouching for.

## What a binding is allowed to do

* **It may not reimplement engine logic.** A binding translates types and
  manages lifetimes. Anything that decides what the database does belongs in
  the engine, where the tests are.
* **It may not paper over an error.** An error code from the engine reaches the
  caller as an error, with the engine's own message; a binding that turns a
  refusal into a `None` or an empty list is hiding the one thing the caller
  needed.
* **It owns its own memory rules.** RAII in Rust, context managers in Python,
  finalizers in Node - each language's normal way of not leaking a handle.
