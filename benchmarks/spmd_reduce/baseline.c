/* benchmarks/spmd_reduce/baseline.c - clang C baseline for spmd_reduce (#1125).
 *
 * Equivalent to benchmarks/spmd_reduce/bench.tl: run `reps` passes of a sum
 * reduction `sum_i (a[i] + r)` over a fixed-size array, fold each pass sum into
 * an accumulator, and return its low byte as the process exit code. uint64_t
 * gives defined modulo-2^64 wrapping that matches TypeLisp i64 `+`, so both
 * programs produce the identical exit code on a given host. The TypeLisp side
 * expresses the reduction with `spmd-reduce`; this is the scalar reference.
 *
 * The array is small (cache-resident) and the work is made runtime-dominant by
 * the outer repetition loop. The per-pass `r` term keeps each pass distinct so
 * the kernel cannot be hoisted, and the trip count `base_reps + argc` (argc is 1
 * with no extra arguments, matching TypeLisp `arg-count`) keeps the result
 * deterministic while preventing whole-loop constant folding.
 */
#include <stdint.h>

#define ARRAY_LEN 4096

int main(int argc, char **argv) {
    (void)argv;
    static uint64_t a[ARRAY_LEN];
    for (uint64_t i = 0; i < ARRAY_LEN; i++) {
        a[i] = i + 1;
    }
    const uint64_t base_reps = 300000ULL;
    uint64_t reps = base_reps + (uint64_t)argc;
    uint64_t acc = 0;
    for (uint64_t r = 0; r < reps; r++) {
        uint64_t sum = 0;
        for (uint64_t i = 0; i < ARRAY_LEN; i++) {
            sum = sum + a[i] + r;
        }
        acc = acc + sum;
    }
    return (int)(acc & 0xFFULL);
}
