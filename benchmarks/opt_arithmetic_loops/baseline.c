#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

static int64_t bench(int64_t n) {
    int64_t i = 0;
    int64_t acc = 1;
    while (i < n) {
        acc = (acc * 31 + (i * 17 + 7)) % 1000000007LL;
        i += 1;
    }
    return acc;
}

int main(int argc, char **argv) {
    int64_t n = argc > 1 ? strtoll(argv[1], 0, 10) : 0;
    printf("%lld\n", (long long)bench(n));
    return 0;
}
