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
branch compiler and runs every row of `ci-gates.tsv`: the source hygiene,
deterministic codegen, compiler/profile, public-tool, integration, stdlib,
documentation, SPMD, benchmark, and instruction-count gates. A helper such as
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
| Check process-tree memory limiting | `verify-linux-memory-limit.sh` (covers `lib-linux-memory-limit.sh`), `verify-windows-memory-limit.ps1` (covers `run-bounded-process.ps1`) |
| Check structural migration invariants | `check-zero-cons.sh` (`--fixtures` in CI; `--full` for the production backlog) |
| Check public CLI behavior | `verify-public-tools.sh`, `verify-selfhost-cli-build-run.sh`, `check-stage1-wrapper.sh` (CLI transcripts in `tests/cli/`, run by `verify-codegen-cases.sh`) |
| Check TLCI containers and package catalogs | `verify-tlci-corpus.sh`, `verify-tlci-native-route-stress.sh`, `verify-stdlib-tlci-identity-differential.sh` (all embedded identities; called by compile-profile), `verify-embedded-stdlib-tlci-resources.sh`, `verify-package-metadata-tlci.sh`, `verify-package-native-tlci.sh`, `verify-package-surface-tlci.sh` |
| Check native behavior | `verify-integration.sh`, `verify-native-link-linux.sh` (`tests/codegen/native-link.cases`), `verify-native-link-windows.sh`, `verify-win64-seh-unwind.sh` (Windows unwind rows and a virtual unwind through framed prologues, `tests/fixtures/win64-seh/`), `verify-fs-rooted-linux.sh`, `verify-process-runtime-linux.sh` |
| Check codegen shape and parity | `verify-cross-mode-differential.sh` (budgeted cross-gate semantic/ABI witnesses), `verify-codegen-cases.sh` (table-driven compile/run/asm-shape cases and CLI transcripts in `tests/codegen/` and `tests/cli/`), `check-codegen-target-parity.sh`, `check-backend-target-asm-parity.sh` |
| Check SPMD behavior | `verify-spmd-simd.sh`, `verify-spmd-runtime-dispatch.sh`, `verify-spmd-package-calls.sh`, `verify-codegen-cases.sh tests/spmd/gang-width.cases` |
| Check ISPC corpus contracts | `verify-codegen-cases.sh tests/codegen/ispc.cases` (one gate per case) |
| Check docs and stdlib | `verify-doc-site.sh`, `verify-doc-tests.sh`, `verify-stdlib.sh` (owns `check-stdlib-concat-lint.sh`), `verify-stdlib-selfhost.sh`, `verify-stdlib-docs.sh` |
| Check handwritten x86-64 template ownership | `check-x64-executable-template-registry.sh` pins every runtime/startup composition gate, all target-owned opaque byte helpers, structured contribution boundaries, and Windows data-only unwind relations. |
| Check performance policy | `check-instruction-counts.sh`, `check-compiler-scaling.sh` (compiler cost growth per input dimension against `perf/compiler-scaling-budgets.tsv`), `check-opt2-cli-regression.sh`, `check-build-invariance.sh`, `check-tlci-native-route-size.sh`, `check-stage0-size.sh` (the stage0 size ratchet against `stage0-size-policy.tsv`), `bench.sh`, `run-optimization-benchmarks.sh` |

`ci-gates.tsv` is the gate table: one row per gate, in run order, with its
stable `id`, `hosts` (`all`, `linux` or `windows`), `label` (the display and
ci-timing name), `needs`, `compiler`, `memory`, `locks` and `command`.
`ci-verify.sh` runs the rows for its host in table order (under `--jobs`, the
order in which ready gates start) and starts no gate after the first failure.
List either host without a compiler or side effects, optionally narrowed to a
dependency-closed selection:

```sh
sh scripts/ci-verify.sh --list-gates linux
sh scripts/ci-verify.sh --list-gates windows
sh scripts/ci-verify.sh --list-gates linux --gates stage2-deterministic-assembly
```

