;: Element reads and stores through a mutable reference returned by a call:
;: the store activates after its right-hand side reads through the same
;: reference.
(defstruct Vec
  (slots (__tl_dyn-array i64))
  (len i64))

(define (slots-mut [v : (&mut v Vec)]) : (&mut v (__tl_dyn-array i64))
  (&mut v.slots))

(define (shift [v : (&mut v Vec)] [j : i64]) : unit
  (let
    [slots (slots-mut v)]
    (set! (array-ref slots j) (array-ref slots (- j 1)))))

(define (shift2 [v : (&mut v Vec)] [j : i64]) : i64
  (let
    [slots (slots-mut v)]
    [value : i64 (array-ref slots j)]
    (begin
      (set! (array-ref slots j) 3)
      value)))

(define (main) : i64
  0)