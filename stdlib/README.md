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

- `io.tl`: file I/O helpers, stdio wrappers, and monomorphic Result-style I/O
  error APIs built on compiler/runtime primitives. Import it with
  `(import "stdlib/io.tl")`.
- `env.tl`: recoverable environment variable lookup and PATH-style list
  helpers. Import it with `(import "stdlib/env.tl")`.
- `json.tl`: JSON value parser and serializer for tool protocols and data
  exchange. Import it with `(import "stdlib/json.tl")`.
- `process.tl`: process command/output/error data model for selfhost tools.
  Runtime execution currently returns structured unsupported diagnostics rather
  than using Rust host actions. Import it with `(import "stdlib/process.tl")`.
- `string.tl`: string utility functions built on compiler/runtime primitives.
  Import it with `(import "stdlib/string.tl")`.
- `test.tl`: minimal assertion helpers for TypeLisp fixtures. Import it with
  `(import "stdlib/test.tl")`.
- `text_buf.tl`: arena-aware text buffer helpers for incremental String
  construction. Import it with `(import "stdlib/text_buf.tl")`.

## Arena Allocation Policy

The stdlib does not own an allocator API. Stdlib functions allocate only by
calling compiler/runtime primitives such as `substring`, `string-append`,
`read-file`, `int->string`, and aggregate constructors. Those allocations use
the active arena: the default program-lifetime arena outside any scoped arena,
or the innermost scoped arena inside `(with-region ...)`. The arena model uses
the term "scoped arena" for this behavior; issue #801 tracks the source spelling
migration from `(with-region ...)` to `(with-arena ...)`.

