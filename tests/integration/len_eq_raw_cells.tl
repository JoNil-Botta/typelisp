(import stdlib.io)

(define direct-left : (__tl_dyn-array i64)
  (__tl_make-array i64 1))
(define direct-right : (__tl_dyn-array i64)
  (__tl_make-array i64 1))
(define borrowed-left : (__tl_dyn-array i64)
  (__tl_make-array i64 1))
(define borrowed-right : (__tl_dyn-array i64)
  (__tl_make-array i64 1))
(define reset-cell : (__tl_dyn-array i64)
  (__tl_make-array i64 8))
(define fixed-cell : (__tl_dyn-array i64)
  (__tl_make-array i64 8))

(define (probe-direct [index : i64]) : i64
  (+ (array-ref direct-left index) (array-ref direct-right index)))

(define (probe-borrowed [index : i64]) : i64
  (+ (array-ref borrowed-left index) (array-ref borrowed-right index)))

(define (grow! [cell : (&mut cell (__tl_dyn-array i64))]) : unit
  (__tl_array-push! cell 0))

(define (probe-reset [remaining : i64]) : i64
  (if (< remaining 0)
    0
    (+ (array-ref reset-cell 7) (probe-reset (- remaining 7)))))

(define (main) : i64
  (let
    [case-id : i64 (io.arg-count)]
    (cond
      [(= case-id 2)
        (__tl_array-push! direct-left 0)
        (probe-direct (- case-id 1))]
      [(= case-id 3)
        (grow! (&mut borrowed-left))
        (probe-borrowed (- case-id 2))]
      [(= case-id 4)
        (set! reset-cell (__tl_make-array i64 2))
        (probe-reset case-id)]
      [else (array-ref fixed-cell 8)])))