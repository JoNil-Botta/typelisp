/* benchmarks/spmd_foreach_2d/baseline.c - clang C baseline for spmd_foreach_2d
 * (#7191).
 *
 * Equivalent to benchmarks/spmd_foreach_2d/bench.tl: each pass maps
 * `out[y * w + x] = a[y * w + x] + b[y * w + x] + r` over two 8-row domains,
 * width 256 (full gangs only) and width 255 (a partial tail on every row), folds
 * one element of each output into an accumulator, and returns its low byte as
 * the process exit code. uint64_t gives defined modulo-2^64 wrapping that
 * matches TypeLisp i64 `+`, so both programs produce the identical exit code.
 *
 * The arrays are cache-resident and the work is made runtime-dominant by the
 * outer repetition loop. The per-pass `r` term keeps each pass distinct so the
 * kernel cannot be hoisted, and the trip count `base_reps + argc` (argc is 1
 * with no extra arguments, matching TypeLisp `arg-count`) keeps the result
 * deterministic while preventing whole-loop constant folding.
 */
#include <stdint.h>

#define ROWS 8
#define FULL_WIDTH 256
#define TAIL_WIDTH 255

static void pass(uint64_t *out, const uint64_t *a, const uint64_t *b,
                 uint64_t w, uint64_t r) {
    for (uint64_t y = 0; y < ROWS; y++) {
        for (uint64_t x = 0; x < w; x++) {
            out[y * w + x] = a[y * w + x] + b[y * w + x] + r;
        }
    }
}

int main(int argc, char **argv) {
    (void)argv;
    static uint64_t a[ROWS * FULL_WIDTH];
    static uint64_t b[ROWS * FULL_WIDTH];
    static uint64_t full[ROWS * FULL_WIDTH];
    static uint64_t tail[ROWS * FULL_WIDTH];
    for (uint64_t i = 0; i < ROWS * FULL_WIDTH; i++) {
        a[i] = i + 1;
        b[i] = i * 2;
    }
    const uint64_t base_reps = 125000ULL;
    uint64_t reps = base_reps + (uint64_t)argc;
    uint64_t acc = 0;
    for (uint64_t r = 0; r < reps; r++) {
        pass(full, a, b, FULL_WIDTH, r);
        pass(tail, a, b, TAIL_WIDTH, r);
        acc = acc + full[r % (ROWS * FULL_WIDTH)] + tail[r % (ROWS * TAIL_WIDTH)];
    }
    return (int)(acc & 0xFFULL);
}
