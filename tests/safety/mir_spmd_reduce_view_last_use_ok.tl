;; The view's last use is inside the reduction: assigning the array afterwards
;; is accepted.
(define (main) : i64
  (let
    [values : (Array i64 4) (array 10 10 10 10)]
    [view : (& values (Array i64 4)) (& values)]
    [total : i64 (spmd-reduce sum ([i : i64 0 4]) 2 (array-ref view i))]
    (begin
      (set! (array-ref values 0) 9)
      total)))