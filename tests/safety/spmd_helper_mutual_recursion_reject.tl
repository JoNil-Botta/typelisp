;; Mutual helper cycles remain bounded and rejected by the frontend.
(define (left [value : i64]) : i64
  (right value))

(define (right [value : i64]) : i64
  (left value))

(define (fill
  [xs : (& xs (__tl_dyn-array i64))]
  [out : (&mut out (__tl_dyn-array i64))]) : unit
  (foreach ([i : i64 0 3]) (set! (array-ref out i) (left (array-ref xs i)))))

(define (main) : i64
  0)