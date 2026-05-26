/* benchmarks/array_sum/baseline.c - clang C baseline for array_sum (#1098).
 *
 * Equivalent to benchmarks/array_sum/bench.tl: fill an i64 array with a
 * deterministic pattern, then sum it `rounds` times into a wrapping 64-bit
 * accumulator and return the low byte as the process exit code. uint64_t gives
 * defined modulo-2^64 wrapping that matches TypeLisp i64 `+`/`*`, so both
 * programs produce the identical exit code on a given host.
 *
 * The array length and round count are `base + argc` (argc is 1 with no extra
 * arguments, matching TypeLisp `arg-count`), so neither trip count is a
 * compile-time constant. The running accumulator is stored back into the array
 * each round (xs[r] = acc), creating a cross-round data dependency that stops
 * the optimizer collapsing the loop-invariant per-round sum into a single pass.
 */
#include <stdint.h>
#include <stdlib.h>

static void fill(uint64_t *xs, uint64_t n) {
    for (uint64_t i = 0; i < n; i++) {
        xs[i] = i * 2654435761ULL + 1013904223ULL;
    }
}

int main(int argc, char **argv) {
    (void)argv;
    const uint64_t base_size = 200003ULL;
    const uint64_t base_rounds = 6000ULL;
    uint64_t n = base_size + (uint64_t)argc;
    uint64_t rounds = base_rounds + (uint64_t)argc;
    uint64_t *xs = (uint64_t *)malloc((size_t)n * sizeof(uint64_t));
    if (!xs) {
        return 2;
    }
    fill(xs, n);
    uint64_t acc = 0;
    for (uint64_t r = 0; r < rounds; r++) {
        for (uint64_t i = 0; i < n; i++) {
            acc += xs[i];
        }
        xs[r] = acc;
    }
    free(xs);
    return (int)(acc & 0xFFULL);
}
