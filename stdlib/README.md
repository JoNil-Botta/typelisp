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

- `io.tl`: file I/O helpers, explicit file-handle open/close wrappers, stdio
  wrappers, and monomorphic Result-style I/O error APIs built on
  compiler/runtime primitives. Import it with
  `(import "stdlib/io.tl")`.
- `env.tl`: recoverable environment variable lookup and PATH-style list
  helpers. Import it with `(import "stdlib/env.tl")`.
- `cpu.tl`: host CPU SIMD ISA detection via the `cpuid`/`xgetbv` primitives
  (#1167). `cpu-runs-avx2?` / `cpu-runs-avx512f?` report an ISA as runnable only
  when both the CPUID feature bit and OS XSAVE state (XCR0) are present, plus the
  underlying `cpu-osxsave?` / `cpu-xcr0` / `cpu-max-leaf` / `cpu-has-avx2?` /
  `cpu-has-avx512f?` accessors. Backs `scripts/detect_simd_isa.tl`, which
  replaced the C cpuid probe (#1168). The `defdispatch` runtime SIMD dispatch
  design in `SPEC.md` uses the same capability model internally; ordinary
  dispatched calls should not require user code to import this module. Import it
  with `(import "stdlib/cpu.tl")` when code needs explicit host capability
  checks.
- `fs.tl`: minimal recoverable filesystem helpers for tool artifact paths,
  current-directory lookup, lexical path normalization, safe relative suffix
  checks, temporary directories, cleanup, and coarse file-kind probes. Import it with
  `(import "stdlib/fs.tl")`.
- `ffi.tl`: caller-owned FFI buffer helpers, including explicit
  NUL-terminated `String` copies into `(MutPtr u8)` storage. Import it with
  `(import "stdlib/ffi.tl")`.
- `hash.tl`: deterministic, non-cryptographic hash and key equality helpers for
  future collections. Import it with `(import "stdlib/hash.tl")`.
- `hashmap.tl`: fixed-capacity, open-addressed `String -> i64` map — the
  linear-probing core with full-table detection (#825) plus the v1 map API
  (`string-i64-map-with-capacity` / `-insert` / `-get` / `-contains?` / `-len`,
  copied-value lookup; #826), tombstone-based removal (`-remove` / `-deleted`,
  with reinsert reusing tombstones; #829), and load-factor resize/rehash
  (`-put` auto-grows; `-resized` / `-grow` / `-needs-grow?`; #827). Deterministic
  iteration is a follow-up. Import it with `(import "stdlib/hashmap.tl")`.
- `json.tl`: JSON value parser and serializer for tool protocols and data
  exchange. Import it with `(import "stdlib/json.tl")`.
- `list.tl`: monomorphic `StringList` and `StringListBuilder` helpers for
  common cons-list workflows, with reverse/append/count and array conversion
  helpers. Import it with `(import "stdlib/list.tl")`.
- `process.tl`: process command/output/error data model for selfhost tools.
  Runtime execution currently returns structured unsupported diagnostics rather
  than using Rust host actions. Import it with `(import "stdlib/process.tl")`.
- `queue.tl`: growable `i64` queue/deque (collections v1, #1549) over a
  circular `(Array i64)`: `i64-deque-with-capacity` / `-new` / `-push-back` /
  `-push-front` / `-pop-front` / `-pop-back` / `-peek-front` / `-peek-back` /
  `-get` / `-len` / `-capacity`, with wraparound growth and explicit empty-pop
  results. Import it with `(import "stdlib/queue.tl")`.
- `random.tl`: deterministic, seeded, non-cryptographic random helpers and
  weighted-index selection for selfhost tools, plus an OS-entropy seed source.
  Import it with `(import "stdlib/random.tl")`.
- `string.tl`: string utility functions built on compiler/runtime primitives.
  Import it with `(import "stdlib/string.tl")`.
- `test.tl`: minimal assertion helpers for TypeLisp fixtures. Import it with
  `(import "stdlib/test.tl")`.
- `text_buf.tl`: arena-aware text buffer helpers for incremental String
  construction. Import it with `(import "stdlib/text_buf.tl")`.
- `vector.tl`: growable `i64` vector (collections v1, #835) over `(Array i64)`:
  `i64-vec-with-capacity` / `-new` / `-push` / `-pop` / `-get` / `-last` /
  `-set!` / `-len` / `-capacity`, with doubling growth and bounds-checked reads,
  plus conversion/iteration helpers `-from-array` / `-to-array` / `-extend` /
  `-reverse!` / `-sum` / `-contains?` (#1212). Import it with
  `(import "stdlib/vector.tl")`.
- `windows_registry.tl`: narrow Windows Kits registry lookup used by SDK
  discovery. Import it with `(import "stdlib/windows_registry.tl")`.
- `windows_sdk.tl`: structured Windows SDK layout discovery helpers for future
  MSVC toolchain setup. Import it with `(import "stdlib/windows_sdk.tl")`.
- `windows_setup.tl`: Visual Studio / Build Tools SetupConfiguration discovery
  data model and structured runtime result API. Import it with
  `(import "stdlib/windows_setup.tl")`.
- `msvc.tl`: MSVC tool discovery (`link.exe` + `PATH`/`LIB`/`INCLUDE` command
  environment) from a configured Developer Command Prompt, or from the newest
  usable SetupConfiguration instance plus Windows SDK discovery. Import it with
  `(import "stdlib/msvc.tl")`.

## Arena Allocation Policy

The stdlib does not own an allocator API. Stdlib functions allocate only by
calling compiler/runtime primitives such as `substring`, `string-append`,
`read-file`, `int->string`, and aggregate constructors. Those allocations use
the active arena: the default program-lifetime arena outside any scoped arena,
or the innermost scoped arena inside `(with-arena ...)`. The arena model uses
the term "scoped arena" for this behavior. Stdlib policy tests use
`(with-arena ...)` as the executable witness for active-arena semantics.

Written reference and arena lifetime syntax exists, and stdlib APIs migrate
non-consuming text inputs to borrowed `(& lifetime str)` signatures as the
borrowed `str` frontend and string API work lands (#1453/#1454/#1082). The checker
conservatively tags aggregate results from stdlib calls made inside a scoped
arena as arena-owned, which prevents those values from escaping the scope. The
v1 `String`/`str` contract in `SPEC.md` classifies which future signatures
should take borrowed text and which should return owned active-arena strings.

| Functions | Allocation behavior |
|-----------|---------------------|
| `is-char-whitespace`, `char-eq`, `string-contains`, `string-contains-char`, `is-string-prefix-at` | Non-allocating string/char inspection; text parameters are borrowed `str` inputs. |
| `string-trim-left`, `string-trim-right`, `string-trim` | Borrow the input text and return fresh `String` storage from `substring`, allocated in the active arena. |
| `string-replace` | Returns fresh `String` storage from `substring`/`string-append` when a replacement is made; returns the caller-provided `s` when `old` is not present. |
| `try-read-file` | Performs host/runtime file inspection; returns `OkIoString` with fresh active-arena `String` storage from `read-file` when the path is readable, or `ErrIoString` for empty paths, expected absence, permission failures, interrupted reads, and target status-code failures. |
| `try-write-file` | Writes through the recoverable runtime status helper; returns `OkIoUnit` on success or `ErrIoUnit` for empty paths, missing parents, permission failures, interrupted writes, and target status-code failures. |
| `try-file-exists?` | Returns `OkIoBool` for existing or expected missing paths; empty paths and hard probe failures return `ErrIoBool`. |
| `try-append-file` | Appends through the recoverable runtime status helper. It preserves existing contents, creates missing files, does not allocate a concatenated temporary string, and uses best-effort host append semantics rather than truncating or rewriting the whole file. |
| `file-open`, `file-close` | `file-open` returns `ResultIoFile` with an opaque runtime-managed `FileHandle` for `OpenRead`, `OpenWriteTruncate`, and `OpenWriteAppend`. The Linux runtime copies the path into active-arena storage for the host syscall and tracks handle state in a process-global table; Windows currently returns `IoUnsupported`. `file-close` releases a valid handle and returns `IoUnsupported` for invalid or already-closed handles. |
| `file-read-chunk`, `file-read-bytes`, `file-read-eof?` | `file-read-chunk` reads up to the requested byte count from a read-mode `FileHandle` and returns `ResultIoRead` with active-arena `String` bytes plus the sticky EOF flag. Negative counts return `IoInvalidPath`; closed, invalid, write-only, and unsupported handles return `IoUnsupported`. The accessors are non-allocating field reads on `FileRead`. |
| `file-write`, `file-flush` | `file-write` writes a `String` to an `OpenWriteTruncate` or `OpenWriteAppend` handle, retrying host short writes until complete or an error is reported. `file-flush` flushes a write-mode handle. Closed, invalid, read-only, and unsupported handles return `IoUnsupported`. |
| `read-file-or` | Convenience wrapper over `try-read-file`; returns the caller-provided `fallback` for every structured error. |
| `append-file` | Panic-on-error convenience wrapper over `try-append-file`; preserves existing contents and creates missing files through host append mode. |
| `file-nonempty?` | Convenience wrapper over `try-read-file`; allocates a temporary active-arena `String` through `read-file` only when the path exists. |
| `stdin-read-line`, `stdin-read-bytes` | Return `StdinRead` aggregates containing a runtime-allocated active-arena `String` plus the post-read sticky EOF state. Byte reads still use `String` storage until a future byte-buffer/slice split lands. |
| `stdin-at-eof?`, `stdin-read-text`, `stdin-read-eof?`, `stdout-write`, `stderr-write`, `stdout-flush` | Non-allocating wrappers/accessors around runtime stdio primitives and `StdinRead` values. |
| `stdout-write-line`, `stderr-write-line` | Allocate a newline-appended active-arena `String` via `string-append`, then write it to the target stream. |
| `env-get`, `env-path-list`, `env-path-split`, `env-path-join` | Lookup names, split inputs, and explicit join separators are borrowed `str` inputs. Environment values and split/join results allocate fresh active-arena Strings/lists when runtime values are read or string pieces are created; missing variables return explicit `EnvNo*` options. |
| `env-get`, `env-path-list`, `env-path-split`, `env-path-join` | Lookup names, split inputs, and explicit join separators are borrowed `str` inputs. Environment values and split/join results allocate fresh active-arena Strings/lists when runtime values are read or string pieces are created; missing variables return explicit `EnvNo*` options. |
| `fs-path-join`, `fs-dirname`, `fs-basename`, `fs-extension`, `fs-path-absolute?`, `fs-path-normalize`, `fs-path-safe-relative?`, `try-current-dir`, `try-mkdir`, `try-mkdir-if-missing`, `try-remove-file`, `try-remove-dir`, `try-rename`, `try-read-dir`, `try-file-kind`, `try-file-metadata`, `try-create-temp-dir` | Path joins allocate active-arena Strings when a separator is inserted or duplicate separator is removed. `fs-dirname`/`fs-basename`/`fs-extension` are pure separator-agnostic string helpers (no allocation beyond the returned substring; `fs-extension` operates on the basename and treats a leading-dot name as extensionless). `fs-path-absolute?` is non-allocating and treats `/...`, `\\...`, `C:/...`, and `C:\\...` as absolute/rooted while leaving drive-relative `C:...` non-absolute. `fs-path-normalize` is lexical only: it accepts `/` and `\\`, collapses repeated separators, removes `.`, resolves `..` against normal segments, preserves relative leading `..`, preserves roots and drive roots, renders `/` as the stable separator on every host, and returns `"."` for empty relative paths. `fs-path-safe-relative?` allocates through normalization and returns true only for non-empty relative suffixes that remain below a caller-chosen root after lexical normalization; it rejects rooted, drive-qualified, empty/`.` and leading-parent paths. `try-current-dir` returns the host-reported cwd as an owned active-arena `String` on Linux, without symlink canonicalization; Windows currently returns `IoUnsupported`. Recoverable filesystem helpers map runtime status codes into `IoError`; `try-file-kind` returns `FsFileRegular`, `FsFileDirectory`, or `FsFileOther` on Linux and `IoUnsupported` on Windows. `try-file-metadata` returns `FsMetadata` with coarse kind and regular-file byte size on Linux; directory and other node sizes are zero in this first slice, and Windows currently returns `IoUnsupported`. `try-mkdir` works on Linux and Windows, `try-mkdir-if-missing` treats an already-existing path as success, and `try-rename` follows host rename/replacement behavior on Linux while returning `IoUnsupported` on Windows. `try-read-dir` returns entry names only, filters `.` and `..`, preserves host directory order without promising stable sorting, and allocates the returned list spine and entry strings in the active arena; Linux reads directories directly through the backend runtime, while Windows currently returns `IoUnsupported`. Linux temp directories are created under `$TMPDIR` or `/tmp` with process-id and retry suffixes. Windows temp directories are created under `%TEMP%`, `%TMP%`, or `.` with process-id and retry suffixes; cleanup helpers still return `IoUnsupported` on Windows. |
| `ffi-c-string-*` helpers | Non-allocating inspection and copying into caller-owned `(MutPtr u8)` storage. `ffi-c-string-copy!` validates interior NUL bytes and capacity before writing, appends the trailing NUL on success, and leaves raw-pointer validity/lifetime with the caller. |
| `hash-*` helpers | Deterministic, non-cryptographic hash and key equality helpers are non-allocating; string hash/equality helpers borrow text inputs. Hashes are stable bucket hints only; collection users must still compare colliding candidate keys with the matching equality predicate. |
| `json-*` helpers | Parser, lookup, and escaping helpers borrow source text or keys. Parsed JSON aggregates, decoded strings, escaped strings, stringified output, and list/member spines allocate owned results in the active arena. |
| `string-list-*` helpers | Construct immutable `StringList` cons nodes and `StringListBuilder` values in the active arena. `string-list-reverse`, `-reverse-onto`, `-append`, `-from-array`, and builder build helpers allocate fresh list spines; `string-list-to-array` allocates a fresh active-arena `(Array String)` and copies the string handles into it. |
| `process-*` helpers | Construct process command/output/error aggregates in the active arena. Command builders keep owned `String` parameters because `ProcessCommand`, argv, env, cwd, and stdin fields currently store owned strings; validators use borrowed text inspection where they do not store inputs. Ordered argv append helpers allocate list nodes; validators inspect executable/env/cwd metadata and reject invalid env names. On Linux, `process-run` and `process-output` execute directly through the backend runtime, preserving inherited environment entries, replacing entries named by env overrides, honoring cwd, and feeding string stdin. Unsupported targets return structured errors. |
| `random-*` helpers | Construct deterministic RNG state, draw/result aggregates, and weight-list cons nodes in the active arena. Draws are deterministic from caller-provided seeds and do not read host entropy. `random-system-seed` reads host entropy through the backend, normalizes the returned seed, and returns a `ResultSystemSeed` aggregate in the active arena; `random-from-system` constructs and returns a new `RandomState` aggregate in the active arena. |
| `assert-*` helpers in `test.tl` | Non-allocating checks on success; failures call `panic` with the caller-provided message. |
| `text-buf-*` helpers in `text_buf.tl` | Buffer chunks and rendered strings allocate in the active arena. Append helpers avoid concatenating the accumulated prefix until `text-buf-render`; `text-buf-clear`/`text-buf-reset` return a fresh empty immutable buffer value. |
| `windows-registry-*` helpers | The SDK registry probe allocates returned root/version strings and result aggregates in the active arena. It reads only `HKLM\\SOFTWARE\\Microsoft\\Windows Kits\\Installed Roots`, the `KitsRoot10` string value, and version subkeys; unsupported hosts and registry failures return structured errors. |
| `windows-sdk-*` helpers | Non-owning root/version/path inputs are borrowed `str` values. SDK layout structs/errors allocate in the active arena; path assembly returns owned strings, and path probes copy borrowed paths while the lower-level `io/fs` APIs still take owned `String`. Environment discovery reads `WindowsSdkDir` / `WindowsSDKVersion`, constructs include/lib/bin path strings, and validates required directories with `try-file-exists?`. Registry discovery uses the narrow `windows-registry-sdk-install` probe, then validates the same include/lib/bin layout before returning it. |
| `windows-setup-*` helpers | Non-owning package-id probes use borrowed `str` values. Helpers that store package/component identifiers copy borrowed inputs into owned active-arena strings, while runtime discovery returns owned strings, package/component lists, and instance lists. `windows-setup-instances` returns structured unsupported/unavailable/query-failed errors when the runtime cannot enumerate SetupConfiguration. |
| `msvc-*` helpers | Non-owning target/tool/version/path inputs are borrowed `str` values. Discovery results store owned executable, PATH, LIB, and INCLUDE strings; setup candidate selection copies the chosen version string before storing it. Some internal path probes copy borrowed paths until the lower-level `io/fs` APIs are fully borrowed. |

The recoverable I/O API maps the runtime's integer status codes into the public
`IoError` model. Common not-found, permission, invalid-path, interrupted, and
directory-read statuses get semantic variants; target-specific or unstable
codes remain available as `IoSystemCode`.

No current stdlib function returns a borrow-typed `str`, mutates a
caller-provided buffer in place, or manually resets arenas. Source-level
`arena-set!`, `arena-destroy`, and `arena-rewind` require `(unsafe ...)`; safe
stdlib APIs should prefer `with-arena` for scoped reclamation. `str` is specified
as an immutable borrowed text referent, not a mutable buffer type; those policies
should remain explicit when borrowed strings and mutable buffers are added.

### File-handle API (v1, #1036)

`SPEC.md` §6.4 specifies the v1 file-handle surface that extends these
whole-file helpers with explicit open/close and streaming I/O. The
implementation lands incrementally:

- **#1056** — implemented: opaque `FileHandle`, the `OpenMode` enum
  (`OpenRead`, `OpenWriteTruncate`, `OpenWriteAppend`), `file-open` returning
  `ResultIoFile`, and `file-close`. v1 requires explicit close; move-only
  aggregate semantics are specified in `SPEC.md`, but implicit drop/close still
  waits for scoped cleanup support.
- **#1057** — implemented: `file-read-chunk` returning `ResultIoRead` / `FileRead` (a
  `String` payload plus a sticky EOF flag, mirroring `StdinRead`). Chunk bytes
  allocate in the active arena and stay `String`-typed until a future
  byte-buffer/slice split lands.
- **#1058** — implemented: `file-write` and `file-flush` for write-mode
  handles. `OpenWriteAppend` matches the non-truncating `try-append-file`
  append primitive; Linux uses host append mode and Windows returns
  `IoUnsupported` until native handle support lands.

All handle helpers reuse the existing `IoError` model; mode violations, closed
or invalid handles, and unsupported Windows operations return structured
`IoError` results rather than panicking.

## Importing Stdlib Modules

Stdlib modules are imported explicitly:

```lisp
(import "stdlib/env.tl")
(import "stdlib/ffi.tl")
(import "stdlib/fs.tl")
(import "stdlib/hash.tl")
(import "stdlib/hashmap.tl")
(import "stdlib/io.tl")
(import "stdlib/json.tl")
(import "stdlib/list.tl")
(import "stdlib/msvc.tl")
(import "stdlib/process.tl")
(import "stdlib/random.tl")
(import "stdlib/string.tl")
(import "stdlib/test.tl")
(import "stdlib/text_buf.tl")
(import "stdlib/windows_sdk.tl")
(import "stdlib/windows_setup.tl")
```

For imports whose path starts with `stdlib/`, the loader first tries the path
relative to the importing file. If that local path cannot be loaded, each
configured stdlib root is searched by stripping the leading `stdlib/` and
joining the remaining suffix to the root. If no configured root provides the
module, the compiler uses its embedded copy of the checked-in stdlib as the
final fallback.

That means local project files take precedence over configured stdlib roots.
Configured stdlib roots take precedence over embedded modules. Configured and
embedded stdlib fallbacks only serve normal relative suffixes below the root;
paths such as `stdlib/../outside.tl` are not resolved through fallback.
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
before that environment fallback, and both are searched before the embedded
stdlib, so scripts and CI should keep passing `--stdlib-root` when they need
reproducible resolution.

Copying or staging `stdlib/` next to an entry source still works because imports
remain filesystem paths, but `--stdlib-root` is the canonical way to verify root
lookup and override behavior.

The assertion helpers in `stdlib/test.tl` are also intended for inline
`(test ...)` items. They do not allocate on success; failures call `panic` with
the caller-provided message. Repository CI runs
`scripts/verify-inline-tests.sh`, so inline tests placed under stdlib modules or
fixtures are discovered without a manifest edit.

## Adding a Module

1. Add the module under `stdlib/`, using a stable explicit import path such as
   `stdlib/name.tl`.
2. Keep the module self-contained except for explicit `(import "...")`
   dependencies.
3. Include a short header comment with its purpose, required primitives, and
   import path.
4. Add the new top-level `.tl` file to `scripts/verify-stdlib.sh`'s module
   manifest.
5. Add new stdlib `.tl` files, including test fixtures, to the embedded stdlib
   manifest in `src/module.rs` so installed compiler binaries can use them
   through embedded stdlib fallback.
6. Add focused fixtures under `stdlib/tests/` and list them in
   `scripts/verify-stdlib.sh`'s runnable test manifest with expected
   exit/stdout/stderr or check-only manifest with expected pass/fail behavior.
7. Add inline `(test ...)` items next to declarations when the check belongs to
   a specific stdlib API; `scripts/verify-inline-tests.sh` discovers them
   automatically.
8. Document the intended public API coverage in `stdlib/tests/README.md`.
9. Add `;#` module docs, attached `;:` item docs for every public top-level
   declaration, allocation-behavior notes for allocating APIs, an update to the
   arena allocation classification table above, and at least one checked doctest
   example that runs with `--stdlib-root`.
10. Run `scripts/verify-stdlib-docs.sh` to generate Markdown and run doctests
   for every stdlib module.
11. Run `scripts/verify-doc-tests.sh` to confirm the repository-wide doctest
   discovery gate picks up the new documented module without a manifest edit.
12. Run `scripts/verify-inline-tests.sh` if the module adds inline tests.
13. Link user-facing docs or tests to the new module when appropriate.

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