Current function signatures cannot write arena lifetimes yet (#802), so stdlib
APIs keep plain `String`/aggregate signatures. The checker conservatively tags
aggregate results from stdlib calls made inside a scoped arena as arena-owned,
which prevents those values from escaping the scope. When written arena
lifetimes exist, stdlib signatures should distinguish owned arena results from
returned caller-owned values.

| Functions | Allocation behavior |
|-----------|---------------------|
| `is-char-whitespace`, `char-eq`, `string-contains`, `string-contains-char`, `is-string-prefix-at` | Non-allocating string/char inspection. |
| `string-trim-left`, `string-trim-right`, `string-trim` | Return fresh `String` storage from `substring`, allocated in the active arena. |
| `string-replace` | Returns fresh `String` storage from `substring`/`string-append` when a replacement is made; returns the caller-provided `s` when `old` is not present. |
| `try-read-file` | Performs host/runtime file inspection; returns `OkIoString` with fresh active-arena `String` storage from `read-file` when the path is readable, or `ErrIoString` for empty paths, expected absence, permission failures, interrupted reads, and target status-code failures. |
| `try-write-file` | Writes through the recoverable runtime status helper; returns `OkIoUnit` on success or `ErrIoUnit` for empty paths, missing parents, permission failures, interrupted writes, and target status-code failures. |
| `try-file-exists?` | Returns `OkIoBool` for existing or expected missing paths; empty paths and hard probe failures return `ErrIoBool`. |
| `try-append-file` | Performs read-modify-write through `try-read-file`, `string-append`, and `try-write-file`. It creates missing files, allocates temporary active-arena strings, and remains non-atomic. |
| `read-file-or` | Convenience wrapper over `try-read-file`; returns the caller-provided `fallback` for every structured error. |
| `append-file` | Panic-on-error convenience wrapper over `try-append-file`. It allocates temporary active-arena strings and rewrites the whole file. |
| `file-nonempty?` | Convenience wrapper over `try-read-file`; allocates a temporary active-arena `String` through `read-file` only when the path exists. |
| `stdin-read-line`, `stdin-read-bytes` | Return `StdinRead` aggregates containing a runtime-allocated active-arena `String` plus the post-read sticky EOF state. Byte reads still use `String` storage until #807 adds byte-slice/string separation. |
| `stdin-at-eof?`, `stdin-read-text`, `stdin-read-eof?`, `stdout-write`, `stderr-write`, `stdout-flush` | Non-allocating wrappers/accessors around runtime stdio primitives and `StdinRead` values. |
| `stdout-write-line`, `stderr-write-line` | Allocate a newline-appended active-arena `String` via `string-append`, then write it to the target stream. |
| `env-get`, `env-path-list`, `env-path-split`, `env-path-join` | Environment values and split/join results allocate fresh active-arena Strings/lists when runtime values are read or string pieces are created; missing variables return explicit `EnvNo*` options. |
| `process-*` helpers | Construct process command/output/error aggregates in the active arena. Ordered argv append helpers allocate list nodes; validators inspect executable/env/cwd metadata and reject invalid env names. On Linux, `process-run` and `process-output` execute directly through the backend runtime, preserving inherited environment entries, replacing entries named by env overrides, honoring cwd, and feeding string stdin. Unsupported targets return structured errors. |
| `assert-*` helpers in `test.tl` | Non-allocating checks on success; failures call `panic` with the caller-provided message. |
| `text-buf-*` helpers in `text_buf.tl` | Buffer chunks and rendered strings allocate in the active arena. Append helpers avoid concatenating the accumulated prefix until `text-buf-render`; `text-buf-clear`/`text-buf-reset` return a fresh empty immutable buffer value. |

The recoverable I/O API maps the runtime's integer status codes into the public
`IoError` model. Common not-found, permission, invalid-path, interrupted, and
directory-read statuses get semantic variants; target-specific or unstable
codes remain available as `IoSystemCode`.

No current stdlib function returns a borrow-typed `str`, mutates a
caller-provided buffer in place, or manually calls `tl_region_mark` /
`tl_region_reset`. Those policies should remain explicit when borrowed strings,
mutable buffers, and unsafe reset APIs are added.

## Importing Stdlib Modules

Stdlib modules are imported explicitly:

```lisp
(import "stdlib/env.tl")
(import "stdlib/io.tl")
(import "stdlib/json.tl")
(import "stdlib/process.tl")
(import "stdlib/string.tl")
(import "stdlib/test.tl")
(import "stdlib/text_buf.tl")
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
typelisp test path/to/main.tl --stdlib-root /path/to/typelisp/stdlib
```

For ad-hoc local commands, `TYPELISP_STDLIB_ROOT=/path/to/typelisp/stdlib`
provides an optional fallback root. Explicit `--stdlib-root` values are searched
before that environment fallback, so scripts and CI should keep passing
`--stdlib-root` when they need reproducible resolution.

Copying or staging `stdlib/` next to an entry source still works because imports
remain filesystem paths, but `--stdlib-root` is the canonical way to verify root
lookup behavior.

The assertion helpers in `stdlib/test.tl` are also intended for inline
`(test ...)` items. They do not allocate on success; failures call `panic` with
the caller-provided message.

## Adding a Module

1. Add the module under `stdlib/`, using a stable explicit import path such as
   `stdlib/name.tl`.
2. Keep the module self-contained except for explicit `(import "...")`
   dependencies.
3. Include a short header comment with its purpose, required primitives, and
   import path.
4. Add the new top-level `.tl` file to `scripts/verify-stdlib.sh`'s module
   manifest.
5. Add focused fixtures under `stdlib/tests/` and list them in
   `scripts/verify-stdlib.sh`'s test manifest with expected exit/stdout/stderr.
6. Document the intended public API coverage in `stdlib/tests/README.md`.
7. Add `;;;;` module docs, attached `;;;` item docs for every public top-level
   declaration, allocation-behavior notes for allocating APIs, and at least one
   checked doctest example that runs with `--stdlib-root`.
8. Run `scripts/verify-stdlib-docs.sh` to generate Markdown and run doctests
   for every stdlib module.
9. Run `scripts/verify-doc-tests.sh` to confirm the repository-wide doctest
   discovery gate picks up the new documented module without a manifest edit.
10. Link user-facing docs or tests to the new module when appropriate.

The verifier intentionally fails when a new top-level `stdlib/*.tl` module or a
new `stdlib/tests/*.tl` fixture is not listed in its corresponding manifest.
That makes every new canonical module and stdlib test an explicit verification
decision.

The documentation verifier discovers every `stdlib/*.tl` file directly and
fails when module docs, item docs for top-level declarations, generated
Markdown, or doctests regress. The repository doctest verifier discovers
documented TypeLisp files under the source and test trees automatically, so new
doctest fences in stdlib modules do not require a separate doctest manifest
update.
