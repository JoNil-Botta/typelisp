;: A module value is a static place: element writes, pushes and borrows act
;: on it in place.
(define items : (__tl_dyn-array i64)
  (__tl_make-array i64 2))

(define (grow [target : (&mut target (__tl_dyn-array i64))] [value : i64]) : unit
  (__tl_array-push! target value))

(define (fill) : unit
  (begin
    (set! (array-ref items 0) 20)
    (__tl_array-push! items 2)
    (grow (&mut items) 0)))

(define (main) : i64
  (begin
    (fill)
    (+ (array-ref items 0) (array-ref items 2) (array-length items) 16)))