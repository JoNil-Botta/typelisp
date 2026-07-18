# TypeLisp

A statically typed Lisp/Scheme dialect that compiles directly to native
x86_64 assembly for Linux and Windows. **Self-hosted**: the compiler is written
in TypeLisp and compiles itself, with **zero third-party dependencies**.

## Goals

- **Typed**: every expression has a known type at compile time. No runtime
  type tagging.
- **Native**: compiles straight to x86_64 assembly, then native toolchains
  produce executables (Linux: `as` + `ld`; Windows: `clang` + MSVC
  `link.exe`). No bytecode VM, no interpreter, no garbage collector.
  Supported targets are `linux-x86_64` and `windows-x86_64`; macOS and ARM
  are not near-term goals.
- **Self-hosted**: the compiler, tooling, and stdlib are written in TypeLisp
  (see [`src/`](src) and [`stdlib/`](stdlib)). The published stage0 compiler
  is a single self-hosted binary that builds its own successor; the toolchain
  has no other-language implementation.
- **Zero dependencies**: no third-party packages. The only build inputs are
  the native assembler/linker toolchain.
- **Fast**: generated code quality should approach LLVM (`clang -O2`) on the
  benchmark corpus while compilation itself stays fast. Performance is
  tracked deterministically — paired C baselines under
  [`benchmarks/`](benchmarks) and an executed-instruction-count CI gate under
  [`perf/`](perf) — rather than by wall-clock noise.

### Language direction

- Keep a minimal language core with Lisp/Scheme syntax and explicit types,
  expressive enough for C-style systems programming: native layout,
  runtime/FFI escape hatches, deterministic builds, and direct linker
  interop.
- Pursue Rust-style safety for ownership, borrowing, move semantics, and
  arena lifetimes. Safe TypeLisp should not have undefined behavior.
  Move-only aggregates, immutable/mutable borrow checking with conservative
  non-lexical lifetime shortening, lifetime-parameterized aggregates, scoped
  arenas, and checker-proven arena invalidation are implemented.
- Treat ISPC-style SPMD as the data-parallel model: `foreach`,
  `spmd-reduce`, `spmd-scan`, and runtime SIMD dispatch, lowered to scalar,
  AVX2, or AVX-512 backends (see [SPEC.md section 5.15](SPEC.md)).
- Use Zig-style comptime as the abstraction mechanism. TypeLisp does not
  grow source-level generics, traits, interfaces, or `impl` syntax; comptime
  code generates concrete types, functions, and implementation bundles.
- Move toward C3-style modules: module identity participates in name
  resolution and prefixes linker symbols. Every top-level item is exported
  by default.
- Use an arena-based memory model: a default program-lifetime arena, scoped
  `(with-arena ...)` regions, and first-class arena values.

