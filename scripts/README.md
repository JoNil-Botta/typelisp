# Repository scripts

The `scripts/` directory contains CI entry points, focused verification gates,
bootstrap helpers, benchmarks, and optional local diagnostics. A filename
prefix alone does not determine whether a script is required by CI.

`fetch-work-queue.sh [OWNER/REPO]` is the optional GitHub worker-queue fetch
wrapper. It requires `gh` and `jq`, retains complete raw open issue/PR state,
and fails rather than silently accepting a reached list limit. See the
[chooser caller contract](../tools/work-queue-chooser/README.md) for capture,
filtering and selection. `test-fetch-work-queue.sh` checks the boundary using a
local fake `gh`; it never authenticates or accesses the network.

## What is a CI gate?

The workflow files are authoritative:

- `.github/workflows/ci.yml` runs `check-implementation-languages.sh`, then
  `ci-verify.sh`, then the timing-budget check.
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
| Check codegen shape and parity | `verify-cross-mode-differential.sh` (budgeted cross-gate semantic/ABI witnesses), `verify-asm-shape-gates.sh`, `verify-by-value-aggregate-abi.sh` (internal Tuple/Array physical ABI shapes), `verify-backend-safety-manifest.sh` (source-derived IR/ABI/object audit map and drift mutations), `check-codegen-target-parity.sh`, `check-backend-target-asm-parity.sh` |
| Check SPMD behavior | `verify-spmd-simd.sh`, `verify-spmd-runtime-dispatch.sh`, `verify-spmd-package-calls.sh`, `verify-spmd-broadcast.sh`, `verify-spmd-lane-identity.sh` |
| Check ISPC corpus contracts | `verify-ispc-perfbench-loads.sh`, `verify-ispc-perfbench-stores.sh`, `verify-ispc-perfbench-gathers.sh`, `verify-ispc-mandelbrot.sh`, `verify-ispc-point-transform.sh` |
| Check gate wiring | `check-gate-reachability.sh`, `check-cli-gate-coverage.sh` |
| Check docs and stdlib | `verify-doc-site.sh`, `verify-docs-workflow-policy.sh`, `verify-doc-tests.sh`, `verify-stdlib.sh` (owns `check-stdlib-concat-lint.sh`), `verify-stdlib-selfhost.sh`, `verify-stdlib-docs.sh` |
| Check handwritten x86-64 template ownership | `check-x64-executable-template-registry.sh` pins every runtime/startup composition gate, all target-owned opaque byte helpers, structured contribution boundaries, and Windows data-only unwind relations. |
| Check performance policy | `check-instruction-counts.sh`, `check-compiler-scaling.sh` (compiler cost growth per input dimension against `perf/compiler-scaling-budgets.tsv`), `check-opt2-cli-regression.sh`, `check-build-invariance.sh`, `check-tlci-native-route-size.sh`, `analyze-ci-timing-trends.sh`, `bench.sh`, `run-optimization-benchmarks.sh` |

`ci-gates.tsv` owns the stable top-level gate IDs, exact timing/display labels,
host applicability and complete sequential order. `ci-verify.sh` binds those
IDs to the existing commands and compiler/provenance setup. This table is a
map, not another manifest. List either host without a compiler or side effects,
optionally narrowed to a dependency-closed selection:

```sh
sh scripts/ci-verify.sh --list-gates linux
sh scripts/ci-verify.sh --list-gates windows
sh scripts/ci-verify.sh --list-gates linux --gates stage2-deterministic-assembly
```

The TSV projection has `id`, `hosts`, `label` and `needs` columns. The original `all`
applicability remains visible in either host projection. LF and CRLF catalogs
produce the same LF output; the repository checkout pins this catalog to LF.
Listing validates the
entire catalog, including the other host's records, before emitting anything;
it does not initialize targets, timing, traces, capabilities or the seed.
It is an inventory report, not a successful verification.

