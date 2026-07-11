;: Generated equality rejects mutable raw pointer values.
(import stdlib.eq)
(import (eq.eq (MutPtr i64)) as mut-ptr-eq)

(define (main) : i64
  42)