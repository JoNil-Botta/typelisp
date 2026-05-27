#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int64_t string_int_repeat(const char *seed_text, int64_t rounds) {
    int64_t seed = strtoll(seed_text, 0, 10);
    int64_t acc = 0;
    char buffer[64];

    for (int64_t i = 0; i < rounds; i += 1) {
        int64_t n = seed + i;
        int len = snprintf(buffer, sizeof(buffer), "%lld", (long long)n);
        int64_t roundtrip = strtoll(buffer, 0, 10);
        acc += roundtrip + len;
    }

    return acc;
}

int main(int argc, char **argv) {
    const char *seed = argc > 1 ? argv[1] : "0";
    int64_t rounds = argc > 2 ? strtoll(argv[2], 0, 10) : 0;
    printf("%lld\n", (long long)string_int_repeat(seed, rounds));
    return 0;
}
