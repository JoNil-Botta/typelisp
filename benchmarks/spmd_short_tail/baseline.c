/* benchmarks/spmd_short_tail/baseline.c - clang C baseline for spmd_short_tail (#1125).
 *
 * Equivalent to benchmarks/spmd_short_tail/bench.tl: run `reps` passes of an
 * elementwise map `out[i] = a[i] + b[i] + r` over an array whose length (1000)
 * is deliberately NOT a multiple of any SIMD lane width, fold one element of
 * each pass into an accumulator, and return its low byte as the process exit
 * code. uint64_t gives defined modulo-2^64 wrapping that matches TypeLisp i64
 * `+`, so both programs produce the identical exit code on a given host. The
 * non-lane-aligned length is the point: a vectorized lowering must handle the
 * remainder/tail; this is the scalar reference.
 *
 * The array is small (cache-resident) and the work is made runtime-dominant by
 * the outer repetition loop. The per-pass `r` term keeps each pass distinct so
 * the kernel cannot be hoisted, and the trip count `base_reps + argc` (argc is 1
 * with no extra arguments, matching TypeLisp `arg-count`) keeps the result
 * deterministic while preventing whole-loop constant folding. The folded index
 * `r % ARRAY_LEN` reads a different element each pass (the length is not a power
 * of two) so the stored array cannot be eliminated.
 */
#include <stdint.h>

#define ARRAY_LEN 1000

int main(int argc, char **argv) {
    (void)argv;
    static uint64_t a[ARRAY_LEN];
    static uint64_t b[ARRAY_LEN];
    static uint64_t out[ARRAY_LEN];
    for (uint64_t i = 0; i < ARRAY_LEN; i++) {
        a[i] = i + 1;
        b[i] = i * 2;
    }
    const uint64_t base_reps = 1000000ULL;
    uint64_t reps = base_reps + (uint64_t)argc;
    uint64_t acc = 0;
    for (uint64_t r = 0; r < reps; r++) {
        for (uint64_t i = 0; i < ARRAY_LEN; i++) {
            out[i] = a[i] + b[i] + r;
        }
        acc = acc + out[r % ARRAY_LEN];
    }
    return (int)(acc & 0xFFULL);
}
