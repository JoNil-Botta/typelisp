;; Runtime wait is part of the same unsafe OS seam; the public process wrapper
;; remains the only safe entry while child-capability hardening is tracked
;; separately.
(import stdlib.process_runtime)

(define (main) : i64
  (begin
    (process_runtime.tl_process_wait (process_runtime.child 1 2 3))
    0))