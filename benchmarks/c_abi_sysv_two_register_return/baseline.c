#include <stdint.h>

typedef struct {
  int64_t lo;
  int64_t hi;
} PairI64;

typedef struct {
  int64_t tag;
  double value;
} MixIF;

typedef struct {
  double value;
  int64_t tag;
} MixFI;

typedef struct {
  double x;
  double y;
} PairF64;

PairI64 tl_cabi_pair_i64_make(int64_t seed) {
  PairI64 out;
  out.lo = seed + 10;
  out.hi = seed + 20;
  return out;
}

static PairI64 tl_cabi_pair_i64_make_indirect(int64_t seed) {
  PairI64 out;
  out.lo = seed + 30;
  out.hi = seed + 40;
  return out;
}

PairI64 (*tl_cabi_pair_i64_make_ptr)(int64_t) =
  tl_cabi_pair_i64_make_indirect;

MixIF tl_cabi_mix_if_make(int64_t seed) {
  MixIF out;
  out.tag = seed + 3;
  out.value = (double)(seed + 4);
  return out;
}

MixFI tl_cabi_mix_fi_make(int64_t seed) {
  MixFI out;
  out.value = (double)(seed + 5);
  out.tag = seed + 6;
  return out;
}

PairF64 tl_cabi_pair_f64_make(int64_t seed) {
  PairF64 out;
  out.x = (double)(seed + 1);
  out.y = (double)(seed + 2);
  return out;
}
