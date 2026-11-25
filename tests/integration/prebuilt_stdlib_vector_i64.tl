;; A generic stdlib instance imported by the user is generated in the user's
;; program while its non-generic helpers come from the prebuilt sysroot.
(import stdlib.vector)
(import (vector.vector i64) as iv)

(define (main) : i64
  (let
    [values : iv.Vec (iv.new)]
    [index : i64 0]
    [sum : i64 0]
    (while (< index 7)
      (iv.push-ref! (&mut values) (+ index 3))
      (+= index 1))
    (set! index 0)
    (while (< index (iv.len (& values)))
      (+= sum (iv.get (& values) index 0))
      (+= index 1))
    sum))