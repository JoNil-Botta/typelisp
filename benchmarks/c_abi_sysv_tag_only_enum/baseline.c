#include <stdint.h>

typedef struct {
  int64_t tag;
} Status;

Status tl_cabi_status_pick(Status first, Status second, int64_t choose_second) {
  return choose_second ? second : first;
}

int64_t tl_cabi_status_eq(Status left, Status right) {
  return left.tag == right.tag ? 1 : 0;
}

static Status tl_cabi_status_pick_indirect(
  Status first,
  Status second,
  int64_t choose_second) {
  return tl_cabi_status_pick(first, second, choose_second);
}

Status (*tl_cabi_status_pick_ptr)(Status, Status, int64_t) =
  tl_cabi_status_pick_indirect;
