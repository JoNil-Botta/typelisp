(defstruct Pair
  (a i64)
  (b i64))

(define (update [p : (& p Pair)]) : unit
  (set!
    p.a
    (begin
      (set! p.b 20)
      7)))

(define (main) : i64
  (let
    [p : Pair (Pair 1 2)]
    (update (& p))
    42))