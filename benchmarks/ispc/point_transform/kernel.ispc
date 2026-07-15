// Copyright (c) 2025, Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause

/*
  Derived from ISPC v1.31.0, commit
  c6adb4f86f5678ce6c41951b1e2b59f727455697,
  examples/cpu/point_transform_ctypes/point_transform.ispc::transform_points.

  Adaptation: the uniform sin(rotation)/cos(rotation) prelude is factored out,
  and the Transform fields are passed as uniform scalars so this comparison
  measures the two-input/two-output f32 zip body rather than a struct ABI.
  Scaling, rotation, translation, strength, array layout, and foreach range are
  otherwise unchanged.
*/
export void transform_points(uniform float points_x[],
                             uniform float points_y[],
                             uniform float result_x[],
                             uniform float result_y[],
                             uniform float scale_x,
                             uniform float scale_y,
                             uniform float translate_x,
                             uniform float translate_y,
                             uniform float sin_theta,
                             uniform float cos_theta,
                             uniform float strength,
                             uniform int count) {
    foreach (i = 0 ... count) {
        float x = points_x[i] * scale_x;
        float y = points_y[i] * scale_y;

        float x_rot = x * cos_theta - y * sin_theta;
        float y_rot = x * sin_theta + y * cos_theta;

        result_x[i] = x_rot + translate_x * strength;
        result_y[i] = y_rot + translate_y * strength;
    }
}
