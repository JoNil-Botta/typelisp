;; Constructor operands are evaluated before validating the final element store.
(defstruct Wide
  (a i64)
  (b i64)
  (c i64)
  (d i64))

(define (main) : i64
  (let
    [a : (Array Wide 1) (array (Wide 1 2 3 4))]
    (set! (array-ref a 1) (Wide (shl (cast 1 : i64) -1) 2 3 4))
    0))