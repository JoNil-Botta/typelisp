/*
  Copyright (c) 2010-2023, Intel Corporation

  SPDX-License-Identifier: BSD-3-Clause

  Correctness driver derived for ISPC v1.31.0
  examples/cpu/mandelbrot/mandelbrot.ispc. It adds complete-buffer, sentinel,
  and fixed-checksum validation around the unchanged exported kernel.
*/

#include <stdint.h>
#include <stdio.h>

#include "kernel_ispc.h"

enum { kCaseCount = 8, kCapacity = 65, kSentinel = -1431655766 };

typedef struct Case {
    float x0, y0, x1, y1;
    int width, height, max_iterations;
    int64_t checksum;
} Case;

static const Case kCases[kCaseCount] = {
    {-2.0f, -1.0f, 1.0f, 1.0f, 0, 3, 12, 0},
    {-2.0f, -1.0f, 1.0f, 1.0f, 3, 0, 12, 0},
    {3.0f, 3.0f, 4.0f, 4.0f, 1, 1, 17, 1},
    {0.0f, 0.0f, 1.0f, 1.0f, 1, 1, 17, 18},
    {-2.0f, -1.0f, 1.0f, 1.0f, 3, 1, 12, 46},
    {-2.0f, -1.0f, 1.0f, 1.0f, 16, 1, 24, 532},
    {-2.0f, -1.0f, 1.0f, 1.0f, 19, 1, 32, 681},
    {-2.0f, -1.0f, 1.0f, 1.0f, 5, 1, 0, 15},
};

static int scalar_mandel(float c_re, float c_im, int count) {
    float z_re = c_re, z_im = c_im;
    int i;
    for (i = 0; i < count; ++i) {
        if (z_re * z_re + z_im * z_im > 4.0f)
            break;
        float new_re = z_re * z_re - z_im * z_im;
        float new_im = (2.0f * z_re) * z_im;
        z_re = c_re + new_re;
        z_im = c_im + new_im;
    }
    return i;
}

static void scalar_mandelbrot(const Case *c, int32_t *output) {
    float dx = (c->x1 - c->x0) / (float)c->width;
    float dy = (c->y1 - c->y0) / (float)c->height;
    for (int j = 0; j < c->height; ++j) {
        for (int i = 0; i < c->width; ++i) {
            float x = c->x0 + (float)i * dx;
            float y = c->y0 + (float)j * dy;
            output[j * c->width + i] =
                scalar_mandel(x, y, c->max_iterations);
        }
    }
}

static int64_t checksum(const int32_t *values, int count) {
    int64_t sum = 0;
    for (int i = 0; i < count; ++i)
        sum += (int64_t)(i + 1) * (int64_t)(values[i] + 1);
    return sum;
}

int main(void) {
    int32_t got[kCapacity] = {0};
    int32_t want[kCapacity] = {0};

    for (int case_id = 0; case_id < kCaseCount; ++case_id) {
        const Case *c = &kCases[case_id];
        int count = c->width * c->height;
        got[count] = kSentinel;
        want[count] = kSentinel;

        scalar_mandelbrot(c, want);
        mandelbrot_ispc(c->x0, c->y0, c->x1, c->y1, c->width,
                        c->height, c->max_iterations, got);

        for (int i = 0; i < count; ++i) {
            if (got[i] != want[i]) {
                fprintf(stderr,
                        "mandelbrot case %d index %d: got %d, expected %d\n",
                        case_id, i, got[i], want[i]);
                return 1;
            }
        }
        if (got[count] != kSentinel || want[count] != kSentinel) {
            fprintf(stderr, "mandelbrot case %d overwrote sentinel\n", case_id);
            return 1;
        }
        int64_t got_checksum = checksum(got, count);
        if (got_checksum != c->checksum) {
            fprintf(stderr,
                    "mandelbrot case %d checksum: got %lld, expected %lld\n",
                    case_id, (long long)got_checksum,
                    (long long)c->checksum);
            return 1;
        }
    }

    return 42;
}
