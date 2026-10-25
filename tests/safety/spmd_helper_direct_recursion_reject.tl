;; The helper stack rejects a true direct cycle even after sibling reuse works.
(define (cycle [value : i64]) : i64
  (cycle value))

(define (fill
  [xs : (& xs (__tl_dyn-array i64))]
  [out : (&mut out (__tl_dyn-array i64))]) : unit
  (foreach ([i : i64 0 3]) (set! (array-ref out i) (cycle (array-ref xs i)))))

(define (main) : i64
  0)