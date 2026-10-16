(defstruct Pair
  (a i64)
  (b i64))

(define (main) : i64
  (let
    [p : Pair (Pair 1 2)]
    [view : (& p Pair) (& p)]
    (set!
      p.a
      (begin
        (set! p (Pair 7 8))
        5))
    (+ view.a view.b)))