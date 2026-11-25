;; An owner hash hook must take a shared borrow, not an exclusive one.
(import stdlib.eq)
(import stdlib.hash)

(defstruct Point
  (x i64))

(eq.gen Point)

(define (hash-point [value : (&mut value Point)]) : i64
  value.x)

(import (hash.hash Point) as point_hash)

(define (main) : i64
  0)