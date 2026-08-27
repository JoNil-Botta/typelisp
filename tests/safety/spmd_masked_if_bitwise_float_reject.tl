;; SPMD masked bit-or/bit-xor remain integer-only at the source boundary.
(define (fill
  [xs : (__tl_dyn-array f32)]
  [out : (__tl_dyn-array f32)]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (let
      [x : f32 (array-ref xs i)]
      (set!
        (array-ref out i)
        (if (< x 0.0)
          (bit-or 1.0 x)
          (bit-xor 2.0 x))))))