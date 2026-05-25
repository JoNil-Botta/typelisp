# TypeLisp

A statically typed Lisp/Scheme dialect that compiles directly to native
x86_64 assembly for Linux and Windows. Written in Rust with **zero third-party
dependencies** (`std` only).

## Goals and inspirations

Current implementation goals:

- **Typed**: Every expression has a known type at compile time. No runtime type tagging.
- **Native**: Compiles straight to x86_64 assembly, then native toolchains produce executables. Linux uses `as` + `ld`; Windows uses `clang` + `lld-link`. No bytecode VM, no interpreter, no garbage collector.
- **Zero dependencies**: Built with Rust `std` only. No third-party crates.
- **Self-hostable front end**: A lexer, s-expression reader, and tree-walking evaluator for TypeLisp are themselves written in TypeLisp (see [`selfhost/`](selfhost)).

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
  See #893, #913, and #970.
- Move toward C3-style modules where module identity participates in name
  resolution and prefixes TypeLisp linker symbols; see #950, #952, and #953.
- Use an arena-based memory model with a default program-lifetime arena and
  scoped `(with-arena ...)` allocation regions (#801).
- Land new language features in the selfhost compiler, not as new Rust compiler
  product surface. The Rust implementation is the stage0/compiler bridge while
  the public toolchain moves toward TypeLisp-built components (#666, #784, #787,
  #795).

The language-direction bullets above are future goals. The rest of this README
describes current behavior unless it explicitly says a feature is planned.

## Quick Start

```bash
git clone https://github.com/JoNil-Botta/typelisp
cd typelisp
cargo build --release

# Type-check, compile, build, or run a program.
# Linux build/run require `as`/`ld`; Windows target build/run require `clang`/`lld-link`.
./target/release/typelisp debug check examples/hello.tl
./target/release/typelisp fmt --check examples/hello.tl
./target/release/typelisp compile examples/hello.tl     # writes examples/hello.s
./target/release/typelisp build   examples/hello.tl     # writes examples/hello
./target/release/typelisp run     examples/hello.tl
./target/release/typelisp test --check examples/hello.tl
./target/release/typelisp run     examples/hello.tl --target windows-x86_64
./target/release/typelisp build                         # builds nearest typelisp.pkg
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

;; Casts
(cast 300 : u8)
```

`cast` currently supports integer/char widening, narrowing, and truncation only.
`f64` arithmetic is supported, but floating-point casts are not implemented yet.

### Types

```
i64 i32 i16 i8   u64 u32 u16 u8   f64   bool   char   unit   String
(Array t)         ; dynamic, runtime-sized array
(Array t n)       ; fixed-size array (literals/ref/set compile; returns rejected)
(Tuple t1 t2 ...) ; local tuple literals/ref compile; params/returns rejected
(-> arg... ret)   ; function type
Name              ; a defenum / defstruct nominal type
```

`f32` is in the type system but rejected by backend validation today.
Raw pointer types `(Ptr T)` and `(MutPtr T)` plus `(unsafe ...)` are specified
for the v1 FFI surface in [SPEC.md §3.4](SPEC.md) and §5.19, but implementation
is still pending.

### Abstraction policy

TypeLisp does not plan source-level generics, traits, interfaces, `impl`
blocks, generic `Option<T>`/`Result<T,E>` syntax, or trait-based error
conversion. Library abstraction should come from Zig-style comptime generation:
compile-time code inspects type values and emits concrete structs, enums,
functions, and implementation bundles. Until that path lands, write explicit
monomorphic declarations such as `MaybeI64` or domain-specific `Result*` enums;
the selfhost compiler already uses `(try expr)` as the Lisp-shaped propagation
form for compatible concrete Result-like enums.

The comptime implementation path is tracked by #893, #913, and #483.

### Top-level forms

`define` (variable / function), `defenum`, `defstruct`, `extern`, `import`.

```lisp
(defenum Tree (Leaf i64) (Node Tree Tree))   ; recursive enums supported
(defstruct Pair (fst i64) (snd i64))
(extern foreign-add : (-> i64 i64 i64))
(import "lib/util.tl")                        ; relative, deduped; cycles load once
```

The Rust stage0 loader still uses the legacy flat import model: imported
definitions merge into one top-level namespace. The selfhost module direction is
private-by-default modules with canonical identities, `(export ...)`, import
aliases, and qualified names such as `math/add`; see `SPEC.md` section 4.4 for
the specified migration contract.

FFI-facing structs will use explicit `repr c` metadata and comptime layout
queries such as `size-of`, `align-of`, and `offset-of`; this is specified for
the selfhost compiler in `SPEC.md` and is being implemented in #987-#989.
Default TypeLisp struct layout remains compiler-owned and should not be treated
as a C ABI contract.

`stdlib/string.tl` is the canonical in-repo string utility module. Stdlib files
are ordinary modules imported with explicit paths such as
`(import "stdlib/string.tl")`. `check`, `compile`, `build <file.tl>`, and `run`
also accept `--stdlib-root <dir>` for resolving `stdlib/...` imports from a
configured source tree. `TYPELISP_STDLIB_ROOT` can provide an optional fallback
root after explicit CLI roots; prefer `--stdlib-root` for CI, bootstrap, and
reproducible scripts. See [stdlib/README.md](stdlib/README.md) for the current
stdlib layout and verification conventions.

Local packages can be described with a std-only S-expression manifest named
`typelisp.pkg`:

```lisp
(package
  (name "my-app")
  (version "0.1.0")
  (entry "src/main.tl")
  (dependencies
    (math "../math")))
```

`typelisp build <file.tl> [-o <exe>]` compiles, assembles, and links one source
file to a native executable without running it. Without `-o`, the executable is
written next to the source path with the `.tl` extension removed. `typelisp
build [--manifest-path path/to/typelisp.pkg]` remains package-oriented: it
resolves `entry` relative to the manifest directory and writes assembly under
`target/typelisp/<package-name>/<package-name>.s`. Dependency paths may be
relative to that same package root or absolute. Inside a package build, imports
of the form `(import "pkg:math/src/lib.tl")` resolve from the dependency root
declared for alias `math`; ordinary string imports remain relative to the
importing file, and `stdlib/...` imports keep their local-first then
configured-root behavior.

Under the legacy loader, imported package definitions share the same flat
top-level namespace as local modules, so duplicate value or type names fail
through the existing duplicate definition diagnostics. The package slice still
has no registry, version solving, lockfile, workspace model, or native
executable build promise for package manifests; namespace isolation and
qualified symbol lookup are specified for the selfhost module model in
`SPEC.md`.

Documentation comments can contain checked examples. `typelisp doc --test
<file.tl>` extracts fenced `typelisp` or `tl` blocks from `;#` module docs and
attached `;:` item docs, writes each example to a deterministic temporary
source file, type-checks it, and removes the temporary directory before exiting.
The self-hosted Markdown generator can render one source file through
`typelisp run selfhost/doc.tl -- input.tl output.md`; import-graph traversal and
Rust CLI plumbing are separate follow-up work.

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
when the example is intended to fail. Ordinary `;` and `;;` comments are not
documentation and are ignored by the doctest scanner. Legacy `;;;;` and `;;;`
doc comments remain accepted while the repository migrates, but `;#` and `;:`
are the canonical spellings.

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

`if`, `let`, `while`, `begin`, `set!`, `match` (incl. nested/recursive enum
patterns and `_`), `ann`, `cast`, `foreach`, plus arithmetic (`+ - * / %`),
comparison (`= != < <= > >=`), boolean (`and` `or`), and bitwise/shift
(`bit-and` `bit-or` `bit-xor` `shl` `shr`) operators. `struct-get` reads a
struct field.

Named top-level functions and `lambda` literals can be passed as pointer-sized
closure descriptor values. Non-capturing lambdas use static descriptors.
Capturing lambdas snapshot supported captures into heap environments: scalars,
function values, `String`, dynamic arrays, tuples/structs/enums (including ones
with nested aggregate fields, which are recursively deep-copied), and a
directly-captured scalar fixed array. The aggregate captures snapshot their
storage onto the heap so the environment can outlive the creating frame.
Aggregate-element / nested fixed-array captures and mutation of captured names
are still rejected.
SPMD/SIMD `foreach` is documented in [SPEC.md section 5.15](SPEC.md). The
compiler parses and type-checks the first source form and lowers it to scalar
reference loops; `--backend-mode avx2` supports a first contiguous map/zip
subset. `spmd-reduce` reduction semantics are specified but not implemented yet.

### Builtins

`print`, `print-bool`, `print-float`, `print-char`, `print-newline`,
`print-string`/`print-str`; `arg-count`, `arg`, `read-file`, `write-file`,
`file-exists?`, `read-file-status`, `write-file-status`,
`file-exists-status`, `read-stdin-line`, `read-stdin-bytes`, `stdin-eof?`,
`flush-stdout`; `make-array`, `array-ref`, `array-set!`,
`array-length`/`length`; strings: `string-length`/`length`,
`string-ref`/`char-at`, `string-eq`/`string=?`, `string-append`/`string-concat`,
`substring`/`string-slice`, `string->int`, `int->string`; and `panic`/`error`.
Array and string indexing is bounds-checked at runtime.

### Memory and aliasing

TypeLisp does not currently have source-level references, borrowing, ownership
transfer, destructors, `free`, or a garbage collector. Aggregate values such as
`String`, dynamic arrays, structs, and enums are implemented as pointer-sized
handles in the IR/ABI, but those handles are not checked language references.
The v1 raw pointer design is now specified as explicit unsafe syntax:
`(Ptr T)`/`(MutPtr T)` are nullable, copyable pointer-sized values, and
dereference/write/offset/cast operations require `(unsafe ...)`. That surface is
for FFI/runtime work and is not implemented yet; it is not the future safe
reference/borrow model.

`String` values are immutable at the source level. Dynamic arrays are shared
mutable buffers: copying or passing an `(Array T)` value aliases the same
storage, so `array-set!` through one handle is visible through another. Struct
and enum values are pointer-shaped internally; structs are read-only today
because `struct-set!` is not implemented. Heap allocation uses a
backend-emitted `tl_alloc` bump allocator and allocations live until process
exit. See [SPEC.md §7](SPEC.md) for the precise current model.

The v1 reclamation direction keeps the program-lifetime arena as the default
allocation target and does not add general per-object `free` or GC yet.
`String` buffers, dynamic array storage, returned enum/struct storage, and
self-hosted data structures all remain heap allocations in the active arena.
General `free` is deferred until ownership, borrowing, and reference semantics
are designed, because current aggregate handles can be copied freely. A tracing
GC is also larger than the next step.

The first safe reclamation surface is `(with-region r body ...)` — a
lexically scoped arena with **static escape checking**. The arena model uses
"scoped arena" for this behavior; the selfhost compiler also accepts
`(with-arena r body ...)` as an exact alias for this form (#801, the migration
spelling), with the same scoped arena, region tags, shadowing, and escape rules.
The typechecker rejects any arena-tagged value
that would leave the scope, so the compiler
can safely lower the form to `tl_region_mark` / `tl_region_reset` around the
body. This makes scoped cleanup safe by construction, unlike the raw extern
helpers below. See [SPEC.md §5.16](SPEC.md) and §7.3 for the full contract.

Scoped cleanup of non-memory resources is separate. The SPEC reserves
`(with ([name init cleanup]) body ...)` for explicit cleanup of files, process
handles, locks, mapped files, and similar resources; it is not implemented yet
and does not imply destructors, `free`, or arena reset semantics.

Programs that need manual control may still declare low-level extern helpers:
`tl_region_mark` and `tl_region_reset` snapshot and restore the bump allocator.
These are unsafe-by-convention — the caller must prove no live handle escapes
the reset — and are currently emitted only for the Linux x86_64 System V
target. See [SPEC.md §7.3](SPEC.md) for details.

See [SPEC.md](SPEC.md) for the full language reference.

## Self-hosting sources

The [`selfhost/`](selfhost) directory builds up a TypeLisp front end *written in
TypeLisp*:

- `lexer.tl` — a tokenizer for TypeLisp's own s-expression syntax.
- `read.tl` — an s-expression reader producing a recursive `Sexpr` cons-cell tree (an importable module).
- `eval.tl` — a tree-walking evaluator over that tree, with integers, strings, cons pairs, and interpreted first-class closures.

Compiler self-test and smoke-driver conventions are documented in
[`selfhost/TESTING.md`](selfhost/TESTING.md).
Published stage0 compilers for local bootstrap checks can be fetched with
[`scripts/fetch-stage0.sh`](scripts/fetch-stage0.sh). To run the same no-Rust
stage0 verification gate used by CI, run
`scripts/verify-no-rust-stage0.sh`; it fetches `stage0-latest` when
`TYPELISP_BIN` is unset and prevents accidental Cargo fallback.

Smaller runnable examples, including `calc.tl`, remain in [`examples/`](examples).

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
typelisp debug tokenize file.tl    # Print token stream
typelisp debug parse    file.tl    # Print AST
typelisp debug check    file.tl    # Type check
typelisp lsp                      # Start stdio LSP diagnostics server
typelisp repl                     # Start minimal stdio REPL (.help, .type, .exit)
typelisp compile        file.tl    # Generate assembly (.s); -o <path>, --target <target>, --emit-ir, --backend-mode <mode>
typelisp build          file.tl    # Build native executable; -o <path>, --target <target>, --backend-mode <mode>
typelisp run            file.tl    # Compile, assemble, link, and run; --target <target>, --backend-mode <mode>
typelisp build                    # Build nearest typelisp.pkg to package assembly; --target <target>, --backend-mode <mode>
typelisp fmt            file.tl    # Format source in place; --check reports changes without writing
typelisp test           file.tl    # Run inline `(test ...)` items; --check type-checks the generated harness
```

The older top-level `tokenize`, `parse`, and `check` commands remain as
compatibility aliases.

The `repl` command currently provides a minimal stdio command loop. It supports
`.help`, `.type <expr>`, and `.exit`. Top-level declarations are remembered for
later `.type` commands; TypeLisp evaluation is planned in follow-up work.

`compile`, `run`, and `build` accept `--backend-mode scalar|avx2|avx512`.
`scalar` is the default. `avx2` supports a first contiguous SPMD `foreach`
map/zip subset and otherwise falls back or rejects unsupported vector IR;
`avx512` parses but is rejected until that backend lands.

`compile`, `run`, source-file `build`, and `test` accept
`--target linux-x86_64|windows-x86_64`. Linux is the default output target for
compile/build. `test` defaults to the host target so the generated executable
can run locally. Windows native builds use the Windows x64 ABI, a CRT-linked
runtime helper policy, and the `clang` + `lld-link` toolchain.

The selfhost source-file build/run host-action planners (`selfhost/build.tl`,
`selfhost/run.tl`) accept `--opt-level 0|1|2|3`. When omitted, the optimizer
runs, matching the prior default; `--opt-level 0` builds without the IR
optimizer (faster compiles, larger/slower code) while `1|2|3` run it. Higher
levels may spend more compile time but must preserve program semantics — the
exit/output of a program never depends on the level. The finer numeric meanings
and a canonical default are reserved for the optimizer-policy work split from
\#939, and `--opt-level` on Rust-owned package builds is tracked separately (it
is not accepted by `typelisp build <pkg>` in this slice).

## Status

Implemented: lexer, parser, type checker, IR lowering, optimizer, and working
x86_64 Linux/Windows backend targets. Integers, floats (`f64`), bool/char/unit,
`if`/`while`/`begin`, local & global variables, direct and indirect calls,
`cast`, enums + `match`, structs + field access, dynamic arrays, strings,
`extern`, multi-file modules, scalar `foreach`, and an initial AVX2 `foreach`
map/zip path all compile to native code. See the
[project roadmap](https://github.com/JoNil-Botta/typelisp/issues/8) and
[SPEC.md §8](SPEC.md) for what is not yet supported (aggregate-element /
nested fixed-array captures, tail calls, tuple/fixed-array by-value returns,
`f32` codegen, general GC/free, ownership/borrowing, and later SPMD/SIMD
reductions/cross-lane work). Raw pointer types and unsafe pointer operations are
specified but not implemented.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT
