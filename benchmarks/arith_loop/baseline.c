/* benchmarks/arith_loop/baseline.c - clang C baseline for arith_loop (#1097).
 *
 * Equivalent to benchmarks/arith_loop/bench.tl: run an LCG recurrence for
 * `iterations` steps over wrapping 64-bit integer arithmetic and return the low
 * byte of the accumulator as the process exit code. uint64_t gives defined
 * modulo-2^64 wrapping that matches TypeLisp i64 `+`/`*`, so both programs
 * produce the identical exit code on a given host.
 *
 * The trip count is `base_iterations + argc` (argc is 1 with no extra
 * arguments, matching TypeLisp `arg-count`). Deriving it from a runtime value
 * keeps the result deterministic while preventing the compiler from
 * constant-folding the whole loop away.
 */
#include <stdint.h>

int main(int argc, char **argv) {
    (void)argv;
    uint64_t acc = 0;
    const uint64_t base_iterations = 1000000000ULL;
    uint64_t iterations = base_iterations + (uint64_t)argc;
    for (uint64_t i = 0; i < iterations; i++) {
        acc = acc * 1664525ULL + 1013904223ULL;
    }
    return (int)(acc & 0xFFULL);
}
