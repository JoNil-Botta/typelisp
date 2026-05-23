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
./target/release/typelisp check   examples/hello.tl
./target/release/typelisp compile examples/hello.tl     # writes examples/hello.s
./target/release/typelisp run     examples/hello.tl
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
(Array t n)       ; fixed-size array (parses/type-checks; value lowering WIP)
(Tuple t1 t2 ...) ; (parses/type-checks; value lowering WIP)
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

`stdlib/string.tl` is the canonical in-repo string utility module. Today it is
still imported through the same filesystem path mechanism as any other module:
make `stdlib/string.tl` reachable relative to the importing file, or use an
absolute path. `check`, `compile`, and `run` also accept
`--stdlib-root <dir>`; for imports under `stdlib/`, TypeLisp first tries the
importer-relative path, then searches configured roots by stripping the leading
`stdlib/`. TypeLisp does not yet have a package manifest, dependency resolver,
or implicit prelude.

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

`lambda` parses and type-checks as a function value in limited cases, but
backend lowering for lambda literals and captured closures is incomplete today.

### Builtins

`print`, `print-bool`, `print-float`, `print-char`, `print-newline`,
`print-string`/`print-str`; `arg-count`, `arg`, `read-file`, `write-file`,
`file-exists?`; `make-array`, `array-ref`, `array-set!`,
`array-length`/`length`; strings: `string-length`/`length`,
`string-ref`/`char-at`, `string-eq`/`string=?`, `string-append`/`string-concat`,
`substring`/`string-slice`, `string->int`, `int->string`; and `panic`/`error`.
Array and string indexing is bounds-checked at runtime.

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
    ↓  Optimizer    → constant folding, DCE, strength reduction, copy propagation
    ↓  Backend      → x86_64 assembly (.s)
    ↓  as + ld      → ELF binary
```

## CLI

```bash
typelisp tokenize file.tl    # Print token stream
typelisp parse    file.tl    # Print AST
typelisp check    file.tl    # Type check
typelisp compile  file.tl    # Generate assembly (.s); -o <path>, --emit-ir
typelisp run      file.tl    # Compile, assemble, link, and run (needs as/ld)
```

## Status

Implemented: lexer, parser, type checker, IR lowering, optimizer, and a working
x86_64 backend. Integers, floats (`f64`), bool/char/unit, `if`/`while`/`begin`,
local & global variables, direct and indirect calls, `cast`, enums + `match`,
structs + field access, dynamic arrays, strings, `extern`, and multi-file
modules all compile to native code. See the
[project roadmap](https://github.com/JoNil-Botta/typelisp/issues/8) and
[SPEC.md §8](SPEC.md) for what is not yet supported (closures, tail calls,
tuple/fixed-array value lowering, `f32` codegen, GC).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT
