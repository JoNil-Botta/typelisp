#include <stdint.h>

/* Every callee writes its by-value aggregate parameter through a volatile
 * pointer. On Win64 an aggregate wider than 8 bytes is passed as a pointer to
 * a caller-owned copy, so these stores land in that copy; on SysV they land in
 * the callee's own register spill or the caller's outgoing stack argument.
 * Either way the caller's own value must not change. */

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
