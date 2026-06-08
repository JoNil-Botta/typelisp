#include <stdint.h>

typedef struct {
  uint64_t a;
  uint64_t b;
} Wide;

Wide tl_cabi_wide_make(uint32_t a, uint32_t b, uint32_t c, uint32_t d, uint64_t tag) {
  Wide out = {
    (uint64_t)a + (uint64_t)b + tag,
    (uint64_t)c + (uint64_t)d + (tag * 10),
  };
  return out;
}

static Wide tl_cabi_wide_make_indirect(uint32_t a, uint32_t b, uint32_t c, uint32_t d, uint64_t tag) {
  Wide out = {
    (uint64_t)a + (uint64_t)b + (tag * 2),
    (uint64_t)c + (uint64_t)d + (tag * 11),
  };
  return out;
}

Wide (*tl_cabi_wide_make_ptr)(uint32_t, uint32_t, uint32_t, uint32_t, uint64_t) =
  tl_cabi_wide_make_indirect;
