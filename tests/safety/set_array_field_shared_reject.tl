(defstruct Pair
  (a i64)
  (b i64))

(define (write [a : (& a (Array Pair 1))]) : unit
  (let
    [p : (& a Pair) (& (array-ref a 0))]
    (set! p.b 70)))

(define (main) : i64
  (let
    [a : (Array Pair 1) (array (Pair 1 2))]
    (write (& a))
    0))