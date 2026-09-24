/* Same serial wrapping recurrence as bench.tl. */
#include <stdint.h>

static const uint64_t factor = UINT64_C(17179869184);

int main(int argc, char **argv) {
    (void)argv;
    uint64_t acc = 16777215;
    const uint64_t iterations = 100000000 + (uint64_t)argc;
    for (uint64_t i = 0; i < iterations; ++i) {
        acc = (acc * factor) ^ (acc >> 29);
    }
    return (int)(acc & 255);
}
