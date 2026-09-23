#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

static uint64_t read_sum(const uint64_t *values, size_t length, uint64_t bias) {
    uint64_t total = bias;
    for (size_t i = 0; i < length; ++i) total += values[i];
    return total;
}

static uint64_t repeat_sum(const uint64_t *values, size_t length, int64_t rounds) {
    uint64_t total = 0;
    for (int64_t i = 0; i < rounds; ++i)
        total = total * UINT64_C(33) + (read_sum(values, length, 7) ^ (uint64_t)i);
    return total;
}

int main(int argc, char **argv) {
    (void)argc;
    uint64_t seed = (uint64_t)strtoll(argv[1], 0, 10);
    int64_t rounds = strtoll(argv[2], 0, 10);
    uint64_t values[64];
    for (size_t i = 0; i < 64; ++i) values[i] = seed + i * UINT64_C(17);
    printf("%llu\n", (unsigned long long)repeat_sum(values, 64, rounds));
    return 0;
}