The listing has `id`, `hosts`, `label`, `needs`, `memory` and `locks` columns,
and checks the whole table first: the header, field count, unique IDs, hosts,
compiler kinds, needs, memory, locks, and that every command's `scripts/` files
and `gate_*` functions exist.

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

`ci-host-tools.tsv` lists the host tools gates run beyond the native assembler
and linker: `tool`, `hosts`, the `gates` that run it there, a `check` (shell
text that succeeds when the tool is usable) and an `install` hint. Before the
first gate starts, and before the seed is fetched, `ci-verify.sh` runs the
checks of every selected gate and fails with each missing tool, its gates and
its hint, so a host without GNU `time` fails at once instead of after the
bootstrap and every gate before the two RSS guards. A missing tool never skips
a gate. A gate that starts running a new host tool adds its ID to that tool's
row. The listing validates this table too: its header, five fields, hosts, and
that each gate exists and runs on every host of its row.

Producers hand their outputs to later gates through plain path files under
`target/` (the bootstrap compilers, build-invariance's opt1 reference
assembly, the compile-profile CLI). A gate receives an output only from a
producer among its own `needs`; any other names a path that cannot exist, so a
gate that uses an output without needing its producer fails in every run
order. A `stage2` gate must need `bootstrap-fixpoint` and a `profile` gate
`stage2-compile-profile-verifier`. Consumers check that what they reuse exists
and fail otherwise.

`--jobs N --memory-mib MIB` runs up to N gates at once, each in its own
subshell, through the bounded pool of `lib-bounded-pool.sh`. A gate starts
once every gate it needs passed, while no running gate holds one of its
`locks`, and while the `memory` of the running gates plus its own fits MIB;
among the gates that may start, the earliest in the table starts first. Each
gate's output is kept in `target/ci-verify-pool/logs/` and printed whole when
it finishes; timing rows are merged in table order. After the first failure
the running gates finish and no further gate starts, and the run lists every
failed, unfinished and not-started gate. `--jobs 1` (the default) runs and
streams the table in order. Hosted CI runs the complete inventory in one job
per host with `--jobs 4 --memory-mib 14336`.

`memory` is the MiB a gate reserves while it runs: its measured process-tree
peak on Linux with about a quarter of headroom, rounded up to 256 MiB. The pool
admits by these reservations but does not enforce them; pools inside a gate
still run every chunk under its own enforced cap, and the reservation covers
those caps' measured use, not their sum. The peak is the largest sum of
resident memory over every process whose working directory or executable lies
in the checkout, sampled while the gate runs alone under `--jobs 1`; that
includes the transient services of its bounded jobs. A gate whose peak grows
past its reservation needs a new measured value in the same change.

`locks` is `-` or a comma-separated list of shared checkout paths the gate
writes, or reads while another gate may write them. Gates that share a lock
never run at once:

| Lock | Shared path |
| --- | --- |
| `build-stamp` | `target/build-stage0/git-hash.txt`, which compiles with `compiler-build-identity` include and root package builds rewrite (the CLI smoke poisons it on purpose) |
| `embedded-image` | `target/embedded-stdlib-tlci/`, which compiles with `embedded-stdlib-tlci` include and the image and resource gates rebuild in place |
| `embedded-payload` | `target/embedded-stdlib-payload-verify/`, which the payload gate and the stdlib gate (through `verify-embedded-stdlib-payload.sh`) both reset |
| `root-release` | `target/release/`, the root package build's output |
| `spmd-package` | `tests/spmd/package_callable/target/` and `tests/spmd/package_consumer/target/` |

A gate whose work files are private to it needs no lock. When one script
serves several gates, each mode keeps its own work directory where it can:
`verify-codegen-cases.sh --only`, `run-optimization-benchmarks.sh
--tl-opt-level`, and the `verify-integration.sh`, `check-tl-format.sh` and
`verify-cross-mode-differential.sh` self-tests. That matters beyond collisions:
the cross-mode differential reuses artifacts the integration corpus leaves in
`target/integration-verify/<host>/`, so no other gate may reset that
directory. A generated input that several gates write whole through a
temporary file and `mv` is safe to share.

