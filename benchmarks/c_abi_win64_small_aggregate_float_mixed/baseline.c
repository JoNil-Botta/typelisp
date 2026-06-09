#include <stdint.h>

/* MSVC ABI float-use marker needed for -NODEFAULTLIB integration links. */
int _fltused = 0;

typedef struct {
  float x;
  float y;
} Vec2;

typedef struct {
  uint32_t tag;
  float value;
} Mix8;

static int vec2_eq(Vec2 arg, float x, float y) {
  return arg.x == x && arg.y == y;
}

static int mix8_eq(Mix8 arg, uint32_t tag, float value) {
  return arg.tag == tag && arg.value == value;
}

int64_t tl_cabi_vec2_score(Vec2 arg, uint64_t tag) {
  if (tag == UINT64_C(7) && vec2_eq(arg, 1.5f, 2.25f)) {
    return 11;
  }
  if (tag == UINT64_C(3) && vec2_eq(arg, 3.5f, 4.25f)) {
    return 12;
  }
  if (tag == UINT64_C(5) && vec2_eq(arg, 5.5f, 9.5f)) {
    return 13;
  }
  return -100 - (int64_t)tag;
}

Vec2 tl_cabi_vec2_make(uint64_t tag) {
  Vec2 out = {3.5f, 4.25f};
  if (tag != UINT64_C(3)) {
    out.x = 0.0f;
    out.y = 0.0f;
  }
  return out;
}

static Vec2 tl_cabi_vec2_make_indirect(uint64_t tag) {
  Vec2 out = {5.5f, 9.5f};
  if (tag != UINT64_C(5)) {
    out.x = 0.0f;
    out.y = 0.0f;
  }
  return out;
}

Vec2 (*tl_cabi_vec2_make_ptr)(uint64_t) = tl_cabi_vec2_make_indirect;

int64_t tl_cabi_mix8_score(Mix8 arg, uint64_t tag) {
  if (tag == UINT64_C(11) && mix8_eq(arg, 11, 6.5f)) {
    return 14;
  }
  if (tag == UINT64_C(17) && mix8_eq(arg, 17, 8.5f)) {
    return 15;
  }
  if (tag == UINT64_C(19) && mix8_eq(arg, 19, 10.5f)) {
    return 16;
  }
  return -200 - (int64_t)tag;
}

Mix8 tl_cabi_mix8_make(uint32_t tag) {
  Mix8 out = {tag, 8.5f};
  if (tag != 17) {
    out.value = 0.0f;
  }
  return out;
}

static Mix8 tl_cabi_mix8_make_indirect(uint32_t tag) {
  Mix8 out = {tag, 10.5f};
  if (tag != 19) {
    out.value = 0.0f;
  }
  return out;
}

Mix8 (*tl_cabi_mix8_make_ptr)(uint32_t) = tl_cabi_mix8_make_indirect;
