;; Hoisted SIMD vector-bound clamps (#5178). Negative and near-INT64_MAX
;; zero-trip ranges must bypass the vector header without overflowing its
;; index + lanes calculation; an ordinary full gang still runs.
(import stdlib.array)

(define (fill
  [input : (__tl_dyn-array i64)]
  [output : (__tl_dyn-array i64)]
  [start : i64]
  [end : i64]) : unit
  (foreach
    ([i : i64 start end])
    (set! (array-ref output i) (+ (array-ref input i) 1))))

(define (main) : i64
  (let
    [input : (__tl_dyn-array i64) (array.make-array i64 8)]
    [output : (__tl_dyn-array i64) (array.make-array i64 8)]
    [i : i64 0]
    (begin
      (while (< i 8)
        (begin
          (set! (array-ref input i) 41)
          (set! i (+ i 1))))
      (fill input output -4 -4)
      (fill input output 9223372036854775806 9223372036854775806)
      (fill input output 0 8)
      (array-ref output 7))))