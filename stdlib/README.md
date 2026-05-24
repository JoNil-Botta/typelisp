# TypeLisp Stdlib Source Tree

This directory is the canonical in-repo standard-library source tree for the
current explicit-root model. Files here are ordinary TypeLisp modules loaded by
the same `import` mechanism as project-local files.

This document describes the source-tree convention only. TypeLisp package
builds support local path dependencies and `pkg:<alias>/...` imports through
`typelisp.pkg`, but the stdlib is not currently distributed as a package.
TypeLisp still does not define registry or version solving, default
installed-root discovery, namespace isolation, or an implicit prelude.

## Current Modules

- `io.tl`: file I/O helpers built on compiler/runtime primitives. Import it
  with `(import "stdlib/io.tl")`.
- `string.tl`: string utility functions built on compiler/runtime primitives.
  Import it with `(import "stdlib/string.tl")`.
- `test.tl`: minimal assertion helpers for TypeLisp fixtures. Import it with
  `(import "stdlib/test.tl")`.

## Importing Stdlib Modules

Stdlib modules are imported explicitly:

```lisp
(import "stdlib/io.tl")
(import "stdlib/string.tl")
(import "stdlib/test.tl")
```

For imports whose path starts with `stdlib/`, the loader first tries the path
relative to the importing file. If that local path cannot be loaded, each
configured stdlib root is searched by stripping the leading `stdlib/` and
joining the remaining suffix to the root.

That means local project files take precedence over configured stdlib roots.
Configured stdlib roots only serve normal relative suffixes below the root;
paths such as `stdlib/../outside.tl` are not resolved through root fallback.
When compiling or checking sources outside the repository tree, prefer passing
the repository stdlib directory explicitly:

```sh
typelisp check path/to/main.tl --stdlib-root /path/to/typelisp/stdlib
typelisp compile path/to/main.tl --stdlib-root /path/to/typelisp/stdlib
typelisp run path/to/main.tl --stdlib-root /path/to/typelisp/stdlib
```

For ad-hoc local commands, `TYPELISP_STDLIB_ROOT=/path/to/typelisp/stdlib`
provides an optional fallback root. Explicit `--stdlib-root` values are searched
before that environment fallback, so scripts and CI should keep passing
`--stdlib-root` when they need reproducible resolution.

Copying or staging `stdlib/` next to an entry source still works because imports
remain filesystem paths, but `--stdlib-root` is the canonical way to verify root
lookup behavior.

## Adding a Module

1. Add the module under `stdlib/`, using a stable explicit import path such as
   `stdlib/name.tl`.
2. Keep the module self-contained except for explicit `(import "...")`
   dependencies.
3. Include a short header comment with its purpose, required primitives, and
   import path.
4. Add the new `.tl` file to `scripts/verify-stdlib.sh`'s manifest.
5. Add meaningful verification coverage in `scripts/verify-stdlib.sh` before
   landing the module.
6. Link user-facing docs or tests to the new module when appropriate.

The verifier intentionally fails when a new `stdlib/*.tl` file is not listed in
its manifest. That makes every new canonical module an explicit verification
decision.
