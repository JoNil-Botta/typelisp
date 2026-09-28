# Small constant multiplication

This paired TypeLisp/C benchmark runs a serial wrapping 64-bit recurrence with
multipliers 3, 5, and 9. Each multiply is mixed with a logical right shift of the
previous value. The shifts carry high bits into the returned low-byte checksum
and prevent the affine recurrence folding exercised by `arith_loop`.

The trip count is 50,000,000 plus runtime argc. TypeLisp uses `u64` and the C
baseline uses `uint64_t`, so overflow and shift behavior agree. The correctness
suite compares stdout, stderr, and exit status, and the case is registered in
`perf/benchmark-ci-cases.tsv`.

The serial dependency chain exposes multiply latency. The backend lowers a
multiply by 3, 5, or 9 to one `leaq (src,src,scale)` instead of `imulq`
(`compiler-backend-mul-immediate-direct-asm`), except when the source is `%rbp`,
which must never look like a frame address to the frame-rebasing pass.
