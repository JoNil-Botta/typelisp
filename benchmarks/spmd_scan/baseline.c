/* benchmarks/spmd_scan/baseline.c - C baseline for spmd_scan (#5349).
 *
 * Equivalent to benchmarks/spmd_scan/bench.tl. Each pass writes an inclusive
 * prefix over a fixed array, seeded by the pass number, and folds a
 * pass-varying prefix into an observable accumulator. uint64_t provides the
 * modulo-2^64 arithmetic required to match TypeLisp i64 addition.
 */
#include <stdint.h>

#define ARRAY_LEN 4096

int main(int argc, char **argv) {
    (void)argv;
    static uint64_t a[ARRAY_LEN];
    static uint64_t out[ARRAY_LEN];
    for (uint64_t i = 0; i < ARRAY_LEN; i++) {
        a[i] = i + 1;
    }
    const uint64_t base_reps = 300000ULL;
    const uint64_t reps = base_reps + (uint64_t)argc;
    uint64_t acc = 0;
    for (uint64_t r = 0; r < reps; r++) {
        uint64_t prefix = r;
        for (uint64_t i = 0; i < ARRAY_LEN; i++) {
            prefix += a[i];
            out[i] = prefix;
        }
        acc += out[r & (ARRAY_LEN - 1)];
    }
    return (int)(acc & 0xFFULL);
}
