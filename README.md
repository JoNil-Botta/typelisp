# TypeLisp

A statically typed Lisp/Scheme dialect that compiles directly to native
x86_64 assembly for Linux and Windows. **Self-hosted**: the compiler is written
in TypeLisp and compiles itself, with **zero third-party dependencies**.

## Goals and inspirations

Current implementation goals:

- **Typed**: Every expression has a known type at compile time. No runtime type tagging.
- **Native**: Compiles straight to x86_64 assembly, then native toolchains produce executables. Linux uses `as` + `ld`; Windows uses `clang` + MSVC `link.exe`. No bytecode VM, no interpreter, no garbage collector.
- **Self-hosted**: The compiler, tooling, and stdlib are written in TypeLisp (see [`selfhost/`](selfhost) and [`stdlib/`](stdlib)). The published stage0 compiler is a single self-hosted binary that builds its own successor; there is no Rust (or other-language) implementation in the toolchain.
- **Zero dependencies**: No third-party packages. The only build inputs are the native assembler/linker toolchain.

Language direction:

- Keep a minimal language core with Lisp/Scheme syntax and explicit types.
- Be expressive enough for C-style systems programming: native layout,
  runtime/FFI escape hatches, deterministic builds, and direct linker interop.
- Pursue Rust-style safety for ownership, borrowing, move semantics, and arena
  lifetimes. Safe TypeLisp should not have undefined behavior; the arena and
  borrow work is tracked by #801, #802, #803, #805, #814, and #182.
- Treat ISPC-style SPMD as the data-parallel model. The current source surface
  is in [SPEC.md section 5.15](SPEC.md); selfhost parity and optimization work
  is tracked by #791 and #937.
- Use Zig-style comptime as the abstraction mechanism. TypeLisp should not grow
  source-level generics, traits, interfaces, or `impl` syntax; comptime code
  should generate concrete types, functions, and implementation bundles instead.
  See #893, #913, #970, and #902.
- Move toward C3-style modules where module identity participates in name
  resolution and prefixes TypeLisp linker symbols; see #950, #952, and #953.
