/* benchmarks/spmd_zip/baseline.c - clang C baseline for spmd_zip (#1125).
 *
 * Equivalent to benchmarks/spmd_zip/bench.tl: run `reps` passes of a three-input
 * zip `out[i] = a[i] * b[i] + c[i] + r` over a fixed-size array, fold one
 * element of each pass into an accumulator, and return its low byte as the
 * process exit code. uint64_t gives defined modulo-2^64 wrapping that matches
 * TypeLisp i64 `+`/`*`, so both programs produce the identical exit code on a
 * given host.
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
    static uint64_t b[ARRAY_LEN];
    static uint64_t c[ARRAY_LEN];
    static uint64_t out[ARRAY_LEN];
    for (uint64_t i = 0; i < ARRAY_LEN; i++) {
        a[i] = i + 1;
        b[i] = i * 2;
        c[i] = i + 3;
    }
    const uint64_t base_reps = 300000ULL;
    uint64_t reps = base_reps + (uint64_t)argc;
    uint64_t acc = 0;
    for (uint64_t r = 0; r < reps; r++) {
        for (uint64_t i = 0; i < ARRAY_LEN; i++) {
            out[i] = a[i] * b[i] + c[i] + r;
        }
        acc = acc + out[r & (ARRAY_LEN - 1)];
    }
    return (int)(acc & 0xFFULL);
}
