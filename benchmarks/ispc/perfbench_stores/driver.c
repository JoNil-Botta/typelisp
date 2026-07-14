/*
  Copyright (c) 2012-2023, Intel Corporation

  SPDX-License-Identifier: BSD-3-Clause

  Correctness driver derived for the isolated ISPC v1.31.0
  examples/cpu/perfbench/perfbench.ispc::stores kernel. The upstream perfbench
  invokes each kernel 100 times; this driver preserves that repetition count
  and adds complete, byte-exact output checks.
*/

#include <stdint.h>
#include <stdio.h>
#include <string.h>

#ifndef EXPECTED_GANG_WIDTH
#error "compile driver.c with -DEXPECTED_GANG_WIDTH=<ISPC target width>"
#endif

#if EXPECTED_GANG_WIDTH != 1
#include "kernel_ispc.h"
#endif

enum {
    kCaseCount = 7,
    kMaxValues = 65536,
    kRepetitions = 100,
    kZeroCount = 32,
};

static int case_count(int case_id) {
    static const int counts[kCaseCount] = {0, 3, 4, 8, 16, 19, 65536};
    return counts[case_id];
}

static float lane_zero(int lane) {
    return (float)(((lane + 1) * 17) - 133);
}

#if EXPECTED_GANG_WIDTH == 1
static void scalar_stores(float *values, int count, const float *zeros) {
    int zero = (int)zeros[0];
    for (int i = 0; i < count; ++i)
        values[i] = (float)zero;
}
#endif

int main(void) {
    static float values[kMaxValues + 1];
    static float expected[kMaxValues + 1];
    float zeros[kZeroCount];
#if EXPECTED_GANG_WIDTH != 1
    float result[1] = {0.0f};
#endif
    const float sentinel = 12345.0f;

    for (int lane = 0; lane < kZeroCount; ++lane)
        zeros[lane] = lane_zero(lane);

    for (int case_id = 0; case_id < kCaseCount; ++case_id) {
        int count = case_count(case_id);
        for (int i = 0; i <= count; ++i) {
            values[i] = sentinel;
            expected[i] = sentinel;
        }
        for (int i = 0; i < count; ++i)
            expected[i] = lane_zero(i % EXPECTED_GANG_WIDTH);

#if EXPECTED_GANG_WIDTH == 1
        for (int repetition = 0; repetition < kRepetitions; ++repetition)
            scalar_stores(values, count, zeros);
#else
        for (int repetition = 0; repetition < kRepetitions; ++repetition)
            stores(values, count, zeros, result);
#endif

        if (memcmp(values, expected, (size_t)(count + 1) * sizeof(float)) != 0) {
            int first = 0;
            while (first <= count &&
                   memcmp(&values[first], &expected[first], sizeof(float)) == 0)
                ++first;
            fprintf(stderr,
                    "perfbench_stores case %d width %d differs at %d\n",
                    case_id, EXPECTED_GANG_WIDTH, first);
            return 1;
        }
    }

    return 41 + EXPECTED_GANG_WIDTH;
}
