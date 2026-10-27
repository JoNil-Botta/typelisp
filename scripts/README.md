# Repository scripts

The `scripts/` directory contains CI entry points, focused verification gates,
bootstrap helpers, benchmarks, and optional local diagnostics. A filename
prefix alone does not determine whether a script is required by CI.

## What is a CI gate?

The workflow files are authoritative:

- `.github/workflows/ci.yml` runs `check-implementation-languages.sh` and
  `check-gitignore.sh`, then `ci-verify.sh`, and uploads the `ci-timing-<host>`
  artifact. On Linux it then runs `self-compile.sh check`, which gates the PR's
  own `self_compile` cost against main (`perf/README.md`).
- `.github/workflows/self-compile-reference.yml` runs on every push to main:
  `ci-verify.sh --gates linux-self-compile-measurement` publishes the commit's
  `self_compile` reference, and `self-compile.sh ledger` accounts for the merge.
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

## Linux instruction-count packages

The shared `.github/actions/linux-instruction-count-tools` action installs
valgrind and libc6-dbg in required Linux CI and the self-compile reference
measurement. The ledger first runs `self-compile.sh ledger --prepare` to
validate its reference and PR records. Only a required fallback or reproduction
runs the shared action, before `self-compile.sh ledger` probes the installed
runner identity or measures anything. The prepared inputs stay in this job's
workspace, bound to its commit, run and attempt; they are never a package cache.
Record-only ledgers skip package resolution, restore, transfer and installation.
On Ubuntu noble, libc6-dbg is a hard dependency of valgrind;
`--no-install-recommends` excludes gdb, not libc6-dbg. Windows is unchanged.

`ci-linux-tools.sh` resolves exact versions against the runner's apt indexes.
Its cache key hashes the distro release, dpkg architecture, runner OS,
ImageOS, ImageVersion, both package versions and their SHA-256 hashes. There
are no partial restore keys. Only the two archives are cached: the package
plan, hashes and installed state are recreated on each runner. Restored files
must match the apt-index SHA-256 hashes before entering fresh private staging.
The pinned `apt-get --download-only` install authenticates the plan against
apt's trusted indexes before a separate `--no-download` install; neither
unauthenticated packages nor insecure repositories are permitted. Both
installed versions must equal the resolution, and are logged.

A missing, corrupt or mismatched archive uses the normal trusted apt download.
A failed acquisition refreshes authenticated indexes and resolves again in
fresh staging; failure of that attempt or installation fails the job. A new
version or runner image gets a new key. Cache restore/save errors cannot skip
installation. A corrupt immutable entry can be removed with GitHub's cache
administration, or invalidated by changing the action's key schema version;
until then each use falls back safely.

The existing push-to-main self-compile measurement job populates the
default-branch cache immediately after a successful package installation,
before its measurement begins. The ledger and new PRs can restore that
main-scoped entry; PR-scoped entries alone cannot serve another PR's first
run. Every main push refreshes an absent version/image key, and ordinary cache
eviction needs no special recovery. Initial cross-PR reach is verified after
this population path lands, before closing #9305.

Each invocation uploads `linux-instruction-tools-<job>` with package identities,
source URIs, trusted-index hashes, cache result and `timing.tsv`. Resolution,
index refresh when needed, cache verification, apt package acquisition and
installation have separate rows. Acquisition includes apt planning; apt's
`Fetched` line reports transfer time itself. Restore/save wall timers also
include intervening Actions step startup, so they conservatively measure cache
overhead. GitHub job timestamps supply total step time, queue time, execution
critical path and runner-minutes; these must be reported separately.

## AVX-512 test execution

CI downloads Intel SDE 10.13.1 from Intel's distribution page through
`fetch-sde.sh`. Its Linux and Windows archives have pinned SHA-256 digests;
cache hits are verified again and extracted afresh with all license notices.
The maintainer approved Intel's Simplified Software License for this CI use
in #8664. See [Intel's download and license page](https://www.intel.com/content/www/us/en/download/684897/intel-software-development-emulator.html).

