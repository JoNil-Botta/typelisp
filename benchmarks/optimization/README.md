# Optimization Benchmarks

This directory contains paired TypeLisp and C benchmark programs for tracking
optimizer progress against clang baselines. The default runner mode is a local
performance report; `--correctness` is the timing-free required-CI gate.

Run on Linux from the repository root:

```sh
TYPELISP_BIN=./target/stage0/typelisp ./scripts/run-optimization-benchmarks.sh
```

Required CI runs the timing-free correctness mode:

```sh
TYPELISP_BIN=./target/stage0/typelisp ./scripts/run-optimization-benchmarks.sh --correctness
```

Correctness mode builds every `cases.tsv` TypeLisp/C pair once, runs each pair
with the manifest arguments, rejects unexpected stderr or nonzero exits, and
compares stdout after normalizing CRLF to LF. It does not run timing repetitions
and does not compute runtime ratios, artifact sizes, or instruction counts.
Linux runs the full corpus through the host GNU toolchain. Windows required CI
currently prints an explicit per-case skip reason pending #2526, because GitHub
Actions Windows miscompiles this corpus while local Windows runs do not
reproduce it. Set `TYPELISP_OPT_BENCH_WINDOWS_FORCE=1` to force-run Windows
correctness mode through `typelisp compile --target windows-x86_64`, `clang`,
and `lld-link` for TypeLisp binaries plus `clang` for the C baselines.

The runner defaults to compiling TypeLisp benchmark sources through the
selfhost `selfhost/compiler_driver.tl` path, then assembling and linking the
generated Linux x86_64 assembly. Set `TYPELISP_BENCH_SELFHOST=0` or pass
`--rust-stage0` to compile TypeLisp sources through the Rust stage0 CLI instead.
These knobs apply to the local timing report; correctness mode always uses the
public `typelisp compile` path plus the native link helper so it can run on both
required CI hosts and on the bootstrapped stage1 compiler.

Requirements:

- For timing mode: Linux with `as`, `ld`, `clang`, `awk`, `wc`, and
  `date +%s%N`.
- For correctness mode: Linux with `as`, `ld`, `clang`, and `awk`, or Windows
  Git Bash/MSYS with `clang` and `lld-link`.
- A TypeLisp compiler via `TYPELISP_BIN`, otherwise the published stage0 is
  fetched into `target/stage0/typelisp`.
- A quiet machine. Wall-clock timings are noisy; compare best-of runs and rerun
  when ratios are close.

Useful knobs:

- `TYPELISP_BENCH_RUNS=5` or `--runs 5` changes runtime repetitions.
- `TYPELISP_BENCH_CLANG_OPT=-O2` changes the clang optimization level. The
  default is `-O3`.
- `--filter array_sum` runs one case by manifest name; `--filter runtime_`
  runs every case with that manifest-name prefix.

The `runtime_*` cases isolate backend-emitted runtime helper shapes for string
equality, substring, concatenation, integer/string conversion, and path helper
copying. They use command-line inputs and loop-carried work so both TypeLisp and
clang see runtime data rather than compile-time constants.

The report columns are CSV:

```text
case,category,tl_ms,c_ms,ratio,tl_compile_ms,c_compile_ms,tl_exe_bytes,c_exe_bytes,tl_asm_bytes,c_asm_bytes,tl_insns,c_insns
```

`ratio` is `TypeLisp runtime / C runtime`; lower is better. Assembly instruction
counts are approximate text counts intended for trend tracking, not a substitute
for hardware counters.
