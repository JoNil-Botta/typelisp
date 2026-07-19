/* benchmarks/spmd_shuffle/baseline.c - clang baseline for #5351.
 *
 * Equivalent to bench.tl: run repeated maps `out[i] = a[i] + r`, fold one
 * element per pass into an accumulator, and return its low byte. The TypeLisp
 * map routes the value through an identity intra-gang shuffle; identity makes
 * this scalar C loop the same observable computation in every backend mode.
 */
#include <stdint.h>

#define ARRAY_LEN 4096

int main(int argc, char **argv) {
    (void)argv;
    static uint64_t a[ARRAY_LEN];
    static uint64_t out[ARRAY_LEN];
    for (uint64_t i = 0; i < ARRAY_LEN; i++) {
        a[i] = i * 3 + 1;
    }
    const uint64_t base_reps = 300000ULL;
    const uint64_t reps = base_reps + (uint64_t)argc;
    uint64_t acc = 0;
    for (uint64_t r = 0; r < reps; r++) {
        for (uint64_t i = 0; i < ARRAY_LEN; i++) {
            out[i] = a[i] + r;
        }
        acc += out[r & (ARRAY_LEN - 1)];
    }
    return (int)(acc & 0xFFULL);
}
