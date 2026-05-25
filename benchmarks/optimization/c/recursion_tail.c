#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

static int64_t sum_tail(int64_t n, int64_t acc) {
    if (n == 0) {
        return acc;
    }
    return sum_tail(n - 1, (acc + n * 3) % 1000000007LL);
}

int main(int argc, char **argv) {
    int64_t n = argc > 1 ? strtoll(argv[1], 0, 10) : 0;
    printf("%lld\n", (long long)sum_tail(n, 0));
    return 0;
}
