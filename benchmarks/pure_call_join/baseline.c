#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

static uint64_t probe(int64_t depth, uint64_t key) {
    uint64_t result = key;
    for (int64_t index = 0; index < depth; ++index) {
        result = result * UINT64_C(1664525) + UINT64_C(1013904223);
        result ^= result >> 13;
    }
    return result;
}

static uint64_t exercise(int64_t rounds, int64_t depth) {
    uint64_t result = 0;
    for (int64_t index = 0; index < rounds; ++index) {
        uint64_t key = (uint64_t)index;
        uint64_t before = probe(depth, key);
        uint64_t middle = (key & 1) == 0
            ? probe(depth - 1, key + 11)
            : probe(depth - 2, key + 19);
        uint64_t after = probe(depth, key);
        result += before + middle + after;
    }
    return result;
}

int main(int argc, char **argv) {
    if (argc != 3) return 1;
    printf("%llu\n", (unsigned long long)exercise(
        strtoll(argv[1], NULL, 10), strtoll(argv[2], NULL, 10)));
    return 0;
}
