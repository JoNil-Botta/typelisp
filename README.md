# TypeLisp

A typed Lisp/Scheme dialect with a custom x86_64 backend and optimizer.

## Goals

- **Typed**: Every expression has a known type at compile time. No runtime type tagging.
- **Simple**: Minimal syntax, minimal runtime, minimal magic.
- **Fast**: Compiles directly to x86_64 assembly. No bytecode VM, no interpreter.
- **Zero dependencies**: Built with Rust `std` only. No third-party crates.
- **Educational**: Small enough to understand the whole compiler in a weekend.

## Quick Start

```bash
git clone https://github.com/JoNil-Botta/typelisp
cd typelisp
cargo build --release
./target/release/typelisp check examples/hello.tl
```

## Example

```lisp
(define (factorial [n : i64]) : i64
  (if (= n 0)
      1
      (* n (factorial (- n 1)))))

(factorial 5)  ; => 120
```

## Language

TypeLisp uses S-expressions with optional type annotations.

```lisp
;; Variables
(define x : i64 42)

;; Functions
(define (add [a : i64] [b : i64]) : i64
  (+ a b))

;; Control flow
(if (< x 10)
    "small"
    "large")

;; Local bindings
(let ([y : i64 (+ x 1)])
  (* y 2))

;; Types
;; i64 i32 i16 i8 u64 u32 u16 u8 f64 f32 bool char unit
;; (-> arg1 arg2 ... ret)
;; (Tuple t1 t2 ...)
;; (Array type size)
```

## Architecture

```
Source Code
    ↓
Lexer → Tokens
    ↓
Parser → AST
    ↓
Type Checker → Typed AST
    ↓
Lowerer → IR (3-address code, basic blocks)
    ↓
Optimizer → Optimized IR
    ↓
Backend → x86_64 Assembly
    ↓
as + ld → Binary
```

## Current Status

See [Project Roadmap](https://github.com/JoNil-Botta/typelisp/issues/8).

- [x] Lexer, parser, AST
- [x] Type checker
- [x] IR data structures + optimizer skeleton
- [x] x86_64 backend skeleton
- [ ] IR lowering (#10)
- [ ] Optimizer pipeline (#11)
- [ ] Complete backend (#12)
- [ ] Source spans / error reporting (#9)
- [ ] Strings, arrays, stdlib (#13)

## CLI

```bash
typelisp tokenize file.tl    # Show tokens
typelisp parse file.tl       # Show AST
typelisp check file.tl       # Type check
typelisp compile file.tl     # Generate assembly
typelisp run file.tl         # Compile and execute
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT
