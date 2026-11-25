;; An owner hash hook must return i64.
(import stdlib.eq)
(import stdlib.hash)

(defstruct Point
  (x i64))

(eq.gen Point)

(define (hash-point [value : (& value Point)]) : bool
  true)

(import (hash.hash Point) as point_hash)

(define (main) : i64
  0)