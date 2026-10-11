(define g : (__tl_dyn-array i64)
  (__tl_make-array i64 1))

(define (write!) : unit
  (set! (array-ref g 0) 9))

(define (read-after [r : (& r i64)]) : i64
  (begin
    (write!)
    (deref r)))

(define (main) : i64
  (read-after (& (array-ref g 0))))