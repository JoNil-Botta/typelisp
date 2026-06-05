#include <stdint.h>

typedef struct {
  uint8_t r;
  uint8_t g;
  uint8_t b;
  uint8_t a;
} Color;

Color tl_cabi_color_make(uint8_t r, uint8_t g, uint8_t b, uint8_t a) {
  Color c = { r, g, b, a };
  return c;
}

int64_t tl_cabi_color_use(Color c) {
  return (int64_t)c.r + ((int64_t)c.g * 2) + ((int64_t)c.b * 3) + ((int64_t)c.a * 4);
}
