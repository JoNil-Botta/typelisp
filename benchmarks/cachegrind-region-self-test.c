/* Fast fixture for the C Cachegrind measured-region harness self-test. */
#include <stdint.h>

#ifndef TYPELISP_IR_STARTUP_ITERATIONS
#define TYPELISP_IR_STARTUP_ITERATIONS 1
#endif

static volatile uint64_t startup_sink;
static volatile uint64_t measured_sink;

__attribute__((constructor)) static void startup_noise(void) {
    uint64_t value = 1;
    for (uint64_t i = 0; i < TYPELISP_IR_STARTUP_ITERATIONS; i++) {
        value = value * 1664525ULL + 1013904223ULL;
    }
    startup_sink = value;
}

int main(int argc, char **argv) {
    (void)argv;
    uint64_t value = (uint64_t)argc;
    for (uint64_t i = 0; i < 10000; i++) {
        value = value * 1103515245ULL + 12345ULL;
    }
    measured_sink = value;
    return 0;
}
