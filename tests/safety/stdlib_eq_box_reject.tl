;: Generated equality rejects boxed values so recursive nominal values remain finite.
(import stdlib.eq)
(import (eq.eq (Box i64)) as box-eq)

(define (main) : i64
  42)