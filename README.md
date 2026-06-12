# TypeLisp

A statically typed Lisp/Scheme dialect that compiles directly to native
x86_64 assembly for Linux and Windows. **Self-hosted**: the compiler is written
in TypeLisp and compiles itself, with **zero third-party dependencies**.

## Goals and inspirations

Current implementation goals:

- **Typed**: Every expression has a known type at compile time. No runtime type tagging.
- **Native**: Compiles straight to x86_64 assembly, then native toolchains produce executables. Linux uses `as` + `ld`; Windows uses `clang` + MSVC `link.exe`. No bytecode VM, no interpreter, no garbage collector. Supported targets are `linux-x86_64` and `windows-x86_64`; macOS and ARM are not supported yet and are not near-term goals.
- **Self-hosted**: The compiler, tooling, and stdlib are written in TypeLisp (see [`selfhost/`](selfhost) and [`stdlib/`](stdlib)). The published stage0 compiler is a single self-hosted binary that builds its own successor; the toolchain has no other-language implementation.
- **Zero dependencies**: No third-party packages. The only build inputs are the native assembler/linker toolchain.
- **Fast**: Generated code quality should approach LLVM (`clang -O2`) on the benchmark corpus while compilation itself stays fast. Performance is tracked deterministically — paired C baselines under [`benchmarks/`](benchmarks) and a cachegrind instruction-count CI gate under [`perf/`](perf) — rather than by wall-clock noise. The codegen-quality roadmap is #2559.

Language direction:

- Keep a minimal language core with Lisp/Scheme syntax and explicit types.
- Be expressive enough for C-style systems programming: native layout,
  runtime/FFI escape hatches, deterministic builds, and direct linker interop.
