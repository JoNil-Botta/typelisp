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

typedef struct {
  float x;
  float y;
} Vec2;

int64_t tl_cabi_pair_score(Pair pair, int64_t salt) {
  return (pair.lo * 3) + (pair.hi * 5) + salt;
}

static int64_t tl_cabi_pair_score_indirect(Pair pair, int64_t salt) {
  return (pair.lo * 2) + (pair.hi * 4) + salt;
}

int64_t (*tl_cabi_pair_score_ptr)(Pair, int64_t) = tl_cabi_pair_score_indirect;

int64_t tl_cabi_outer_score(Outer outer) {
  return (outer.inner.x * 7) + outer.tail;
}

int64_t tl_cabi_mixed_score(Mixed mixed, int64_t scale) {
  return ((int64_t)(mixed.value * (double)scale)) + (int64_t)mixed.tag;
}

int64_t tl_cabi_vec2_score(Vec2 vec, int64_t salt) {
  return ((int64_t)(vec.x * 10.0f)) + ((int64_t)(vec.y * 10.0f)) + salt;
}

Vec2 tl_cabi_vec2_make(int64_t seed) {
  Vec2 result;
  result.x = (float)(seed + 2);
  result.y = (float)(seed + 3);
  return result;
}
