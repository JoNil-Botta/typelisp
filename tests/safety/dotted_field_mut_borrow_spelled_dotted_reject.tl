;: #2610: struct-get and dotted spellings of one mutable field borrow conflict.
(defstruct Pair
  (left i64)
  (right i64))

(define (write-two [_left : (&mut a i64)] [_right : (&mut b i64)]) : unit
  unit)

(define (main) : unit
  (let
    [pair : Pair (Pair 1 2)]
    (write-two (&mut (struct-get pair left)) (&mut pair.left))))