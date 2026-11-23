/* Degree-12 Taylor approximation of exp on [-0.5, 0.5]. */
#include <inttypes.h>
#include <stdio.h>
#include <string.h>

#pragma STDC FP_CONTRACT OFF

static double taylor_exp(double x) {
    double sum = 1.0;
    double term = 1.0;
    for (int64_t n = 1; n <= 12; n++) {
        term = (term * x) / (double)n;
        sum += term;
    }
    return sum;
}

int main(int argc, char **argv) {
    (void)argv;
    int64_t iterations = 2000000 + (int64_t)argc;
    double x = -0.5;
    double sum = 0.0;
    for (int64_t i = 0; i < iterations; i++) {
        sum += taylor_exp(x);
        x += 0.000001;
        if (x > 0.5) {
            x = -0.5;
        }
    }
    uint64_t bits;
    memcpy(&bits, &sum, sizeof bits);
    printf("%" PRIu64 "\n", bits);
    return 0;
}