The issue tracker is the source of truth for direction; the pinned
[Project Roadmap](https://github.com/JoNil-Botta/typelisp/issues/8) issue is
the live index, and design decisions are recorded as comments on their
issues.

### Conventions (write new code this way)

Some transitional spellings survive in the tree while migrations finish. New
code should use the end-state forms and not imitate the leftovers:

- **Imports**: dotted module imports with aliases and dotted member access
  (`(import stdlib.string)`, `(string.eq left right)`). Legacy string path
  imports are compatibility-only while final migration fixtures are removed.
- **Stdlib names**: qualified short names such as `string.append` are the end
  state; module-name-prefixed flat names (`string-append`, `read-dir`, ...)
  are transitional.
- **Core macros**: bare prelude spellings `when`, `unless`, `and`, `or`, and
  bracket-arm `cond` — `(cond [test expr] ... [else fallback])` — are
  canonical. The flat `cond` call shape is rejected.
- **Strings**: `str-cat` (single-allocation variadic concat) and `text_buf`
  builders are the blessed forms; `string-append`/`string-concat` chains are
  deprecated compatibility primitives.
- **Binary bytes**: mutable binary storage uses the `ByteBuf` owner and
  borrowed `bytes` views, not mutable `str` or `(Array u8)`.
- **Arrays**: public `Array` is moving to fixed-size-only `(Array T N)`.
  Runtime-sized/growable collections use vector or slice-style stdlib APIs;
  unsized `(Array T)` remains as a compatibility surface during migration.
- **Mutation**: mutate in place — `(set! place.field value)` (or the
  equivalent `(set! (struct-get place field) value)`) for struct fields and
  `(set! (box-get b) value)` / `(box-take b)` for boxed storage — rather
  than copy-on-update.

## Quick start

```bash
git clone https://github.com/JoNil-Botta/typelisp
cd typelisp

# Fetch the published self-hosted stage0 compiler for this host. It installs as
# target/stage0/typelisp (Linux) or target/stage0/typelisp.exe (Windows).
scripts/fetch-stage0.sh            # or: powershell -ep Bypass -f scripts\fetch-stage0.ps1
tl=target/stage0/typelisp          # tl=target/stage0/typelisp.exe on Windows

# Type-check, compile, build, or run a program.
# Linux build/run require `as`/`ld`; Windows build/run require `clang`/MSVC `link.exe`.
$tl check examples/hello.tl
$tl fmt --check examples/hello.tl
$tl compile examples/hello.tl     # writes examples/hello.s
$tl build   examples/hello.tl     # writes examples/hello
$tl run     examples/hello.tl
$tl test --check examples/hello.tl
$tl run     examples/hello.tl --target windows-x86_64
$tl build                         # builds nearest typelisp.pkg
$tl run                           # builds/runs nearest binary typelisp.pkg
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

The entry point is a function named `main` returning `i64` or `unit`. If
`main` is omitted, the compiler synthesizes one that returns 0.

## Language overview

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
(begin (when (< answer 0) (return 0)) answer)

;; Casts and zero/identity initialization
(cast 300 : u8)
(import stdlib.array)
(let ([n : i64 (init)]
      [items : (Array i64 4) (init : (Array i64 4))])
  (+ n (array-ref items 0)))
```

`cast` supports the full scalar numeric matrix: integer/char widening,
narrowing, and truncation; `f64` <-> `f32` precision changes; and
integer/char <-> float conversions (float -> integer truncates toward zero).
`(init : T)` constructs a valid initialized value for supported `T`;
contextual `(init)` works where an expected type is known.

### Types

```
i64 i32 i16 i8   u64 u32 u16 u8   f64 f32   bool   char   unit   String
ByteBuf           ; owned mutable byte buffer
(Array t n)       ; fixed-size array (public Array end state)
(Array t)         ; compatibility runtime-sized buffer during migration
(Tuple t1 t2 ...) ; tuple (by-value params/returns supported)
(Box t)           ; arena-owned indirection for recursive aggregates
(& r t)           ; immutable reference tied to lifetime/arena r
(& r str)         ; borrowed string view of an owned String
(& r bytes)       ; immutable borrowed byte slice
(&mut r bytes)    ; exclusive mutable borrowed byte slice
(-> arg... ret)   ; function type
Name              ; a defenum / defstruct nominal type
(Name r...)       ; lifetime-parameterized nominal type use
```

Both `f64` and `f32` support scalar parameters, returns, locals, arithmetic,
comparisons, and casts. Raw pointer types `(Ptr T)` / `(MutPtr T)` and
`(unsafe ...)` are the FFI/runtime escape hatch (see
[SPEC.md](SPEC.md) sections 3.4, 4.3.1, and 5.20), including sequentially
consistent raw-pointer atomics (`atomic-load`, `atomic-store!`,
`atomic-add!`, `atomic-fetch-add!`, `atomic-cas!`) for 32/64-bit integer
elements.

Function signatures normally elide reference lifetime names: write
`[item : (& Item)]` or `[item : (&mut Item)]`, and an elided reference return
uses the sole input reference lifetime. Use explicit names such as
`(& selected Item)` only when an API intentionally relates multiple reference
inputs; fields, globals, locals, and nominal lifetime arguments remain
explicit. Borrow expressions stay `(& place)` and `(&mut place)`.
At a typed call, an existing `&mut T` argument may be passed to an `&T`
parameter as a tracked shared reborrow; the reverse conversion is never
implicit.

### Abstraction: comptime, not generics

TypeLisp does not plan source-level generics, traits, interfaces, `impl`
blocks, generic `Option<T>`/`Result<T,E>` syntax, or trait-based error
conversion. Library abstraction comes from comptime generation: compile-time
code inspects type values and emits concrete structs, enums, functions, and
implementation bundles through declaration-emitting `defmacro` forms.
Comptime-generated declarations, type reflection, and typed expression
macros are implemented; see SPEC.md sections 3.7 and 5.17. Comptime code is
pure safe TypeLisp — no `unsafe`, `extern`, or host I/O — bounded by
deterministic fuel. Write hand-authored monomorphic declarations (such as a
domain-specific `Result*` enum) when a generated family has not been
requested; `(try expr)` is the propagation form over compatible concrete
Result-like enums.

### Top-level forms

`define` (variable / function), `defenum`, `defstruct`, `extern`, `import`,
`module`, and `defmacro`. Every top-level item is exported by default (there
is no `export` form).

```lisp
(defenum Tree (Leaf i64) (Node (Box Tree) (Box Tree)))
(defstruct Pair (fst i64) (snd i64))
(extern (foreign-add [a : i64] [b : i64]) : i64)
(extern (printf [fmt : (Ptr u8)] ...) : i32 (:symbol "printf"))
(extern foreign-add-ptr (:symbol "foreign_add_ptr") : (-> i64 i64))
(import stdlib.string)
```

Structs and enums have stable inline layout by default: struct fields use
declaration order with natural alignment; enums use an 8-byte tag plus
max-aligned payload storage. Comptime layout queries (`size-of`, `align-of`,
`offset-of`) use that layout. Recursive aggregates use explicit `(Box T)`
fields/payloads at the recursive edge.

`extern` defaults to the target C ABI with the linker symbol equal to the
local name; `(:symbol "...")` binds an exact foreign symbol (without the
`_tl_` prefix used for ordinary TypeLisp declarations). Function-head externs
are direct external functions; bare-name externs are external data symbols,
and a bare function type is a raw C function pointer called with the C ABI.
C varargs are declared with bare `...` (any C ABI tail) or `[arg : ...T]`
(homogeneous tail).

### Modules and imports

Dotted module imports bind a module alias and keep imported definitions out
of the local unqualified namespace: `(import stdlib.string)` binds `string`,
and `(import stdlib.core_macros as core)` binds `core`. Imported values,
types, constructors, variants, patterns, and macros are referenced with
dotted member access — `(string.eq left right)`, `[p : geometry.Point]`.
Macro imports use the same module identities, with expansion happening
before ordinary typechecking. Legacy string path imports are retained only for
named compatibility fixtures until final removal; new code should use dotted
module identities.

The compile driver prepends the stdlib runtime and the core macro module as
an implicit prelude, so bare `when`, `unless`, `and`, `or`, and bracket-arm
`cond` resolve without imports. Stdlib modules otherwise resolve local-first,
then from `--stdlib-root <dir>` (or the `TYPELISP_STDLIB_ROOT` fallback),
then from the compiler's embedded copy of the checked-in stdlib. Prefer
`--stdlib-root` for CI and reproducible scripts; see
[stdlib/README.md](stdlib/README.md) for the stdlib layout.

Within each module, type names and value names live in separate namespaces:
enum and struct type names share the type namespace, while functions,
variables, externs, struct constructors, and enum variant constructors share
the value namespace. An enum type may share a name with one of its own
variants. Module identity then qualifies both namespaces, so two modules can
define the same local name without colliding.

### Conditional compilation

`compile`, `run`, and `build` accept repeated `--cfg <name>` flags. Source
can wrap a top-level declaration as `(cfg predicate declaration)` or use the
expression form `(cfg predicate expr [else-expr])`, where `predicate` is a
flag name, `(all ...)`, `(any ...)`, or `(not ...)`. Inactive branches are
read but not parsed as declarations, so they can hide stage- or
platform-specific code. Target OS predicates are enabled automatically:
`linux`/`unix`/`target-linux`/`os-linux` and
`windows`/`target-windows`/`os-windows`.

### Expression forms

`if`, `when`, `unless`, `let`, scalar `for`, `while` (with unit
`break`/`continue`),
`begin`, `set!`, `match` (nested/recursive enum patterns, constructor-shaped
struct patterns, `_`), `ann`, `cast`, `return`, `try`, `foreach`,
`spmd-reduce`, `spmd-scan`; arithmetic (`+ - * / %`), comparison
(`= != < <= > >=`), boolean (`and` `or`), and bitwise/shift (`bit-and`
`bit-or` `bit-xor` `shl` `shr`) operators. `struct-get` reads a struct
field, and dotted syntax `place.field` is sugar for the same operation;
`(set! place.field value)` writes in place.

Named top-level functions and `lambda` literals are pointer-sized closure
descriptor values. Non-capturing lambdas use static descriptors; capturing
lambdas snapshot supported captures (scalars, function values, `String`,
aggregates, fixed arrays — recursively deep-copied) into heap environments
that outlive the creating frame. Local non-escaping closures may capture
immutable references; escaping closures reject reference captures, and
mutation of captured names is rejected by design. Direct, mutual, and
supported indirect function-value tail calls are optimized to jumps; ABI
shapes that cannot be tail-jumped are conservatively emitted as ordinary
calls.

### Builtins and stdlib

Compiler-owned builtins are a small set: fixed-array element operations
(`array-ref`, `array-set!`, `array-length`/`length`), string
indexing/slicing primitives (`substring`/`string-slice`, `int->string`),
and the CPU instruction intrinsics. Array and string indexing is
bounds-checked at runtime. Everything else lives in stdlib modules imported
with dotted imports: printing and `panic`/`error` in `stdlib.io`, string
inspection/parsing in `stdlib.string`, files and processes in `stdlib.io`
and `stdlib.fs`, string building in `stdlib.str_cat`, `stdlib.format`, and `stdlib.text_buf`,
binary buffers in `stdlib.byte_buf`, arenas in `stdlib.arena`, and threading
in `stdlib.thread` / `stdlib.sync`.

## Memory and ownership

TypeLisp implements move-only aggregate semantics and lexical
immutable/mutable borrow checking with conservative non-lexical lifetime
shortening. There are no destructors, no general `free`, and no garbage
collector; heap allocation uses a backend-emitted bump allocator into the
active arena. Scalars, raw pointers, and non-capturing function values are
copyable; `String`, arrays, tuples, structs, enums, and capturing closures
move in by-value positions. See [SPEC.md](SPEC.md) sections 4.7.2 and 7 for
the precise model.

`String` values are immutable at the source level; borrowing a `String`
place produces a borrowed `(& lifetime str)` view, and typed calls
auto-borrow borrowable places for immutable reference parameters.
`substring`/`string-slice` return fresh owned copies;
`substring-view`/`string-slice-view` return bounds-checked borrowed slices
without copying. Mutable binary storage is the owned `ByteBuf` plus
`(& lifetime bytes)` / `(&mut lifetime bytes)` borrowed views; conversions
between text, arrays, and byte buffers are explicit copy or borrow
boundaries.

`(Box T)` is a safe, move-only, arena-owned indirection handle: `(box expr)`
allocates in the active arena, `(box-get b)` projects the value, `(box-take
b)` consumes the box, and `(set! (box-get b) value)` mutates boxed storage.
A box allocated inside `(with-arena r ...)` cannot escape that scope.

### Arenas

The first safe reclamation surface is `(with-arena r body ...)` — a
lexically scoped arena with static escape checking: the typechecker rejects
any arena-tagged value that would leave the scope, so the compiler can
safely reset the region afterwards. On top of that, `stdlib.arena` provides
typed first-class arenas. The standard patterns:

- `(with-arena scratch ...)` for temporary work returning only scalars or
  outer-owned values; nest scopes for stack-shaped lifetimes (level/frame).
- `(with-escape scratch ...)` with an `arena.make` arena, or
  `(with-scratch ...)` for one-shot work, when one supported result must be
  cloned out.
- `(in-arena arena body ...)` when results should remain owned by a
  first-class arena; `(arena.make-atomic)` for a shared atomic allocation
  target across threads.
- `arena.phase` plus `arena.rewind-safe!` / `arena.destroy-safe!` for
  checker-proven arena invalidation: the checker rejects the reset while any
  values, borrows, captures, or owner handles from that arena remain live.
- Raw `arena.set!` / `arena.rewind` / `arena.destroy` require
  `(unsafe ...)`.

The runnable cookbook in
[`examples/arena_lifetimes.tl`](examples/arena_lifetimes.tl) covers lexical
frame scopes, double-buffered frame arenas, and event-driven unload. Scoped
cleanup of non-memory resources is separate:
`(with ([name init cleanup]) body ...)` runs cleanup functions in reverse
binding order on scope exit (files, locks, process handles); it does not
imply destructors or arena resets.

## Safe task threading

Safe task threads use generated typed closure modules from
`stdlib/thread.tl` — for example `(import (thread.handle i64) as
thread-i64)` with `thread-i64.spawn` / `thread-i64.join` — plus aggregate
wrappers. The checker validates captured environments and joined results
structurally (no traits): references, borrowed views, scoped regions,
ordinary arenas, raw-pointer ownership claims, and live mutable aliases do
not cross task-thread boundaries; values cross threads only when owned by an
arena whose lifetime spans both, such as a shared atomic arena.
`stdlib/sync.tl` provides generated channel and mutex modules. An atomic
arena proves allocation lifetime, not data-race freedom — use mutexes,
channels, or atomics for shared mutation. See
[`examples/safe_threading.tl`](examples/safe_threading.tl) for a complete
safe program and SPEC.md section 6.5 for the model.

## SPMD and SIMD

Task threading creates independently scheduled workers; SPMD is
data-parallel lowering inside one task. `compile`, `run`, and `build` accept
`--backend-mode scalar|avx2|avx512` (default `scalar`).

- Every SPMD form has scalar reference lowering; backend modes must preserve
  its semantics.
- AVX2 and AVX-512 vectorize a contiguous `foreach` map/zip subset over
  `i8`–`i64`, `u8`–`u64`, `f32`, and `f64` lanes (AVX-512 additionally
  covers bool lanes), plus eligible `spmd-reduce` array folds (`sum` over
  `i32`/`i64`/`f32`/`f64`, `min`/`max` over `i32`, and AVX-512 `min`/`max` over
  `i64`). Contiguous maps can borrow vector backing or slice storage, so
  public APIs can take vector/slice views.
- Scalar lowering supports `spmd-reduce` `sum`/`min`/`max`/`all`/`any` and
  inclusive `spmd-scan` over the SPEC-supported types.
- Masked varying `if` (including nested masks and value-producing selects) and
  varying `while` with loop-carried active masks run in scalar, AVX2, and
  AVX-512 subsets. AVX2 still reports explicit diagnostics for varying `match`
  (enum tags and lane payload bindings), early exits, and other unsupported
  control-flow shapes instead of silently scalarizing them.
- `(program-index)` and `(program-count)` are lane identity forms inside
  SPMD scopes; programs using them intentionally observe backend gang
  width.
- `defdispatch` declares one logical function with scalar/AVX2/AVX-512
  variants; ordinary calls resolve once per process via the CPUID/XGETBV
  checks exposed by `stdlib/cpu.tl` (AVX-512 dispatch requires F+BW+DQ and OS
  ZMM/opmask state).

Public vector/mask value types and vectorized scans/shuffles are deferred.
Non-inlined varying helper calls now typecheck and lower to specialized private
scalar/AVX-512 call IR with active masks; native emission remains staged. See
SPEC.md sections 5.15 and 8.

## Packages

Local packages are described by a std-only S-expression manifest named
`typelisp.pkg`:

```lisp
(package
  (name "my-app")
  (version "0.1.0")
  (dependencies
    (math "../math")
    (lint (github "JoNil-Botta/typelisp-lint" (rev "abc123"))))
  (link
    (libraries "raylib")
    (search-paths "vendor/raylib/lib")
    (linux-libraries "GL" "m" "pthread" "dl" "rt" "X11")
    (windows-libraries "opengl32" "gdi32" "winmm" "shell32" "user32")))
```

`typelisp build [--manifest-path <typelisp.pkg>]` resolves `entry` relative
to the manifest directory and writes outputs under `target/<profile>/`
(profiles: `release` default, `--profile dev`; release defaults to
`--opt-level 2`, dev to `0`). `kind "bin"` builds a native executable;
`kind "staticlib"` builds a static archive. When both are omitted, `bin` is
inferred from `src/main.tl` and `staticlib` from `src/lib.tl`. Package
builds also emit a host comptime image `<name>.tlci` beside the native
artifact. Macro-free packages use a metadata-only image; macro-defining
packages include deterministic native entry shells and one registration-table
record per package-owned macro. `typelisp inspect <file.tlci>` renders the
image header, sections, and package metadata. Macro-body lowering and consumer
dispatch remain staged separately from these package emission artifacts.
Self-host bootstrap builds the compiler's exact embedded stdlib source set into
a source-bound `stdlib.tlci`, embeds it in the next compiler stage, and validates
all registered macro identities through the production loader. A bootstrapped
compiler exposes that payload as `typelisp inspect embedded:stdlib.tlci`.
When compilation consumes the embedded stdlib and no explicit `--stdlib-root`
was supplied, macro expansion maps that image once per expansion pass and
checks each stdlib macro against its native registration catalog. Transformer
bodies still execute through CTFE; compile-profile counters report catalog
hits/misses, load failures, and the interpreted fallback separately. Supplying
an explicit stdlib root skips the TLCI route. The compile-profile gate compiles
the same corpus through both routes and requires byte-identical assembly.
`typelisp run [--manifest-path <typelisp.pkg>]` uses the same package
resolution and build profile rules, then executes `bin` package artifacts;
runtime arguments are passed after `--`.

Dependencies may be local paths or git/GitHub pins (`rev`, `tag`, or
`branch`). Remote pins resolve through `typelisp.lock` — a deterministic
S-expression lockfile recording alias, normalized URL, pin, and exact
commit — and a content-keyed package cache under
`target/typelisp/cache/`. `--locked` requires matching lock entries and
never rewrites the lockfile; `--update-lock` intentionally refreshes remote
pins. Dependency packages must be static libraries; transitive dependencies
build once per invocation as a DAG (concurrently where the host supports
it), and cycles fail with a diagnostic. Inside a package build, an import
whose leading segment is a dependency alias, such as `(import math.src.lib)`,
resolves from that dependency root. The optional `(link ...)` section declares
native link inputs per target; on Linux any non-empty link input switches the
package to linking through `cc` instead of freestanding `ld`. Registry support,
semantic-version solving, and workspaces are deferred by design: the model
is deterministic zero-dependency builds through the host `git` CLI plus
checked-in lockfile replay. See [SPEC.md §4.6](SPEC.md) for the full
contract.

Package source discovery walks `.tl` files below the manifest directory,
skipping build/VCS state, nested package roots, and `tests` directories
(reserved for `typelisp test` integration discovery and fixture corpora).
Package `check`/`build` validate the entry's reachable import closure;
package `lint` checks every discovered source.

## Tests and documentation

Inline tests live next to source declarations as `(test name body...)`
items. Normal builds type-check inline tests owned by the package's own
sources (never imported stdlib or dependencies), then drop them before
production codegen. `typelisp test <file.tl>` turns a file's inline tests
into a generated harness and runs it; with no file, it runs the nearest
package's inline tests plus `tests/**/*.tl` integration programs (exit 0
passes). `typelisp test --check` type-checks harnesses without linking.
Tests commonly import `stdlib/test.tl` for assertions. CI auto-discovers
inline-test-bearing files, so adding tests requires no manifest edits.

