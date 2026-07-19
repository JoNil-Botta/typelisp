# Freestanding exponential benchmark

This manual benchmark compares `stdlib.math.f64-exp` with a straightforward
degree-12 Taylor polynomial over the shared `[-0.5, 0.5]` input sequence. Both
programs perform 2,000,001 runtime-opaque calls and return exit code 42.

From the repository root:

```powershell
tools/stage0/typelisp.exe build benchmarks/math_exp/stdlib_exp.tl -o target/math-exp-stdlib.exe --opt-level 2 --stdlib-root stdlib --stdlib-root src
tools/stage0/typelisp.exe build benchmarks/math_exp/taylor_exp.tl -o target/math-exp-taylor.exe --opt-level 2 --stdlib-root stdlib --stdlib-root src
1..7 | ForEach-Object { (Measure-Command { & target/math-exp-stdlib.exe }).TotalMilliseconds }
1..7 | ForEach-Object { (Measure-Command { & target/math-exp-taylor.exe }).TotalMilliseconds }
```

Compile the same sources with `compile` instead of `build` to inspect static
assembly instruction count and emitted byte size. The Taylor program is a cost
baseline, not the accuracy oracle; checked correctness uses MPFR-256 vectors.
