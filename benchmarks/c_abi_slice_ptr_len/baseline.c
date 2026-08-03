#include <stdint.h>

int64_t tl_cabi_slice_ptr_len_sum(const int64_t *data, int64_t len) {
  int64_t sum = 0;
  if (len <= 0) {
    return 0;
  }
  for (int64_t i = 0; i < len; ++i) {
    sum += data[i];
  }
  return sum;
}

int64_t tl_cabi_slice_ptr_len_add_first_and_sum(
    int64_t *data,
    int64_t len,
    int64_t delta) {
  int64_t sum = 0;
  if (len <= 0) {
    return 0;
  }
  data[0] += delta;
  for (int64_t i = 0; i < len; ++i) {
    sum += data[i];
  }
  return sum;
}
