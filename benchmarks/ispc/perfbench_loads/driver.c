/*
  Copyright (c) 2012-2023, Intel Corporation

  SPDX-License-Identifier: BSD-3-Clause

  Correctness driver derived for the isolated ISPC v1.31.0
  examples/cpu/perfbench/perfbench.ispc::loads kernel. The upstream perfbench
  invokes each kernel 100 times; this driver preserves that repetition count
  and adds bit-exact deterministic oracle checks.
*/

#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "kernel_ispc.h"

enum { kCaseCount = 7, kMaxValues = 65536, kRepetitions = 100 };

static int case_count(int case_id) {
    static const int counts[kCaseCount] = {0, 3, 8, 16, 19, 12, 65536};
    return counts[case_id];
}

static float case_value(int case_id, int index) {
    switch (case_id) {
    case 1:
        return (float)(index + 1);
    case 2:
    case 3:
        return 1.0f;
    case 4:
        return (float)((index % 7) - 3);
    case 5:
        return (index % 2) == 0 ? 1024.0f : -1024.0f;
    default:
        return 1.0f;
    }
}

static float scalar_loads(const float *values, int count) {
    float sum = 0.0f;
    for (int i = 0; i < count; ++i)
        sum += values[i];
    return sum;
}

static uint32_t f32_bits(float value) {
    uint32_t bits = 0;
    memcpy(&bits, &value, sizeof(bits));
    return bits;
}

int main(void) {
    static const uint32_t expected_bits[kCaseCount] = {
        0x00000000u, 0x40c00000u, 0x41000000u, 0x41800000u,
        0xc0a00000u, 0x00000000u, 0x47800000u,
    };
    static float values[kMaxValues];
    float zeros[32] = {0.0f};

    for (int case_id = 0; case_id < kCaseCount; ++case_id) {
        int count = case_count(case_id);
        for (int i = 0; i < count; ++i)
            values[i] = case_value(case_id, i);

        float expected = scalar_loads(values, count);
        if (f32_bits(expected) != expected_bits[case_id]) {
            fprintf(stderr,
                    "perfbench_loads oracle case %d: got 0x%08x, expected 0x%08x\n",
                    case_id, f32_bits(expected), expected_bits[case_id]);
            return 1;
        }
        float result[1] = {-1.0f};
        for (int repetition = 0; repetition < kRepetitions; ++repetition)
            loads(values, count, zeros, result);

        if (f32_bits(result[0]) != expected_bits[case_id]) {
            fprintf(stderr,
                    "perfbench_loads case %d: got 0x%08x, expected 0x%08x\n",
                    case_id, f32_bits(result[0]), expected_bits[case_id]);
            return 1;
        }
    }

    return 42;
}
