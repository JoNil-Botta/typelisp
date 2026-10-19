(defstruct Total
  (sum i64)
  (count i64))

(define (main) : i32
  (let
    [xs : (Array i64 8) (array 1 2 3 4 5 6 7 8)]
    [total : Total (Total 0 0)]
    (begin
      (foreach ([i : i64 0 8]) (set! total.sum (array-ref xs i)))
      (cast total.sum : i32))))