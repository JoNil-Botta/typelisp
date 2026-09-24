# Repository scripts

The `scripts/` directory contains CI entry points, focused verification gates,
bootstrap helpers, benchmarks, and optional local diagnostics. A filename
prefix alone does not determine whether a script is required by CI.

## What is a CI gate?

The workflow files are authoritative:

- `.github/workflows/ci.yml` runs `check-implementation-languages.sh` and
  `check-gitignore.sh`, then `ci-verify.sh`, and uploads the `ci-timing-<host>`
  artifact.
- `.github/workflows/bootstrap-stage0.yml` runs the stage0 fetch/build/smoke
  and bootstrap-fixpoint scripts.
- `.github/workflows/docs-pages.yml` runs after a successful
  `Bootstrap Stage0`, downloads that exact run's Linux artifact, checks out the
  same main commit, and runs `verify-doc-site.sh`. Manual dispatch names a
  successful bootstrap run ID, so it uses the same exact source/compiler pair.

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
rg -n 'scripts/[^ ]+\.(sh|ps1)' .github/workflows scripts/ci-gates.tsv scripts/ci-verify.sh
rg -n 'scripts/<script-name>' .
```

A required gate is a row of `ci-gates.tsv`; `ci-verify.sh` rejects a row whose
command names a missing script or `gate_*` function. Optional local tools
should use a `benchmark-`, `measure-`, or `analyze-` name.

## Core development loop

| Purpose | Entry point |
| --- | --- |
| Fetch the published seed | `fetch-stage0.sh` / `fetch-stage0.ps1` |
| Build a successor compiler | `build-stage0.sh` |
| Prove self-host and same-commit TLCI handoff convergence | `check-bootstrap-fixpoint.sh` |
| Run the complete local CI suite | `ci-verify.sh` |
| Check TypeLisp formatting and lint | `check-tl-format.sh`, `verify-format-large-crlf.sh`, `check-tl-lint.sh` |
| Check compiler-source coverage | `verify-selfhost-compile-manifest.sh`, `verify-inline-tests.sh` |
| Check cfg-only compiler instrumentation | `verify-regalloc-census.sh` |
| Check process-tree memory limiting | `verify-linux-memory-limit.sh` (covers `lib-linux-memory-limit.sh`), `verify-windows-memory-limit.ps1` (covers `run-bounded-process.ps1`) |
| Check structural migration invariants | `check-zero-cons.sh` (`--fixtures` in CI; `--full` for the production backlog) |
| Check public CLI behavior | `verify-public-tools.sh`, `check-stage1-wrapper.sh` |
| Check TLCI containers and package catalogs | `verify-tlci-corpus.sh`, `verify-tlci-native-route-stress.sh`, `verify-stdlib-tlci-identity-differential.sh` (all embedded identities; called by compile-profile), `verify-embedded-stdlib-tlci-resources.sh`, `verify-package-metadata-tlci.sh`, `verify-package-native-tlci.sh`, `verify-package-surface-tlci.sh` |
| Check native behavior | `verify-integration.sh`, `verify-native-link-linux.sh`, `verify-native-link-windows.sh`, `verify-fs-rooted-linux.sh`, `verify-process-runtime-linux.sh` |
| Check codegen shape and parity | `verify-cross-mode-differential.sh` (budgeted cross-gate semantic/ABI witnesses), `verify-asm-shape-gates.sh`, `verify-by-value-aggregate-abi.sh` (internal Tuple/Array physical ABI shapes), `check-codegen-target-parity.sh`, `check-backend-target-asm-parity.sh` |
| Check SPMD behavior | `verify-spmd-simd.sh`, `verify-spmd-runtime-dispatch.sh`, `verify-spmd-package-calls.sh`, `verify-spmd-broadcast.sh`, `verify-spmd-lane-identity.sh` |
| Check ISPC corpus contracts | `verify-ispc-perfbench-loads.sh`, `verify-ispc-perfbench-stores.sh`, `verify-ispc-perfbench-gathers.sh`, `verify-ispc-mandelbrot.sh`, `verify-ispc-point-transform.sh` |
| Check CLI gate coverage | `check-cli-gate-coverage.sh` |
| Check docs and stdlib | `verify-doc-site.sh`, `verify-doc-tests.sh`, `verify-stdlib.sh` (owns `check-stdlib-concat-lint.sh`), `verify-stdlib-selfhost.sh`, `verify-stdlib-docs.sh` |
| Check handwritten x86-64 template ownership | `check-x64-executable-template-registry.sh` pins every runtime/startup composition gate, all target-owned opaque byte helpers, structured contribution boundaries, and Windows data-only unwind relations. |
| Check performance policy | `check-instruction-counts.sh`, `check-compiler-scaling.sh` (compiler cost growth per input dimension against `perf/compiler-scaling-budgets.tsv`), `check-opt2-cli-regression.sh`, `check-build-invariance.sh`, `check-tlci-native-route-size.sh`, `bench.sh`, `run-optimization-benchmarks.sh` |

`ci-gates.tsv` is the gate table: one row per gate, in run order, with its
stable `id`, `hosts` (`all`, `linux` or `windows`), `label` (the display and
ci-timing name), `needs`, `compiler` and `command`. `ci-verify.sh` runs the
rows for its host in order and stops at the first failure. List either host
without a compiler or side effects, optionally narrowed to a
dependency-closed selection:

```sh
sh scripts/ci-verify.sh --list-gates linux
sh scripts/ci-verify.sh --list-gates windows
sh scripts/ci-verify.sh --list-gates linux --gates stage2-deterministic-assembly
```

The listing has `id`, `hosts`, `label` and `needs` columns, and checks the
whole table first: the header, field count, unique IDs, hosts, compiler kinds,
needs, and that every command's `scripts/` files and `gate_*` functions exist.

`--gates ID[,ID...]` runs a dependency-closed subset of the same table: the
named gates of this host plus every gate their `needs` reach, in table order.
It is the local reproduction command for one gate:

```sh
sh scripts/ci-verify.sh --gates stage2-deterministic-assembly
```

That example runs `bootstrap-fixpoint`, `stage2-selfhost-compile-manifest` and
then the named gate. Empty, unknown, duplicate and other-host IDs fail before
any gate starts. The seed is resolved only when the closure contains
`bootstrap-fixpoint`. Unless the closure is the whole host inventory, the run
ends with `CI verification partial: ...`: it records no verification-complete
timing row and never prints the success message.

`needs` is `-` or a comma-separated list of earlier gates whose outputs the
gate uses (a compiler, an assembly reference, a work directory). `id@linux` /
`id@windows` limits an edge to one host. A need must name an earlier gate that
runs wherever the consumer does, so table order is a topological order.

`compiler` is the `TYPELISP_BIN` the command sees: `stage2` for the converged
bootstrap compiler, `profile` for the compile-profile CLI that
`stage2-compile-profile-verifier` publishes, and `-` for a path under
`target/ci-verify-unproduced/` that cannot exist, so a gate that uses a
compiler without naming one fails instead of resolving the fetched seed. A
produced compiler whose gate did not run is such a path too, so its consumers
fail. `command` is shell text evaluated from the checkout root; it may use
`$ROOT`, `$STAGE1_BIN` and `$STAGE2_BIN`. A gate whose setup or handoff does
not fit one line is a `gate_*` function in `ci-verify.sh`. A new gate is one
row, plus a function only when it needs one.

Producers hand their outputs to later gates through plain path files under
`target/` (the bootstrap compilers, build-invariance's opt1 reference
assembly, the compile-profile CLI). Consumers check that what they reuse
exists and fail otherwise. Hosted CI runs the complete inventory in one job
per host.

`verify-cross-mode-differential.sh` reads
`tests/cross-mode/corpus.tsv` after its producer gates have run. It reuses the
integration, TLCI, SPMD, Windows COFF, and same-run bootstrap artifacts instead
of rebuilding their exhaustive corpora. Every manifest row records its axes,
observations, route metadata, producer gate (the gate ID it reuses, which this
gate's row in `ci-gates.tsv` needs on the row's hosts), and host/ISA
applicability; the gate
writes the evaluated state to
`target/cross-mode-differential/applicability.tsv`. Use `--case NAME` to
reproduce the first reported difference with retained producer artifacts, or
`--self-test` to run controlled observation and mode-selection perturbations
without a compiler.

The focused inline profile-summary probe uses `lib-linux-memory-limit.sh` to
enforce a 1 GiB resident-memory ceiling on Linux. A usable user-systemd manager
provides a hard cgroup-v2 `MemoryMax` with swap disabled. Other Linux runners
use a documented fallback that samples and terminates the isolated process
group when aggregate RSS crosses the same ceiling; neither path uses
`RLIMIT_AS` or treats virtual reservations as resident memory.

`run-memory-bounded.sh` gives gates one fail-closed interface to those Linux
backends and the Windows Job Object wrapper. The Windows helper tests retain a
one-second timeout classification case and separately check descendant cleanup
with delayed child creation and a ten-second bounded startup/cleanup deadline.
Its stable key/value record
distinguishes command failure, timeout, memory termination, wrapper/setup
failure, and success. `verify-embedded-stdlib-tlci-resources.sh` applies an
8192 MiB cap to the production image build, matched opt1/opt2 compiler builds,
cold starts, and representative native/source expansions on both CI hosts.
It writes informational measurements to
`target/embedded-stdlib-tlci-resources/<host>/report.tsv`, while required
identity, output, routing, and parity results live separately in
`assertions.tsv`. Linux adds Cachegrind instruction evidence when available;
no noisy time or instruction measurement is a regression ratchet.

On Linux, `TYPELISP_LINUX_MEMORY_LIMIT_METRICS_FILE` is an invocation-local
output destination for the limiting helper. The helper removes it from the
workload's environment; its own sampler receives the destination explicitly.
Nested callers can request their own metrics file or `--report` path. They do
not inherit or remove their parent's evidence. Systemd stderr uses a unique
temporary file per invocation, cleaned up after success or failure. The helper
self-test covers nested library calls and explicit inner reports on both Linux
backends without building another compiler.

On Windows, `verify-integration.sh` sends independent manifest links through
`windows-integration-linker.ps1`. The measured default is four concurrent
`lld-link` children; set `TYPELISP_WINDOWS_LINK_JOBS=1` for serial debugging or
to another value from 1 through 64 for a host-specific measurement.

Some gate-owned helpers deliberately retain measurement-oriented names:

| Helper | Owning gate |
| --- | --- |
| `measure-instruction-counts.sh` | `check-instruction-counts.sh` and `ci-verify.sh` self-test |
| `measure-spmd-mode-instruction-counts.sh` | `ci-verify.sh` self-test and SPMD baseline checks |
| `measure-compile-batch-memory.ps1` | `verify-compile-profile.sh` |
| `measure-heavy-closure-profile.sh` | `verify-compile-profile.sh` |
| `analyze-stage0-size.sh` | `verify-stage0-smoke.sh` report |
| `analyze-selfhost-build-asm-size.sh` | `ci-verify.sh` parser self-test; optional linked-size report |

Keep these at the top level while their owning gate references them.

## Everything else

- `check-*` scripts normally enforce a policy or invariant.
- `verify-*` scripts normally exercise one behavior or corpus.
- `benchmark-*`, `measure-*`, and `analyze-*` scripts are optional local tools
  unless a workflow or gate entry point invokes them.
- `lib-*` files are sourced support code and are not standalone commands.
- `generate-*` scripts refresh reviewed test vectors or other checked inputs.
- Data files next to scripts are owned by the gate that reads them.

Active optional tools stay at the top level when they support recurring work:
the compiler and CLI benchmarks, selfhost size report, instruction-count
runners, the SFrame v3 codec scale measurement, ISPC/SPMD comparisons, LSP
latency, and the `run-bounded-process.ps1` job-memory cap wrapper. See
`src/TESTING.md`, `perf/README.md`, and `benchmarks/README.md` for their
workload-specific instructions.

## Moving a script

Before moving or deleting a script:

1. Search workflows, `ci-verify.sh`, other scripts, documentation, and test
   manifests for its path.
2. Keep live gate helpers at the top level even when their name begins with
   `measure-`.
3. Delete closed, one-off experiments instead of archiving them; name the
   owning issue in the commit message so the script stays recoverable from
   history.
4. Run shell/PowerShell syntax checks for moved files and the focused gate for
   every changed live reference.
5. Run `check-implementation-languages.sh` and `git diff --check`.
