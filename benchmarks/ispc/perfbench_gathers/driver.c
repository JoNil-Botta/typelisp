/*
  Copyright (c) 2012-2023, Intel Corporation

  SPDX-License-Identifier: BSD-3-Clause

  Correctness driver derived for the isolated ISPC v1.31.0
  examples/cpu/perfbench/perfbench.ispc::gathers kernel. The upstream
  perfbench invokes each kernel 100 times; this driver preserves that
  repetition count and adds bit-exact deterministic oracle checks.
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
    kPadding = 5,
    kOffsetCount = 32,
    kRepetitions = 100,
};

static int case_count(int case_id) {
    static const int counts[kCaseCount] = {0, 1, 3, 8, 16, 19, 65536};
    return counts[case_id];
}

static int lane_offset(int lane) {
    static const int offsets[8] = {0, 3, 1, 4, 2, 0, 4, 1};
    return offsets[lane % 8];
}

static float value_at(int index) {
    return (float)(1 + ((index * 5) % 17));
}

static float scalar_gathers(const float *values, int count,
                            const float *zeros) {
    float sum = 0.0f;
    for (int i = 0; i < count; ++i)
        sum += values[i + (int)zeros[i % EXPECTED_GANG_WIDTH]];
    return sum;
}

static uint32_t f32_bits(float value) {
    uint32_t bits = 0;
    memcpy(&bits, &value, sizeof(bits));
    return bits;
}

int main(void) {
    static float values[kMaxValues + kPadding];
    float zeros[kOffsetCount];
    float result[1] = {-1.0f};

    for (int lane = 0; lane < kOffsetCount; ++lane)
        zeros[lane] = (float)lane_offset(lane);

    for (int case_id = 0; case_id < kCaseCount; ++case_id) {
        int count = case_count(case_id);
        for (int i = 0; i < count + kPadding; ++i)
            values[i] = value_at(i);

        float expected = scalar_gathers(values, count, zeros);
        for (int repetition = 0; repetition < kRepetitions; ++repetition) {
#if EXPECTED_GANG_WIDTH == 1
            result[0] = scalar_gathers(values, count, zeros);
#else
            gathers(values, count, zeros, result);
#endif
        }

        if (f32_bits(result[0]) != f32_bits(expected)) {
            fprintf(stderr,
                    "perfbench_gathers case %d width %d: got 0x%08x, expected 0x%08x\n",
                    case_id, EXPECTED_GANG_WIDTH, f32_bits(result[0]),
                    f32_bits(expected));
            return 1;
        }
    }

    return 42;
}
