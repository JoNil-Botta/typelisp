;: #2610: dotted and struct-get spellings of one mutable field borrow conflict.
(defstruct Pair
  (left i64)
  (right i64))

(define (write-two [_left : (&mut a i64)] [_right : (&mut b i64)]) : unit
  unit)

(define (main) : unit
  (let
    [pair : Pair (Pair 1 2)]
    (write-two (&mut pair.left) (&mut (struct-get pair left)))))