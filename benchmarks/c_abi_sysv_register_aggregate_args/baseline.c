#include <stdint.h>

typedef struct {
  int64_t lo;
  int64_t hi;
} Pair;

typedef struct {
  int64_t x;
} Inner;

typedef struct {
  Inner inner;
  int64_t tail;
} Outer;

typedef struct {
  uint64_t tag;
  double value;
} Mixed;

int64_t tl_cabi_pair_score(Pair pair, int64_t salt) {
  return (pair.lo * 3) + (pair.hi * 5) + salt;
}

int64_t tl_cabi_outer_score(Outer outer) {
  return (outer.inner.x * 7) + outer.tail;
}

int64_t tl_cabi_mixed_score(Mixed mixed, int64_t scale) {
  return ((int64_t)(mixed.value * (double)scale)) + (int64_t)mixed.tag;
}
