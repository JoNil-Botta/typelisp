# Small constant multiplication

This paired TypeLisp/C benchmark runs a serial wrapping 64-bit recurrence with
multipliers 3, 5, and 9. Each multiply is mixed with a logical right shift of the
previous value. The shifts carry high bits into the returned low-byte checksum
and prevent the affine recurrence folding exercised by `arith_loop`.

The trip count is 50,000,000 plus runtime argc. TypeLisp uses `u64` and the C
baseline uses `uint64_t`, so overflow and shift behavior agree. The correctness
suite compares stdout, stderr, and exit status, and the case is registered in
`perf/benchmark-ci-cases.tsv`.

## Local code-generation measurement

AMD Ryzen 9 9950X, Linux x86-64, Clang 22.1.8, TypeLisp opt2 versus Clang `-O2`.
The existing harness warms each executable, interleaves the TypeLisp, Clang,
and scalar-Clang legs, and verifies matching output/status before reporting.

| Compiler | Median runtime | TypeLisp / Clang `-O2` |
| --- | ---: | ---: |
| Upstream `b01f4b32`, 7 rounds | 112.560 ms | 1.970 |
| LEA for 3/5/9, 5 rounds | 56.417 ms | 0.997 |

The branch's Clang median was 56.575 ms (56.210 ms with vectorization disabled).
This closes the gap for this specific dependency-chain workload on this host;
it does not establish parity for the full compiler or benchmark corpus.

The backend replaces `imulq $3, src, dst` with
`leaq (src,src,2), dst`, and similarly uses scales 4 and 8 for factors 5 and 9.
This preserves wrapping 64-bit results and works when source and destination
are the same register. `%rbp` retains IMUL because the frame-rebasing pass must
not mistake a value-register base for a frame reference. Existing narrow-width
and other-constant paths are unchanged.

Reproduce with a separately built upstream or branch compiler:

```sh
TYPELISP_BIN=/path/to/compiler scripts/bench.sh \
  --cases mul_small_constants --runs 7 \
  --output target/exp/mul-small-constants
```