`lib-simd-execution.sh` keeps the native CPUID/OS probe unchanged. The codegen,
SPMD comparison, package-call and cross-mode differential harnesses select
native execution when available, or SDE's Sapphire Rapids (`-spr`) model for AVX-512. Compiler
builds and performance measurements stay native. Existing cases, optimization
levels, exit statuses, stderr assertions and negative paths remain required.
Each AVX-512 execution has a route receipt; each execution harness reports
native, emulated and skipped totals. Cross-mode checks validate the producing
SPMD receipt. With `CI=true`, missing both routes is an error. Local runs may
still report unavailable execution explicitly. CLI transcript `if-isa` checks
and runtime-dispatch selection continue to test the actual native host,
including the CLI's unsupported-host diagnostics.

On native AVX-512 CI hosts, the workflow additionally executes the SPMD,
lane/broadcast and package corpus under SDE and checks the cross-mode oracle
against those observations. Hosts without native support already use SDE in
the canonical gates. Thus both operating systems exercise the fallback on
every required run, while native dispatch and execution coverage is retained.

To validate the emulator route even on an AVX-512 host, run the existing corpus:

```sh
export TYPELISP_SDE_BIN=$(sh scripts/fetch-sde.sh)
TYPELISP_AVX512_EXECUTION=sde scripts/verify-spmd-simd.sh
```

`TYPELISP_AVX512_EXECUTION=sde` requires SDE even when native execution is
available; its consumer is this forced-emulation validation. Omit it for the
normal native-first route. Fetching SDE downloads software under Intel's
license, so local users should review that license before running the fetcher.

## Core development loop

`analyze-stage0-size.sh BINARY` decodes v1 and fixed-Huffman v2 LZSS frames
directly from the linked binary. It requires exact equality with the source
declarations: the embedded-stdlib manifests plus all top-level
`include-str-lzss` declarations in the production `src/*.tl` modules. The
inventory is conservative: a declaration in an unlinked module fails the
count rather than being silently excluded. A token walk recognizes whitespace,
comments, strings and character delimiters; escaped or multiline input paths
fail explicitly. `--compiler-sources "file ..."`
can specify a known source set for a different compiler, together with
`--embedded-stdlib "file ..."`. The report lists declaration categories and
input paths; its aggregate LZSS byte totals include every counted stream,
including the executable-template catalog. TLCH/TLCI accounting and the
existing stdlib file buckets remain separate.

Use the source checkout that built the binary. An older binary with a
different declaration set (such as the 8d29 seed, whose catalog was not
compressed) fails with an explicit expected/found count diagnostic against
current sources. V1 framing remains supported when its declaration inventory
matches. `verify-stage0-lzss-scanner.sh` covers both formats, malformed and
truncated frames, and declaration/count/path failures. The required size gate
runs these fixtures and the analyzer on the already bootstrapped compiler on
Linux and Windows, without building another compiler. Payload/publication
changes also trigger the Bootstrap Stage0 build, smoke and fixpoint jobs on
the exact PR head; only a push to main can publish releases.