- Pursue Rust-style safety for ownership, borrowing, move semantics, and arena
  lifetimes. Safe TypeLisp should not have undefined behavior. Move-only
  aggregates, lexical immutable/mutable borrow checking, lifetime-parameterized
  aggregates, and scoped arenas are implemented; #182 remains the umbrella map,
  with non-lexical lifetimes (#810) as the main open slice. Struct field-place
  mutation through `(set! (struct-get place field) value)` is implemented by
  #1521.
- Treat ISPC-style SPMD as the data-parallel model. The current source surface
  is in [SPEC.md section 5.15](SPEC.md); masked varying `if` is in flight
  (#2131, #2205, #2207) and the post-masked-if queue is tracked by #2548.
- Use Zig-style comptime as the abstraction mechanism. TypeLisp should not grow
  source-level generics, traits, interfaces, or `impl` syntax; comptime code
  generates concrete types, functions, and implementation bundles instead.
  Comptime-generated declarations, type reflection, and typed expression macros
  are implemented; see SPEC.md sections 3.7 and 5.17.
- Move toward C3-style modules where module identity participates in name
  resolution and prefixes TypeLisp linker symbols. Module identities and
  exports are implemented; the repository-wide migration to dotted module
  imports is tracked by #2452, #2453, #2454, and #2492.
- Use an arena-based memory model with a default program-lifetime arena and
  scoped `(with-arena ...)` allocation regions (implemented).
- Land new language features in the self-hosted compiler ([`selfhost/`](selfhost)).
  The toolchain is fully self-hosted (#666, #795); each published stage0 binary
  builds its successor.

Most of the language-direction bullets above are now implemented; the bullets
say where the remaining work is tracked. The rest of this README describes
current behavior unless it explicitly says a feature is planned.

## Decided direction (read this before writing new code)

The issue tracker is the source of truth for direction; issue #8 is the live
roadmap index, and design decisions are recorded as comments on their issues.
The following decisions are **made**; new code should anticipate them instead
of imitating transitional patterns still present in the tree:

- **Imports**: dotted module imports with aliases and dotted qualified member
  access replace path imports and slash-qualified source names (#2452, #2453,
  #2454, #2492). The legacy `(import "path/file.tl")` spelling is being
  removed.
- **Stdlib names**: module-name prefixes on stdlib functions
  (`string-append`, `fs-read-dir`, ...) are flat-namespace fossils; the
  end-state is qualified short names such as `str.append` (#2582, #2583).
- **Core macros**: bare prelude spellings (`when`, `unless`, `and`, `or`,
  `cond`) are canonical; qualified `core.` calls are transitional (#2581).
  Macros support bracket operands for clause-shaped surfaces (#2578), and
  `cond` returns to bracket arms `(cond [test expr] ... [else fallback])`
  when the core macro is migrated; the flat call shape is transitional (#2579).
  Macros become order-independent within a module (#2584).
- **Strings**: `str-cat` (single-allocation variadic concat, #2576) and
  `text_buf` are the blessed forms; user-facing `string-append`/
  `string-concat` chains are deprecated (#2573).
- **Binary bytes**: mutable binary storage uses the specified `ByteBuf` owner
  and borrowed `bytes` views, not mutable `str` or `TextBuf` (#2782). Current
  `(Array u8)` and `String` byte plumbing is compatibility surface until the
  stdlib byte-buffer module lands.
- **Mutation**: in-place mutation is the direction: struct field-place
  assignment uses `(set! (struct-get place field) value)` (#1521), and mutable
  box access is tracked by #2553. Copy-on-update is transitional and hot paths
  migrate once those land (#2575).
- **Memory + threads**: per-thread default arenas plus a shared atomic arena
  for concurrent allocation (#2591, #2593). Thread safety follows the Rust
  model via structural checker classification — no traits (#2590): values
  cross threads only when owned by an arena whose lifetime spans both; safe
  spawn/join/mutex/channels build on the SPEC.md section 6.5 model (#2592).
- **Testing**: inline `(test ...)` items and doctests are typechecked on
  every build of the owning package and never generate code outside the test
  runner (#2587, #2594); stdlib adopts inline tests (#2586). The typechecked
  test surface is exactly the package's own sources — never stdlib or
  dependencies.
- **Performance**: the codegen target is `clang -O2` quality (#2559).
  Optimizations are proven, not asserted: every claimed win must show an
  executed-instruction delta against the committed baselines, and compile
  speed is gated the same way (#2532).
- **Compilation model**: one whole program per executable with import-graph
  dedup (each module typechecked once per program); package dependencies are
  codegen'd once into archives but re-typechecked per consumer until
  signature metadata exists; in-process session caching is the accepted
  compile-speed direction (#2596).
- **Comptime execution**: the public macro/comptime surface is stdlib-owned
  `Expr`/reflection data (#2647/#2653). Source stdlib overrides
  (`--stdlib-root`) execute through CTFE, while the embedded stdlib executes
  compiled comptime code from an embedded `stdlib.tlci`; both paths must produce
  byte-identical expansions (#2658). Comptime code is pure safe TypeLisp with no
  `unsafe`, `extern`, or host I/O (#2648), bounded by deterministic fuel
  (#2656). Every package emits a `tlci` compile-time interface carrying
  signature metadata and macro code when present (#2651, #2655, #2659).

Transitional states in the current tree — do **not** imitate them in new
code: path imports, `core.`-qualified macro calls, module-name-prefixed
stdlib calls, flat `cond`, `string-append` chains, copy-on-update for record
mutation, and the in-flight aggregate-inline representation work
(#1867/#2296/#2357).

## Quick Start

```bash
git clone https://github.com/JoNil-Botta/typelisp
cd typelisp

# Fetch the published self-hosted stage0 compiler for this host. It installs as
# target/stage0/typelisp (Linux) or target/stage0/typelisp.exe (Windows).
scripts/fetch-stage0.sh            # or: powershell -ep Bypass -f scripts\fetch-stage0.ps1
tl=target/stage0/typelisp          # tl=target/stage0/typelisp.exe on Windows

# Type-check, compile, build, or run a program.
# Linux build/run require `as`/`ld`; Windows target build/run require `clang`/MSVC `link.exe`.
$tl check examples/hello.tl
$tl fmt --check examples/hello.tl
$tl compile examples/hello.tl     # writes examples/hello.s
$tl build   examples/hello.tl     # writes examples/hello
$tl run     examples/hello.tl
$tl test --check examples/hello.tl
$tl run     examples/hello.tl --target windows-x86_64
$tl build                         # builds nearest typelisp.pkg
```

## Example

```lisp
(defstruct Point (x i64) (y i64))

(defenum Shape
  (Circle i64)        ; radius
  (Rect   i64 i64))   ; width height

(define (area [s : Shape]) : i64
  (match s
    [(Circle r)   (* 3 (* r r))]
    [(Rect w h)   (* w h)]))

(define (main) : i64
  (let ([p : Point (Point 3 4)])
    (+ (struct-get p x)            ; 3
       (area (Rect 5 6)))))        ; 30  -> main returns 33
```

The entry point is a function named `main` returning `i64` or `unit`. If `main`
is omitted, the compiler synthesizes one that returns 0.

## Language at a glance

TypeLisp uses S-expressions with explicit type annotations on parameters,
struct/enum fields, and (optionally) `let` bindings.

```lisp
;; Global variable (scalar and aggregate initializers, including runtime
;; initializers, are supported)
(define answer : i64 42)

;; Function (parameters must be typed; return type defaults to unit)
(define (add [a : i64] [b : i64]) : i64 (+ a b))

;; Local bindings (sequential, let* scoping)
(let ([x : i64 10]
      [y     (* x 2)])   ; type inferred
  (+ x y))

;; Control flow
(if (< answer 100) "small" "large")
(while (> answer 0) (set! answer (- answer 1)))
(begin (print 1) (print 2) 0)
(begin (when (< answer 0) (return 0)) answer)

;; Casts
(cast 300 : u8)

;; Zero/identity initialization
(let ([n : i64 (init)]
      [text : String (init : String)]
      [items : (Array i64) (make-array i64 4)])
  (+ n (array-ref items 0)))
```

`cast` supports the full scalar numeric matrix: integer/char widening,
narrowing, and truncation; `f64` <-> `f32` precision changes; and integer/char
<-> float conversions (float -> integer truncates toward zero).
`(init : T)` constructs a valid initialized value for supported `T`;
contextual `(init)` works where an expected type is known. `make-array`
initializes every live element under the same ZII rules.

### Types

```
i64 i32 i16 i8   u64 u32 u16 u8   f64 f32   bool   char   unit   String
ByteBuf           ; specified owned mutable byte buffer
(Array t)         ; dynamic, runtime-sized array
(Array t n)       ; fixed-size array (by-value returns supported)
(Tuple t1 t2 ...) ; tuple (by-value params/returns supported)
(Box t)           ; specified arena-owned indirection for recursive aggregates
(& r t)           ; specified immutable reference tied to lifetime/arena r
(& r bytes)       ; specified immutable borrowed byte slice
(&mut r bytes)    ; specified exclusive mutable borrowed byte slice
(-> arg... ret)   ; function type
Name              ; a defenum / defstruct nominal type
(Name r...)       ; specified lifetime-parameterized nominal type use
```

Both `f64` and `f32` support scalar parameters, returns, locals, arithmetic,
comparisons, and casts.
Raw pointer types `(Ptr T)` and `(MutPtr T)`, `(unsafe ...)`, and unsafe
function/extern declaration wrappers are implemented for the v1 FFI surface
described in [SPEC.md](SPEC.md) sections 3.4, 4.3.1, and 5.20.

### Abstraction policy

TypeLisp does not plan source-level generics, traits, interfaces, `impl`
blocks, generic `Option<T>`/`Result<T,E>` syntax, or trait-based error
conversion. Library abstraction should come from Zig-style comptime generation:
compile-time code inspects type values and emits concrete structs, enums,
functions, and implementation bundles. V1 supports explicit
`comptime-decl`-generated concrete declarations and `comptime-decls` bundles
when several generated items share one request key; write hand-authored
monomorphic declarations such as `MaybeI64` or domain-specific `Result*` enums
when a generated family has not been requested. Use `(return expr)` for
function-local early exits, `(when cond body)` /
`(unless cond body)` for unit-valued guards, and `(try expr)` for the
Lisp-shaped propagation form over compatible concrete Result-like enums.

The comptime implementation path is tracked by #893 and #902; v1 type
reflection from #913 is implemented in the selfhost CTFE path. Historical
generic/type-constructor work in #483 is superseded by that chain.

### Top-level forms

Implemented today: `define` (variable / function), `defenum`, `defstruct`,
`extern`, and `import`. The selfhost module/macro path also supports `module`,
`export`, and `defmacro` for typed expression macro workflows; the final
stdlib-macro migration of parser-owned core forms remains separate.

```lisp
(defenum Tree (Leaf i64) (Node (Box Tree) (Box Tree))) ; future inline-safe recursion
(defstruct Pair (fst i64) (snd i64))
(extern (foreign-add [a : i64] [b : i64]) : i64)
(extern (local-add [a : i64] [b : i64]) : i64 (:symbol "foreign_add_exact"))
(extern (printf [fmt : (Ptr u8)] ...) : i32 (:symbol "printf"))
(extern foreign-add-ptr (:symbol "foreign_add_ptr") : (-> i64 i64))
(import "lib/util.tl")                        ; relative, deduped; cycles load once
```

Ordinary `defstruct` and `defenum` declarations have stable inline layout
metadata by default. Struct fields use declaration order with natural
alignment; enums use an 8-byte tag at offset 0 plus max-aligned payload
storage. The current lowering path may still use aggregate heap handles in
runtime slots, and full recursive-by-value enforcement is being staged
separately, but source that needs recursive aggregates should use explicit
`(Box T)` fields/payloads at the recursive edge.

`extern` defaults to the target C ABI with the linker symbol equal to the local
name. Function-head externs are direct external functions. Bare-name externs are
external data symbols; a bare function type is loaded as a raw C function
pointer and remains raw when copied to a local. Calls through such values use
the C ABI, distinct from ordinary TypeLisp function or closure descriptor
calls. `(:symbol "...")` can bind a local TypeLisp
declaration to an exact foreign linker symbol without applying the `_tl_` prefix
used for ordinary TypeLisp declarations. C varargs externs can use a
function-head declaration: bare `...` accepts any C ABI value tail and
`[arg : ...T]` requires every variadic argument to have type `T`.

Dotted module imports bind a module alias and keep imported definitions out of
the local unqualified namespace: `(import stdlib.string)` binds `string`, and
`(import stdlib.core_macros as core)` binds `core`. Imported values, types,
constructors, variants, patterns, and macros are referenced with dotted member
access such as `(string.length text)`, `[p : geometry.Point]`, and
`(core.when cond body)`. Full module paths such as `stdlib.string.length` are
accepted only when that module identity has been imported in the current
module. Slash-qualified source names such as `string/length` are rejected.
Legacy path imports such as `(import "lib/util.tl")` keep the transitional flat
behavior while that spelling is removed; see `SPEC.md` section 4.4 for the
migration contract. Macro
exports/imports use the same module loader identities and path-resolution rules,
with macro expansion happening before ordinary runtime typechecking.

Comptime layout queries such as `size-of`, `align-of`, and `offset-of` use
ordinary aggregate layout. `(:repr c)` remains accepted on structs as
compatibility/ABI-intent metadata, but it is not required for declaration-order
field offsets. Target C ABI call/return lowering for aggregate externs is a
separate backend contract.

`stdlib/string.tl` is the canonical in-repo string utility module. Stdlib files
are ordinary modules imported with explicit paths such as
`(import "stdlib/string.tl")`. `check`, `compile`, `build <file.tl>`, and `run`
also accept `--stdlib-root <dir>` for resolving `stdlib/...` imports from a
configured source tree. `TYPELISP_STDLIB_ROOT` can provide an optional fallback
root after explicit CLI roots. If no local path or configured root provides the
module, the compiler falls back to its embedded copy of the checked-in stdlib.
Prefer `--stdlib-root` for CI, bootstrap, and reproducible scripts. See
[stdlib/README.md](stdlib/README.md) for the current stdlib layout and
verification conventions.

The compile driver prepends the stdlib runtime and the core macro module as an
implicit prelude. Bare `when`, `unless`, `and`, `or`, and flat call-shaped
`cond` resolve to `stdlib/core_macros.tl` unless a local or imported macro
shadows them. The same module can still be imported explicitly as
`(import "stdlib/core_macros.tl" module stdlib.core-macros as core)` for
qualified calls such as `core.when`, `core.unless`, `core.and`, `core.or`, and
`core.cond`.

`typelisp compile` accepts `--cfg <name>` to enable source-level conditional
compilation flags. Source may wrap a top-level declaration as
`(cfg predicate declaration)`, where `predicate` is a flag name, `(all ...)`,
`(any ...)`, or `(not predicate)`. Inactive `cfg` branches are lexed/read but are
not parsed as TypeLisp declarations, so they can hide stage- or platform-specific
declarations from compilers that should not see them. The compiler also enables
target OS predicates automatically: `linux`, `unix`, `target-linux`, and
`os-linux` for `linux-x86_64`; `windows`, `target-windows`, and `os-windows` for
`windows-x86_64`.

Local packages can be described with a std-only S-expression manifest named
`typelisp.pkg`:

```lisp
(package
  (name "my-app")
  (version "0.1.0")
  (dependencies
    (math "../math")
    (lint (github "JoNil-Botta/typelisp-lint" (rev "abc123")))))
```

`typelisp build <file.tl> [-o <exe>]` compiles, assembles, and links one source
file to a native executable without running it. Without `-o`, the executable is
written next to the source path with the `.tl` extension removed. `typelisp
build [--manifest-path path/to/typelisp.pkg]` remains package-oriented: it
resolves `entry` relative to the manifest directory and writes outputs under
`target/<profile>/`, where the package build profile defaults to `release`.
`--profile dev` uses the `dev` profile; `--profile release` and `--release`
select the release profile. Omitted `entry` defaults to `src/main.tl` for
binaries and `src/lib.tl` for static libraries. When both `kind` and `entry` are
omitted from a disk-backed manifest, package loading infers `bin` if only
`src/main.tl` exists and `staticlib` if only `src/lib.tl` exists; if both or
neither conventional entry exists, add an explicit `kind` or `entry`. `kind
"bin"` builds a native executable named after the package; `kind "staticlib"`
builds a static archive (`lib<name>.a` on Linux, `<name>.lib` on Windows).
Assembly and object side artifacts use the same `target/<profile>/` directory.
`kind "lib"` remains accepted as a compatibility alias. Dependency entries may
use a local path relative to that same package root, an absolute path, or the
GitHub shorthand form shown above. `tag` and `branch` pins are also accepted,
and the shorthand normalizes to
`https://github.com/owner/repo.git#rev=commit`. Remote entries are resolved
through `typelisp.lock` and the package cache. When an existing lock entry
matches the manifest alias, normalized URL, and requested `rev`/`tag`/`branch`
pin, package builds replay the recorded commit as an exact `rev`; otherwise the
requested pin is resolved and the lockfile is rewritten deterministically.
`--locked` requires matching lock entries and never rewrites `typelisp.lock`;
missing, stale, or extra lock entries fail with a diagnostic. `--update-lock`
intentionally refreshes remote pins and rewrites `typelisp.lock`. A
pre-existing legacy fetch root under `target/typelisp/git-deps/<alias>` with
`typelisp.pkg` is used as-is unless it has a `.git` directory, in which case the
checkout is refreshed.

Resolved remote package pins can be represented in `typelisp.lock`, a
deterministic v1 S-expression lockfile:

```lisp
(typelisp-lock
  (version "v1")
  (dependencies
    (dependency
      (alias "lint")
      (url "https://github.com/JoNil-Botta/typelisp-lint.git")
      (pin (tag "v1.0.0"))
      (commit "0123456789abcdef0123456789abcdef01234567"))))
```

Each dependency records its manifest alias, normalized URL, original pin
kind/value (`rev`, `tag`, or `branch`), and exact resolved commit. The selfhost
lockfile helper parses this format with duplicate, missing-field, malformed,
non-string, and unknown-version diagnostics, and emits entries in stable alias
order. Package builds consume that model through `build_cli_core.tl`: matching
entries pin remote dependencies to the recorded commit, missing or stale entries
are refreshed from the manifest pin by default, and a deterministic lockfile is
written when remote dependencies or a prior lockfile are present. `--locked`
turns missing or stale entries into errors, while `--update-lock` refreshes
remote pins intentionally.

Remote package cache helpers use a deterministic v1 layout under the package
root at `target/typelisp/cache/packages/v1`. Cache entries are keyed by the
normalized remote URL plus an exact `rev` commit pin; `tag` and `branch` pins
must be resolved, either from `typelisp.lock` or from `git`, before they can be
reused as cache entries. Complete entries with matching metadata, completion
marker, and `typelisp.pkg` are reused without invoking `git`, including during
locked replay. Missing entries, partial writes, corrupt metadata, or stale
marker state are fetched into a staging directory and finalized through the
package-cache helpers; conflicting corrupt entries are preserved with a
`.corrupt.N` suffix before replacement.

The repository root is also a package. From a checkout, `typelisp build` builds
the unified selfhost CLI from `selfhost/cli.tl` and writes
`target/release/typelisp` (or `target/release/typelisp.exe` on Windows). Stage0
publication uses
`scripts/build-stage0.sh`, which compiles `selfhost/cli.tl` directly and links
it with the host toolchain so a seed compiler does not depend on its own
`build` command.

Package-wide source discovery walks regular `.tl` source files below the
manifest directory while skipping build/tool state (`target`, VCS directories),
nested package roots that have their own `typelisp.pkg`, and directories named
`tests`. Test directories are reserved for `typelisp test` integration
discovery and repository fixture corpora such as `selfhost/tests/`.

Package builds load local dependency manifests into a normalized DAG keyed by
manifest path before code generation. Transitive dependencies are built once per
package build invocation, diamond graphs share the common archive build,
independent ready dependency nodes run concurrently on hosts with async process
handles, binaries link the transitive static archives in dependency-aware order,
and dependency cycles fail with a `build: dependency cycle:` path diagnostic.
Hosts without async child handles keep the same graph semantics through a serial
fallback. Dependency packages must be `staticlib`/`lib` packages.
Inside a package build, imports of the form `(import
"pkg:math/src/lib.tl")` resolve from the dependency root declared for alias
`math`; ordinary string imports remain relative to the importing file, and
`stdlib/...` imports keep their local-first then configured-root then embedded
fallback behavior.

Under the legacy loader, imported package definitions share the same flat
top-level namespace as local modules, so duplicate value or type names fail
through the existing duplicate definition diagnostics. The next package-manager
phase keeps the explicit local-path plus git/GitHub pin model: registry support
is deferred, semantic-version solving is a non-goal, and workspaces are deferred.
The rationale is deterministic zero-dependency builds through the host `git` CLI
plus checked-in `typelisp.lock` replay. Namespace isolation and qualified symbol
lookup are specified for the selfhost module model in `SPEC.md`.

Documentation comments can contain checked examples. `typelisp doc --test
<file.tl>` extracts fenced `typelisp` or `tl` blocks from `;#` module docs and
attached `;:` item docs, writes each example to a deterministic temporary
source file, type-checks it, and removes the temporary directory before exiting.
Multiple explicit doctest inputs and package doctests keep per-file reporting.
The self-hosted Markdown generator renders `typelisp doc input.tl -o output.md`
from the entry file plus its reachable import graph, with deterministic module
sections and navigation. Package docs use `typelisp doc -o output.md
--manifest-path typelisp.pkg`.

```lisp
;# ```typelisp
;# (define (main) : i64 42)
;# ```

;: ```tl expect-error
;: (define (bad) : i64 true)
;: ```
(define documented : i64 1)
```

Examples are standalone TypeLisp source snippets. By default an example must
parse, resolve imports, and type-check. Add `expect-error` after the language tag
when the example is intended to fail. `typelisp run` / `tl run` fences are
recognized as runnable examples: they must include `;; doctest-exit: <integer>`
and may include `;; doctest-stdout: -` / `;; doctest-stderr: -` or
`literal:<escaped text>` (`\n`, `\t`, `\r`, `\\`). On Linux, runnable examples
compile and run through the self-hosted build/run path and compare exact
exit status, stdout, and stderr. Unsupported hosts report an unsupported
runnable doctest diagnostic. Ordinary `;` and `;;` comments are not
documentation and are ignored by the doctest scanner. `;#` and `;:` are the
only public documentation comment syntaxes.

Inline tests can live next to source declarations as `(test name body...)`
items. Normal `check`, `compile`, `build`, and `run` ignore them. `typelisp
test <file.tl>` loads the import graph, turns inline tests owned by the
requested source into private unit-returning functions, generates a test-owned
`main`, and runs the resulting executable. Imported files provide runtime
declarations but do not contribute their own inline tests to that harness. With
no file, `typelisp test` discovers the nearest package and runs package sources
that contain top-level inline tests, plus package-local `tests/**/*.tl`
integration test files; stdlib and dependency imports provide runtime
declarations only. Integration test files run as normal programs: a `main` exit
status of `0` passes, while any non-zero status fails the package test command
with exit `1`. `typelisp test --check` type-checks generated inline harnesses
and integration test files without assembling or linking. Package integration
discovery skips reserved fixture corpora such as
`tests/diagnostics/**`, `tests/format_golden/**`, `tests/inline/**`,
`tests/no-libc/**`, `tests/safety/**`, and `tests/spmd/**`; it also leaves
`tests/integration/**` to explicit integration manifests when
`tests/integration/native-*.manifest` exists. Dedicated verification scripts
own those files. Tests commonly import `stdlib/test.tl` for assertion helpers.

CI runs `scripts/verify-inline-tests.sh`, which auto-discovers inline
test-bearing `.tl` files under `selfhost/`, `stdlib/`, `tests/integration/`,
`tests/inline/`, and `examples/`. Add inline tests without editing a manifest;
the script fails if discovered tests do not type-check, build, or pass.

### Enum and struct namespace rules

In the current flat stage0 model, TypeLisp keeps **type names** and **value
names** in separate namespaces:

- **Type namespace**: enum and struct type names share one namespace, so
  `defenum Shape` and `defstruct Shape` collide.
- **Value namespace**: functions, variables (`define`), `extern`s, struct
  constructors, and enum *variant* constructors all share one namespace, so a
  variant `Foo` cannot coexist with a function, variable, or `extern` named
  `Foo`, even if they belong to different enums.
- An enum *type* name may intentionally share a name with one of its own
  variants (e.g. `defenum Result (Result i64) (Err String)`), because the type
  and the constructor live in different namespaces.

The selfhost module model keeps the same value/type split inside each module,
then qualifies exported names by module identity so two modules can define the
same local value or type name without colliding.

### Expression forms

`if`, `when`, `unless`, `let`, `while`, `begin`, `set!`, `match` (incl.
nested/recursive enum patterns and `_`), `ann`, `cast`, `foreach`,
`spmd-reduce`, plus
arithmetic (`+ - * / %`),
comparison (`= != < <= > >=`), boolean (`and` `or`), and bitwise/shift
(`bit-and` `bit-or` `bit-xor` `shl` `shr`) operators. `struct-get` reads a
struct field, and `(set! (struct-get place field) value)` writes one in place.

Named top-level functions and `lambda` literals can be passed as pointer-sized
closure descriptor values. Non-capturing lambdas use static descriptors.
Capturing lambdas snapshot supported captures into heap environments: scalars,
function values, `String`, dynamic arrays, tuples/structs/enums, and fixed
arrays, including nested aggregate and fixed-array contents that are recursively
deep-copied. The aggregate captures snapshot their storage onto the heap so the
environment can outlive the creating frame. Local non-escaping closures may
capture immutable references (#2280); escaping closures still reject reference
captures, and mutation of captured names is rejected (#2552).
SPMD/SIMD `foreach` is documented in [SPEC.md section 5.15](SPEC.md). The
compiler parses and type-checks the first source form and lowers it to scalar
reference loops; `--backend-mode avx2|avx512` supports a first contiguous
map/zip subset over `i32`, `i64`, `f32`, and `f64` lanes. Runtime-dispatched
SIMD variants are specified with `defdispatch`:
ordinary calls resolve once per process to AVX-512, AVX2, or scalar fallback
using the same CPUID/XGETBV capability checks exposed by `stdlib/cpu.tl`.
`spmd-reduce` scalar lowering supports `sum` over `i32`, `i64`, and `f64`,
`min`/`max` over `i32` and `i64`, and `all`/`any` over `bool`. SIMD backend
modes vectorize eligible contiguous array reductions: `sum` over `i32`, `i64`,
and `f64`; `min`/`max` over `i32`; and AVX-512 `min`/`max` over `i64`. The
SPEC also defines the next masked varying `if` slice; the current compiler
still rejects varying `if` until that implementation lands. `SPEC.md` also
defines the future `(program-index)` and `(program-count)` SPMD lane identity
forms; compiler support is still pending, and programs that use those forms
intentionally observe backend gang width.

### Builtins

Compiler-owned builtins are `print`, `print-bool`, `print-newline`,
`make-array`, `array-ref`, `array-set!`,
`array-length`/`length`; strings: `string-length`/`length`,
`string-ref`/`char-at`, `string-eq`/`string=?`, `substring`/`string-slice`,
`string->int`, `int->string`; and `panic`/`error`.
Array and string indexing is bounds-checked at runtime. File, stdin/stdout,
argv, filesystem, and richer printing helpers live in `stdlib/io.tl` and
`stdlib/fs.tl`; import those modules to use `read-file`, `write-file`,
`file-open`, `read-stdin-line`, `flush-stdout`, `fs-*`, and related APIs.
For user-facing string concatenation, import `stdlib/str_cat.tl` and use
`str-cat` for fixed-arity joins; use `stdlib/text_buf.tl` for incremental
builders. `string-append`/`string-concat` are deprecated low-level
compatibility primitives kept for legacy code. The
staged lint rule is available with `typelisp lint --deprecated-string-concat`
while the remaining in-tree migrations land.

### Memory and aliasing

TypeLisp implements v1 move-only aggregate semantics and lexical
immutable/mutable borrow checking; it does not implement destructors, `free`,
or a garbage collector, and non-lexical lifetimes remain future work (#810).
Scalars, raw pointers, and non-capturing function values are copyable, while
`String`, arrays, tuples, structs, enums, and capturing closures move in
by-value positions. Aggregate values are implemented as
pointer-sized handles in the IR/ABI, but those handles are not checked language
references. The v1 raw pointer design is now specified as explicit unsafe
syntax:
`(Ptr T)`/`(MutPtr T)` are nullable, copyable pointer-sized values, and
dereference/write/offset/cast operations require `(unsafe ...)`. The selfhost
compiler implements that surface for FFI/runtime work; it is not the future safe
reference/borrow model.

`String` values are immutable at the source level. Dynamic arrays are mutable
buffers reached through a live owner handle or an exclusive mutable reference;
`array-set!` and `array-push!` reject immutable-reference receivers. Struct
fields can be mutated in place with `(set! (struct-get place field) value)`
when the receiver is an owned storage place or mutable reference; immutable
reference receivers are rejected. The current IR/ABI may
still carry aggregate values through pointer-shaped heap handles in positions
not covered by the new layout-query contract. Heap allocation uses a
backend-emitted `tl_alloc` bump allocator and allocations live until process
exit. See [SPEC.md](SPEC.md) sections 4.6.2 and 7 for the precise current and
specified model.

`SPEC.md` also defines the v1 owned `String` / borrowed `str` direction:
string literals remain owned `String` values, `str` is a borrowed-only referent
used as `(& lifetime str)`, and borrowing a `String` place produces a borrowed
`str` view. Typed calls auto-borrow borrowable places for immutable reference
parameters, including `String` places passed to `(& lifetime str)`. The `str`
frontend and stdlib API migration are implemented
(#1453, #1454); several compiler builtins keep compatibility `String`
signatures. Mutable binary storage is specified separately as owned `ByteBuf`
plus `(& lifetime bytes)` / `(&mut lifetime bytes)` borrowed views; conversions
between text, arrays, and byte buffers are explicit copy or borrow boundaries.

Lifetime-parameterized named aggregates are specified with declaration metadata
such as `(:lifetimes r)` on `defstruct`/`defenum` and type uses such as
`(RefBox r)`. Those arguments are lifetime names only, not source-level generic
type parameters; selfhost parser/typechecker support is implemented (#1722) —
see `stdlib/text_buf_borrowed.tl` and `stdlib/vector_slice.tl` for usage.

`(Box T)` is specified as a safe, move-only, arena-owned indirection handle:
`(box expr)` allocates `expr` in the active arena, and `(box-get b)` projects
the boxed value for read/pattern use under the move rules. A box allocated
inside `(with-arena r ...)` is typed as `(in r (Box T))` and cannot escape that
scope. It provides the explicit indirection required by the default inline
aggregate layout contract for recursive structs/enums; complete enforcement is
staged separately (#2554). Destructive `box-take` and mutable access through
boxes remain future work (#2553).

The v1 reclamation direction keeps a process-lifetime default arena per thread
and does not add general per-object `free` or GC yet. `String` buffers, dynamic
array storage, returned enum/struct storage, and self-hosted data structures all
remain heap allocations in the active arena.
General `free` is deferred until ownership, borrowing, and reference semantics
are enforced, because arbitrary object reclamation before move/borrow checking
would make double-free and use-after-free errors expressible. A tracing GC is
also larger than the next step.

The first safe reclamation surface is `(with-arena r body ...)` — a
lexically scoped arena with **static escape checking**. The arena model uses
"scoped arena" for this behavior. The typechecker rejects any arena-tagged value
that would leave the scope, so the compiler
can safely lower the form to `tl_region_mark` / `tl_region_reset` around the
body. This makes scoped cleanup safe by construction, unlike the raw extern
helpers below. See [SPEC.md §5.16](SPEC.md) and §7.3 for the full contract.

The standard scratch patterns are: use `(with-arena scratch ...)` for temporary
work that returns only scalars or outer-owned values; use `(with-escape scratch
...)` with a first-class arena from `arena-make` when one supported result must
be cloned out; reserve manual `arena-set!` / `arena-rewind` / `arena-destroy`
calls for unsafe internals that can prove every invalidated handle is dead.

Scoped cleanup of non-memory resources is separate. The implemented
`(with ([name init cleanup]) body ...)` form (SPEC.md §5.19) runs cleanup
functions in reverse binding order on scope exit for files, process handles,
locks, mapped files, and similar resources; it does not imply destructors,
`free`, or arena reset semantics.

Programs that need manual control import `stdlib/arena.tl` and use the
first-class arena helpers. `arena-make`, `arena-current`, and `arena-mark` are
safe because they only create/read handles or record a reset mark. `arena-set!`,
`arena-destroy`, and `arena-rewind` require
`(unsafe ...)`, because switching, freeing, or rewinding arenas can invalidate
live heap handles. The safe `with-arena` surface remains preferred for scoped
cleanup. See [SPEC.md §7.3](SPEC.md) for details.

See [SPEC.md](SPEC.md) for the full language reference.

## Self-hosting sources

The [`selfhost/`](selfhost) directory builds up a TypeLisp front end *written in
TypeLisp*:

- `lexer.tl` — a tokenizer for TypeLisp's own s-expression syntax.
- `read.tl` — an s-expression reader producing a recursive `Sexpr` cons-cell tree (an importable module).
- The REPL and all tooling evaluate through the real compiler path only:
  source is parsed, typechecked, compiled, linked, and run by the same pipeline
  used for non-interactive commands.

Compiler self-test and smoke-driver conventions are documented in
[`selfhost/TESTING.md`](selfhost/TESTING.md).
The published stage0 is a single self-hosted [`selfhost/cli.tl`](selfhost/cli.tl)
binary per OS (`typelisp-stage0-linux`, `typelisp-stage0-windows.exe`) that
handles every toolchain command in-process. The `Bootstrap Stage0` workflow
([`.github/workflows/bootstrap-stage0.yml`](.github/workflows/bootstrap-stage0.yml))
is **self-perpetuating**: on each merge to `main` it fetches the
previously published stage0, uses *that* compiler to build the next stage0 from
`selfhost/cli.tl`, and publishes the result to the `stage0-latest` and immutable
`stage0-*` releases. Each stage0 therefore builds its own successor. To reproduce
that build locally, run [`scripts/build-stage0.sh`](scripts/build-stage0.sh) with
a fetched stage0 as the seed:

```sh
scripts/fetch-stage0.sh
scripts/build-stage0.sh target/stage0/typelisp typelisp-stage0-linux   # Linux
scripts/build-stage0.sh target/stage0/typelisp.exe typelisp-stage0-windows.exe  # Windows (Git Bash)
```

`build-stage0.sh` compiles `selfhost/cli.tl` to assembly with the seed and links
it through the host toolchain (`as`/`ld` on Linux; `clang` + MSVC `link.exe` on
Windows). The bootstrap path deliberately uses `compile` plus the native linker
so a stage0 can build its successor without depending on its own `build` command.

Published stage0 compilers can be fetched with
[`scripts/fetch-stage0.sh`](scripts/fetch-stage0.sh), or
[`scripts/fetch-stage0.ps1`](scripts/fetch-stage0.ps1) from PowerShell. Both
download the single host asset and install it as the command under
`target/stage0/`.

To run the same stage0 verification gate used by CI, run
`scripts/ci-verify.sh`; it fetches `stage0-latest` when
`TYPELISP_BIN` is unset. The gate performs a single compiler build on every
host: the published compiler seeds the stage1->stage2->stage3 bootstrap
fixpoint over `selfhost/cli.tl`, and every remaining gate then runs on the
freshly bootstrapped stage2 compiler (the branch-built full CLI).

The fixpoint gate is `scripts/check-bootstrap-fixpoint.sh`. On Linux it emits
and compares Linux assembly through `as` and `ld`; on Git Bash/MSYS/Cygwin for
Windows it emits `windows-x86_64` assembly, assembles with `clang
--target=x86_64-pc-windows-msvc -c`, links compiler stages with MSVC
`link.exe`, and compares `stage2.s` with `stage3.s`. From Git Bash:

```sh
scripts/fetch-stage0.sh
scripts/check-bootstrap-fixpoint.sh target/stage0/typelisp.exe
```

From PowerShell, fetch the Windows stage0 and invoke the same script through
`bash`:

```powershell
powershell -ep Bypass -f scripts\fetch-stage0.ps1
bash scripts/check-bootstrap-fixpoint.sh target/stage0/typelisp.exe
```

Set `TYPELISP_WINDOWS_CLANG` or `TYPELISP_WINDOWS_LINK` to override tool
discovery. The Windows path requires a Clang that accepts the MSVC target plus a
Visual Studio/MSVC `link.exe` and Windows SDK installation.

Smaller runnable examples, including `calc.tl`, remain in [`examples/`](examples).

## Documentation site

A static language-reference and stdlib/API documentation site is generated
entirely in TypeLisp by [`selfhost/doc_site.tl`](selfhost/doc_site.tl) and
published to GitHub Pages at <https://jonil-botta.github.io/typelisp/>. Pushes
to `main` rebuild and publish it automatically via the
[`Publish Docs`](.github/workflows/docs-pages.yml) workflow; pull requests build
and validate the site without publishing (the "Verify docs site" step in CI).

Build the site locally into any output directory:

```bash
typelisp run selfhost/doc_site.tl -- target/site
# Build + validate links/anchors the way CI does (no publish):
scripts/verify-doc-site.sh
```

## Architecture

```
Source (.tl)
    ↓  Lexer        → Tokens
    ↓  Parser       → AST
    ↓  Type Checker → Typed AST
    ↓  Lowerer      → IR (3-address code, basic blocks)
    ↓  Optimizer    → constant folding, GVN/CSE, copy propagation, DCE, LICM with loop preheaders, function inlining, strength reduction; opt-level 2 adds scalar register allocation
    ↓  Backend      → x86_64 assembly (.s)
    ↓  target tools → native executable
```

## CLI

```text
Synopsis:
    typelisp - A typed Lisp/Scheme dialect with x86_64 backend

Usage:
    typelisp <command> [options]
    typelisp <command> --help

Commands:
    typelisp build          Build a source file or package artifact
    typelisp check          Type check a source file or package
    typelisp clean          Remove build artifacts
    typelisp compile        Generate assembly or IR
    typelisp doc            Generate documentation or run doc tests
    typelisp fmt            Format source files or a package
    typelisp init           Scaffold a package in the current directory
    typelisp lint           Lint source files or a package
    typelisp lsp            Start stdio LSP diagnostics server
    typelisp new            Scaffold a new package directory
    typelisp repl           Start minimal stdio REPL
    typelisp run            Compile, link, and run a source file
    typelisp test           Run or check inline tests
```

`check` is the public type-check command.

Common options include `--target <target>`, `--backend-mode <mode>`,
`--manifest-path <file>`, `--stdlib-root <dir>`, `--opt-level <0|1|2>`,
`--locked`, `--update-lock`, and `--cfg <name>`. Run command-specific help with
`typelisp <command> --help`.

The `typelisp repl` command provides a stdio command loop for `.help`,
`.type <expr>`, and `.exit`. Top-level declarations are remembered for later
commands and bare expressions are evaluated by compiling a scratch program
through the TypeLisp-owned build/run path.

`compile`, `run`, and `build` accept `--backend-mode scalar|avx2|avx512`.
`scalar` is the default. `avx2` and `avx512` support a first contiguous SPMD
`foreach` map/zip subset over `i32`, `i64`, `f32`, and `f64` lanes, plus
eligible `spmd-reduce` array folds. Scalar `spmd-reduce` lowering supports
`sum`, `min`, `max`, `all`, and `any` over the SPEC.md supported types.
AVX-512 uses ZMM vectors and opmask predicated tails, and additionally
vectorizes `i64` min/max reductions.
Unsupported vector IR falls back or rejects explicitly.
Masked varying `if` semantics are specified in SPEC.md as the next SPMD slice,
but are not implemented yet. The future `(program-index)`/`(program-count)`
lane identity forms are also specified in `SPEC.md` but not accepted by the
current compiler.

`compile` accepts repeated `--cfg <name>` flags. Enabled names control `(cfg
predicate declaration)` and expression-level `(cfg predicate expr [else-expr])`
forms. Without `--cfg`, named predicates are false, `(all ...)` is true only when
all operands are true, `(any ...)` is true when any operand is true, and
`(not ...)` negates one predicate. Target OS predicates are enabled implicitly
from `--target`: `linux`, `unix`, `target-linux`, and `os-linux` for
`linux-x86_64`; `windows`, `target-windows`, and `os-windows` for
`windows-x86_64`.

The language-level runtime dispatch design is specified as `defdispatch` in
`SPEC.md`: one logical function can list scalar, AVX2, and AVX-512 variant
functions, with scalar required as the fallback. Ordinary calls do not need to
manually call CPU detection helpers.

`compile`, `run`, source-file `build`, and `test` accept
`--target linux-x86_64|windows-x86_64`. Linux is the default output target for
compile/build. `test` defaults to the host target so the generated executable
can run locally. Windows native builds use the Windows x64 ABI, a CRT-linked
runtime helper policy, and the `clang` + `lld-link` toolchain.

Source-file `typelisp build`/`typelisp run` and package build (`typelisp build
[--manifest-path <typelisp.pkg>]`) accept `--opt-level 0|1|2`. Package builds
also accept `--profile dev|release` and `--release`; the selected profile is
visible in `target/<profile>/`. When `--opt-level` is
omitted, the release profile uses level 2 and the dev profile uses level 0.
Explicit `--opt-level` overrides the profile default. `--opt-level 0` builds
without the IR optimizer (faster compiles, larger/slower code), level 1 runs the
cheap stack-only optimizer path, and level 2 runs the full optimizer plus scalar
register allocation and inlining.
Higher levels may spend more compile time but must preserve program semantics —
the exit/output of a program never depends on the level. The package-build flags
report missing/duplicate/invalid diagnostics.
Package builds also accept `--locked` to require a matching `typelisp.lock`
without rewriting it, and `--update-lock` to refresh remote pins and rewrite the
lockfile. These flags are rejected for source-file builds.

## Status

Implemented: lexer, parser, type checker, IR lowering, optimizer, and working
x86_64 Linux/Windows backend targets. Integers, floats (`f64`/`f32`), bool/char/unit,
`if`/`while`/`begin`, local & global variables, direct and indirect calls,
`cast`, enums + `match`, structs + field access/mutation, dynamic arrays, strings,
`extern`, multi-file modules, scalar `foreach`, an initial SIMD `foreach`
map/zip path, and initial SIMD `spmd-reduce` folds all compile to native code. See the
[project roadmap](https://github.com/JoNil-Botta/typelisp/issues/8) and
[SPEC.md §8](SPEC.md) for what is not yet supported (mutation of captured
names, indirect/closure tail calls, general GC/free, non-lexical lifetimes,
masked varying SPMD control flow, and
later public SPMD/SIMD cross-lane work). Raw pointer types and unsafe pointer
operations are implemented, including local scalar address-of scratch pointers
for FFI out-params. Broader C-string and address-of ergonomics remain follow-up
FFI work.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Two standing policies to note: TypeLisp
is **self-hosted with zero dependencies** (implementation, tooling, and tests are
written in TypeLisp), and **syntax changes carry no aliases** — when a spelling
changes, every usage migrates and the old form is removed in the same change
rather than kept as a parallel parser path.

## License

MIT
