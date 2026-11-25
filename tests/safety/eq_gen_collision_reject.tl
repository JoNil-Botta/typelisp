;; `eq.gen` rejects a hand-written hook of the same name.
(import stdlib.eq)

(defstruct Point
  (x i64))

(define (eq-point [left : (& left Point)] [right : (& right Point)]) : bool
  true)

(eq.gen Point)

(define (main) : i64
  0)