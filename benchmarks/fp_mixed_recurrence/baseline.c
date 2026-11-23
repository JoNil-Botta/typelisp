/* Mixed integer and f64 leaf recurrence with an index-weighted sum. */
#include <inttypes.h>
#include <stdio.h>
#include <string.h>

#pragma STDC FP_CONTRACT OFF

static double mixed_f64_recurrence(int64_t n, double x0, double a, double b) {
    double x = x0;
    double acc = 0.0;
    for (int64_t i = 0; i < n; i++) {
        x = a * x + b;
        acc += (double)i * x;
    }
    return acc + x;
}

/* Read the function pointer once so the leaf keeps its mixed GP/FP ABI. */
static double (*volatile run_recurrence)(int64_t, double, double, double) =
    mixed_f64_recurrence;

int main(int argc, char **argv) {
    (void)argv;
    int64_t n = 20000000 + (int64_t)argc;
    double sum = run_recurrence(n, 0.25, 1.000001, 0.5);
    uint64_t bits;
    memcpy(&bits, &sum, sizeof bits);
    printf("%" PRIu64 "\n", bits);
    return 0;
}
