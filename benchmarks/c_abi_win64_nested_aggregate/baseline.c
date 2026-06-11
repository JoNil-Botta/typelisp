#include <stdint.h>

/* MSVC ABI float-use marker needed for -NODEFAULTLIB integration links. */
int _fltused = 0;

typedef struct {
  uint8_t value;
} InnerByteC;

typedef struct {
  InnerByteC inner;
} OuterByteC;

typedef struct {
  uint8_t lo;
  uint8_t hi;
} InnerPairDefault;

typedef struct {
  InnerPairDefault inner;
} OuterPairC;

typedef struct {
  uint16_t lo;
  uint16_t hi;
} InnerWordC;

typedef struct {
  InnerWordC inner;
} OuterWordDefault;

typedef struct {
  double value;
} InnerDoubleC;

typedef struct {
  InnerDoubleC inner;
} OuterDoubleC;

typedef struct {
  uint64_t a;
  uint64_t b;
} WideInnerDefault;

typedef struct {
  uint32_t tag;
  WideInnerDefault inner;
  uint32_t tail;
} WideOuterC;

int64_t tl_cabi_nested_byte_score(OuterByteC arg, uint64_t tag) {
  if (tag == UINT64_C(1) && arg.inner.value == 7) {
    return 11;
  }
  if (tag == UINT64_C(2) && arg.inner.value == 9) {
    return 12;
  }
  return -100 - (int64_t)tag;
}

OuterByteC tl_cabi_nested_byte_make(uint64_t tag) {
  OuterByteC out;
  out.inner.value = (tag == UINT64_C(2)) ? 9 : 0;
  return out;
}

int64_t tl_cabi_nested_pair_score(OuterPairC arg, uint64_t tag) {
  if (tag == UINT64_C(3) && arg.inner.lo == 3 && arg.inner.hi == 4) {
    return 21;
  }
  if (tag == UINT64_C(4) && arg.inner.lo == 5 && arg.inner.hi == 6) {
    return 22;
  }
  return -200 - (int64_t)tag;
}

static int64_t tl_cabi_nested_pair_score_indirect(OuterPairC arg, uint64_t tag) {
  if (tag == UINT64_C(5) && arg.inner.lo == 8 && arg.inner.hi == 9) {
    return 23;
  }
  return -300 - (int64_t)tag;
}

int64_t (*tl_cabi_nested_pair_score_ptr)(OuterPairC, uint64_t) =
  tl_cabi_nested_pair_score_indirect;

OuterPairC tl_cabi_nested_pair_make(uint64_t tag) {
  OuterPairC out;
  out.inner.lo = (tag == UINT64_C(4)) ? 5 : 0;
  out.inner.hi = (tag == UINT64_C(4)) ? 6 : 0;
  return out;
}

int64_t tl_cabi_nested_word_score(OuterWordDefault arg, uint64_t tag) {
  if (tag == UINT64_C(6) && arg.inner.lo == 100 && arg.inner.hi == 200) {
    return 31;
  }
  if (tag == UINT64_C(7) && arg.inner.lo == 300 && arg.inner.hi == 400) {
    return 32;
  }
  return -400 - (int64_t)tag;
}

OuterWordDefault tl_cabi_nested_word_make(uint64_t tag) {
  OuterWordDefault out;
  out.inner.lo = (tag == UINT64_C(7)) ? 300 : 0;
  out.inner.hi = (tag == UINT64_C(7)) ? 400 : 0;
  return out;
}

int64_t tl_cabi_nested_double_score(OuterDoubleC arg, uint64_t tag) {
  if (tag == UINT64_C(8) && arg.inner.value == 1.5) {
    return 41;
  }
  if (tag == UINT64_C(9) && arg.inner.value == 2.5) {
    return 42;
  }
  if (tag == UINT64_C(10) && arg.inner.value == 3.5) {
    return 43;
  }
  return -500 - (int64_t)tag;
}

OuterDoubleC tl_cabi_nested_double_make(uint64_t tag) {
  OuterDoubleC out;
  out.inner.value = (tag == UINT64_C(9)) ? 2.5 : 0.0;
  return out;
}

static OuterDoubleC tl_cabi_nested_double_make_indirect(uint64_t tag) {
  OuterDoubleC out;
  out.inner.value = (tag == UINT64_C(10)) ? 3.5 : 0.0;
  return out;
}

OuterDoubleC (*tl_cabi_nested_double_make_ptr)(uint64_t) =
  tl_cabi_nested_double_make_indirect;

int64_t tl_cabi_nested_wide_score(WideOuterC arg, uint64_t tag) {
  if (
    tag == UINT64_C(11) &&
    arg.tag == 11 &&
    arg.inner.a == UINT64_C(1000) &&
    arg.inner.b == UINT64_C(2000) &&
    arg.tail == 12) {
    return 51;
  }
  if (
    tag == UINT64_C(13) &&
    arg.tag == 15 &&
    arg.inner.a == UINT64_C(5000) &&
    arg.inner.b == UINT64_C(6000) &&
    arg.tail == 16) {
    return 53;
  }
  if (
    tag == UINT64_C(14) &&
    arg.tag == 17 &&
    arg.inner.a == UINT64_C(7000) &&
    arg.inner.b == UINT64_C(8000) &&
    arg.tail == 18) {
    return 54;
  }
  return -600 - (int64_t)tag;
}

static int64_t tl_cabi_nested_wide_score_indirect(WideOuterC arg, uint64_t tag) {
  if (
    tag == UINT64_C(12) &&
    arg.tag == 13 &&
    arg.inner.a == UINT64_C(3000) &&
    arg.inner.b == UINT64_C(4000) &&
    arg.tail == 14) {
    return 52;
  }
  return -700 - (int64_t)tag;
}

int64_t (*tl_cabi_nested_wide_score_ptr)(WideOuterC, uint64_t) =
  tl_cabi_nested_wide_score_indirect;

WideOuterC tl_cabi_nested_wide_make(uint64_t tag) {
  WideOuterC out;
  out.tag = (tag == UINT64_C(13)) ? 15 : 0;
  out.inner.a = (tag == UINT64_C(13)) ? UINT64_C(5000) : 0;
  out.inner.b = (tag == UINT64_C(13)) ? UINT64_C(6000) : 0;
  out.tail = (tag == UINT64_C(13)) ? 16 : 0;
  return out;
}

static WideOuterC tl_cabi_nested_wide_make_indirect(uint64_t tag) {
  WideOuterC out;
  out.tag = (tag == UINT64_C(14)) ? 17 : 0;
  out.inner.a = (tag == UINT64_C(14)) ? UINT64_C(7000) : 0;
  out.inner.b = (tag == UINT64_C(14)) ? UINT64_C(8000) : 0;
  out.tail = (tag == UINT64_C(14)) ? 18 : 0;
  return out;
}

WideOuterC (*tl_cabi_nested_wide_make_ptr)(uint64_t) =
  tl_cabi_nested_wide_make_indirect;
