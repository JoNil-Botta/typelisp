;; Byte products are vectorizable, but byte reduction results do not yet have
;; a horizontal SIMD reduction. Type checking diagnoses that exact unsupported
;; result surface before any backend could silently scalarize it.
(define (product-sum
  [a : (__tl_dyn-array i8)]
  [b : (__tl_dyn-array i8)]
  [n : i64]) : i8
  (spmd-reduce
    sum
    ([i : i64 0 n])
    (cast 0 : i8)
    (* (array-ref a i) (array-ref b i))))

(define (main) : i64
  (let
    [a : (__tl_dyn-array i8) (__tl_make-array i8 9)]
    [b : (__tl_dyn-array i8) (__tl_make-array i8 9)]
    [i : i64 0]
    (begin
      (while (< i 9)
        (begin
          (set! (array-ref a i) (cast (+ i 1) : i8))
          (set! (array-ref b i) (cast (+ i 2) : i8))
          (set! i (+ i 1))))
      (if (= (product-sum a b 9) (cast 74 : i8))
        42
        1))))