# Repository scripts

The `scripts/` directory contains CI entry points, focused verification gates,
bootstrap helpers, benchmarks, and optional local diagnostics. A filename
prefix alone does not determine whether a script is required by CI.

## What is a CI gate?

The workflow files are authoritative:

- `.github/workflows/ci.yml` runs the fast open-PR TLCI op-claim check in its
  own job; its Linux and Windows matrix runs `check-implementation-languages.sh`,
  then `ci-verify.sh`, then the timing-budget check.
- `.github/workflows/bootstrap-stage0.yml` runs the stage0 fetch/build/smoke
  and bootstrap-fixpoint scripts.
- `.github/workflows/docs-pages.yml` runs `fetch-stage0.sh` and
  `verify-doc-site.sh`.

`ci-verify.sh` is the full pull-request development gate. It bootstraps a
branch compiler and explicitly invokes the source hygiene, deterministic
codegen, compiler/profile, public-tool, integration, stdlib, documentation,
SPMD, benchmark, and instruction-count gates. A helper such as
`measure-instruction-counts.sh` can therefore be CI-critical even though its
own header calls it a measurement harness: `check-instruction-counts.sh` owns
the policy and invokes that helper.

When changing a script, check both direct workflow references and transitive
references from the gate entry points:

```sh
rg -n 'scripts/[^ ]+\.(sh|ps1)' .github/workflows scripts/ci-verify.sh
rg -n 'scripts/<script-name>' .
```

`check-gate-reachability.sh` enforces that mapping. It walks the same
references transitively from the workflow files and requires every top-level
`check-*` and `verify-*` script to be reached, so a new gate cannot land
unreferenced the way the two ISPC correctness gates did (#5690). Documentation
is never a root: a gate mentioned only by this README still counts as dead.
A gate that is intentionally not wired goes in `optional-gate-allowlist.tsv`
with a reason, and the entry is rejected once the gate becomes reachable.
Optional local tools should use a `benchmark-`, `measure-`, or `analyze-` name
instead, which the sweep does not require to be reachable.

## Core development loop

| Purpose | Entry point |
| --- | --- |
| Fetch the published seed | `fetch-stage0.sh` / `fetch-stage0.ps1` |
| Build a successor compiler | `build-stage0.sh` |
| Prove self-host convergence | `check-bootstrap-fixpoint.sh` |
| Run the complete local CI suite | `ci-verify.sh` |
| Check TypeLisp formatting and lint | `check-tl-format.sh`, `check-tl-lint.sh` |
| Check compiler-source coverage | `verify-selfhost-compile-manifest.sh`, `verify-inline-tests.sh` |
| Check public CLI behavior | `verify-public-tools.sh`, `check-stage1-wrapper.sh` |
| Check native behavior | `verify-integration.sh`, `verify-native-link-linux.sh`, `verify-native-link-windows.sh` |
| Check codegen shape and parity | `verify-asm-shape-gates.sh`, `check-codegen-target-parity.sh`, `check-backend-target-asm-parity.sh` |
| Check SPMD behavior | `verify-spmd-simd.sh`, `verify-spmd-runtime-dispatch.sh`, `verify-spmd-package-calls.sh`, `verify-spmd-broadcast.sh`, `verify-spmd-lane-identity.sh` |
| Check ISPC corpus contracts | `verify-ispc-perfbench-loads.sh`, `verify-ispc-perfbench-stores.sh`, `verify-ispc-perfbench-gathers.sh`, `verify-ispc-mandelbrot.sh`, `verify-ispc-point-transform.sh` |
| Check gate wiring | `check-gate-reachability.sh`, `check-cli-gate-coverage.sh` |
| Check docs and stdlib | `verify-doc-site.sh`, `verify-doc-tests.sh`, `verify-stdlib.sh`, `verify-stdlib-selfhost.sh`, `verify-stdlib-docs.sh` |
| Check performance policy | `check-instruction-counts.sh`, `check-opt2-cli-regression.sh`, `check-build-invariance.sh`, `bench.sh`, `run-optimization-benchmarks.sh` |

The complete and current invocation order remains in `ci-verify.sh`; this table
is a map, not a second manifest.

Some gate-owned helpers deliberately retain measurement-oriented names:

| Helper | Owning gate |
| --- | --- |
| `measure-instruction-counts.sh` | `check-instruction-counts.sh` and `ci-verify.sh` self-test |
| `measure-spmd-avx512-instructions.sh` | `ci-verify.sh` self-test and AVX-512 baseline checks |
| `measure-spmd-mode-instruction-counts.sh` | `ci-verify.sh` self-test and SPMD baseline checks |
| `measure-compile-batch-memory.ps1` | `verify-compile-profile.sh` |
| `measure-heavy-closure-profile.sh` | `verify-compile-profile.sh` and `measure-compile-rss.sh` |
| `measure-result-import-cost.sh` | `verify-result-import-harness.sh` fixture preparation |
| `analyze-stage0-size.sh` | `verify-stage0-smoke.sh` report |
| `benchmark-bootstrap.ps1` | `ci-verify.sh` command-construction self-test |

Keep these at the top level while their owning gate references them.

## Everything else

- `check-*` scripts normally enforce a policy or invariant.
- `verify-*` scripts normally exercise one behavior or corpus.
- `benchmark-*`, `measure-*`, and `analyze-*` scripts are optional local tools
  unless a workflow or gate entry point invokes them.
- `lib-*` files are sourced support code and are not standalone commands.
- `generate-*` scripts refresh reviewed test vectors or other checked inputs.
- Data files next to scripts are owned by the gate that reads them.
- `attic/` contains runnable historical experiment harnesses. They are not CI
  gates and must not be referenced by workflows or `ci-verify.sh`.

Active optional tools stay at the top level when they support recurring work:
the compiler and CLI benchmarks, selfhost size report, compile-memory and RSS
tools, instruction-count runners, ISPC/SPMD comparisons, LSP latency,
typecheck-prefix-cache measurements, and platform profilers. See
`src/TESTING.md`, `perf/README.md`, and `benchmarks/README.md` for their
workload-specific instructions.

## Moving a script

Before moving or deleting a script:

1. Search workflows, `ci-verify.sh`, other scripts, documentation, and test
   manifests for its path.
2. Keep live gate helpers at the top level even when their name begins with
   `measure-`.
3. Move only closed, one-off experiments to `attic/`; record the owning issue
   and update any historical reproduction command.
4. Run shell/PowerShell syntax checks for moved files and the focused gate for
   every changed live reference.
5. Run `check-implementation-languages.sh` and `git diff --check`.
