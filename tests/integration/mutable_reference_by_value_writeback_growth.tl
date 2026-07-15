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
    (set! (struct-get a x) 1)
    (set! (struct-get b x) 2)
    (set! (struct-get c x) 3)
    (set! (struct-get d x) 4)
    (set! (struct-get e x) 5)))

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
        (= (struct-get a x) 1)
        (= (struct-get b x) 2)
        (= (struct-get c x) 3)
        (= (struct-get d x) 4)
        (= (struct-get e x) 5)
        (= (struct-get a y) 11)
        (= (struct-get b y) 12)
        (= (struct-get c y) 13)
        (= (struct-get d y) 14)
        (= (struct-get e y) 15))
        42
        1))))