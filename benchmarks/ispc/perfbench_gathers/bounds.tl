;; Safety probe for the gather-reduction lowering used by bench.tl. This lives
;; outside the measured benchmark symbol so the timed corpus remains valid.
(import stdlib.array)

(define (gathers-bounds-probe
  [values : (Array f32)]
  [offsets : (Array i64)]
  [count : i64]) : f32
  (spmd-reduce
    sum
    ([i : i64 0 count])
    (cast 0.0 : f32)
    (array-ref values (+ i (array-ref offsets (program-index))))))

(define (main) : i64
  (let
    [count : i64 16]
    [values : (Array f32) (array.make-array f32 count)]
    [offsets : (Array i64) (array.make-array i64 count)]
    [i : i64 0]
    (begin
      (while (< i count)
        (begin
          (array-set! values i (cast (+ i 1) : f32))
          (array-set! offsets i 0)
          (set! i (+ i 1))))
      ;; Lane zero is invalid in scalar, AVX2, and AVX-512 modes.
      (array-set! offsets 0 count)
      (if (> (gathers-bounds-probe values offsets count) (cast 0.0 : f32))
        1
        2))))
