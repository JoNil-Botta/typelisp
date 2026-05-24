# TypeLisp

A statically typed Lisp/Scheme dialect that compiles directly to native
x86_64 Linux assembly. Written in Rust with **zero third-party dependencies**
(`std` only).

## Goals

- **Typed**: Every expression has a known type at compile time. No runtime type tagging.
- **Native**: Compiles straight to x86_64 assembly, then `as` + `ld` to an ELF binary. No bytecode VM, no interpreter, no garbage collector.
- **Zero dependencies**: Built with Rust `std` only. No third-party crates.
- **Self-hostable front end**: A lexer, s-expression reader, and tree-walking evaluator for TypeLisp are themselves written in TypeLisp (see [`selfhost/`](selfhost)).

## Quick Start

```bash
git clone https://github.com/JoNil-Botta/typelisp
cd typelisp
cargo build --release

# Type-check, compile, or run a program (run requires `as`/`ld` on Linux):
./target/release/typelisp debug check examples/hello.tl
./target/release/typelisp compile examples/hello.tl     # writes examples/hello.s
./target/release/typelisp run     examples/hello.tl
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

### Top-level forms

`define` (variable / function), `defenum`, `defstruct`, `extern`, `import`.

```lisp
(defenum Tree (Leaf i64) (Node Tree Tree))   ; recursive enums supported
(defstruct Pair (fst i64) (snd i64))
(extern foreign-add : (-> i64 i64 i64))
(import "lib/util.tl")                        ; relative, deduped; cycles load once
```

`stdlib/string.tl` is the canonical in-repo string utility module. Stdlib files
are ordinary modules imported with explicit paths such as
`(import "stdlib/string.tl")`. `check`, `compile`, and `run` also accept
`--stdlib-root <dir>` for resolving `stdlib/...` imports from a configured
source tree. `TYPELISP_STDLIB_ROOT` can provide an optional fallback root after
explicit CLI roots; prefer `--stdlib-root` for CI, bootstrap, and reproducible
scripts. See [stdlib/README.md](stdlib/README.md) for the current stdlib layout
and verification conventions.

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

`typelisp build [--manifest-path path/to/typelisp.pkg]` resolves `entry`
relative to the manifest directory and writes assembly under
`target/typelisp/<package-name>/<package-name>.s`. Dependency paths may be
relative to that same package root or absolute. Inside a package build, imports
of the form `(import "pkg:math/src/lib.tl")` resolve from the dependency root
declared for alias `math`; ordinary string imports remain relative to the
importing file, and `stdlib/...` imports keep their local-first then
configured-root behavior.

Imported package definitions share the same flat top-level namespace as local
modules, so duplicate value or type names fail through the existing duplicate
definition diagnostics. This package slice has no registry, version solving,
lockfile, workspace model, namespace isolation, qualified symbol lookup, or
native executable build promise.

Documentation comments can contain checked examples. `typelisp doc --test
<file.tl>` extracts fenced `typelisp` or `tl` blocks from `;;;;` module docs and
attached `;;;` item docs, writes each example to a deterministic temporary
source file, type-checks it, and removes the temporary directory before exiting.
The self-hosted Markdown generator can render one source file through
`typelisp run selfhost/doc.tl -- input.tl output.md`; import-graph traversal and
Rust CLI plumbing are separate follow-up work.

```lisp
;;;; ```typelisp
;;;; (define (main) : i64 42)
;;;; ```

