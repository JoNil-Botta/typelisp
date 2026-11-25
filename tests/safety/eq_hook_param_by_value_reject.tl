;; An owner equality hook must take shared borrows, not values.
(import stdlib.eq)

(defstruct Point
  (x i64))

(define (eq-point [left : Point] [right : Point]) : bool
  (= left.x right.x))

(import (eq.eq Point) as point_eq)

(define (main) : i64
  0)