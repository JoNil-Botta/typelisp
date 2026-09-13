# Compiler architecture and CLI

This page describes the compiler pipeline and command-line surface. Run
`typelisp <command> --help` for the current option details.

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

Memory-class aggregate expressions carry addresses into inline storage.
`lower-local-assignment-value` gives a loop-carried memory-class local its own
inline storage before rebinding it. The source can arrive through a field,
enum payload, fixed-array projection, conditional merge, or nested loop; the
copy must not depend on incomplete address-provenance tracking. Otherwise a
later call can overwrite a retained result slot even at opt0. Raw pointers
copy only their address. The native `loop_carried_enum_payload_snapshot` and
`loop_carried_raw_read_snapshot` fixtures guard this boundary on both targets
at every optimization level. Address generation uses `lower-emit-gep`, also
shared by byte-offset projections through `lower-gep-byte`.

The compiler also has a pure, versioned incremental-query identity layer. It
canonicalizes typed source, logical-name, dependency, package/stdlib,
configuration, macro/comptime, target, and ordered-child inputs into a bounded
binary transcript and exact SHA-256 fingerprint. The layer is relocatable and
independent of cache storage: callers supply authority-checked package-relative
paths and nominal compiler/child identities, while event capture, invalidation,
result serialization, and reuse policy remain separate compiler services.

Aggregate declaration markers live in `AstDeclMeta` in
[`compiler_ast_types.tl`](../src/compiler_ast_types.tl), separate from runtime
layout. Parsing and surface hydration share its runtime metadata constructor;
unmarked runtime declarations reuse the singleton, and unchanged marker updates
do not allocate. Generated-declaration reuse in `compiler_specialize.tl` compares
these semantic flags even when the aggregates have identical ABI. The existing
AST wrapper, surface roundtrip, and specialization selftests guard these rules;
serialized metadata changes also require a surface-AST schema version change.

Handwritten runtime, startup, and direct-object x86-64 code is covered by the
closed [compiler-owned executable template registry](compiler-x64-executable-templates.md).
It records mutation-sensitive source identities and typed control/frame events
for later native-code certification.

Expression node IDs belong to an AST pool. Literal analysis in
`compiler_typecheck_core.tl` snapshots the context's expression owner for its
read-only walk and shares the AST unspanner with other structural consumers. The
scalar owner accessor borrows the context field directly; it must not copy the
complete pool aggregate merely to read its segment-base token.
An unrelated installed pool must not change literal classification, contextual
numeric types, or retained source provenance. The explicit compatibility route follows
its selected pool; macro-capable walks must resolve their owner again after a
possible pool install. The `tc-literal-expression-pool-isolation` inline test
covers colliding IDs, nested source views, expansion wrappers, and contextual
overflow rejection.

## Performance gates

Generated code is compared with `clang -O2` using paired cases under
[`../benchmarks/`](../benchmarks). Compiler and generated-code performance is
tracked with deterministic executed-instruction baselines under
[`../perf/`](../perf), avoiding wall-clock noise in required CI gates.

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
    typelisp explain        Explain a diagnostic code
    typelisp fmt            Format source files or a package
    typelisp init           Scaffold a package in the current directory
    typelisp inspect        Inspect a TypeLisp comptime image
    typelisp lint           Lint source files or a package
    typelisp lsp            Start stdio language server
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

Human-facing `check`, `compile`, `build`, `run`, and test-preflight failures
render error codes, source locations and snippets, carets, secondary labels,
and available help/notes. LSP and other machine consumers keep their structured
or stable flat diagnostic representations. Diagnostic codes are append-only:
published numbers are never renumbered or reused. The currently classified
typecheck codes are `E0201` (unbound name), `E0202` (arity mismatch), `E0203`
(non-exhaustive match), `E0204` (unknown struct field), `E0205` (region
escape), `E0206` (type mismatch), `E0207` (borrow violation), `E0208` (move
violation), `E0209` (unsafe context required), `E0210` (lifetime mismatch),
`E0211` (resource ownership violation), `E0212` (arena ownership violation),
`E0213` (invalid pattern), `E0214` (SPMD restriction), `E0215`
(invalid storage place), `E0216` (control-flow misuse), `E0217` (thread-safety
violation), `E0218` (compile-time constraint), and `E0219` (unsafe callable
effect erasure). Run
`typelisp explain <code>` for a description, minimal failing
example, suggested fix, and related references. Code lookup is ASCII
case-insensitive. `typelisp explain --list` prints the registry and
`typelisp explain --search <term>` searches its titles and prose. The generic
`E0100` parse and `E0200` unclassified typecheck entries also have complete
explanations. The checked-in ownership and construction-site inventory is in
[diagnostic-codes.md](diagnostic-codes.md).

Disposable measurements and diagnostics belong under `target/exp/<name>/`;
`typelisp clean --experiments` removes that subtree at the nearest package root
without touching bootstrap or package build outputs.
