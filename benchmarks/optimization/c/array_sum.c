#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

static void fill(int64_t *xs, int64_t n) {
    for (int64_t i = 0; i < n; i += 1) {
        xs[i] = (i * 13 + 5) % 97;
    }
}

static int64_t sum_array(const int64_t *xs, int64_t n) {
    int64_t acc = 0;
    for (int64_t i = 0; i < n; i += 1) {
        acc += xs[i];
    }
    return acc;
}

int main(int argc, char **argv) {
    int64_t n = argc > 1 ? strtoll(argv[1], 0, 10) : 0;
    int64_t *xs = (int64_t *)calloc((size_t)n, sizeof(int64_t));
    if (!xs) {
        return 2;
    }
    fill(xs, n);
    printf("%lld\n", (long long)sum_array(xs, n));
    free(xs);
    return 0;
}
