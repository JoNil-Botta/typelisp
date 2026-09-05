;; #7645: 44 bytes leaves an 8-byte plus 4-byte tail after two leading
;; 16-byte chunks. Every chunk must be copied to the outgoing stack.
(defstruct Vector3Mem
  (:repr c)
  (x f32)
  (y f32)
  (z f32))

(defstruct CameraMem
  (:repr c)
  (position Vector3Mem)
  (target Vector3Mem)
  (up Vector3Mem)
  (fovy f32)
  (projection i32))

(extern (camera-mem-ok [camera : CameraMem]) : i64 (:symbol "tl_cabi_camera_mem_ok"))

(define (main) : i64
  (if (=
    (camera-mem-ok
      (CameraMem
        (Vector3Mem 10.0 3.7 14.0)
        (Vector3Mem 10.0 3.0 13.0)
        (Vector3Mem 0.0 1.0 0.0)
        78.0
        0))
    1)
    42
    8))