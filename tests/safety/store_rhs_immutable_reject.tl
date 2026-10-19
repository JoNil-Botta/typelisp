(defstruct Pair
  (a i64))

(define (bad [p : (& p Pair)]) : i64
  (set! p.a (return 42))
  0)

(define (main) : i64
  0)