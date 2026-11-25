;: Generated equality rejects borrowed fields whose lifetime is not value structure.
(import stdlib.eq)

(defstruct EqReferenceHolder
  (item (& program i64)))

(eq.gen EqReferenceHolder)

(import (eq.eq EqReferenceHolder) as reference-eq)

(define (main) : i64
  42)