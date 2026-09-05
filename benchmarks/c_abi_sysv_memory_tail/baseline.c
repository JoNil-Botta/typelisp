#include <stdint.h>

typedef struct {
  float x;
  float y;
  float z;
} Vector3Mem;

typedef struct {
  Vector3Mem position;
  Vector3Mem target;
  Vector3Mem up;
  float fovy;
  int32_t projection;
} CameraMem;

int64_t tl_cabi_camera_mem_ok(CameraMem camera) {
  return camera.position.x == 10.0f && camera.position.y == 3.7f &&
         camera.position.z == 14.0f && camera.target.x == 10.0f &&
         camera.target.y == 3.0f && camera.target.z == 13.0f &&
         camera.up.x == 0.0f && camera.up.y == 1.0f &&
         camera.up.z == 0.0f && camera.fovy == 78.0f &&
         camera.projection == 0;
}
