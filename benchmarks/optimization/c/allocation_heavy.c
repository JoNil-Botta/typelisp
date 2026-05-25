#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

static int64_t bench(int64_t n) {
    int64_t acc = 0;
    char buf[64];
    for (int64_t i = 0; i < n; i += 1) {
        int written = snprintf(buf, sizeof(buf), "%lld", (long long)(i * 17 + 5));
        if (written > 0) {
            acc += written;
        }
    }
    return acc;
}

int main(int argc, char **argv) {
    int64_t n = argc > 1 ? strtoll(argv[1], 0, 10) : 0;
    printf("%lld\n", (long long)bench(n));
    return 0;
}
