;; An owner equality hook must take two shared borrows.
(import stdlib.eq)

(defstruct Point
  (x i64))

(define (eq-point [left : (& left Point)]) : bool
  true)

(import (eq.eq Point) as point_eq)

(define (main) : i64
  0)