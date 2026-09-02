# Testing, documentation, and bootstrap

This page describes the project verification layers, self-hosting workflow,
and documentation site.

## Tests and documentation

Inline tests live next to source declarations as `(test name body...)`
items. Normal builds type-check inline tests owned by the package's own
sources (never imported stdlib or dependencies), then drop them before
production codegen. `typelisp test <file.tl>` turns a file's inline tests
into a generated harness and runs it; with no file, it runs the nearest
package's inline tests plus `tests/**/*.tl` integration programs (exit 0
passes). `typelisp test --check` type-checks harnesses without linking.
The runner announces every selected runnable test, continues after assertion
failures, prints `ok` or `FAILED` for each executed test, and finishes with
passed, failed, ignored, slow-skipped, and total counts. Tests may begin with
`(:ignore "reason")` and/or `(:slow)` metadata and are skipped unless their
corresponding `--include-ignored` / `--include-slow` option is present.
`--filter <substring>` selects inline-test names (and package integration
paths); `--exact <name>` selects a complete name or normalized integration path
instead. `--list` prints names, locations, and skip states. Repeatable `--cfg
<name>` values compose with automatic `test` and target cfgs. `--shuffle`
prints its seed before listing/execution, and `--shuffle --seed <u64>` replays
the same portable order. Ordinary assertion failures exit `1`; an unexpected
harness abort exits `2`.
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
compile, run, and compare exit/stdout/stderr on Linux). `typelisp doc input.tl
-o output.md` renders Markdown docs for the entry file and its import graph.
Bare `typelisp doc` discovers the nearest package and writes a deterministic
offline site to `target/doc/index.html`; `--open` opens that index when a
graphical platform opener is available and otherwise prints its path without
failing. `--no-deps` guarantees root-package-only output. An explicit package
`-o <out.md>` retains the single-file Markdown form.

TypeLisp names follow the project-wide convention: top-level values,
functions, macros, parameters, and local binders use kebab-case; struct and enum
types use UpperCamelCase. Macro operands declared as `type` also use
descriptive kebab-case, while one-letter type variables may use the conventional
uppercase spelling such as `T`. One leading `_` marks an intentionally unused
parameter or local. ABI-constrained and generated spellings require a targeted
lint suppression at their declaration.

Public stdlib operations that mutate caller-owned state through `&mut` use a
terminal `!`. The suffix describes the effect; it does not make ordinary calls
implicitly borrow a mutable place. Some generated APIs separately provide
place-taking bang macros that evaluate each operand once and expand through
normal checked `&mut` semantics. Consuming owners and reading or yielding views
through `&mut` do not alone require `!`, and iterator `next` / `next-mut` is the
protocol exception. See [the stdlib naming
contract](../stdlib/README.md#public-mutator-names) for examples and migration
rules.

`typelisp lint` includes staged migration rules such as
`--deprecated-string-concat` and `--redundant-function-name`;
`--prefer-dotted-field` is a deprecated no-op because dotted projection is now
the only public field syntax. `--name-case` enforces those naming conventions.
Legacy string-path imports are rejected by the parser rather than reported by
an opt-in lint rule. Findings use rich source diagnostics by default,
including the rule ID accepted by `;; lint-allow: <rule-id>` and a suggested
remedy. Scripts that parse lint output can select the stable
`path:line:column: message` form with `--format flat`.

The default `raw-arena-op` rule rejects direct calls to the raw arena
set/destroy/rewind helpers and their unsafe `arena` wrappers outside the
checked-in audited module allowlist. New code should use `in-arena`,
`with-scratch`, `with-arena`, `rewind-safe!`, or `destroy-safe!`; the allowlist
exists only for runtime protocols whose migration is tracked separately.

Dead-code lint treats library packages as external API roots and reports
unreachable declarations in `bin` packages.

### Cross-mode differential corpus

The required CI suite runs one compact cross-cutting semantic and ABI corpus
after its exhaustive producer gates. The checked manifest at
[`../tests/cross-mode/corpus.tsv`](../tests/cross-mode/corpus.tsv) pairs
high-risk routes across optimizer levels, internal/C ABI calls, bootstrap
generations, source/native comptime, scalar/SIMD lowering, Windows
assembly/direct-object emission, and platform-independent target behavior.
The shared `verify-cross-mode-differential.sh` oracle canonicalizes only the
declared observations—exit status, exact stdout/stderr, normalized diagnostic,
or artifact digest—rather than requiring unrelated machine code to be
byte-identical.

The corpus deliberately reuses binaries and observations left by integration,
TLCI, SPMD, and Windows COFF gates. Its only fresh compiles are one compact
fixture with the previous and successor compiler binaries already built by the
same bootstrap. Host and ISA exclusions are written to
`target/cross-mode-differential/applicability.tsv`; an absent prerequisite for
an active row is a failure, never a silent skip. Run a retained failing row
with:

```sh
TYPELISP_BIN=path/to/successor \
TYPELISP_CROSS_MODE_PREVIOUS_COMPILER=path/to/previous \
scripts/verify-cross-mode-differential.sh --case CASE
```

`scripts/verify-cross-mode-differential.sh --self-test` applies controlled
changes to both sides of every manifest pair and requires the oracle to report
the first differing axis, observation, route, and reproduction command.
Feature-local gates remain authoritative for exhaustive coverage; this corpus
only supplies representative cross-mode witnesses.

## Self-hosting and bootstrap

The compiler front end, IR, optimizer, backends, and all tooling under
[`../src/`](../src) are written in TypeLisp; compiler self-test conventions are
documented in [`../src/TESTING.md`](../src/TESTING.md). The repository root is
itself a package: from a checkout, `typelisp build` builds the unified
selfhost CLI from `src/main.tl` into `target/release/`.

The published stage0 is a single self-hosted binary per OS
(`typelisp-stage0-linux`, `typelisp-stage0-windows.exe`). The
[`Bootstrap Stage0`](../.github/workflows/bootstrap-stage0.yml) workflow is
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
discovery. The Windows package archive gate also requires `llvm-ar` and checks
the deterministic `TYPELISP_WINDOWS_LIB` contract documented in
[`packages.md`](packages.md).

## Documentation site

A static language-reference and stdlib/API site is generated entirely in
TypeLisp by [`../tools/doc-site/doc_site.tl`](../tools/doc-site/doc_site.tl) and
published to GitHub Pages at <https://jonil-botta.github.io/typelisp/> on
every push to `main`; pull requests build and validate it without publishing.
Build locally with
`typelisp run tools/doc-site/doc_site.tl --stdlib-root stdlib --stdlib-root src -- target/site`,
or run `scripts/verify-doc-site.sh` to build and validate links the way CI
does. The generated site includes an offline static search index and a
keyboard-accessible search box (`/` focuses it). Results cover guide headings,
modules, declaration names, signatures, and documentation text. API entries
link to their exact source line at the recorded source revision, while page
metadata records the compiler, source, and package identities used for the
build. The verifier rejects broken links, duplicate anchors/search identities,
stale page/index identity pairs, missing search records, and an unexpectedly
large index.
