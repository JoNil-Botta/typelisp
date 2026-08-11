;; #4875: five register-resident mutable arguments force the lowerer's compact
;; writeback vector past its default capacity while preserving every result.
(defstruct Pair
  (x i64)
  (y i64))

(define (set-five!
  [a : (&mut a Pair)]
  [b : (&mut b Pair)]
  [c : (&mut c Pair)]
  [d : (&mut d Pair)]
  [e : (&mut e Pair)]) : unit
  (begin
    (set! a.x 1)
    (set! b.x 2)
    (set! c.x 3)
    (set! d.x 4)
    (set! e.x 5)))

(define (main) : i64
  (let
    [a : Pair (Pair 0 11)]
    [b : Pair (Pair 0 12)]
    [c : Pair (Pair 0 13)]
    [d : Pair (Pair 0 14)]
    [e : Pair (Pair 0 15)]
    (begin
      (set-five! (&mut a) (&mut b) (&mut c) (&mut d) (&mut e))
      (if (and
        (= a.x 1)
        (= b.x 2)
        (= c.x 3)
        (= d.x 4)
        (= e.x 5)
        (= a.y 11)
        (= b.y 12)
        (= c.y 13)
        (= d.y 14)
        (= e.y 15))
        42
        1))))