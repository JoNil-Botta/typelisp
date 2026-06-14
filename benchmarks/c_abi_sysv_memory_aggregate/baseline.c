#include <stdint.h>

typedef struct {
  uint64_t a;
  uint64_t b;
  uint64_t c;
} WideMem;

typedef struct {
  uint64_t lo;
  uint64_t hi;
} InnerMem;

typedef struct {
  InnerMem inner;
  uint64_t tail;
} NestedMem;

int64_t tl_cabi_wide_mem_score(WideMem arg, uint64_t salt) {
  return (int64_t)((arg.a * 3) + (arg.b * 5) + (arg.c * 7) + salt);
}

static int64_t tl_cabi_wide_mem_score_indirect(WideMem arg, uint64_t salt) {
  return (int64_t)((arg.a * 2) + (arg.b * 4) + (arg.c * 6) + salt);
}

int64_t (*tl_cabi_wide_mem_score_ptr)(WideMem, uint64_t) =
  tl_cabi_wide_mem_score_indirect;

WideMem tl_cabi_wide_mem_make(uint64_t seed) {
  WideMem out;
  out.a = seed + 10;
  out.b = seed + 20;
  out.c = seed + 30;
  return out;
}

int64_t tl_cabi_nested_mem_score(NestedMem arg) {
  return (int64_t)(arg.inner.lo + (arg.inner.hi * 2) + (arg.tail * 3));
}
