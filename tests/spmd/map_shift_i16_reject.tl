;; #5679: narrow direct-map shifts stage with a stable operator/type/backend
;; diagnostic instead of the generic SIMD-pattern fallback.
(import stdlib.array)

(define (main) : i64
  (let
    [n : i64 17]
    [xs : (__tl_dyn-array i16) (array.make-array i16 n)]
    [out : (__tl_dyn-array i16) (array.make-array i16 n)]
    [copy : (__tl_dyn-array i16) (array.make-array i16 n)]
    (begin
      (foreach
        ([i : i64 0 n])
        (begin
          (set! (array-ref out i) (shl (array-ref xs i) 1))
          (set! (array-ref copy i) (array-ref xs i))))
      42)))