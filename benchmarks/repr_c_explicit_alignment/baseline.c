#include <stddef.h>
#include <stdint.h>

/* C11 `_Alignas` equivalents of tests/integration/repr_c_explicit_alignment.tl.
   A struct-level alignment is written on the first member, which raises the
   aggregate alignment and rounds its size exactly as a type attribute does. */
struct CanFrame {
  uint32_t can_id;
  uint8_t len;
  uint8_t pad;
  uint8_t res0;
  uint8_t len8_dlc;
  _Alignas(8) uint8_t data[8];
};

struct Prefix {
  _Alignas(8) uint8_t kind;
  _Alignas(8) uint8_t schedule;
};

struct Outer {
  uint8_t tag;
  struct Prefix inner;
  uint16_t tail;
};

struct Shelf {
  struct Prefix items[3];
  uint8_t after;
};

struct Halves {
  uint8_t a;
  _Alignas(4) uint16_t b;
  uint8_t c;
};

int64_t tl_align_c_layout(int64_t which) {
  switch (which) {
    case 0: return (int64_t)sizeof(struct CanFrame);
    case 1: return (int64_t)_Alignof(struct CanFrame);
    case 2: return (int64_t)offsetof(struct CanFrame, data);
    case 3: return (int64_t)sizeof(struct Prefix);
    case 4: return (int64_t)_Alignof(struct Prefix);
    case 5: return (int64_t)offsetof(struct Prefix, schedule);
    case 6: return (int64_t)sizeof(struct Outer);
    case 7: return (int64_t)_Alignof(struct Outer);
    case 8: return (int64_t)offsetof(struct Outer, inner);
    case 9: return (int64_t)offsetof(struct Outer, tail);
    case 10: return (int64_t)sizeof(struct Shelf);
    case 11: return (int64_t)offsetof(struct Shelf, after);
    case 12: return (int64_t)sizeof(struct Halves);
    case 13: return (int64_t)_Alignof(struct Halves);
    case 14: return (int64_t)offsetof(struct Halves, b);
    case 15: return (int64_t)offsetof(struct Halves, c);
    default: return -1;
  }
}

int64_t tl_align_c_fill_frame(struct CanFrame *frame) {
  int i;
  frame->can_id = 0x123;
  frame->len = 8;
  for (i = 0; i < 8; i++) {
    frame->data[i] = (uint8_t)(i + 1);
  }
  return 77;
}

int64_t tl_align_c_sum_shelf(const struct Shelf *shelf) {
  int64_t sum = shelf->after;
  int i;
  for (i = 0; i < 3; i++) {
    sum += shelf->items[i].kind * 10 + shelf->items[i].schedule;
  }
  return sum;
}

int64_t tl_align_c_sum_halves(const struct Halves *halves) {
  return halves->a + halves->b * 16 + halves->c * 4096;
}

int64_t tl_align_c_sum_outer(const struct Outer *outer) {
  return outer->tag + outer->inner.kind * 16 + outer->inner.schedule * 256 +
         outer->tail * 4096;
}

/* By value: `struct Prefix` is two INTEGER eightbytes on SysV, with `schedule`
   alone in the second, and goes by reference on Win64. `struct Halves` fits
   one eightbyte on both. */
struct Prefix tl_align_c_make_prefix(int64_t kind, int64_t schedule) {
  struct Prefix prefix;
  prefix.kind = (uint8_t)kind;
  prefix.schedule = (uint8_t)schedule;
  return prefix;
}

int64_t tl_align_c_prefix_value(struct Prefix prefix) {
  return prefix.kind * 16 + prefix.schedule;
}

struct Halves tl_align_c_make_halves(int64_t a, int64_t b, int64_t c) {
  struct Halves halves;
  halves.a = (uint8_t)a;
  halves.b = (uint16_t)b;
  halves.c = (uint8_t)c;
  return halves;
}

int64_t tl_align_c_halves_value(struct Halves halves) {
  return halves.a + halves.b * 16 + halves.c * 4096;
}
