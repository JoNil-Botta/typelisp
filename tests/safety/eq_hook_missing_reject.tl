;; The equality adapter never reflects a nominal type; a missing owner hook is
;; reported with the generator call and the exact manual signature.
(import stdlib.eq)

(defstruct Point
  (x i64))

(import (eq.eq Point) as point_eq)

(define (main) : i64
  0)