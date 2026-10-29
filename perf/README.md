# Performance baselines

The checked tables in this directory, and the gates and scripts that own them:

| File | Owner |
| --- | --- |
| `insn-exec-baseline.tsv` | `linux-instruction-count-baseline` (`scripts/check-instruction-counts.sh`) |
| `insn-exec-heavy-baseline.tsv` | `linux-heavy-instruction-count-baseline` (the same script) |
| `benchmark-ci-cases.tsv` | suite membership for the benchmark, optimizer-corpus and instruction-count gates |
| `compiler-scaling-budgets.tsv` | `linux-compiler-scaling-budgets` (`scripts/check-compiler-scaling.sh`) |
| `spmd-mode-insn-baseline.tsv`, `spmd-mode-support.tsv` | opt-in `scripts/measure-spmd-mode-instruction-counts.sh` |
| `self-compile-declarations/pr-<N>.tsv` | PR N's acknowledged `self_compile` cost (`scripts/self-compile.sh check`) |
| `self-compile-ledger-resolutions.tsv`, `self-compile-ledger-checkpoint.tsv` | reviewed `self_compile` ledger resolutions and checkpoint (`scripts/self-compile.sh ledger`), when present |

Measured deltas belong in the PR that changes a row, not in this file.

## Instruction-count baselines

