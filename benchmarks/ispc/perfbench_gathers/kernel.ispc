/*
  Copyright (c) 2012-2023, Intel Corporation

  SPDX-License-Identifier: BSD-3-Clause

  Derived from ISPC v1.31.0, commit
  c6adb4f86f5678ce6c41951b1e2b59f727455697,
  examples/cpu/perfbench/perfbench.ispc::gathers.
  Adaptation: isolated the gathers kernel without changing its signature or
  body.
*/

export void gathers(uniform float array[], uniform int count,
                    uniform float zeros[], uniform float result[]) {
    float sum = 0;
    int zero = zeros[programIndex];
    foreach (i = 0 ... count) {
        #pragma ignore warning(perf)
        sum += array[i + zero];
    }
    result[0] = reduce_add(sum);
}
