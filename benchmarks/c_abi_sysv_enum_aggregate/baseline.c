#include <stdint.h>

typedef struct {
  int64_t value;
} SmallSomePayload;

typedef union {
  SmallSomePayload some;
} SmallChoicePayload;

typedef struct {
  int64_t tag;
  SmallChoicePayload payload;
} SmallChoice;

typedef struct {
  SmallChoice choice;
} WrappedSmall;

typedef struct {
  double value;
} FloatSomePayload;

typedef union {
  FloatSomePayload some;
} FloatChoicePayload;

typedef struct {
  int64_t tag;
  FloatChoicePayload payload;
} FloatChoice;

typedef struct {
  uint64_t lo;
  uint64_t hi;
} WideSomePayload;

typedef union {
  WideSomePayload some;
} WideChoicePayload;

typedef struct {
  int64_t tag;
  WideChoicePayload payload;
} WideChoice;

int64_t tl_cabi_small_choice_score(SmallChoice arg, int64_t bias) {
  if (arg.tag == 1) {
    return (arg.payload.some.value * 3) + bias;
  }
  return bias + 1000;
}

static int64_t tl_cabi_small_choice_score_indirect(
  SmallChoice arg,
  int64_t bias) {
  if (arg.tag == 1) {
    return (arg.payload.some.value * 4) + bias;
  }
  return bias + 1000;
}

int64_t (*tl_cabi_small_choice_score_ptr)(SmallChoice, int64_t) =
  tl_cabi_small_choice_score_indirect;

SmallChoice tl_cabi_small_choice_make(int64_t seed, int64_t make_some) {
  SmallChoice out;
  out.tag = make_some ? 1 : 0;
  out.payload.some.value = seed + 40;
  return out;
}

int64_t tl_cabi_wrapped_small_score(WrappedSmall arg, int64_t bias) {
  if (arg.choice.tag == 1) {
    return (arg.choice.payload.some.value * 7) + bias;
  }
  return bias + 4000;
}

WrappedSmall tl_cabi_wrapped_small_make(int64_t seed) {
  WrappedSmall out;
  out.choice.tag = 1;
  out.choice.payload.some.value = seed + 60;
  return out;
}

int64_t tl_cabi_float_choice_score(FloatChoice arg, int64_t bias) {
  if (arg.tag == 1) {
    return (int64_t)(arg.payload.some.value * 10.0) + bias;
  }
  return bias + 2000;
}

static int64_t tl_cabi_float_choice_score_indirect(
  FloatChoice arg,
  int64_t bias) {
  if (arg.tag == 1) {
    return (int64_t)(arg.payload.some.value * 20.0) + bias;
  }
  return bias + 2000;
}

int64_t (*tl_cabi_float_choice_score_ptr)(FloatChoice, int64_t) =
  tl_cabi_float_choice_score_indirect;

FloatChoice tl_cabi_float_choice_make(double seed, int64_t make_some) {
  FloatChoice out;
  out.tag = make_some ? 1 : 0;
  out.payload.some.value = seed + 1.5;
  return out;
}

int64_t tl_cabi_wide_choice_score(WideChoice arg, uint64_t salt) {
  if (arg.tag == 1) {
    return (int64_t)((arg.payload.some.lo * 5) + (arg.payload.some.hi * 7) + salt);
  }
  return (int64_t)(salt + 3000);
}

static int64_t tl_cabi_wide_choice_score_indirect(
  WideChoice arg,
  uint64_t salt) {
  if (arg.tag == 1) {
    return (int64_t)((arg.payload.some.lo * 11) + (arg.payload.some.hi * 13) + salt);
  }
  return (int64_t)(salt + 3000);
}

int64_t (*tl_cabi_wide_choice_score_ptr)(WideChoice, uint64_t) =
  tl_cabi_wide_choice_score_indirect;

WideChoice tl_cabi_wide_choice_make(uint64_t seed) {
  WideChoice out;
  out.tag = 1;
  out.payload.some.lo = seed + 11;
  out.payload.some.hi = seed + 22;
  return out;
}