`verify-cross-mode-differential.sh` and its manifest are described under
[Cross-mode differential corpus](../docs/testing-and-bootstrap.md#cross-mode-differential-corpus).

Linux memory limits (`lib-linux-memory-limit.sh`, used directly by the focused
inline profile-summary and large CRLF formatter probes) need a usable
user-systemd manager: it provides a hard cgroup-v2 `MemoryMax` over the complete
process tree with swap disabled. A host without one fails closed; there is no
unbounded or RSS-polling fallback, and nothing uses `RLIMIT_AS` or treats
virtual reservations as resident memory.

`run-memory-bounded.sh` gives gates one fail-closed interface to that Linux
backend and the Windows Job Object wrapper. On Linux it samples the process
group's RSS inside the cgroup to report a trustworthy peak. Its unit uses
`OOMPolicy=continue` and the workload raises its `oom_score_adj` to 1000, so a
cgroup OOM kill takes a workload task and never the sampler. The sampler then
sees the cgroup's `oom_kill` count rise, ends the rest of the workload, records
the cgroup's exact `memory.peak` and reports exit 137. Direct
`lib-linux-memory-limit.sh` callers keep `OOMPolicy=kill`, and an
`ExecStopPost` hook records their peak. The Windows helper tests retain a
one-second timeout classification case and separately check descendant cleanup
with delayed child creation and a ten-second bounded startup/cleanup deadline.
Its stable key/value record
distinguishes command failure, timeout, memory termination, wrapper/setup
failure, and success. `verify-embedded-stdlib-tlci-resources.sh` runs its
builds under that interface; `src/TESTING.md` (Embedded stdlib and TLCI gates)
describes its caps and reports.

On Linux, `TYPELISP_LINUX_MEMORY_LIMIT_METRICS_FILE` is an invocation-local
output destination for the limiting helper. The helper removes it from the
workload's environment; its own sampler receives the destination explicitly.
Nested callers can request their own metrics file or `--report` path. They do
not inherit or remove their parent's evidence. Systemd stderr uses a unique
temporary file per invocation, cleaned up after success or failure. The helper
self-test covers nested library calls and explicit inner reports without
building another compiler.

On Windows, `verify-integration.sh` sends independent manifest links through
`windows-integration-linker.ps1`. The measured default is four concurrent
`lld-link` children; set `TYPELISP_WINDOWS_LINK_JOBS=1` for serial debugging or
to another value from 1 through 64 for a host-specific measurement.

Some gate-owned helpers deliberately retain measurement-oriented names:

| Helper | Owning gate |
| --- | --- |
| `measure-instruction-counts.sh` | `check-instruction-counts.sh` and gate `c-measured-region-instruction-harness-self-tests` |
| `measure-spmd-mode-instruction-counts.sh` | gate `spmd-mode-instruction-count-harness-self-tests` and SPMD baseline checks |
| `measure-compile-batch-memory.ps1` | `verify-compile-profile.sh` |
| `measure-heavy-closure-profile.sh` | `verify-compile-profile.sh` |
| `analyze-stage0-size.sh` | `verify-stage0-smoke.sh` report |
| `analyze-selfhost-build-asm-size.sh` | gate `selfhost-linked-size-attribution-parser-self-tests`; optional linked-size report |

Keep these at the top level while their owning gate references them.

## Everything else

- `check-*` scripts normally enforce a policy or invariant.
- `verify-*` scripts normally exercise one behavior or corpus.
- `benchmark-*`, `measure-*`, and `analyze-*` scripts are optional local tools
  unless a workflow or gate entry point invokes them.
- `lib-*` files are sourced support code and are not standalone commands.
  `lib-gate.sh` holds the `fail` helper (prefixed by `GATE_FAIL_PREFIX`) and
  the `TYPELISP_BIN`/stage0 compiler resolution most gate scripts share;
  `lib-benchmark.sh` holds the benchmark harnesses' metadata, build and
  Cachegrind helpers and the CI benchmark case manifest reader.
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
