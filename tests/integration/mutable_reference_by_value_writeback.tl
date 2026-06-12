;; #2721: explicit mutable borrows of by-value/register-resident locals passed
;; as call arguments materialize into stack scratch and write back after the
;; call.
(defstruct Pair
  (x i64)
  (y i64))

(define (set-pair-x! [p : (&mut p Pair)] [value : i64]) : unit
  (set! (struct-get p x) value))

(define (touch-scalar! [n : (&mut n i64)]) : unit
  unit)

(define (main) : i64
  (let
    [p : Pair (Pair 7 35)]
    [n : i64 41]
    (begin
      (set-pair-x! (&mut p) 40)
      (touch-scalar! (&mut n))
      (if (and (= (struct-get p x) 40) (= (struct-get p y) 35) (= n 41))
        42
        1))))