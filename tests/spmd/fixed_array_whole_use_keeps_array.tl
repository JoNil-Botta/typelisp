;; A fixed array used whole inside a `foreach` body keeps the array binding
;; (#8346): here it is also borrowed as `(& table)` for a call, so the body is
;; not given a Slice view and SIMD modes report the ordinary shape diagnostic
;; instead of passing a view where the callee expects the array. Scalar mode
;; runs the reference semantics and exits 23.
(define table : (Array i64 8)
  (array 10 11 12 13 14 15 16 17))

(define (first [t : (& t (Array i64 8))]) : i64
  (array-ref t 0))

(define (main) : i64
  (let
    [out : (Array i64 8) (make-array i64 8)]
    (foreach
      ([i : i64 0 8])
      (set! (array-ref out i) (+ (array-ref table i) (first (& table)))))
    (array-ref out 3)))