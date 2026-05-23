# TypeLisp standard library

The `stdlib/` directory is the canonical in-repo source tree for TypeLisp
standard-library modules. These files are ordinary TypeLisp modules, not a
separate package format.

## Import convention

Import stdlib modules explicitly by path:

```lisp
(import "stdlib/string.tl")
```

For files outside the repository, prefer passing the repository stdlib directory
as an explicit root:

```sh
typelisp check path/to/main.tl --stdlib-root path/to/typelisp/stdlib
typelisp compile path/to/main.tl --stdlib-root path/to/typelisp/stdlib
typelisp run path/to/main.tl --stdlib-root path/to/typelisp/stdlib
```

For imports that start with `stdlib/`, the loader first tries the path relative
to the importing file. If that path is not readable, it searches each configured
`--stdlib-root` by stripping the leading `stdlib/` and joining the remainder to
the root. This means a local project file such as `stdlib/string.tl` takes
precedence over configured stdlib roots.

## Current modules

- `string.tl`: string trimming, containment, character containment, and
  replacement helpers built on compiler/runtime string primitives.

## Adding a module

When adding a new canonical stdlib module:

1. Put the source under `stdlib/` using a stable path that callers can import.
2. Keep imports explicit. Do not assume an implicit prelude.
3. Add the module to the manifest in `scripts/verify-stdlib.sh`.
4. Add meaningful verification coverage to the stdlib verifier or to a focused
   integration test that the verifier invokes.
5. Keep README/SPEC references accurate if the public convention changes.

## Out of scope today

The current stdlib layout does not define package manifests, a dependency
solver, package-qualified import syntax, default installed stdlib discovery,
namespace isolation, or an implicit prelude. Those decisions remain part of the
broader stdlib/package hierarchy work.
