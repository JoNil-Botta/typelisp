;; An `spmd-reduce` value reads through a view that is still used: assigning
;; the viewed array before the reduction is rejected.
(define (main) : i64
  (let
    [values : (Array i64 4) (array 1 2 3 4)]
    [view : (& values (Array i64 4)) (& values)]
    (begin
      (set! (array-ref values 0) 9)
      (spmd-reduce sum ([i : i64 0 4]) 0 (array-ref view i)))))