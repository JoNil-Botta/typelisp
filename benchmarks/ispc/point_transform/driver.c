// Copyright (c) 2025, Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause

/*
  Correctness driver for the derived ISPC v1.31.0
  examples/cpu/point_transform_ctypes/point_transform.ispc::transform_points
  zip kernel. The scalar oracle disables contraction; ISPC may contract the
  multiply/add shapes, so nontrivial rotations admit at most two binary32 ULPs.
*/

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#ifdef USE_ISPC
#include "kernel_ispc.h"
#endif

enum { kCaseCount = 5, kCapacity = 20, kRepetitions = 100 };

typedef struct Case {
    int count;
    float scale_x, scale_y;
    float translate_x, translate_y;
    float sin_theta, cos_theta;
    float strength;
    int max_ulp;
} Case;

static const Case kCases[kCaseCount] = {
    {0, -1.5f, 0.25f, 4.0f, -6.0f, -0.7071067690849304f,
     0.7071067690849304f, 1.25f, 2},
    {3, 2.0f, -0.5f, 4.0f, -8.0f, 0.0f, 1.0f, 0.0f, 0},
    {8, -1.0f, 2.0f, 1.0f, -3.0f, 0.0f, 1.0f, 1.0f, 0},
    {16, 1.25f, -0.75f, -2.5f, 3.5f, 0.6000000238418579f,
     0.800000011920929f, 0.375f, 2},
    {19, -1.5f, 0.25f, 4.0f, -6.0f, -0.7071067690849304f,
     0.7071067690849304f, 1.25f, 2},
};

static float input_x(int case_id, int index) {
    switch (case_id) {
    case 1: return (float)(index - 2);
    case 2: return (float)(index - 4);
    case 3: return (float)(index - 8) * 0.25f;
    default: return (float)(index - 9) * -0.375f;
    }
}

static float input_y(int case_id, int index) {
    switch (case_id) {
    case 1: return (float)(index * 2 - 1);
    case 2: return (float)(3 - index);
    case 3: return (float)(index % 5 - 2) * 0.5f;
    default: return (float)(index % 7 - 3) * 1.25f;
    }
}

static void scalar_transform(const float *points_x, const float *points_y,
                             float *result_x, float *result_y, const Case *c) {
    for (int i = 0; i < c->count; ++i) {
        float x = points_x[i] * c->scale_x;
        float y = points_y[i] * c->scale_y;
        float x_rot = x * c->cos_theta - y * c->sin_theta;
        float y_rot = x * c->sin_theta + y * c->cos_theta;
        result_x[i] = x_rot + c->translate_x * c->strength;
        result_y[i] = y_rot + c->translate_y * c->strength;
    }
}

static uint32_t f32_bits(float value) {
    uint32_t bits;
    memcpy(&bits, &value, sizeof(bits));
    return bits;
}

static uint32_t ulp_distance(float left, float right) {
    uint32_t a = f32_bits(left), b = f32_bits(right);
    uint32_t a_mag = a & UINT32_C(0x7fffffff);
    uint32_t b_mag = b & UINT32_C(0x7fffffff);
    if ((a >> 31) == (b >> 31))
        return a_mag > b_mag ? a_mag - b_mag : b_mag - a_mag;
    return a_mag + b_mag;
}

static int fixed_exact(int case_id, int index, float x, float y) {
    if (case_id == 1)
        return x == (float)(index * 2 - 4) && y == 0.5f - (float)index;
    if (case_id == 2)
        return x == (float)(5 - index) && y == (float)(3 - index * 2);
    return 1;
}

int main(void) {
    float points_x[kCapacity], points_y[kCapacity];
    float got_x[kCapacity], got_y[kCapacity];
    float want_x[kCapacity], want_y[kCapacity];
    const float sentinel = 12345.0f;

    for (int case_id = 0; case_id < kCaseCount; ++case_id) {
        const Case *c = &kCases[case_id];
        for (int i = 0; i < c->count; ++i) {
            points_x[i] = input_x(case_id, i);
            points_y[i] = input_y(case_id, i);
        }
        for (int i = 0; i <= c->count; ++i)
            got_x[i] = got_y[i] = want_x[i] = want_y[i] = sentinel;

        scalar_transform(points_x, points_y, want_x, want_y, c);
        for (int repetition = 0; repetition < kRepetitions; ++repetition) {
#ifdef USE_ISPC
            transform_points(points_x, points_y, got_x, got_y,
                             c->scale_x, c->scale_y,
                             c->translate_x, c->translate_y,
                             c->sin_theta, c->cos_theta,
                             c->strength, c->count);
#else
            scalar_transform(points_x, points_y, got_x, got_y, c);
#endif
        }

        for (int i = 0; i < c->count; ++i) {
            uint32_t dx = ulp_distance(got_x[i], want_x[i]);
            uint32_t dy = ulp_distance(got_y[i], want_y[i]);
            if (!isfinite(got_x[i]) || !isfinite(got_y[i]) ||
                dx > (uint32_t)c->max_ulp || dy > (uint32_t)c->max_ulp ||
                !fixed_exact(case_id, i, got_x[i], got_y[i])) {
                fprintf(stderr,
                        "point_transform case %d index %d differs: "
                        "x=%08x/%08x (%u ULP), y=%08x/%08x (%u ULP)\n",
                        case_id, i, f32_bits(got_x[i]), f32_bits(want_x[i]), dx,
                        f32_bits(got_y[i]), f32_bits(want_y[i]), dy);
                return 1;
            }
        }
        if (f32_bits(got_x[c->count]) != f32_bits(sentinel) ||
            f32_bits(got_y[c->count]) != f32_bits(sentinel)) {
            fprintf(stderr, "point_transform case %d overwrote sentinel\n", case_id);
            return 1;
        }
    }
    return 42;
}
