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

TypeLisp is built around ten project pillars. They are decision criteria and
measured targets, not a claim that every current program already meets them:
[SPEC.md](SPEC.md) is the authoritative contract, and its section 8 records the
implemented subset.

- **C-class control and native layout.** Ordinary structs and enums keep their
  declared native/C layout; the compiler never inserts hidden representation
  changes. See [SPEC.md](SPEC.md) sections 3.5.3 and 4.7.3.
- **Rust-class safety and usability.** Safe code has no undefined behavior:
  ownership, borrows, lifetimes, and arena regions are checked statically, and
  diagnostics and ordinary API use are held to the same practical standard.
  See [SPEC.md](SPEC.md) section 1 and the [memory model](docs/memory-model.md).
- **`clang -O2`-class generated-code performance with fast compilation.**
  Generated code is measured against paired C baselines and instruction-count
  gates, while compile time stays an independently guarded target. See
  [benchmarks](benchmarks/README.md) and [CONTRIBUTING.md](CONTRIBUTING.md).
- **Lisp simplicity and minimal magic.** A small core of explicit, inspectable
  mechanisms; no hidden heap identity and no implicit language magic. See the
  [language guide](docs/language-guide.md).
- **Zig-style comptime expressed as Lisp macros.** Typed expression macros and
  declaration-generating macros replace source generics, traits, interfaces,
  and `impl` blocks. See [SPEC.md](SPEC.md) section 3.7.
- **ISPC-style SPMD.** One source model with scalar reference semantics and
  native AVX2/AVX-512 lowering for supported subsets, with gaps stated in
  [SPEC.md](SPEC.md) section 8.2.
- **Full self-hosting and zero package dependencies.** Compiler, stdlib,
  tooling, and tests are TypeLisp; host OS interfaces and the documented
  assembler/linker toolchain are not package dependencies. See [the bootstrap
  guide](docs/testing-and-bootstrap.md).
- **Deterministic, native Linux/Windows tooling.** Reproducible identities,
  diagnostics, and specified artifacts, with equivalent supported behavior on
  both native targets. See [compiler invariants](docs/compiler-invariants.md).
- **Zero is initialization.** The all-zero state of every ZII storage type is
  valid, safely overwritable, and safely discardable without hidden
  construction or cleanup. See [SPEC.md](SPEC.md) section 5.12.1.
- **Arena-based allocation and reclamation.** No garbage collector and no
  general-purpose per-object `free`; allocation is explicit and memory is
  reclaimed through program-lifetime, scoped, first-class, or atomic arenas.
  See the [memory model](docs/memory-model.md).

On Linux, TypeLisp assembles its own output and uses the host linker and
archiver. Windows builds use the Windows native toolchain.

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

Fetching uses `curl`; recovery from an unavailable `stage0-latest` also
requires `jq` to select a checksum-verified immutable release from `main`.

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
typelisp assemble <file.s> -o <file.o> [--target linux-x86_64|windows-x86_64]
typelisp run <file.tl>         Build and run
typelisp test <file.tl>        Run inline tests
typelisp fmt --check <file.tl>
typelisp lint <file.tl>
typelisp doc                    Build target/doc/index.html for the nearest package
typelisp doc --test <file.tl>
typelisp expand <file.tl> --at LINE:COL
                                Show the checked expansion of a macro invocation
