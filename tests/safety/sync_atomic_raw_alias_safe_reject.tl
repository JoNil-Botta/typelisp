;; A compatibility extern alias must retain the raw atomic helper's effect.
(import stdlib.sync)

(define (main) : i64
  (sync.atomic-i64-load-ptr (ptr-null : (Ptr i64))))