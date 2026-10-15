;; Reading an intermediate receiver traps before the final store's value runs.
(defstruct Wide
  (a i64)
  (b i64)
  (c i64)
  (d i64))

(define (main) : i64
  (let
    [a : (Array (Array Wide 1) 1) (array (array (Wide 1 2 3 4)))]
    (set! (array-ref (array-ref a 1) 0) (Wide (shl (cast 1 : i64) -1) 2 3 4))
    0))