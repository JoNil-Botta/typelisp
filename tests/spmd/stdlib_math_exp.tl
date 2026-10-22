;; A transitive stdlib helper with branches and loops must retain scalar
;; reference semantics when called with varying lane arguments.
(import stdlib.math)

(define (my-exp [value : f64]) : f64
  (math.f64-exp value))

(define (fill
  [xs : (& xs (__tl_dyn-array f64))]
  [out : (&mut out (__tl_dyn-array f64))]
  [n : i64]) : unit
  (foreach ([i : i64 0 n]) (set! (array-ref out i) (my-exp (array-ref xs i)))))

(define (main) : i64
  (let
    [xs : (__tl_dyn-array f64) (__tl_make-array f64 13)]
    [out : (__tl_dyn-array f64) (__tl_make-array f64 13)]
    [i : i64 0]
    (while (< i 13)
      (set! (array-ref xs i) (* (cast (- i 6) : f64) 0.125))
      (+= i 1))
    (fill (& xs) (&mut out) 0)
    (fill (& xs) (&mut out) 13)
    (set! i 0)
    (while (< i 13)
      (when
        (!=
          (math.f64-to-bits (array-ref out i))
          (math.f64-to-bits (my-exp (array-ref xs i))))
        (return 1))
      (+= i 1))
    42))