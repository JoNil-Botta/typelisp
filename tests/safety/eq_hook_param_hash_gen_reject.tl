;; `hash.gen` never calls the owner equality hook it validates, so a hook whose
;; parameters are not shared borrows of the owner type is rejected up front.
(import stdlib.eq)
(import stdlib.hash)

(defstruct Point
  (x i64))

(define (eq-point [left : i64] [right : i64]) : bool
  (= left right))

(hash.gen Point)

(define (main) : i64
  0)