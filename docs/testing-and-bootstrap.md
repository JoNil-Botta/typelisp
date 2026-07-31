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
The runner announces every selected test, continues after assertion failures,
prints `ok` or `FAILED` for each test, and finishes with passed, failed, and
total counts. `--filter <substring>` selects inline-test names (and package
integration paths), while `--list` prints the selected names without running
them. Ordinary assertion failures exit `1`; an unexpected harness abort exits
`2`.
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
`--deprecated-string-concat`, `--redundant-function-name`, and
`--prefer-dotted-field`. `--legacy-path-import` reports compatibility-only
string-path imports with their dotted replacements, and `--name-case` enforces
those naming conventions. Findings use rich source diagnostics by default,
including the rule ID accepted by `;; lint-allow: <rule-id>` and a suggested
remedy. Scripts that parse lint output can select the stable
`path:line:column: message` form with `--format flat`.
Dead-code lint treats library packages as external API roots and reports
unreachable declarations in `bin` packages.

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
discovery.

## Documentation site

A static language-reference and stdlib/API site is generated entirely in
TypeLisp by [`../tools/doc-site/doc_site.tl`](../tools/doc-site/doc_site.tl) and
published to GitHub Pages at <https://jonil-botta.github.io/typelisp/> on
every push to `main`; pull requests build and validate it without publishing.
Build locally with
`typelisp run tools/doc-site/doc_site.tl --stdlib-root stdlib --stdlib-root src -- target/site`,
or run `scripts/verify-doc-site.sh` to build and validate links the way CI
does.