Documentation comments use `;#` (module docs) and `;:` (item docs), and can
contain checked examples:

```lisp
;# ```typelisp
;# (define (main) : i64 42)
;# ```

;: ```tl expect-error
;: (define (bad) : i64 true)
;: ```
(define documented : i64 1)
```

`typelisp doc --test <file.tl>` type-checks every fenced `typelisp`/`tl`
example (add `expect-error` for intended failures; `typelisp run` fences
compile, run, and compare exit/stdout/stderr on Linux). `typelisp doc
input.tl -o output.md` renders Markdown docs for the entry file and its
import graph; `--manifest-path` documents a package.

`typelisp lint` includes staged migration rules such as
`--deprecated-string-concat`, `--redundant-function-name`, and
`--prefer-dotted-field`. `--name-case` checks top-level values as
SCREAMING-KEBAB-CASE, functions/macros and local binders as kebab-case, and
struct/enum types as UpperCamelCase. Dead-code lint treats library packages as external
API roots and reports unreachable declarations in `bin` packages.

## Self-hosting and bootstrap

The compiler front end, IR, optimizer, backends, and all tooling under
[`src/`](src) are written in TypeLisp; compiler self-test conventions are
documented in [`src/TESTING.md`](src/TESTING.md). The repository root is
itself a package: from a checkout, `typelisp build` builds the unified
selfhost CLI from `src/main.tl` into `target/release/`.

The published stage0 is a single self-hosted binary per OS
(`typelisp-stage0-linux`, `typelisp-stage0-windows.exe`). The
[`Bootstrap Stage0`](.github/workflows/bootstrap-stage0.yml) workflow is
self-perpetuating: on each merge to `main` it fetches the previously
published stage0, uses *that* compiler to build the next stage0 from
`src/main.tl`, and publishes the result — each stage0 builds its own
successor. Reproduce locally:

```sh
scripts/fetch-stage0.sh
scripts/build-stage0.sh target/stage0/typelisp typelisp-stage0-linux            # Linux
scripts/build-stage0.sh target/stage0/typelisp.exe typelisp-stage0-windows.exe # Windows (Git Bash)
```

`build-stage0.sh` compiles `src/main.tl` with the seed and links through the
host toolchain, so a stage0 never depends on its own `build` command.
`scripts/ci-verify.sh` runs the same gate as CI: the published compiler
seeds a stage1->stage2->stage3 bootstrap fixpoint
(`scripts/check-bootstrap-fixpoint.sh` compares stage2 and stage3 assembly),
and every remaining gate runs on the freshly bootstrapped compiler. On
Windows the fixpoint script runs from Git Bash and uses `clang
--target=x86_64-pc-windows-msvc` plus MSVC `link.exe`; set
`TYPELISP_WINDOWS_CLANG` / `TYPELISP_WINDOWS_LINK` to override tool
discovery.

## Documentation site

A static language-reference and stdlib/API site is generated entirely in
TypeLisp by [`tools/doc-site/doc_site.tl`](tools/doc-site/doc_site.tl) and
published to GitHub Pages at <https://jonil-botta.github.io/typelisp/> on
every push to `main`; pull requests build and validate it without
publishing. Build locally with
`typelisp run tools/doc-site/doc_site.tl --stdlib-root stdlib --stdlib-root src -- target/site`, or run
`scripts/verify-doc-site.sh` to build and validate links the way CI does.

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

Compilation is one whole program per executable with import-graph dedup
(each module typechecked once per program). Package dependencies are
codegen'd once into archives; an in-process session cache warms compiler
pools across compiles within one process (batch and LSP paths).

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
    typelisp inspect        Inspect a TypeLisp comptime image
    typelisp lint           Lint source files or a package
    typelisp lsp            Start stdio LSP diagnostics server
    typelisp new            Scaffold a new package directory
    typelisp repl           Start minimal stdio REPL
    typelisp run            Compile, link, and run a source file or package
    typelisp test           Run or check inline tests
```

