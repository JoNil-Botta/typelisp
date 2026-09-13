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

Package inline-test preflight owns AST/type pools and scratch storage per
source file. Its cfg-name snapshot owns copied strings across per-file intern
retirement. Pool-backed caches and derived dependency surfaces are cleared
before the pools are destroyed; replacement session carriers live in the
enclosing arena. The scalar scan for inline tests also releases its file text.

Package doctest discovery uses a separate frontend lifetime through
`compiler-driver-load-package-paths-with-runtime`. Earlier frontend consumers
must be finished: discovery resets reader origins and analysis caches, while
the caller retains manifest/root/dependency strings and its admitted catalog.
The temporary load session
borrows the enclosing package's admitted dependency catalog and owns its parsed
AST/type pools, interner, caches, and hydrated dependency surfaces. It copies
ordered path strings or a diagnostic into the caller's arena before restoring
the enclosing session, interner and builtin state and releasing those temporary
owners. The serial parser advances the active interner's scalar cursor, so this
load session uses the serial adapter that captures that live cursor. Binding an
explicit pre-parse interner snapshot here can silently omit imported modules.
Returned paths use absent owner/provenance IDs (`-1`): the builtin for the empty
spelling is itself an intern ID and cannot cross this
boundary. Releasing the borrowed catalog would invalidate the enclosing
package's native mappings and is forbidden.

After discovery, package doctest file reading and fence extraction use another
scratch lifetime. Only live example/error rows, including runnable output
expectations, are copied into the checker arena. Source bytes, line buffers,
and fence-scanner temporaries are released before typechecking. Both source
and file callers share the same extracted-example checker, preserving order,
counts, diagnostics, and the existing adjacent-path deduplication rule.

The lifetime tests in
[`compiler_package_discovery_lifetime_tests.tl`](../src/tests/compiler_package_discovery_lifetime_tests.tl)
exercise arena reuse, path and diagnostic ownership, session restoration,
subsequent checking, target changes, cfg snapshots, admitted native mappings,
and runnable/failure metadata. Ordinary
`clone` is not a valid way to escape flat-node compiler ASTs: their pool-backed
payloads require the loader's pool-aware compaction or an explicitly owned
pool lifetime.

The compiler also has a pure, versioned incremental-query identity layer. It
canonicalizes typed source, logical-name, dependency, package/stdlib,
configuration, macro/comptime, target, and ordered-child inputs into a bounded
binary transcript and exact SHA-256 fingerprint. The layer is relocatable and
independent of cache storage: callers supply authority-checked package-relative
paths and nominal compiler/child identities, while event capture, invalidation,
result serialization, and reuse policy remain separate compiler services.

Handwritten runtime, startup, and direct-object x86-64 code is covered by the
closed [compiler-owned executable template registry](compiler-x64-executable-templates.md).
It records mutation-sensitive source identities and typed control/frame events
for later native-code certification.

### Package direct-object routing

`build-package-prepare-runtime` in `build_cli_core.tl` owns package route
selection through `BuildPackageDirectObjectRequest`: target, artifact kind,
backend mode, debug policy, resource policy, strict policy, and loaded inputs.
Its result contains object bytes and complete side assembly, valid fallback
assembly with a closed `CompilerDirectObjectFallbackReason`, or a diagnostic.
Callers must not recheck eligibility or infer the route from diagnostic text.
The strict helper rejects every fallback before external tools or publication.

Package policy is distinct from serializer capability. Source and package ELF
consumers share `source-tool-linux-direct-object-eligibility` and
`source-tool-render-linux-direct-object` in `build_run_core.tl`; package code
only translates the artifact kind. COFF capability remains owned by
`compiler_windows_coff_core.tl`. Reason categories and bounded context are
rendered centrally in `compiler_backend.tl`, without parsing serializer errors.
The package freshness gate checks the shared ELF boundary, including mutations
that bypass it; inline tests cover policy combinations and malformed images.

The fresh-artifact pipeline prepares the runtime once for checked-surface
capture, then passes that same result to artifact finishing. Finishers accept
bytes and text, not AST/IR inputs; they cannot lower again or regenerate side
assembly. The package COFF request always asks for side assembly, and a missing
side artifact is an internal error. The freshness gate rejects mutations that
restore preparation or frontend inputs at this boundary.

Fallbacks retain assembly, without retaining the object image. Future archive
export summaries must be derived at
the successful-image boundary before compiler arenas retire, then returned as
bounded owned data alongside bytes. This preserves the route contract while
the backend migrates to shared machine records; it does not broaden object
eligibility or introduce public strict-mode options (#7452, #7395, #7032).

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
