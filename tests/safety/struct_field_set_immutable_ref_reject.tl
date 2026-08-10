(defstruct Pair
  (x i64)
  (y i64))

(define (bad [p : (& p Pair)]) : unit
  (set! p.x 3))

(define (main) : unit
  unit)