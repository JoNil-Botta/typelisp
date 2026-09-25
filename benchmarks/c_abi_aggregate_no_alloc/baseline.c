#include <stdint.h>

#if defined(_WIN32)
/* MSVC ABI float-use marker for the freestanding -NODEFAULTLIB link. */
int _fltused = 0;
#endif

/* The by-value parameter callees write their aggregate parameter through a
 * volatile pointer. On Win64 an aggregate wider than 8 bytes is passed as a
 * pointer to a caller-owned copy, so these stores land in that copy; on SysV
 * they land in the callee's own register spill or the caller's outgoing stack
 * argument. Either way the caller's own value must not change.
 *
 * The result makers return aggregates through every C return convention: a
 * hidden result pointer (sret), two registers, and one register holding a
 * value that TypeLisp keeps in memory. */

typedef struct {
  int64_t a;
  int64_t b;
} Pair;

typedef struct {
  int64_t a;
  int64_t b;
  int64_t c;
} Triple;

typedef struct {
  int64_t x;
  int64_t y;
} ChoiceSomePayload;

typedef struct {
  int64_t a;
  double b;
} IntDouble;

typedef struct {
  int32_t a;
  float b;
} IntFloat;

typedef union {
  ChoiceSomePayload some;
} ChoicePayload;

typedef struct {
  int64_t tag;
  ChoicePayload payload;
} Choice;

int64_t tl_win64_byref_pair_bump(Pair p, int64_t k) {
  volatile Pair *q = &p;
  int64_t seen = q->a + q->b;
  q->a = q->a + 1000;
  q->b = q->b + 1000;
  return seen + k;
}

int64_t tl_win64_byref_triple_bump(Triple t, int64_t k) {
  volatile Triple *q = &t;
  int64_t seen = q->a + q->b + q->c;
  q->a = q->a + 1000;
  q->b = q->b + 1000;
  q->c = q->c + 1000;
  return seen + k;
}

int64_t tl_win64_byref_choice_bump(Choice c, int64_t k) {
  volatile Choice *q = &c;
  int64_t seen = (q->tag == 1) ? q->payload.some.x + q->payload.some.y : 500;
  q->tag = 7;
  q->payload.some.x = 1000;
  q->payload.some.y = 1000;
  return seen + k;
}

/* Overwrites x, then reads y: if both arguments shared one copy, y would read
 * the overwritten values. */
int64_t tl_win64_byref_pair_clobber_first(Pair x, Pair y) {
  volatile Pair *qx = &x;
  volatile Pair *qy = &y;
  qx->a = 1000;
  qx->b = 1000;
  return qy->a + qy->b;
}

int64_t tl_win64_byref_triple_clobber_first(Triple x, Triple y) {
  volatile Triple *qx = &x;
  volatile Triple *qy = &y;
  qx->a = 1000;
  qx->b = 1000;
  qx->c = 1000;
  return qy->a + qy->b + qy->c;
}

Pair tl_win64_byref_pair_make(int64_t seed) {
  Pair out;
  out.a = seed;
  out.b = 2 * seed + 1;
  return out;
}

Triple tl_cabi_noalloc_triple_make(int64_t seed) {
  Triple out;
  out.a = seed;
  out.b = seed + 100;
  out.c = seed + 200;
  return out;
}

Triple (*tl_cabi_noalloc_triple_make_ptr)(int64_t) = tl_cabi_noalloc_triple_make;

/* Odd seeds make ChoiceNone. */
Choice tl_cabi_noalloc_choice_make(int64_t seed) {
  Choice out;
  out.tag = seed & 1 ? 0 : 1;
  out.payload.some.x = seed;
  out.payload.some.y = seed * 3;
  return out;
}

IntDouble tl_cabi_noalloc_int_double_make(int64_t seed) {
  IntDouble out;
  out.a = seed;
  out.b = (double)seed + 0.5;
  return out;
}

IntFloat tl_cabi_noalloc_int_float_make(int32_t seed) {
  IntFloat out;
  out.a = seed;
  out.b = (float)seed + 0.25f;
  return out;
}