typelisp explain <code>         Explain a diagnostic code
typelisp explain --list         List diagnostic codes
typelisp explain --search TERM  Search diagnostic explanations
```

Run `typelisp <command> --help` for the current command-specific options.
Inline tests may start with `(:ignore "reason")` and/or `(:slow)` metadata.
`typelisp test` skips those tests by default; use `--include-ignored` or
`--include-slow`, `--exact <name>` for a complete-name selection, and
`--shuffle --seed <u64>` to replay a shuffled order. Repeatable `--cfg <name>`
values compose with the automatic `test` and target cfg predicates.

Pass `--backtrace` (or `--debug`/`-g`) to `compile`, `build`, or `run` to
embed fatal-error symbol metadata. Such binaries default to a full trace;
`TYPELISP_BACKTRACE=off|short|full` selects silence, eight captured frames, or
64 captured frames at runtime. Ordinary builds contain no backtrace metadata or
runtime hooks. For reproducible debug artifacts,
`TYPELISP_REMAP_PATH_PREFIX=FROM=TO` rewrites matching source-path prefixes in
line tables, fatal-site descriptors, and the embedded map.

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

The return value of `main` is the process exit code. An executable must define
`main`: a program without one is rejected rather than given an empty entry
point. Library code (a `staticlib` package, or `typelisp compile --no-entry`)
needs no `main`.

For a guided introduction, start with the [getting-started
guide](https://jonil-botta.github.io/typelisp/getting-started.html). The checked
source is [`docs/getting_started.tl`](docs/getting_started.tl), and CI compiles
its examples so the guide cannot silently drift from the language.

## Current status

The following parts are implemented and actively tested:

- The full compiler pipeline from lexer to x86-64 assembly, with Linux and
  Windows object/link targets.
- Structs, enums, exhaustive `match`, tuples, fixed arrays, borrowed `Slice`
  views with checked range-disjoint splitting, strings, closures, FFI, raw
  pointers, and atomics.
- Move and borrow checking, scoped and first-class arenas, native-layout
  recursive data through explicit finite-size edges (`Box`, checked references,
  or raw pointers in C-compatible declarations), and safe task threading.
- Comptime macros with type reflection, package manifests and lockfiles,
  inline tests, doctests, formatting, linting, documentation generation, and a
  stdio language server with a deterministic multi-root workspace index and
  open-document overlays.
- Shallow application-owned package graphs: executables declare every normal
  dependency directly, and reusable TypeLisp static libraries are
  dependency-free.
- Rust-style primitive Debug selectors with byte-safe quoted text, source-width
  float behavior, hexadecimal integer leaves, checked-reference forwarding,
  and shared String/writer/stdout/stderr dispatch.
- SPMD `foreach`, `spmd-reduce`, `spmd-scan`, `spmd-compact`, `spmd-broadcast`, and
  `spmd-shuffle`, plus `program-index` / `program-count` lane identity, with
  scalar reference lowering and native AVX2/AVX-512 lowering for eligible
  shapes. `foreach-active` visits active lanes in increasing order. It uses
  a one-lane gang in scalar mode and native mask iteration on SSE2, AVX2,
  and AVX-512.
  `foreach` can use ordinary `stdlib.math` calls such as `f64-abs`,
  `f32-sqrt`, and the float bit conversions. Loops that reach these float
  intrinsics can use scalar-reference lowering in every backend mode. In
  SIMD modes the compiler diagnoses combinations with gang identity,
  `foreach-active`, lane collectives, or imported SPMD specializations that
  require a gang.

Some capabilities remain restricted or experimental:

- Canonical range-wide scans vectorize in both AVX2 and AVX-512; other
  supported scan shapes retain the specified scalar reference. Native SIMD is
  limited to the eligible shapes in SPEC section 8.2; deliberate language
  exclusions receive focused diagnostics instead of silent scalarization.
- Published compilers dispatch trusted embedded-stdlib and package-dependency
  comptime macros through TLCI native catalogs on Linux and Windows. Dependency
  catalogs are source- and host-admitted, selected by physical defining
  provenance, and revalidated against their package key and mapping generation
  immediately before execution; unsupported registered shells retain
  deterministic source CTFE.
- Public vector, mask, and varying source value types remain deferred by
  design. A package registry and workspaces are also not complete.
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
- [Compiler architecture](docs/compiler-architecture.md)
- [Compiler invariants and CLI](docs/compiler-invariants.md)
- [Standard library reference](stdlib/README.md)
- [VS Code extension](tools/vs-code-extension/README.md)
- [Generated documentation site](https://jonil-botta.github.io/typelisp/)

### Syntax conventions

New code should use dotted module imports, qualified standard-library names,
fixed-size `Array`, `ByteBuf` for mutable binary data, in-place mutation with
`set!`, and declaration-emitting comptime macros. String-path imports are no
longer accepted. The [language guide](docs/language-guide.md) shows the current
surface, and `typelisp lint` reports several staged migrations.

## Editor support

The [`tools/vs-code-extension`](tools/vs-code-extension) directory contains a
VS Code extension with syntax highlighting and a stdio language server. It
provides diagnostics, compiler and lint quick fixes, definition lookup,
semantic references and safe semantic rename across the workspace, hover,
cursor-aware completion over semantic visibility, imports, members, and live
workspace overlays, semantic signature help, inlay hints, and formatting.
Rename uses standard `prepareRename`/`rename` requests, rejects incomplete or
non-editable targets before returning any edit, and versions open-document
edits. The server indexes workspace sources, with unsaved open documents
overriding disk snapshots, and lazily caches owned semantic snapshots for
unopened sources behind a completeness-reporting query boundary. See the extension
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

Run `scripts/ci-verify.sh` to execute the full local verification gate. Its
host prerequisites are listed under Development Setup in
[CONTRIBUTING.md](CONTRIBUTING.md), and it checks them before the first gate
starts. The repository's [scripts README](scripts/README.md) explains which
gates run in CI.

## License

MIT
