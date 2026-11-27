/* benchmarks/fp_stencil_2d/baseline.c - clang C baseline for fp_stencil_2d.
 *
 * Equivalent to benchmarks/fp_stencil_2d/bench.tl: allocates two ping-pong
 * n x n double grids with clamped Dirichlet borders and a deterministic
 * asymmetric interior initial temperature field, runs `steps` 5-point Jacobi
 * updates, and hashes the IEEE-754 binary64 bit patterns of all final cells.
 */
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#pragma STDC FP_CONTRACT OFF

#define FS_HASH_BASIS 0xcbf29ce484222325ULL
#define FS_HASH_PRIME 1099511628211ULL

static uint64_t fs_mix(uint64_t h, uint64_t v) {
    return (h ^ v) * FS_HASH_PRIME;
}

static void fs_init_grids(double *a, double *b, int64_t n) {
    int64_t last = n - 1;
    double inv_last = 1.0 / (double)last;
    for (int64_t r = 0; r < n; r++) {
        int64_t row_base = r * n;
        for (int64_t c = 0; c < n; c++) {
            double val;
            if (r == 0) {
                val = 100.0;
            } else if (r == last) {
                val = 0.0;
            } else if (c == 0) {
                val = 50.0 * (1.0 - ((double)r * inv_last));
            } else if (c == last) {
                val = 25.0 * (1.0 - ((double)r * inv_last));
            } else {
                val = (double)((r * 7 + c * 13) % 97) * 0.25;
            }
            a[row_base + c] = val;
            b[row_base + c] = val;
        }
    }
}

static void fs_step(const double *src, double *dst, int64_t n) {
    int64_t limit = n - 1;
    for (int64_t r = 1; r < limit; r++) {
        int64_t row_base = r * n;
        int64_t up_base = row_base - n;
        int64_t dn_base = row_base + n;
        for (int64_t c = 1; c < limit; c++) {
            int64_t idx = row_base + c;
            double center = src[idx];
            double left = src[idx - 1];
            double right = src[idx + 1];
            double up = src[up_base + c];
            double down = src[dn_base + c];
            double neighbors = (left + right) + (up + down);
            dst[idx] = (0.4 * center) + (0.15 * neighbors);
        }
    }
}

static uint64_t fs_hash_grid(const double *grid, int64_t total) {
    uint64_t h = FS_HASH_BASIS;
    for (int64_t i = 0; i < total; i++) {
        uint64_t bits = 0;
        memcpy(&bits, &grid[i], sizeof bits);
        h = fs_mix(h, bits);
    }
    return h;
}

static uint64_t fs_bench(int64_t n, int64_t steps) {
    int64_t total = n * n;
    double *a = (double *)calloc((size_t)total, sizeof(double));
    double *b = (double *)calloc((size_t)total, sizeof(double));
    if (!a || !b) abort();

    fs_init_grids(a, b, n);
    int64_t step = 0;
    while (step + 1 < steps) {
        fs_step(a, b, n);
        fs_step(b, a, n);
        step += 2;
    }
    uint64_t res;
    if (step < steps) {
        fs_step(a, b, n);
        res = fs_hash_grid(b, total);
    } else {
        res = fs_hash_grid(a, total);
    }

    free(a);
    free(b);
    return res;
}

int main(int argc, char **argv) {
    int64_t n = argc > 1 ? strtoll(argv[1], 0, 10) : 0;
    int64_t steps = argc > 2 ? strtoll(argv[2], 0, 10) : 0;
    printf("%" PRIu64 "\n", fs_bench(n, steps));
    return 0;
}
