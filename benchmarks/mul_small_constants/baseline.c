/* Same serial wrapping recurrence as bench.tl. */
#include <stdint.h>

int main(int argc, char **argv) {
    (void)argv;
    uint64_t acc = 16777215;
    const uint64_t iterations = 50000000 + (uint64_t)argc;
    for (uint64_t i = 0; i < iterations; ++i) {
        acc = (acc * 3) ^ (acc >> 29);
        acc = (acc * 5) ^ (acc >> 31);
        acc = (acc * 9) ^ (acc >> 27);
    }
    return (int)(acc & 255);
}
