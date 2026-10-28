(defstruct Pair
  (x i64)
  (y i64))

(define (pass [v : (&mut i64)]) : (&mut i64)
  v)

(define (probe [shared : (& shared Pair)]) : i64
  (replace! (deref (pass (&mut shared.x))) 5))

(define (main) : i64
  42)