Common options include `--target linux-x86_64|windows-x86_64` (Linux is the
default output target; `test` defaults to the host), `--backend-mode
scalar|avx2|avx512`, `--opt-level 0|1|2` (0: no IR optimizer; 1: cheap
stack-only passes; 2: full optimizer with register allocation and inlining —
levels never change program semantics), `--manifest-path <file>`,
`--stdlib-root <dir>`, `--locked`, `--update-lock`, and `--cfg <name>`. Run
`typelisp <command> --help` for command-specific help. The REPL remembers
top-level declarations and evaluates bare expressions by compiling a scratch
program through the real build/run pipeline — there is no interpreter.
`.load <file>` adds a source file's declarations to the current session after
checking the combined session. Scalar results are printed directly; structs,
enums, tuples, and fixed arrays use the stable fallback `<value: Type>` because
TypeLisp does not currently provide runtime reflection for their contents.

## Status

Implemented: the full pipeline (lexer, parser, type checker, IR lowering,
optimizer, Linux/Windows x86_64 backends); integers, floats, bool/char/unit,
strings, enums + `match`, structs with in-place field mutation, fixed and
compatibility dynamic arrays, tuples, closures, tail calls, `extern`/FFI
with raw pointers, atomics, and volatile raw pointer access, move/borrow
checking with conservative non-lexical lifetime shortening, arenas with
checker-proven invalidation,
safe task threading, SPMD `foreach`/`spmd-reduce`/`spmd-scan` with
scalar/AVX2/AVX-512 backends and runtime dispatch, comptime macros with type
reflection, packages with lockfiles, inline tests, doctests, fmt, lint, doc
generation, a docs site, and an LSP diagnostics server.

Not yet (see [SPEC.md §8](SPEC.md) for the authoritative matrix): general
GC/`free` (deferred by design in favor of arenas), vectorized varying `match`
control flow, vectorized SPMD scans/shuffles and public vector/mask values,
native emission for out-of-line varying helper calls, reference captures in
escaping closures
(rejected by design), package registry and workspaces, and richer IDE
features. Codegen quality versus `clang -O2` is an active work stream
tracked by the committed benchmark baselines.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Two standing policies to note:
TypeLisp is **self-hosted with zero dependencies** (implementation, tooling,
and tests are written in TypeLisp), and **syntax changes carry no aliases**
— when a spelling changes, every usage migrates and the old form is removed
in the same change rather than kept as a parallel parser path.

## License

MIT
