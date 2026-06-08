#include <stdint.h>

typedef struct {
  uint64_t a;
  uint64_t b_bits;
} WideArg;

int64_t tl_cabi_wide_arg_score(WideArg arg, uint64_t tag) {
  int64_t field_score = (arg.b_bits == UINT64_C(0x3ff8000000000000)) ? 15 : 1000;
  return (int64_t)arg.a + field_score + (int64_t)tag;
}

static int64_t tl_cabi_wide_arg_score_indirect(WideArg arg, uint64_t tag) {
  int64_t field_score = (arg.b_bits == UINT64_C(0x4004000000000000)) ? 50 : 1000;
  return (int64_t)arg.a + field_score + (int64_t)tag;
}

int64_t (*tl_cabi_wide_arg_score_ptr)(WideArg, uint64_t) =
  tl_cabi_wide_arg_score_indirect;
