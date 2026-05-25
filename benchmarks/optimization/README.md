# Optimization Benchmarks

This directory contains paired TypeLisp and C benchmark programs for tracking
optimizer progress against clang baselines. They are local performance tools,
not correctness CI gates.

Run on Linux from the repository root:

```sh
TYPELISP_BIN=./target/release/typelisp ./scripts/run-optimization-benchmarks.sh
```

The runner defaults to compiling TypeLisp benchmark sources through the
selfhost `selfhost/compiler_driver.tl` path, then assembling and linking the
generated Linux x86_64 assembly. Set `TYPELISP_BENCH_SELFHOST=0` or pass
`--rust-stage0` to compile TypeLisp sources through the Rust stage0 CLI instead.

Requirements:

- Linux with `as`, `ld`, `clang`, `awk`, `wc`, and `date +%s%N`.
- A built TypeLisp compiler via `TYPELISP_BIN`, or Cargo available so the
  script can build `target/release/typelisp`.
- A quiet machine. Wall-clock timings are noisy; compare best-of runs and rerun
  when ratios are close.

Useful knobs:

- `TYPELISP_BENCH_RUNS=5` or `--runs 5` changes runtime repetitions.
- `TYPELISP_BENCH_CLANG_OPT=-O2` changes the clang optimization level. The
  default is `-O3`.
- `--filter array_sum` runs one case by manifest name.

The report columns are CSV:

```text
case,category,tl_ms,c_ms,ratio,tl_compile_ms,c_compile_ms,tl_exe_bytes,c_exe_bytes,tl_asm_bytes,c_asm_bytes,tl_insns,c_insns
```

`ratio` is `TypeLisp runtime / C runtime`; lower is better. Assembly instruction
counts are approximate text counts intended for trend tracking, not a substitute
for hardware counters.
