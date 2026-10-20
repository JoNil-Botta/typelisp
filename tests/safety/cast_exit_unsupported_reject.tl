(defstruct Pair
  (a i64)
  (b i64))

(define (probe) : Pair
  (cast (ann (return (Pair 1 2)) : i32) : Pair))

(define (main) : i64
  0)