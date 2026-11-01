;: A module value cannot be written while a mutable borrow of it is reserved.
(define items : (__tl_dyn-array i64)
  (__tl_make-array i64 2))

(define (grow [target : (&mut target (__tl_dyn-array i64))] [value : i64]) : unit
  (__tl_array-push! target value))

(define (run) : unit
  (grow
    (&mut items)
    (begin
      (set! (array-ref items 0) 1)
      2)))

(define (main) : i64
  0)