;;; ```tl expect-error
;;; (define (bad) : i64 true)
;;; ```
(define documented : i64 1)
```

Examples are standalone TypeLisp source snippets. By default an example must
parse, resolve imports, and type-check. Add `expect-error` after the language tag
when the example is intended to fail. Ordinary `;` and `;;` comments are not
documentation and are ignored by the doctest scanner.

### Enum and struct namespace rules

TypeLisp keeps **type names** and **value names** in separate namespaces:

- **Type namespace**: enum and struct type names share one namespace, so
  `defenum Shape` and `defstruct Shape` collide.
- **Value namespace**: functions, variables (`define`), `extern`s, struct
  constructors, and enum *variant* constructors all share one namespace, so a
  variant `Foo` cannot coexist with a function, variable, or `extern` named
  `Foo`, even if they belong to different enums.
- An enum *type* name may intentionally share a name with one of its own
  variants (e.g. `defenum Result (Result i64) (Err String)`), because the type
  and the constructor live in different namespaces.

### Expression forms

`if`, `let`, `while`, `begin`, `set!`, `match` (incl. nested/recursive enum
patterns and `_`), `ann`, `cast`, plus arithmetic (`+ - * / %`), comparison
(`= != < <= > >=`), boolean (`and` `or`), and bitwise/shift (`bit-and` `bit-or`
`bit-xor` `shl` `shr`) operators. `struct-get` reads a struct field.

Named top-level functions and non-capturing `lambda` literals can be passed as
raw function pointer values. Lambda literals are lowered to deterministic
synthetic top-level functions and can return the same pointer-backed aggregate
values as named functions. Captured closures are still rejected.
SPMD/SIMD `foreach` is documented in [SPEC.md section 5.15](SPEC.md). The
compiler parses and type-checks the first source form and lowers it to scalar
reference loops; vector IR and AVX backend support are not implemented yet.

### Builtins

`print`, `print-bool`, `print-float`, `print-char`, `print-newline`,
`print-string`/`print-str`; `arg-count`, `arg`, `read-file`, `write-file`,
`file-exists?`; `make-array`, `array-ref`, `array-set!`,
`array-length`/`length`; strings: `string-length`/`length`,
`string-ref`/`char-at`, `string-eq`/`string=?`, `string-append`/`string-concat`,
`substring`/`string-slice`, `string->int`, `int->string`; and `panic`/`error`.
Array and string indexing is bounds-checked at runtime.

### Memory and aliasing

TypeLisp does not currently have source-level references, borrowing, ownership
transfer, destructors, `free`, or a garbage collector. Aggregate values such as
`String`, dynamic arrays, structs, and enums are implemented as pointer-sized
handles in the IR/ABI, but those handles are not checked language references.

`String` values are immutable at the source level. Dynamic arrays are shared
mutable buffers: copying or passing an `(Array T)` value aliases the same
storage, so `array-set!` through one handle is visible through another. Struct
and enum values are pointer-shaped internally; structs are read-only today
because `struct-set!` is not implemented. Heap allocation uses a
backend-emitted `tl_alloc` bump allocator and allocations live until process
exit. See [SPEC.md §7](SPEC.md) for the precise current model.

The v1 reclamation direction keeps that process-lifetime arena as the default
and does not add general per-object `free` or GC yet. `String` buffers, dynamic
array storage, returned enum/struct storage, and self-hosted data structures all
remain heap allocations. General `free` is deferred until ownership, borrowing,
and reference semantics are designed, because current aggregate handles can be
copied freely. A tracing GC is also larger than the next step. The planned first
reclamation mechanism is explicit region reset for tool-owned phase boundaries:
resetting a region invalidates every heap handle allocated after its mark and is
only valid when a compiler, formatter, package-tooling, or REPL phase has
discarded those values. See #320, #418, and #419 for the split follow-up work.

See [SPEC.md](SPEC.md) for the full language reference.

## Self-hosting sources

The [`selfhost/`](selfhost) directory builds up a TypeLisp front end *written in
TypeLisp*:

- `lexer.tl` — a tokenizer for TypeLisp's own s-expression syntax.
- `read.tl` — an s-expression reader producing a recursive `Sexpr` cons-cell tree (an importable module).
- `eval.tl` — a tree-walking evaluator over that tree, with integers, strings, cons pairs, and interpreted first-class closures.

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
    ↓  as + ld      → ELF binary
```

## CLI

```bash
typelisp debug tokenize file.tl    # Print token stream
typelisp debug parse    file.tl    # Print AST
typelisp debug check    file.tl    # Type check
typelisp compile        file.tl    # Generate assembly (.s); -o <path>, --emit-ir, --backend-mode <mode>
typelisp run            file.tl    # Compile, assemble, link, and run (needs as/ld); --backend-mode <mode>
typelisp build                    # Build nearest typelisp.pkg to package assembly; --backend-mode <mode>
```

The older top-level `tokenize`, `parse`, and `check` commands remain as
compatibility aliases.

`compile`, `run`, and `build` accept `--backend-mode scalar|avx2|avx512`.
`scalar` is the default and only implemented mode today; `avx2` and `avx512`
parse but are rejected until SIMD code generation lands.

## Status

Implemented: lexer, parser, type checker, IR lowering, optimizer, and a working
x86_64 backend. Integers, floats (`f64`), bool/char/unit, `if`/`while`/`begin`,
local & global variables, direct and indirect calls, `cast`, enums + `match`,
structs + field access, dynamic arrays, strings, `extern`, and multi-file
modules all compile to native code. See the
[project roadmap](https://github.com/JoNil-Botta/typelisp/issues/8) and
[SPEC.md §8](SPEC.md) for what is not yet supported (closures, tail calls,
tuple/fixed-array by-value returns, `f32` codegen, general GC/free,
ownership/borrowing, SPMD/SIMD).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT
