# TypeLisp

TypeLisp is a statically typed Lisp dialect for native systems programming. It
compiles directly to x86-64 assembly, is designed to keep safe code free of
undefined behavior through ownership and borrowing, and uses arenas instead of
a garbage collector. The compiler, standard library, formatter, linter,
documentation generator, and language server are written in TypeLisp.

The project is experimental. The compiler and toolchain are usable on Linux and
Windows x86-64, but the language and standard library are still changing. Expect
breaking changes. TypeLisp is currently best suited to compiler work,
experimentation, and small native tools.

## Why TypeLisp?

TypeLisp combines several deliberate constraints:

- Lisp syntax with static types, algebraic data types, pattern matching, and
  native data layout.
- Direct native compilation with no bytecode VM, interpreter, or garbage
  collector.
- Move semantics, lexical borrowing, scoped arenas, and safe boxed recursive
  data.
- Zig-style comptime generation instead of source-level generics, traits, or
  `impl` blocks.
- ISPC-style SPMD forms with scalar, AVX2, and AVX-512 lowering for supported
  subsets.
- A self-hosted compiler with no third-party package dependencies.

The native assembler and linker are still required build inputs. “Zero
third-party dependencies” does not mean that the operating-system toolchain is
optional.

## Quick start

TypeLisp currently supports `linux-x86_64` and `windows-x86_64`. macOS and ARM
are not current targets.

### Linux

```sh
git clone https://github.com/JoNil-Botta/typelisp.git
cd typelisp
scripts/fetch-stage0.sh
tl=target/stage0/typelisp

$tl check examples/hello.tl
$tl fmt --check examples/hello.tl
$tl run examples/hello.tl
```

Linux builds require `as` and `ld`. The example prints:

```text
Hello, TypeLisp!
factorial(5) = 120
```

### Windows PowerShell

```powershell
git clone https://github.com/JoNil-Botta/typelisp.git
Set-Location typelisp
powershell -ExecutionPolicy Bypass -File scripts\fetch-stage0.ps1
$tl = "target/stage0/typelisp.exe"

& $tl check examples\hello.tl
& $tl fmt --check examples\hello.tl
& $tl run examples\hello.tl
```

Windows builds require `clang`, MSVC `link.exe`, and a Windows SDK.

### Common commands

```text
typelisp check <file.tl>       Type-check without linking
typelisp compile <file.tl>     Generate assembly
typelisp build <file.tl>       Compile, assemble, and link
typelisp run <file.tl>         Build and run
typelisp test <file.tl>        Run inline tests
typelisp fmt --check <file.tl>
typelisp lint <file.tl>
typelisp doc --test <file.tl>
```

Run `typelisp <command> --help` for the current command-specific options.

## A small example

```lisp
(defenum Shape
  (Circle i64)
  (Rect i64 i64))

(define (area [shape : Shape]) : i64
  (match shape
    [(Circle radius) (* 3 (* radius radius))]
    [(Rect width height) (* width height)]))

(define (main) : i64
  (area (Rect 5 6)))
```

The return value of `main` is the process exit code. If `main` is absent, the
compiler synthesizes an entry point that returns `0`.

For a guided introduction, start with the [getting-started
guide](https://jonil-botta.github.io/typelisp/getting-started.html). The checked
source is [`docs/getting_started.tl`](docs/getting_started.tl), and CI compiles
its examples so the guide cannot silently drift from the language.

## Current status

The following parts are implemented and actively tested:

- The full compiler pipeline from lexer to x86-64 assembly, with Linux and
  Windows object/link targets.
- Structs, enums, exhaustive `match`, tuples, fixed arrays, strings, closures,
  FFI, raw pointers, and atomics.
- Move and borrow checking, scoped and first-class arenas, safe recursive data
  through `(Box T)`, and safe task threading.
- Comptime macros with type reflection, package manifests and lockfiles,
  inline tests, doctests, formatting, linting, documentation generation, and a
  stdio language server.
- SPMD `foreach`, `spmd-reduce`, and `spmd-scan` with scalar lowering and
  restricted AVX2/AVX-512 lowering.

Some capabilities remain restricted or experimental:

- Scalar `spmd-scan` is implemented. AVX2 and AVX-512 support covers only a
  restricted set of canonical scan forms. General scan vectorization is not
  complete.
- The TLCI native comptime route is an opt-in verification path, not the
  default route in published stage0 builds.
- Public vector and mask value types, general vectorized SPMD support, a
  package registry, and workspaces are not complete.
- General `free` and GC are intentionally not planned. TypeLisp uses arenas as
  its memory-reclamation model.

See [SPEC.md](SPEC.md) for the authoritative language contract and its complete
implementation matrix. See the [project roadmap](https://github.com/JoNil-Botta/typelisp/issues/8)
for active work and design decisions.

## Documentation

- [Getting started](https://jonil-botta.github.io/typelisp/getting-started.html)
- [Language guide](docs/language-guide.md)
- [Language specification](SPEC.md)
- [Memory and ownership](docs/memory-model.md)
- [Concurrency and SIMD](docs/concurrency-and-simd.md)
- [Packages](docs/packages.md)
- [Testing, documentation, and bootstrap](docs/testing-and-bootstrap.md)
- [Compiler architecture and CLI](docs/compiler-architecture.md)
- [Standard library reference](stdlib/README.md)
- [VS Code extension](tools/vs-code-extension/README.md)
- [Generated documentation site](https://jonil-botta.github.io/typelisp/)

### Syntax conventions

New code should use dotted module imports, qualified standard-library names,
fixed-size `Array`, `ByteBuf` for mutable binary data, in-place mutation with
`set!`, and declaration-emitting comptime macros. Compatibility spellings may
remain in migration fixtures, but new code should not imitate them. The
[language guide](docs/language-guide.md) shows the current surface, and
`typelisp lint` reports several staged migrations.

## Editor support

The [`tools/vs-code-extension`](tools/vs-code-extension) directory contains a
VS Code extension with syntax highlighting and a stdio language server. It
provides diagnostics, compiler and lint quick fixes, definition lookup, hover,
completion, inlay hints, and formatting. See its
[README](tools/vs-code-extension/README.md) for installation.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) before changing the compiler or language.
The important project rules are:

- The implementation, tooling, and tests stay self-hosted in TypeLisp.
- The project has no third-party package dependencies.
- Syntax migrations remove the old spelling instead of adding aliases.
- New code must follow the current naming and module conventions.
- Compiler and performance changes must include the appropriate tests and
  deterministic measurements.

Run `scripts/ci-verify.sh` to execute the full local verification gate. The
repository's [scripts README](scripts/README.md) explains which gates run in CI.

## License

MIT
