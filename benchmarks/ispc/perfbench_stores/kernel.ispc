/*
  Copyright (c) 2012-2023, Intel Corporation

  SPDX-License-Identifier: BSD-3-Clause

  Derived from ISPC v1.31.0, commit
  c6adb4f86f5678ce6c41951b1e2b59f727455697,
  examples/cpu/perfbench/perfbench.ispc::stores.
  Adaptation: isolated the stores kernel without changing its signature or body.
*/

export void stores(uniform float array[], uniform int count,
                   uniform float zeros[], uniform float result[]) {
    int zero = zeros[programIndex];
    foreach (i = 0 ... count)
        array[i] = zero;
}