- Use an arena-based memory model with a default program-lifetime arena and
  scoped `(with-arena ...)` allocation regions (#801).
- Land new language features in the self-hosted compiler ([`selfhost/`](selfhost)).
  The toolchain is fully self-hosted (#666, #795); each published stage0 binary
  builds its successor.

The language-direction bullets above are future goals. The rest of this README
describes current behavior unless it explicitly says a feature is planned.

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
;; Global variable (scalar literal initializer only)
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
```

`cast` supports the full scalar numeric matrix: integer/char widening,
narrowing, and truncation; `f64` <-> `f32` precision changes; and integer/char
<-> float conversions (float -> integer truncates toward zero).

### Types

```
i64 i32 i16 i8   u64 u32 u16 u8   f64 f32   bool   char   unit   String
(Array t)         ; dynamic, runtime-sized array
(Array t n)       ; fixed-size array (literals/ref/set compile; returns rejected)
(Tuple t1 t2 ...) ; local tuple literals/ref compile; params/returns rejected
(Box t)           ; specified arena-owned indirection for recursive aggregates
(& r t)           ; specified immutable reference tied to lifetime/arena r
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
functions, and implementation bundles. Until that path lands, write explicit
monomorphic declarations such as `MaybeI64` or domain-specific `Result*` enums.
Use `(return expr)` for function-local early exits, `(when cond body...)` /
`(unless cond body...)` for unit-valued guards, and `(try expr)` for the
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
(extern foreign-add : (-> i64 i64 i64))
(extern local-add (:abi c) (:symbol "foreign_add_exact") : (-> i64 i64 i64))
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
name. `(:symbol "...")` can bind a local TypeLisp declaration to an exact
foreign linker symbol without applying the `_tl_` prefix used for ordinary
TypeLisp declarations.

The compiler still uses the legacy flat import model: imported
definitions merge into one top-level namespace. The module direction is
private-by-default modules with canonical identities, `(export ...)`, import
aliases, and qualified names such as `math/add`; see `SPEC.md` section 4.4 for
the specified migration contract. Macro exports/imports use the same module
loader identities and path-resolution rules, with macro expansion happening
before ordinary runtime typechecking.

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

Stdlib macros are explicit imports, not an automatic prelude. The checked-in
core macro module is available as
`(import "stdlib/core_macros.tl" module stdlib.core-macros as core)`, after
which exported macros are called through the alias, for example `core/when` and
`core/unless`. Unqualified built-in guard forms remain available during the
transition to the final stdlib macro migration, but local macros named `when`
or `unless` now take precedence before the compatibility guard desugaring runs.
The legacy bracket-arm `cond` form remains compatibility parsed while a flat
call-shaped `cond` can be used by macro migration tests.

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
`target/typelisp/<profile>/<package-name>/`, where the package build profile
defaults to `release`. `--profile dev` uses the `dev` profile; `--profile
release` and `--release` select the release profile. Omitted `kind` defaults to
`bin`; omitted `entry` defaults to `src/main.tl` for binaries and `src/lib.tl`
for static libraries. `kind "bin"` builds a native executable named after the
package; `kind "staticlib"` builds a static archive (`lib<name>.a` on Linux,
`<name>.lib` on Windows). `kind "lib"` remains accepted as a compatibility
alias. Dependency entries may use a local path relative to that same package
root, an absolute path, or the GitHub shorthand form shown above. `tag` and
`branch` pins are also accepted, and the shorthand normalizes to
`https://github.com/owner/repo.git#rev=commit`. Remote entries currently report
a fetch-support diagnostic until git dependency fetch, cache, and lockfile
support lands; local paths keep the existing behavior.

The repository root is also a package. From a checkout, `typelisp build` builds
the unified selfhost CLI from `selfhost/cli.tl` and writes
`target/typelisp/typelisp/typelisp` (or
`target/typelisp/typelisp/typelisp.exe` on Windows). Stage0 publication still
uses `scripts/build-stage0.sh`, which compiles `selfhost/cli.tl` directly until
the remaining standalone-driver cleanup tracked by #1574 lands.

Inside a package build, imports of the form `(import
"pkg:math/src/lib.tl")` resolve from the dependency root declared for alias
`math`; ordinary string imports remain relative to the importing file, and
`stdlib/...` imports keep their local-first then configured-root then embedded
fallback behavior.

Under the legacy loader, imported package definitions share the same flat
top-level namespace as local modules, so duplicate value or type names fail
through the existing duplicate definition diagnostics. The package slice still
has no registry, version solving, lockfile, or workspace model; namespace
isolation and qualified symbol lookup are specified for the selfhost module
model in `SPEC.md`.

Documentation comments can contain checked examples. `typelisp doc --test
<file.tl>` extracts fenced `typelisp` or `tl` blocks from `;#` module docs and
attached `;:` item docs, writes each example to a deterministic temporary
source file, type-checks it, and removes the temporary directory before exiting.
The self-hosted Markdown generator can render one source file through
`typelisp run selfhost/doc.tl -- input.tl output.md`; import-graph traversal is
separate follow-up work.

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
compile and run through the self-hosted no-Rust build/run path and compare exact
exit status, stdout, and stderr. Unsupported hosts report an unsupported
runnable doctest diagnostic. Ordinary `;` and `;;` comments are not
documentation and are ignored by the doctest scanner. `;#` and `;:` are the
only public documentation comment syntaxes.

Inline tests can live next to source declarations as `(test name body...)`
items. Normal `check`, `compile`, `build`, and `run` ignore them. `typelisp
test <file.tl>` loads the import graph, turns inline tests into private
unit-returning functions, generates a test-owned `main`, and runs the resulting
executable. `typelisp test --check <file.tl>` type-checks that generated
harness without assembling or linking. Tests commonly import `stdlib/test.tl`
for assertion helpers.

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
nested/recursive enum patterns and `_`), `ann`, `cast`, `foreach`, plus
arithmetic (`+ - * / %`),
comparison (`= != < <= > >=`), boolean (`and` `or`), and bitwise/shift
(`bit-and` `bit-or` `bit-xor` `shl` `shr`) operators. `struct-get` reads a
struct field.

Named top-level functions and `lambda` literals can be passed as pointer-sized
closure descriptor values. Non-capturing lambdas use static descriptors.
Capturing lambdas snapshot supported captures into heap environments: scalars,
function values, `String`, dynamic arrays, tuples/structs/enums, and fixed
arrays, including nested aggregate and fixed-array contents that are recursively
deep-copied. The aggregate captures snapshot their storage onto the heap so the
environment can outlive the creating frame. Capturing aggregate-element
references and mutation of captured names are still rejected. `SPEC.md`
specifies the future checker-only rule for local non-escaping immutable
reference captures; relaxing the current rejection is tracked by #808.
SPMD/SIMD `foreach` is documented in [SPEC.md section 5.15](SPEC.md). The
compiler parses and type-checks the first source form and lowers it to scalar
reference loops; `--backend-mode avx2|avx512` supports a first contiguous
map/zip subset over `i32`, `i64`, `f32`, and `f64` lanes. Runtime-dispatched
SIMD variants are specified with `defdispatch`:
ordinary calls resolve once per process to AVX-512, AVX2, or scalar fallback
using the `stdlib/cpu.tl` capability checks. Parser/compiler support for
`defdispatch` is pending. `spmd-reduce` scalar lowering is implemented, and
SIMD backend modes vectorize eligible contiguous array reductions: `sum` over
`i32`, `i64`, and `f64`; `min`/`max` over `i32`; and AVX-512 `min`/`max` over
`i64`.

### Builtins

Compiler-owned builtins are `print`, `print-bool`, `print-newline`,
`make-array`, `array-ref`, `array-set!`,
`array-length`/`length`; strings: `string-length`/`length`,
`string-ref`/`char-at`, `string-eq`/`string=?`, `string-append`/`string-concat`,
`substring`/`string-slice`, `string->int`, `int->string`; and `panic`/`error`.
Array and string indexing is bounds-checked at runtime. File, stdin/stdout,
argv, filesystem, and richer printing helpers live in `stdlib/io.tl` and
`stdlib/fs.tl`; import those modules to use `read-file`, `write-file`,
`file-open`, `read-stdin-line`, `flush-stdout`, `fs-*`, and related APIs.

### Memory and aliasing

TypeLisp does not currently implement source-level borrow checking,
destructors, `free`, or a garbage collector. `SPEC.md` now defines v1
move-only aggregate handle semantics and the reserved immutable borrow
expression forms `(& place)` / `(& arena place)` for the selfhost checker:
scalars, raw pointers, and non-capturing function values are copyable, while
`String`, arrays, tuples, structs, enums, and capturing closures move in
by-value positions. The current compiler may still accept aggregate
copies until that checker lands. Aggregate values are implemented as
pointer-sized handles in the IR/ABI, but those handles are not checked language
references. The v1 raw pointer design is now specified as explicit unsafe
syntax:
`(Ptr T)`/`(MutPtr T)` are nullable, copyable pointer-sized values, and
dereference/write/offset/cast operations require `(unsafe ...)`. The selfhost
compiler implements that surface for FFI/runtime work; it is not the future safe
reference/borrow model.

`String` values are immutable at the source level. Dynamic arrays are mutable
buffers reached through a live owner handle; `array-set!` is a temporary
borrow-like compatibility operation until mutable references land. Structs are
read-only today because `struct-set!` is not implemented. The current IR/ABI may
still carry aggregate values through pointer-shaped heap handles in positions
not covered by the new layout-query contract. Heap allocation uses a
backend-emitted `tl_alloc` bump allocator and allocations live until process
exit. See [SPEC.md](SPEC.md) sections 4.6.2 and 7 for the precise current and
specified model.

`SPEC.md` also defines the v1 owned `String` / borrowed `str` direction:
string literals remain owned `String` values, `str` is a borrowed-only referent
used as `(& lifetime str)`, and borrowing a `String` place produces a borrowed
`str` view. Implementation of the `str` frontend and stdlib API migration is
still pending; current public builtins continue to use compatibility `String`
signatures.

Lifetime-parameterized named aggregates are specified with declaration metadata
such as `(:lifetimes r)` on `defstruct`/`defenum` and type uses such as
`(RefBox r)`. Those arguments are lifetime names only, not source-level generic
type parameters; selfhost parser/typechecker support is tracked by #1722.

`(Box T)` is specified as a safe, move-only, arena-owned indirection handle:
`(box expr)` allocates `expr` in the active arena, and `(box-get b)` projects
the boxed value for read/pattern use under the move rules. A box allocated
inside `(with-arena r ...)` is typed as `(in r (Box T))` and cannot escape that
scope. It provides the explicit indirection required by the default inline
aggregate layout contract for recursive structs/enums; complete enforcement is
staged separately.

The v1 reclamation direction keeps the program-lifetime arena as the default
allocation target and does not add general per-object `free` or GC yet.
`String` buffers, dynamic array storage, returned enum/struct storage, and
self-hosted data structures all remain heap allocations in the active arena.
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

Scoped cleanup of non-memory resources is separate. The SPEC reserves
`(with ([name init cleanup]) body ...)` for explicit cleanup of files, process
handles, locks, mapped files, and similar resources; it is not implemented yet
and does not imply destructors, `free`, or arena reset semantics.

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
- `eval.tl` — a tree-walking evaluator over that tree, with integers, strings, cons pairs, and interpreted first-class closures.

Compiler self-test and smoke-driver conventions are documented in
[`selfhost/TESTING.md`](selfhost/TESTING.md).
The published stage0 is a single self-hosted [`selfhost/cli.tl`](selfhost/cli.tl)
binary per OS (`typelisp-stage0-linux`, `typelisp-stage0-windows.exe`) that
handles every toolchain command in-process. The `Bootstrap Stage0` workflow
([`.github/workflows/bootstrap-stage0.yml`](.github/workflows/bootstrap-stage0.yml))
is **self-perpetuating with no Rust**: on each merge to `main` it fetches the
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
`scripts/verify-no-rust-stage0.sh`; it fetches `stage0-latest` when
`TYPELISP_BIN` is unset. On Linux, that gate uses the published compiler as the
bootstrap seed, checks the stage0-to-stage1 bootstrap, then runs deterministic
assembly and the toolchain capability gates through the freshly bootstrapped
stage1 compiler directly. On Windows, the host-supported gates run against the
published stage0 compiler and the gate also runs the native MSVC link smoke plus
the stage2/stage3 Windows fixpoint when the seed has the required staged runtime
symbols.

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
    ↓  Optimizer    → constant folding, basic-block CSE, DCE, strength reduction, copy propagation
    ↓  Backend      → x86_64 assembly (.s)
    ↓  target tools → native executable
```

## CLI

```bash
typelisp lsp                      # Start stdio LSP diagnostics server
typelisp repl                     # Start minimal stdio REPL (.help, .type, .exit)
typelisp check          file.tl    # Type check
typelisp compile        file.tl    # Generate assembly (.s); -o <path>, --target <target>, --emit-ir, --backend-mode <mode>, --cfg <name>
typelisp build          file.tl    # Build native executable; -o <path>, --target <target>, --backend-mode <mode>
typelisp run            file.tl    # Compile, assemble, link, and run; --target <target>, --backend-mode <mode>
typelisp build                    # Build nearest typelisp.pkg artifact; --profile dev|release, --target <target>, --backend-mode <mode>
typelisp fmt            file.tl    # Format source in place; --check reports changes without writing
typelisp lint           file.tl    # Report lint findings; --check exits non-zero when findings are present
typelisp test           file.tl    # Run inline `(test ...)` items; --check type-checks the generated harness
```

`check` is the public type-check command.

The selfhost REPL driver provides a stdio command loop for `.help`,
`.type <expr>`, and `.exit`. Top-level declarations are remembered for later
commands and bare expressions are evaluated by compiling a scratch program
through the TypeLisp-owned build/run path.

`compile`, `run`, and `build` accept `--backend-mode scalar|avx2|avx512`.
`scalar` is the default. `avx2` and `avx512` support a first contiguous SPMD
`foreach` map/zip subset over `i32`, `i64`, `f32`, and `f64` lanes, plus
eligible `spmd-reduce` array folds. AVX-512 uses ZMM vectors and opmask
predicated tails, and additionally vectorizes `i64` min/max reductions.
Unsupported vector IR falls back or rejects explicitly.

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

The selfhost source-file build/run tools (`selfhost/build.tl --direct`,
`selfhost/run.tl --direct`) and package build (`typelisp build
[--manifest-path <typelisp.pkg>]`) accept `--opt-level 0|1|2|3`. Package builds
also accept `--profile dev|release` and `--release`; the selected profile is
visible in `target/typelisp/<profile>/<package-name>/`. When `--opt-level` is
omitted, the release profile uses level 2 and the dev profile uses level 0.
Explicit `--opt-level` overrides the profile default. `--opt-level 0` builds
without the IR optimizer (faster compiles, larger/slower code) while `1|2|3` run
it.
Higher levels may spend more compile time but must preserve program semantics —
the exit/output of a program never depends on the level. The package-build flags
report missing/duplicate/invalid diagnostics. The finer numeric meanings and a
canonical default are reserved for the optimizer-policy work split from \#939.

## Status

Implemented: lexer, parser, type checker, IR lowering, optimizer, and working
x86_64 Linux/Windows backend targets. Integers, floats (`f64`/`f32`), bool/char/unit,
`if`/`while`/`begin`, local & global variables, direct and indirect calls,
`cast`, enums + `match`, structs + field access, dynamic arrays, strings,
`extern`, multi-file modules, scalar `foreach`, an initial SIMD `foreach`
map/zip path, and initial SIMD `spmd-reduce` folds all compile to native code. See the
[project roadmap](https://github.com/JoNil-Botta/typelisp/issues/8) and
[SPEC.md §8](SPEC.md) for what is not yet supported (aggregate-element
reference captures, tail calls, tuple/fixed-array by-value returns,
general GC/free, ownership/borrowing, and later public SPMD/SIMD cross-lane
work). Raw pointer types and unsafe pointer operations are
implemented, while C-string/address-of ergonomics remain follow-up FFI work.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Two standing policies to note: TypeLisp
is **self-hosted with zero dependencies** (implementation, tooling, and tests are
written in TypeLisp), and **syntax changes carry no aliases** — when a spelling
changes, every usage migrates and the old form is removed in the same change
rather than kept as a parallel parser path.

## License

MIT