| Purpose | Entry point |
| --- | --- |
| Fetch the published seed | `fetch-stage0.sh` / `fetch-stage0.ps1` |
| Build a successor compiler | `build-stage0.sh` |
| Prove self-host and same-commit TLCI handoff convergence | `check-bootstrap-fixpoint.sh` |
| Run the complete local CI suite | `ci-verify.sh` |
| Check TypeLisp formatting and lint | `check-tl-format.sh`, `verify-format-large-crlf.sh`, `check-tl-lint.sh` |
| Check compiler-source coverage | `verify-selfhost-compile-manifest.sh`, `verify-inline-tests.sh` |
| Check ownership semantics | `verify-safety-corpus.sh` (located source diagnostics and runtime twins), `verify-ownership-model.sh` (independent finite model and typed-core comparisons at opt0/1/2), `verify-arena-sanitizer-selfhost.sh` (the compiler's check, opt1 self-compile and a batch of inline-test sessions under an arena-sanitizer build, Linux) |
| Check the shared IR dependency boundary | `verify-core-ir-dependencies.sh` (canonical resolved closure, explicit module policy, source and fact-stream fixtures; bounded on both hosts) |
| Check process-tree memory limiting | `verify-linux-memory-limit.sh` (covers `lib-linux-memory-limit.sh`), `verify-windows-memory-limit.ps1` (covers `run-bounded-process.ps1`) |
| Check structural migration invariants | `check-zero-cons.sh` (`--fixtures` in CI; `--full` for the production backlog), `check-compiler-state-schema.sh` (packed compiler state stays behind its schema's typed accessors), `check-shared-view-count.sh` (the `*-shared-view` call count may only fall, against `shared-view-baseline.tsv`; it also reports, without gating, the count weighted by the call sites of the function or macro that holds each view, with thin wrappers transparent so a copy weighs the same inside an accessor or at its call sites) |
| Check public CLI behavior | `verify-public-tools.sh`, `verify-selfhost-cli-build-run.sh`, `check-stage1-wrapper.sh` (CLI transcripts in `tests/cli/`, run by `verify-codegen-cases.sh`) |
| Check application workflows | `verify-app-corpus.sh` (the projects and scenario manifest in `tests/apps/`; see `tests/apps/README.md`) |
| Check TLCI containers and package catalogs | `verify-tlci-corpus.sh`, `verify-tlci-native-route-stress.sh`, `verify-stdlib-tlci-identity-differential.sh` (all embedded identities; called by compile-profile), `verify-embedded-stdlib-tlci-resources.sh`, `verify-package-metadata-tlci.sh`, `verify-package-native-tlci.sh`, `verify-package-surface-tlci.sh` |
| Check native behavior | `verify-integration.sh`, `verify-native-link-linux.sh` (`tests/codegen/native-link.cases`), `verify-native-link-windows.sh`, `verify-win64-seh-unwind.sh` (Windows unwind rows and a virtual unwind through framed prologues, `tests/fixtures/win64-seh/`), `verify-fs-rooted-linux.sh`, `verify-process-runtime-linux.sh` |
| Check codegen shape and parity | `verify-cross-mode-differential.sh` (budgeted cross-gate semantic/ABI witnesses), `verify-codegen-cases.sh` (table-driven compile/run/asm-shape cases and CLI transcripts in `tests/codegen/` and `tests/cli/`), `check-codegen-target-parity.sh`, `check-backend-target-asm-parity.sh` |
| Check SPMD behavior | `verify-spmd-simd.sh`, `verify-spmd-runtime-dispatch.sh`, `verify-spmd-package-calls.sh`, `verify-codegen-cases.sh tests/spmd/gang-width.cases` |
| Check ISPC corpus contracts | `verify-codegen-cases.sh tests/codegen/ispc.cases` (one gate per case) |
| Check docs and stdlib | `verify-doc-site.sh`, `verify-doc-tests.sh`, `verify-stdlib.sh` (owns `check-stdlib-concat-lint.sh`), `verify-stdlib-selfhost.sh`, `verify-stdlib-docs.sh` |
| Check handwritten x86-64 template ownership | `check-x64-executable-template-registry.sh` pins every runtime/startup composition gate, all target-owned opaque byte helpers, structured contribution boundaries, and Windows data-only unwind relations. |
| Check performance policy | `check-instruction-counts.sh` (exact benchmark rows), `self-compile.sh` (`self_compile` measurement, the main-relative PR check, the reference record and the ledger; logic in `lib-self-compile.sh`, fixtures in `self-compile-self-test.sh`), `check-compiler-scaling.sh` (compiler cost growth per input dimension against `perf/compiler-scaling-budgets.tsv`), `check-opt2-cli-regression.sh`, `check-build-invariance.sh`, `check-tlci-native-route-size.sh`, `check-stage0-size.sh` (the stage0 size ratchet against `stage0-size-policy.tsv`), `bench.sh`, `run-optimization-benchmarks.sh` |

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
| `build-stamp` | `target/build-stage0/git-hash.txt` and `tree-hash.txt`, which compile with `compiler-build-identity` includes and root package builds rewrite (the CLI smoke poisons them on purpose) |
| `embedded-image` | `target/embedded-stdlib-tlci/`, which compiles with `embedded-stdlib-tlci` include and the image and resource gates rebuild in place |
| `embedded-payload` | `target/embedded-stdlib-payload-verify/`, which the payload gate and the stdlib gate (through `verify-embedded-stdlib-payload.sh`) both reset |
| `instruction-count` | `target/instruction-count-check/`, where the benchmark instruction-count gate (which resets it) and the `self_compile` gate both measure at their historical paths, because measured paths reach the counts |
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
user-systemd manager that delegates cgroup v2 memory, with systemd 254 or newer
(`DelegateSubgroup=`, `--expand-environment=`). It provides a hard `memory.max`
over the complete process tree with swap disabled. A host without one fails
closed; there is no unbounded or RSS-polling fallback, and nothing uses
`RLIMIT_AS` or treats virtual reservations as resident memory.

Nested calls stay inside every enclosing cap. A top-level call is a transient
service with memory delegated to it. Its command runs in the leaf
`workload/tlmem-run`, and the `workload` node carries the requested
`memory.max`, no swap and `memory.oom.group=1`. A library or wrapper call made
from a `tlmem-run` leaf starts no unit of its own, because the user manager
would place that unit beside the outer one, outside its cap. It creates a node
`tlmem-<pid>-<n>` beside the caller's leaf with its own limits, runs its
command there as an ordinary child, and kills and removes the node afterwards.
The kernel charges every nested call, concurrent ones included, to every
enclosing workload node. Inner limits still apply, and the outer cap bounds
their aggregate. Each node's `memory.peak` is a measured peak of its whole
subtree. An outer OOM, timeout or unit stop also ends the nested work. Units
use `OOMPolicy=continue`, since systemd would count an inner node's OOM kill
against the outer unit; `memory.oom.group` keeps an OOM at a workload node's
own limit fatal to that whole node. Nesting is decided from the caller's own
`/proc/self/cgroup`. The inherited `TYPELISP_LINUX_MEMORY_LIMIT_NODE` only
detects a lost hierarchy: a caller that has it but has left its `tlmem-run`
leaf fails closed, as does a workload node that cannot give a nested node
memory limits. The Windows Job Object backend nests natively: a job created
inside a bounded job stays under that job's limits.

`run-memory-bounded.sh` gives gates one fail-closed interface to that Linux
backend and the Windows Job Object wrapper. On Linux the sampled route's
delegated unit, or nested node, contains a sampler leaf and the workload node.
The workload keeps the exact requested `memory.max`, with swap disabled; its
entire subtree is killed on OOM. The sampler has a separate 64 MiB limit, and
the containing unit or node is capped at the requested bytes plus that monitor
headroom. This headroom does not raise the workload's ceiling. Missing
delegation fails before user code starts. The sampler measures the process
group's RSS from outside its OOM domain and watches the `oom_kill` count of the
workload's own leaf, which a nested call's OOM at its own limit leaves alone.
On OOM it terminates the complete workload node with `cgroup.kill` and reports
its `memory.peak` before exiting 137. Otherwise its peak is the larger of the
RSS samples and that `memory.peak`, which also covers nested calls. The stop-post
hook and systemd summary remain additional peak evidence. Direct
`lib-linux-memory-limit.sh` callers start in a `launch` leaf that builds the
same workload node, and an `ExecStopPost` hook records their peak. The Windows helper tests retain a
one-second timeout classification case and separately check descendant cleanup
with delayed child creation and a ten-second bounded startup/cleanup deadline.
Its stable key/value record
distinguishes command failure, timeout, memory termination, wrapper/setup
failure, and success. `verify-embedded-stdlib-tlci-resources.sh` runs its
builds under that interface; `src/TESTING.md` (Embedded stdlib and TLCI gates)
describes its caps and reports.

Linux success also requires an invocation-owned terminal status: the unit's
private waiter publishes it only after its command's wait completes. A zero
`systemd-run --wait` status or a positive memory peak alone proves no workload
completion. Missing, malformed or foreign terminal evidence reports
`wrapper-failure` regardless of peak measurement, including direct library calls
without metrics (`LINUX_MEMORY_LIMIT_REASON`). A zero launcher status becomes
exit 2; an actual workload exit 2 remains `command-failure`. Known nonzero launcher statuses,
OOM evidence (137) and timeouts (124) keep their established precedence. Nested
calls use ordinary child waits inside their enclosing cap. Terminal records are
fresh per invocation, passed to the waiter through arguments rather than the
workload's environment, and removed with that invocation's stderr/peak scratch.
Direct calls without metrics now also retain stop-post OOM evidence while
streaming stderr directly. A known OOM returns 137;
systemd's generic failure status alone does not identify an OOM.

Integration, inline-test and selfhost-manifest pools validate the complete
bounded report against the waited status, host and admitted cap before using
outputs. Cancellation and invalid completion stop further pool admission and
fail the gate. Integration may replay ordinary failures and known panic/crash
exits (including `os-exit 134` and native Windows exceptions) for per-entry
diagnostics. Replay is labelled diagnostic-only: every failed batch remains a
gate failure even if all standalone entries succeed. Standalone compiles retain
the chunk memory cap, swap policy and timeout, and their completion is checked
before diagnostics are used. Replay assembly cannot supply passing native
results. Refusal reasons reach the gate console even when
compile streams are redirected. Interrupted chunks cannot supply passing
evidence through replay.

Linux pool self-tests exhaust both report encodings and all completion faults.
Windows runs representative native reports through each real worker, reader and
diagnostic path, retaining cancellation, invalid/missing completion, ordinary
failure, panic, native exception and success cases. Native Ctrl-C and nonzero
exits truncated to shell zero are included. Both hosts keep admission-stop,
output-rejection, bounded-replay and console-reason assertions. Report parsing
and fixture verdicts use the same host-independent shell/AWK code; the full
Linux matrix includes Windows CRLF and native status mappings. Hosted Windows
workloads additionally exercise actual MSYS launches and Job Object reports.
Native exception replay remains conditional on the observed shell mapping.

The existing pool self-tests print same-run cost attribution for the new
completion matrices beside the unchanged fixture portion. With CI timing
enabled these are sub-phase rows, preserving the canonical gate inventory;
they are not a paired causal base/head measurement.

`verify-selfhost-cli-build-run.sh` caps its complete public build/run corpus,
including the root opt0 build, at 8192 MiB and writes
`target/selfhost-build-run.memory`. The root release build in
`check-opt2-cli-regression.sh` has the same cap and writes
`target/opt2-cli-regression/build.memory`. Either gate fails on a capped
termination. CI retains these reports on both hosts in its root-build-memory
artifact, including reports from failed builds.

On Linux, `TYPELISP_LINUX_MEMORY_LIMIT_METRICS_FILE` is an invocation-local
output destination for the limiting helper. The helper removes it from the
workload's environment; its own sampler receives the destination explicitly.
Nested callers can request their own metrics file or `--report` path. They do
not inherit or remove their parent's evidence. Systemd stderr uses a private
temporary directory beside the metrics destination, cleaned up after success or
failure. This preserves its filesystem: moving a large capture to tmpfs would
charge it against the workload's memory cap. Without metrics only the tiny
terminal/stop-post records use `TMPDIR`. The helper
self-test covers nested library calls, explicit inner reports and the hierarchy
cases without building another compiler: overlapping, concurrent and inner-OOM
allocations, outer timeout and cancellation, and fail-closed hierarchies. Run
from inside another bounded workload, every call it makes nests, and it names
the top-level-only cases it could not run; hosted CI runs it at top level.

On Windows, `verify-integration.sh` sends independent manifest links through
`windows-integration-linker.ps1`. The measured default is four concurrent
`lld-link` children; set `TYPELISP_WINDOWS_LINK_JOBS=1` for serial debugging or
to another value from 1 through 64 for a host-specific measurement.

Some gate-owned helpers deliberately retain measurement-oriented names:

| Helper | Owning gate |
| --- | --- |
| `measure-instruction-counts.sh` | `check-instruction-counts.sh`, `self-compile.sh` (gate `linux-self-compile-measurement`) and gate `c-measured-region-instruction-harness-self-tests` |
| `measure-spmd-mode-instruction-counts.sh` | gate `spmd-mode-instruction-count-harness-self-tests` and SPMD baseline checks |
| `measure-compile-batch-memory.ps1` | `verify-compile-profile.sh` |
| `measure-heavy-closure-profile.sh` | `verify-compile-profile.sh` |
| `analyze-stage0-size.sh` | `verify-stage0-smoke.sh` report and required PR `stage0-size-ratchet` gate on both hosts |
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
  `lib-c-provenance.sh` owns C benchmark producer records, validation and
  diagnostics. It is loaded only for benchmarks or their self-tests, keeping
  the two-file `self_compile` procedure usable over older checkouts.
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
