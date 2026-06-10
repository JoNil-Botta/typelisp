#include <stdint.h>

typedef struct {
  int64_t a;
} W8;

W8 tl_cabi_w8_make(int64_t x) {
  W8 w = { x * 2 };
  return w;
}

int64_t tl_cabi_w8_use(W8 w) {
  return w.a + 100;
}
