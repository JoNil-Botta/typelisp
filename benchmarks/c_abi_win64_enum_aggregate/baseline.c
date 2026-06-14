#include <stdint.h>

typedef struct {
  int64_t tag;
} Status;

Status tl_win64_status_pick(Status first, Status second, int64_t choose_second) {
  return choose_second ? second : first;
}

static Status tl_win64_status_pick_indirect(
  Status first,
  Status second,
  int64_t choose_second) {
  return tl_win64_status_pick(first, second, choose_second);
}

Status (*tl_win64_status_pick_ptr)(Status, Status, int64_t) =
  tl_win64_status_pick_indirect;

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

int64_t tl_win64_small_score(SmallChoice arg, int64_t bias) {
  if (arg.tag == 1) {
    return arg.payload.some.value + bias + 100;
  }
  return bias + 700;
}

static int64_t tl_win64_small_score_indirect(SmallChoice arg, int64_t bias) {
  return tl_win64_small_score(arg, bias);
}

int64_t (*tl_win64_small_score_ptr)(SmallChoice, int64_t) =
  tl_win64_small_score_indirect;

typedef struct {
  uint64_t n;
  uint64_t weight_bits;
} WideSomePayload;

typedef union {
  WideSomePayload some;
} WideChoicePayload;

typedef struct {
  int64_t tag;
  WideChoicePayload payload;
} WideChoice;

int64_t tl_win64_wide_score(WideChoice arg, uint64_t tag) {
  if (arg.tag == 1) {
    int64_t weight =
      (arg.payload.some.weight_bits == UINT64_C(0x4004000000000000))
        ? 25
        : 1000;
    return (int64_t)arg.payload.some.n + weight + (int64_t)tag;
  }
  return 900 + (int64_t)tag;
}

static int64_t tl_win64_wide_score_indirect(WideChoice arg, uint64_t tag) {
  return tl_win64_wide_score(arg, tag);
}

int64_t (*tl_win64_wide_score_ptr)(WideChoice, uint64_t) =
  tl_win64_wide_score_indirect;

typedef struct {
  uint64_t lo;
  uint64_t hi;
} ReturnPairPayload;

typedef union {
  ReturnPairPayload pair;
} ReturnChoicePayload;

typedef struct {
  int64_t tag;
  ReturnChoicePayload payload;
} ReturnChoice;

ReturnChoice tl_win64_return_choice_make(uint32_t a, uint32_t b, uint64_t tag) {
  ReturnChoice out;
  out.tag = 1;
  out.payload.pair.lo = (uint64_t)a + tag;
  out.payload.pair.hi = (uint64_t)b + (tag * 10);
  return out;
}

static ReturnChoice tl_win64_return_choice_make_indirect(
  uint32_t a,
  uint32_t b,
  uint64_t tag) {
  return tl_win64_return_choice_make(a, b, tag);
}

ReturnChoice (*tl_win64_return_choice_make_ptr)(uint32_t, uint32_t, uint64_t) =
  tl_win64_return_choice_make_indirect;
