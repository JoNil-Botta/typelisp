(defstruct Pair
  (x i64)
  (y i64))

(define (main) : unit
  (set! (struct-get (Pair 1 2) x) 3))