`--gates ID[,ID...]` runs a dependency-closed subset of the same runner: the
named gates of this host plus every gate their `needs` reach, in ledger order,
each with the setup it owns (a producer's capture and provenance handoff, a
consumer's validation). It is the local reproduction command for one gate or
one shard:

```sh
sh scripts/ci-verify.sh --gates stage2-deterministic-assembly
```

That example runs `bootstrap-fixpoint`, `stage2-selfhost-compile-manifest` and
then the named gate. Empty, malformed, unknown, duplicate and other-host IDs
fail before any gate starts. The seed is resolved only when the closure contains
`bootstrap-fixpoint`. Setup is guarded by the ID of the gate that owns it, and
a guard naming no gate of the host poisons completion. A compiler or artifact
path whose producer did not run names a path that cannot exist, so its consumer
fails rather than falling back to another compiler. Unless the closure is the
whole host inventory, the run ends with `CI verification partial: ...`: it
records no verification-complete timing row and never prints the success
message. Hosted CI still runs the complete inventory in one job per host.

The full runner resolves each ID against the next required ledger row. Unknown,
duplicate, wrong-host and out-of-order gates fail; a command failure retains its
exit status and poisons completion. Missing or active gates prevent both the
verification-complete timing row and the final success message. Keep IDs stable
when changing wording; preserve labels unless their timing consumers are updated.
`needs` records what a gate consumes from earlier gates: `-`, a comma-separated
list of gate IDs, or `*` on the closing gate, which needs everything before it.
The final record must be that closing gate, and no other record may use `*`.
`id@linux` / `id@windows` limits an edge to one host, and a host projection
shows only the edges that apply there. A need must name an earlier gate that
runs wherever the consumer does, so ledger order is a topological order by
construction. The column is not an independent opinion:
`ci_gate_ledger_validate_needs` (run by the ledger self-test and by the artifact
inventory validation) requires a gate after `bootstrap-fixpoint` to need it
exactly when one of its bindings names a produced compiler (`$STAGE1_BIN`,
`$STAGE2_BIN` or `$COMPILE_PROFILE_BIN`); forbids needs and produced-compiler
arguments before it; and requires the remaining edges to match the consume
records of `ci-compiler-artifacts.tsv` exactly, in both directions and per host.
That first rule holds because a gate's environment does not depend on earlier
gates: `run_with_compiler` passes its compiler to that one gate as
`TYPELISP_BIN`, and `run_gate` passes the entry environment. A gate that uses a
compiler must name it. A dependency that is not an artifact handoff (a
directory one gate leaves for another, an exported variable) must first become
an inventory record. `--gates` executes the column in one checkout; running
gates in separate jobs and the mandatory shard aggregate remain #7766.

A new gate needs one ledger row and an executable binding in the matching host
position. Update the three declared counts intentionally; duplicate IDs/labels,
invalid hosts, fields, needs, counts and truncated records are rejected.
`test-ci-gate-ledger.sh` exercises these boundaries, selection closure and
diagnostics, the real listing CLI, and a real `--gates` run in a stub checkout
on both host branches.

Nested corpora, targets, optimization levels, compiler producers and artifact
handoffs remain owned by their existing gates/manifests and provenance helpers.
The ledger does not authorize concurrent execution; balanced shards, their
artifact transfer and mandatory shard aggregation remain in #7766.
Workflow-level setup/checks/uploads remain in the workflow.

Every full `ci-verify.sh` execution creates a fresh same-run artifact token and
initializes `target/ci-compiler-artifacts/trace.tsv`, including local runs.
Set `TYPELISP_CI_COMPILER_ARTIFACT_TRACE` to choose another destination;
relative paths resolve against the checkout root, and an empty value uses the
default. The trace is replaced at startup and checked for complete producer and
consumer coverage at the end. Child gates inherit both token and trace.
Standalone native-link verification can omit both variables; supplying only
one remains an error. `test-ci-artifact-run-setup.sh` exercises actual CI startup
through a probe child on both host branches before any compiler work.

`verify-cross-mode-differential.sh` reads
`tests/cross-mode/corpus.tsv` after its producer gates have run. It reuses the
integration, TLCI, SPMD, Windows COFF, and same-run bootstrap artifacts instead
of rebuilding their exhaustive corpora. Every manifest row records its axes,
observations, route metadata, producer, and host/ISA applicability; the gate
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

`benchmark-semantic-index.sh` is the opt-in compiler-scale consumer of that
interface. It builds a current-tree runner with an explicitly selected compiler
and reports owned semantic record count, process-tree peak memory, wall time,
exit status, and normalized termination reason for
`src/compiler_typecheck_core.tl`. Its `--self-test` mode is wired into CI on
both hosts, but the expensive corpus workload is deliberately not; see
`tools/semantic-index-bench/README.md` for the reproducible command and schema.

On Windows, `verify-integration.sh` sends independent manifest links through
`windows-integration-linker.ps1`. The measured default is four concurrent
`lld-link` children; set `TYPELISP_WINDOWS_LINK_JOBS=1` for serial debugging or
to another value from 1 through 64 for a host-specific measurement.

For process-level safe-thread stress, `measure-thread-integration-stress.sh`
builds the seven `thread_safe_*` manifest fixtures once and repeatedly runs the
native executables on Linux or Windows. It retains every exit code and stream;
use `TYPELISP_THREAD_STRESS_ITERATIONS=1000`,
`TYPELISP_THREAD_STRESS_JOBS=8`, and, on Linux,
`TYPELISP_THREAD_STRESS_CPU=0` to increase scheduling pressure.

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
| `analyze-selfhost-build-asm-size.sh` | `ci-verify.sh` parser self-test; optional linked-size report |
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
tools, instruction-count runners, the compiler-scale semantic-index benchmark,
the SFrame v3 codec scale measurement, ISPC/SPMD comparisons, LSP latency,
typecheck-prefix-cache measurements, the `run-bounded-process.ps1` job-memory
cap wrapper, and platform profilers. See
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
