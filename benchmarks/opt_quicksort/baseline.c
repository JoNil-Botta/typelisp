/* benchmarks/opt_quicksort/baseline.c - clang C baseline for opt_quicksort.
 *
 * Equivalent to benchmarks/opt_quicksort/bench.tl: each round refills an array
 * with a round-seeded LCG pattern (masked into a small non-negative range),
 * sorts it in place with a Lomuto-partition quicksort, and folds an
 * order-sensitive rolling hash of the sorted array into a wrapping accumulator.
 * TypeLisp `+`/`-`/`*` wrap modulo 2^64, so the LCG arithmetic uses uint64_t to
 * match. Masked values stay in [0, 2^31) and the accumulator stays in
 * [0, prime), so the printed decimal matches TypeLisp's print of an i64.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#define QS_MODULUS 1000000007ULL
#define QS_MASK 2147483647ULL

static void qs_swap(uint64_t *xs, int64_t i, int64_t j) {
    uint64_t tmp = xs[i];
    xs[i] = xs[j];
    xs[j] = tmp;
}

static int64_t qs_partition(uint64_t *xs, int64_t lo, int64_t hi) {
    uint64_t pivot = xs[hi];
    int64_t store = lo;
    for (int64_t scan = lo; scan < hi; scan += 1) {
        if (xs[scan] < pivot) {
            qs_swap(xs, store, scan);
            store += 1;
        }
    }
    qs_swap(xs, store, hi);
    return store;
}

static void qs_sort(uint64_t *xs, int64_t lo, int64_t hi) {
    if (lo < hi) {
        int64_t pivot_index = qs_partition(xs, lo, hi);
        qs_sort(xs, lo, pivot_index - 1);
        qs_sort(xs, pivot_index + 1, hi);
    }
}

static uint64_t qs_fill(uint64_t *xs, int64_t n, uint64_t seed) {
    uint64_t state = seed;
    for (int64_t i = 0; i < n; i += 1) {
        state = (state * 1103515245ULL + 12345ULL) & QS_MASK;
        xs[i] = state;
    }
    return state;
}

static uint64_t qs_checksum(uint64_t *xs, int64_t n) {
    uint64_t hash = 0;
    for (int64_t i = 0; i < n; i += 1) {
        hash = (hash * 131ULL + xs[i]) % QS_MODULUS;
    }
    return hash;
}

static uint64_t qs_bench(int64_t n, int64_t rounds) {
    uint64_t *xs = (uint64_t *)malloc((size_t)n * sizeof(uint64_t));
    if (!xs) {
        abort();
    }
    uint64_t acc = 0;
    uint64_t seed = 1;
    for (int64_t round = 0; round < rounds; round += 1) {
        seed = qs_fill(xs, n, seed + (uint64_t)round * 2654435761ULL);
        qs_sort(xs, 0, n - 1);
        acc = (acc + qs_checksum(xs, n)) % QS_MODULUS;
    }
    free(xs);
    return acc;
}

int main(int argc, char **argv) {
    int64_t n = argc > 1 ? strtoll(argv[1], 0, 10) : 0;
    int64_t rounds = argc > 2 ? strtoll(argv[2], 0, 10) : 0;
    printf("%lld\n", (long long)qs_bench(n, rounds));
    return 0;
}