`perf/insn-exec-baseline.tsv` and `perf/insn-exec-heavy-baseline.tsv` are the
committed cachegrind `Ir` baselines for the required Linux per-PR performance
gates. The first covers the `instruction-main` cases of
`perf/benchmark-ci-cases.tsv`: the twelve compiler-derived kernels,
`pure_call_join` and `loop_call_literal`, and the eleven original kernels
(`arith_loop`, `array_sum`, `borrowed_disjoint_store`, the four `hashmap_*`
cases, `opt_bytecode_vm`, `opt_crc32`, `opt_quicksort` and `spmd_reduce`).
That is every `benchmark/typelisp` row the file carries, so none goes stale
unchecked. The second covers the `instruction-heavy` cases, benchmark rows
only. Explicit `--benchmarks` subsets
are scoped against the selected cases even when a baseline carries additional
rows. Neither file carries `self_compile`, whose absolute count is
environment-specific; it is gated main-relative (see [`self_compile`](#self_compile)).

Benchmark metrics are exact: `current != baseline` fails in either direction,
and an intentional change is accepted by committing the refreshed rows in the
same PR. Both improvements and regressions therefore block the PR that
introduces them.

### Refreshing

Benchmark rows reproduce exactly across the supported Linux, WSL and
GitHub-hosted environments, so a local Linux or WSL run refreshes them:

```sh
scripts/check-instruction-counts.sh --update-baseline
```

A refresh rewrites the measured rows and preserves every other row
(`--benchmarks-only` is still accepted). A baseline that carries a
`self_compile` row fails the gate: that row was a pin of the retired
checked-row contract.

Refresh the heavy baseline with the gate's own selection:

```sh
scripts/check-instruction-counts.sh \
  --update-baseline \
  --baseline perf/insn-exec-heavy-baseline.tsv \
  --benchmarks spmd_map,spmd_mask,spmd_zip,spmd_short_tail,string_scan \
  --benchmarks-only \
  --runs 1 \
  --output target/instruction-count-heavy
```

### `self_compile`

`self_compile/compile_cli_opt1` is the Cachegrind `Ir` of the bootstrap
fixpoint compiler compiling `src/main.tl` at opt1. Unlike the benchmark rows it
deliberately measures the full compiler process, and its absolute count depends
on the environment. On one host and checkout path it is bit-identical from run
to run, but the path alone changes it: a checkout path 52 characters longer
added about 10,000 Ir to a small compile, and a longer `-o` path a few hundred.
The compiler path (argv[0]) made no difference. So `self_compile` is not a row
of any committed baseline. Since #9307 (council decision D-C15-9307) it is
gated main-relative.

**Measurement.** The required Linux gate `linux-self-compile-measurement` runs
`scripts/self-compile.sh measure`. It invokes the harness with its historical
command line, so its values compare directly with earlier hosted runs, and
writes a record: the value and its measurement identity. The identity is:

- the measured argv (from Cachegrind's `cmd:` line), cwd and environment;
- a hash of the measurement harness (`scripts/measure-instruction-counts.sh`
  and `scripts/lib-benchmark.sh`);
- the SHA-256 of the measured compiler, and the source commit stamped into it,
  which must be the measured commit;
- the environment reuse key: ImageOS, kernel, valgrind, `as`, `ld`, workspace
  path and architecture.

The image version and CPU model are recorded but are not part of the key.
For identity/build changes, the reference workflow's PR dry run also invokes
`scripts/verify-self-compile-stamp-invariance.sh`. It reuses the first bootstrap
and measurement, creates a local second commit of the same tree, then builds
and measures it at the same path with the same seed and harness. It requires
equal Ir, byte-identical ordinary/TLCH images, both bootstrap/provenance
fixpoints, and native compiler equality after replacing only the unique
40-byte commit field. Both commit objects, records and compilers are retained;
the synthetic record is experimental and never published as a main reference.
The probe restores shared image inputs and compiler/profile handoffs on every
exit, preserving original absence; its failure-injection self-test checks that
restoration without rebuilding a compiler.

Build-recipe scripts are not part of the harness hash: they shape the compiler
under test, so their effect is part of a PR's own cost. Locally the record is
`local`, and nothing local is gated or reused.

**Main reference.** `.github/workflows/self-compile-reference.yml` runs the
same gate on every push to main. It publishes the record as that commit's
reference (artifact `self-compile-reference`, kept 90 days).

**PR check.** After `ci-verify`, the Linux CI job runs
`scripts/self-compile.sh check`. It identifies the tested merge T, its first
parent B (the main it merges onto) and the PR head H. It then gates the PR's
own cost, `own = M(T) − M(B)`. The check passes if and only if
`|own × 10⁶ − d × M(B)| ≤ 5000 × M(B)`, computed in exact integers, where d is
the PR's honoured declaration in ppm, or 0. `TYPELISP_IR_SELF_COMPILE_TOLERANCE_PPM`
(default 5000) is unchanged.

- M(B) is B's reference only when all of these hold:
  - the GitHub API shows a push-to-main run of the reviewed workflow, in this
    repository, for B;
  - that run's `Self-compile reference (Linux)` job succeeded in its latest
    executed attempt (a "re-run failed jobs" copy of a successful job counts as
    the attempt that ran it);
  - the record is the newest unexpired artifact of that name from the run (a
    re-run adds an artifact without removing the earlier attempt's) and names
    that run, attempt, commit and tree, and a compiler stamped with that commit;
  - its comparable identity (argv, cwd, env, harness hash and the environment
    reuse key) equals T's record. The compiler SHA-256 is recorded and bound to
    the commit; it is compared only between measurements of one commit.

  A pending reference is awaited for up to 30 minutes.
- Otherwise the job measures B in place. It sets T's `target/` aside and checks
  out B. It builds B's own fixpoint compiler with B's
  `ci-verify --gates bootstrap-fixpoint` and a freshly fetched seed, measures it
  with T's harness at the same path, then restores T, also when the job is
  terminated. The rejected reference, if any, is kept alongside for comparison;
  built with the same `as` and `ld`, it must have measured the same compiler
  bytes.
- Nothing passes without a valid, comparable M(B) of B's commit and tree. An API
  error, a missing or rejected reference, or a pending one that does not finish
  within the wait leads to the in-place measurement; if that also fails, the
  job fails.
- The job summary and the `self-compile-measurement` artifact record T, B, H,
  both values, the source of M(B), the own cost in Ir and ppm, and the status.

**Declarations.** A PR whose own cost is beyond ±5000 ppm acknowledges it in
`perf/self-compile-declarations/pr-<N>.tsv`, where N is its PR number. The file
is one line:
`self_compile/compile_cli_opt1<TAB><finite signed decimal ppm><TAB><reason>`.

- It is honoured only for PR N, and only while B lacks the file. The PR may edit
  its own new declaration before merge.
- A PR fails if it adds another PR's declaration, or modifies, deletes or
  renames one already in B. A malformed declaration fails.
- A declaration only records acknowledgement. It never justifies a regression
  or waives review.

#### Reporting replaces the ratchet

There is no pin to commit. Every PR record cites the CI own cost from the job
summary: Ir, ppm, and the source of M(B). Reviewers assess it.

- Only `|own| ≤ 1000` Ir, with unchanged compiler, stdlib and workload inputs,
  may be called runner variation.
- A positive cost above +5000 ppm, declared or measured, is non-routine and
  needs a council disposition.
- An improvement beyond −5000 ppm needs both technical reviewers to explain its
  source and confirm that no work was skipped.

#### The ledger

The `Self-compile ledger` job (`scripts/self-compile.sh ledger`) accounts for
every merge c with parent p. It uses three quantities, each subtraction taken
over values of one measurement identity:

- `step = M(c) − M(p)`;
- the merged PR's `own = M(T) − M(B)`, as its CI reported it (its own T and B
  records, in its own identity). This is the `own` the account sums;
- `A = step − own'`, where `own'` is the comparable own cost: the reported one
  when the PR's identity matches the pair's, otherwise the reproduced one
  (`own_reproduced`) measured in the pair's identity.

So, in a complete account, Σstep − Σown − ΣA is the sum of the reproduction differences
`own_reproduced − own`, which the account reports as
`sum.reproduction_delta` (0 when nothing was reproduced).

Incomparable values are never subtracted:

- When p's reference is not comparable with c's, the ledger job measures p on
  its own runner, and c as well when c's record is not comparable there.
- When the merged PR's T and B were measured in another identity, the job
  reproduces them on its runner in one identity with the pair. B is measured in
  place. T is the landed commit when the trees are equal; otherwise it is
  rebuilt with `git merge-tree` from B and the PR head and checked against the
  recorded tested tree. The original report is kept alongside.
- A mismatch that cannot be reproduced fails as a comparability failure.

Each merge is then checked as follows:

- **Class S** (the landed tree is the tested tree):
  - R = M(c) − M(T) in one identity (`r_method direct`); after a reproduction,
    R = `own_reproduced − own` (`r_method paired-delta`), two deltas of the same
    T and B trees each taken within one identity. Warn above 1,000 Ir; fail
    above 10,000 Ir.
  - T (the tested merge) and c (its squash) are different commits of one tree.
    The commit is recorded in a named static provenance field; content-derived
    labels and the compressed embedded stdlib image use source-tree identity.
    Their compilers differ only in that field, and equal trees perform equal
    measured work. Two measurements of one commit must have byte-identical
    compilers. The existing residual bounds remain the reproduction check.
  - A is recorded too. When B and p have the same tree it has the same bounds;
    otherwise it is assessed as class M.
- **Class M** (the landed tree or base differs from the tested composition):
  - R = A, recorded with the B..p merges.
  - Warn above 10,000 Ir; fail when `|R| × 10⁶ > 1000 × M(p)`.
- **Landed gate window**, on every merge: fail when
  `|step × 10⁶ − d × M(p)| > 5000 × M(p)`.
- **Missing PR record:** fails, whatever the numbers.

The ledger's `outcome.tsv` names the result for the merge-pause rules, with
`complete` and the account state. The outcomes are `ok`, `warning`, `pending`,
`numerical-failure`, `comparability-failure`, `provenance-failure`,
`attribution-failure`, `continuity-failure`, `measurement-failure` and
`infrastructure-failure`.

The account is the anchor plus one compact line per merge since it, carrying
step, the reported own, `own_reproduced`, A, R, the identity and the outcome.
Each run re-folds its `summary.tsv` from those lines, including every
subthreshold value:

- Σstep, Σown (reported), ΣA and the summed reproduction differences;
- the class S and class M residuals;
- warnings, failures and merges;
- identity segments;
- merges without a measured step or without attribution. Missing values are
  never summed as zero, and either makes the totals incomplete.

Each ledger run carries the account forward from its parent's run, so the
account outlives the 90-day artifact retention as long as main merges at least
once in that period; otherwise the checkpoint below restores it. The uploaded ledger holds only
these compact records. Every unresolved failure stays listed.

- Only a reviewed row in `perf/self-compile-ledger-resolutions.tsv`
  (`commit<TAB>outcome<TAB>reference`) resolves a failure. It is refused for a
  merge whose step was never measured or whose attribution is missing.
- A missing measurement is repaired by re-running that merge's ledger job: a
  later run replaces the entry with the repaired one and re-folds every total.
- If the artifact chain is lost, a reviewed
  `perf/self-compile-ledger-checkpoint.tsv` (a copy of an account) restores
  continuity.
- The anchor is the merge that introduced the reference workflow. Its parent is
  measured on the ledger runner.
- From the anchor on, a merge without a ledger entry fails as a continuity gap.

#### Local same-host deltas

Repeated runs on one host are stable, so a local reviewer can measure a
compiler change as a same-host delta. A local absolute value must never be
compared with a hosted one:

```sh
# Run on the base tree.
scripts/measure-instruction-counts.sh \
  --self-compile-only --opt-level 1 --runs 1 \
  --output target/instruction-count-base

# Run the same command on the branch tree, changing only --output.
scripts/measure-instruction-counts.sh \
  --self-compile-only --opt-level 1 --runs 1 \
  --output target/instruction-count-branch
```

Compare the `self_compile/compile_cli_opt1` rows in the two `summary.tsv` files.
`scripts/self-compile.sh measure --compiler <stage2>` writes the same record as
CI, marked `local`. The `self_compile` optimizer level is selected by
`--opt-level` (default 1) and recorded in the row name.

### What the checker measures

Unless `TYPELISP_IR_CHECK_COMPILER` names a prebuilt compiler (CI passes its
bootstrap stage2), the checker builds a fresh full CLI stage1 and stage2 under
its work directory and measures benchmarks with that fixed stage2 compiler.
Measured paths reach the counts (a C benchmark's input path, the self-compile
`-o` path), so CI's benchmark gate and the `self_compile` gate both keep their
historical paths under `target/instruction-count-check` and never run at once
(the `instruction-count` gate lock).
Benchmark binaries are built at **opt-level 2**, so the TypeLisp-vs-C rows are
a release-vs-release comparison (TypeLisp opt2 against `clang -O2`); override
with `TYPELISP_IR_BENCH_OPT_LEVEL`. A selected benchmark case must contain both
`bench.tl` and `baseline.c`.

TypeLisp deliberately does not auto-vectorize ordinary loops. Explicit SPMD
(`foreach`, `spmd-reduce`, and `spmd-scan`) is the data-parallel model.
Accordingly, every TypeLisp row (`benchmark/typelisp/<name>`) must carry its
scalar-fair counterpart `benchmark/c-scalar/<name>`, built with
`clang -O2 -fno-vectorize -fno-slp-vectorize`, and `check-instruction-counts.sh`
enforces that pairing. The measurement also runs `benchmark/c/<name>` with
ordinary `clang -O2` auto-vectorization, making the auto-vectorizer gap visible;
`ratios.tsv` reports both `typelisp_over_clang_scalar_x` and
`typelisp_over_clang_auto_x`. A baseline opts into gating the auto-vectorized
row by carrying `benchmark/c/<name>` rows: the default baseline gates only the
TypeLisp and scalar-fair rows, while the heavy baseline keeps them. Every
measured run must also reproduce exact stdout, stderr, and exit status across
TypeLisp, auto-vectorized C, and scalar-fair C.

C baselines are compiled with `benchmarks/cachegrind-region.c` and run with
Cachegrind instrumentation off until the C `main` boundary. This excludes
dynamic-loader and PIE startup while retaining the benchmark, libc work reached
by the benchmark, and process-exit path. The C harness requires a Cachegrind
version and development header that provide
`CACHEGRIND_START_INSTRUMENTATION`. Its self-test compiles binaries with
different constructor workloads and requires identical nonzero measured-region
counts across both workloads and a repeated invocation; it fails with an
explicit unsupported-environment diagnostic if the request is unavailable:

```sh
scripts/measure-instruction-counts.sh --self-test
```

A clang, libc, or Valgrind change that alters instructions executed from `main`
onward is still a real, reviewable C comparison change; only pre-`main` loader
startup is excluded.

### C comparison provenance

Each benchmark measurement writes `measure/c-provenance.json` under the
checker's output directory (`c-provenance.json` for direct measurements).
Schema 1 records the resolved compiler path, full version, executable SHA-256
and target; Valgrind and linker identities; libc version and each executable's
resolved libc path/hash; architecture, OS release, cwd and runner image/kernel
information. Each `benchmark/c/…` and `benchmark/c-scalar/…` row retains its
count, exact build/run argv, binary, C source and optimization-metadata hashes,
and hashes of file arguments such as the compiler-derived input corpus. The
instrumentation wrapper hash, Cachegrind options and clean runtime environment
are recorded too. `absent` marks an optional optimization-metadata file that
does not exist. `unknown` explicitly means unavailable; it is never a match
proving comparability. `complete:false` records an interrupted/failed run and
cannot be used as a producer record. Exact output/status checks still run
before a record becomes complete.
Disposable output directories must remain inside the checkout's `target/`;
the scripts validate that boundary before clearing a previous output.

The required Linux job uploads `c-comparison-provenance` on success or failure,
with both suites' records, summaries, checked rows and numerical diffs. Its
recorded repository, workflow, run ID, attempt, job and commit identify the
producer. The artifact is retained for 90 days. No host environment variable
is passed to the measured process: its environment remains `env -i LC_ALL=C`.

`<baseline>.provenance.json` describes the producer of the checked C rows.
The initial schema-1 sidecars explicitly mark historical provenance unknown;
they make no claim about which tools produced the existing values. To
establish provenance, run the complete required Linux job for an identified
commit, retaining the `c-comparison-provenance` artifact and successful gate
logs. Verify that **every checked C row in each suite matches exactly** and
that output parity and required case coverage passed. Copy that suite's
complete measured record into its sidecar in a reviewed, record-only PR;
include the run/attempt, job and direct artifact URL in that PR. Preserve all
baseline counts. Do not promote a subset, a failed run, or this host's metadata
as historical identity. A later TypeLisp-only row refresh needs no C metadata
refresh; a deliberate C count/source/tool change needs new authoritative
evidence and review. The sidecar's per-row counts bind its claimed producer
to the corresponding C pins; an old record never explains a different pin.

On a numerical mismatch the checker still exits nonzero in either direction.
For each affected C row it distinguishes unknown/unavailable provenance,
different recorded toolchain/commands/workload, and the same recorded identity
(which needs investigation). The record is evidence, not proof that it captures
every possible host influence. A TypeLisp row keeps its own exact failure.
Malformed records fail validation; missing historical records are diagnosed as
unknown. Neither absence nor incompatibility skips C rows, substitutes a mode,
changes tolerances, or authorizes a baseline update. The scalar/auto modes
remain separate, and the TypeLisp <=1.01x C target is unchanged.

To reproduce a hosted comparison locally, use a disposable VM or container
matching the record's OS/architecture, and install its exact Clang, libc,
linker and Valgrind versions **inside that environment**. Restore the named
source commit and input hashes, mount the checkout at the recorded cwd, and
use the gate's historical output paths and recorded argv. Verify executable
hashes as well as version labels; runner image/package revisions can differ
under the same version. Invoke `scripts/check-instruction-counts.sh` there
(and the heavy command above). Alternatively put an isolated tool prefix first
in PATH when libc and the other recorded inputs already match. Replacing host
tools globally or changing shared Git configuration is unnecessary. A passing
local reproduction does not replace required hosted CI.

### Suite membership

`perf/benchmark-ci-cases.tsv` assigns positive membership to the Linux generic
`benchmark` suite, the `optimization-opt2` optimizer-corpus suite, and the
`instruction-main` and `instruction-heavy` suites. `scripts/lib-benchmark.sh`
enforces that no `instruction-heavy` case is also in `benchmark`: its measured
execution already supplies output parity. An `instruction-main` case may also
be in `benchmark` or `optimization-opt2`, because each suite checks something
the others do not. `benchmark` correctness builds TypeLisp at the default
level (opt1). The opt2 corpus refuses compiler stderr and links through its
own assembler path. The instruction gate checks opt2 parity across TypeLisp,
auto and scalar C and pins the counts. The eleven original kernels are in all
the suites they were in before they were gated. Local `--cases` and `--filter`
selections are independent of CI membership.

## Compiler scaling budgets

`perf/compiler-scaling-budgets.tsv` is checked by the required Linux gate
`scripts/check-compiler-scaling.sh`. The fixed-input instruction counts above
cannot see a compiler cost that is acceptable at today's sizes and quadratic in
the size of one function, struct or module; this gate measures growth directly.

`tools/compiler-scaling` generates a deterministic program for a dimension and
a size. One dimension varies one property and a size only changes how many
units there are, never what a unit does:

| dimension | varies | each unit |
| --- | --- | --- |
| `decls` | declaration count | one small function, all reachable from `main` through eight-way callers |
| `cfg` | size of one function and its CFG | one two-armed branch on a running value, then a mask |
| `fields` | width of one struct | one `i64` field, initialized once and read once |
| `expansions` | macro expansions within one module | one `decls` function, defined by its own `: Decls` macro invocation inside one generated module |

Every program checks itself: the generator evaluates the same arithmetic while
it emits the source, and `main` returns 42 only if the compiled program
reproduces that value. The gate builds and runs every program before it
measures anything, so a miscompiled or substituted input is a failure, not a
data point.

For each budget row the gate measures the compiler under Cachegrind at three
sizes `S < M < L` and derives two numbers in which the compiler's fixed
start-up cost cancels:

- **marginal**: `(Ir(L) - Ir(M)) / (L - M)`, instructions per added unit;
- **growth**: that marginal cost divided by `(Ir(M) - Ir(S)) / (M - S)`. It is
  1.0 for a linear cost and, with sizes in ratio 1:2:4, 2.0 for a quadratic one.

Because both are differences of counts on one binary, the host's environment
and paths do not reach them, so a local run reproduces the CI values. A row
fails when the marginal cost moves more than 10% or the growth more than 0.10
from its checked value, **in either direction**, matching the instruction-count
baselines: an improvement is accepted by committing the refreshed row.

```sh
scripts/check-compiler-scaling.sh target/bootstrap-fixpoint/stage3
scripts/check-compiler-scaling.sh --update-budgets target/bootstrap-fixpoint/stage3
```

`--update-budgets` rewrites only the two measured columns. Review the diff: a
changed number needs its measured cause in the PR, and a baseline refresh never
justifies a regression. A row whose growth is not linear names the issue that
owns the defect in its `owner` column; the PR that fixes the defect refreshes
the row, which turns the fix into a permanent regression check. New dimensions
and phases are new rows; do not widen the tolerances to admit a slower
compiler. The complete gate builds the generator, validates 15 programs and
runs 30 Cachegrind measurements.

This is the compiler-scaling half of #7773. It does not replace the
self-compile row or the memory checks: it bounds how cost grows, not how large
it is on the compiler's own sources.

## SPMD scalar/AVX2 mode matrix

`scripts/measure-spmd-mode-instruction-counts.sh` is the opt-in deterministic
mode comparison for the seven SPMD benchmarks. It builds TypeLisp explicitly at
`--opt-level 2 --backend-mode scalar|avx2`; scalar rows are paired with
`clang -O2 -fno-vectorize -fno-slp-vectorize`, while AVX2 rows are paired with
auto-vectorized `clang -O2 -mavx2 -mno-avx512f`. Thus each
benchmark/mode/implementation row lives in the same checked
`perf/spmd-mode-insn-baseline.tsv` table: scalar measures like-for-like codegen,
and AVX2 measures the explicit TypeLisp SPMD backend against clang's
auto-vectorized end-state target. Every measured pair must return the same exit
status. The checked support contract is `perf/spmd-mode-support.tsv`; an
unsupported TypeLisp row must fail with its exact recorded lowering diagnostic
and is emitted as `unsupported`, never as a missing or zero count.

Run the full local matrix from Linux or WSL and compare it with the committed
`perf/spmd-mode-insn-baseline.tsv`:

```sh
TYPELISP_BIN=target/stage0/typelisp \
  scripts/measure-spmd-mode-instruction-counts.sh \
  --runs 1 --check-baseline
```

Use `--cases spmd_shuffle --modes scalar,avx2` for a focused run and
`--update-baseline` only for an intentional full-matrix refresh. Output under
`target/spmd-mode-instruction-counts/` includes compiler/tool/flag metadata,
raw runs, stable summaries, per-benchmark TypeLisp/clang ratios, and per-mode
geomeans. Fast mutation coverage for mode selection, C flags, unsupported
rows, missing/unstable counts, ratios, and geomeans is available cross-platform:

```sh
scripts/measure-spmd-mode-instruction-counts.sh --self-test
```

AVX-512 is never run under cachegrind because Valgrind 3.22 raises SIGILL and
records only startup instructions, so AVX-512 has no instruction-count
baseline.

The opt-in ISPC comparison corpus (`scripts/measure-ispc-spmd.sh`) is
report-only and is not mixed into these tables; see
[`benchmarks/ispc/README.md`](../benchmarks/ispc/README.md).

## Optimizer pass-firing census

`scripts/measure-pass-firing.sh <compiler>` compiles the benchmarks, examples,
integration and inline tests, the `tools/` programs and `src/main.tl` at
`--opt-level 2` and counts, per optimizer pass slot and program, the functions
the slot changed (`firing.tsv`); `summary.tsv` marks slots that change code only
in benchmark programs. The script header describes its exact (IR dump diff) and
counts (trace-only) methods and their limits.

## Compile-profile optimizer escape capture

Use the compile-profile verifier to build a profile-enabled CLI, then capture an
optimized self-compile stderr log:

```sh
scripts/verify-compile-profile.sh
target/compile-profile-verify/<host>/typelisp-profile compile src/main.tl \
  -o target/compile-profile-verify/<host>/self-profile.s \
  --target <target> \
  --cfg <host-cfg> \
  --stdlib-root stdlib \
  --stdlib-root src \
  --opt-level 1 \
  2> target/compile-profile-verify/<host>/self-profile.stderr
grep -E 'compile-profile\|optimize\.functions\||compile-profile-detail\|optimize\.escape\.' \
  target/compile-profile-verify/<host>/self-profile.stderr
```

Use the same target and cfgs that match the host being measured. The escape rows
are `compile-profile-detail|optimize.escape.<phase>|elapsed_ms|opt_level|function`
with phases `body`, `dce_escape`, `compact`, `clone`, and `restore`.

## CI timing artifacts

Pull-request CI uploads one `ci-timing-Linux` and one `ci-timing-Windows`
artifact per run (`target/ci-timing/<host>.tsv`, written by `ci-verify.sh` when
`TYPELISP_CI_TIMING=1`). Each host's required-check aggregator merges them
from its two CI lanes (`scripts/README.md`, CI lanes): each gate's rows come
from the lane that owns it, and the complete-verification row is the slowest
lane's verification time. Each lane also uploads its own rows as
`ci-timing-<lane>-r<run>-a<attempt>`. They record every gate's wall time and
finer rows such as the four build-invariance selfhost compiles
(`opt1-built:selfhost_main_opt1`, `opt2-built:selfhost_main_opt2`, ...). They
are evidence for performance work; CI applies no wall-clock budget to them.
Linux also retains build-invariance's authoritative corpus, both producers'
case/entry/alias plans, pool queue and chunk metrics in the
`backend-memory-linux-1-r<run>-a<attempt>` artifact of the lane that runs
build-invariance. Its `provenance.txt` identifies the source,
compiler binaries, common invocation flags and worker count. Those are the
same plans the local gate validates and executes; there is no artifact cache
in the comparison gate.

Exact instruction counts guard performance instead. Use
`scripts/benchmark-compile-cli.sh` for phase-level local investigation of a
compile-time change.
