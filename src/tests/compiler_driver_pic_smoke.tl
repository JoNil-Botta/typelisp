;; compiler_driver_pic_smoke.tl - Driver-level smoke for no-entry PIC images.
(import "../compiler_driver_smoke_tests.tl")

(define (main) : i64
  (compiler-driver-pic-smoke-main))