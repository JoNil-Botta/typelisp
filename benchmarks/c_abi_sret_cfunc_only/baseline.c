#include <stdint.h>

typedef struct {
  uint64_t a;
  uint64_t b;
  uint64_t c;
} SretOnly;

static SretOnly make(uint64_t seed) {
  SretOnly result = {seed, seed + 10, seed + 20};
  return result;
}

SretOnly (*tl_cabi_sret_only_maker)(uint64_t) = make;
