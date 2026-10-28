(defstruct Pair
  (x i64)
  (y i64))

(define (probe [shared : (& shared Pair)]) : i64
  (replace! (deref (&mut shared.x)) 5))

(define (main) : i64
  42)