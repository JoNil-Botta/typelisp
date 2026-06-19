#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

static int64_t mix_value(int64_t x, int64_t y) {
    return (x * 33 + (y * 7 + 11)) % 1000000007LL;
}

static int64_t bench(int64_t n) {
    int64_t acc = 5;
    for (int64_t i = 0; i < n; i += 1) {
        acc = mix_value(acc, i);
    }
    return acc;
}

int main(int argc, char **argv) {
    int64_t n = argc > 1 ? strtoll(argv[1], 0, 10) : 0;
    printf("%lld\n", (long long)bench(n));
    return 0;
}
