;: Generated equality rejects dynamic arrays; only fixed arrays are structural.
(import stdlib.eq)
(import (eq.eq (Array i64)) as dynamic-array-eq)

(define (main) : i64
  42)