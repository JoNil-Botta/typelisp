;: Generated equality rejects raw pointer values.
(import stdlib.eq)
(import (eq.eq (Ptr i64)) as ptr-eq)

(define (main) : i64
  42)