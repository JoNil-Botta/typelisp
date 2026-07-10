;: Generated equality rejects function values.
(import stdlib.eq)
(import (eq.eq (-> i64 i64)) as function-eq)

(define (main) : i64
  42)