#include <stdint.h>

/* C baseline for tests/integration/c_abi_f32_scalar.tl.
 *
 * Exercises the scalar `f32` C ABI in extern positions: arguments and returns
 * are passed in XMM registers (xmm0-xmm7 on System V, the four positional
 * xmm0-xmm3 slots on Windows x64) using single-precision `movss`. The mixed
 * int/float helper checks that the System V independent integer/SSE counters
 * and the Windows shared positional slots both land each value correctly, and
 * the nine-argument helper forces a stack-passed `f32` argument on both ABIs.
 */

float tl_cabi_f32_add(float a, float b) {
  return a + b;
}

float tl_cabi_f32_scale(float a, float b, float c) {
  return a * b + c;
}

/* Nine f32 arguments: the ninth is stack-passed on System V and past the four
 * positional register slots on Windows x64. Returns the stack-passed value. */
float tl_cabi_f32_ninth(float a, float b, float c, float d, float e, float f,
                        float g, float h, float i) {
  (void)a;
  (void)b;
  (void)c;
  (void)d;
  (void)e;
  (void)f;
  (void)g;
  (void)h;
  return i;
}

/* Interleaved integer and float parameters: n,m use the integer sequence while
 * x,y use the SSE sequence (System V) or share positional slots (Windows). */
float tl_cabi_f32_mix(int64_t n, float x, int64_t m, float y) {
  return (float)(n + m) + x + y;
}

/* f32 argument, integer return: result lands in %rax. */
int64_t tl_cabi_f32_to_i64(float x) {
  return (int64_t)x;
}
