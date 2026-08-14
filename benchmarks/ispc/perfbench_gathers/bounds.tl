;; Safety probe for the gather-reduction lowering used by bench.tl. This lives
;; outside the measured benchmark symbol so the timed corpus remains valid.
(import stdlib.vector)
(import (vector.vector f32) as f32v)
(import (vector.vector i64) as i64v)

(define (gathers-bounds-probe
  [values : (&mut values (Slice f32))]
  [offsets : (&mut offsets (Slice i64))]
  [count : i64]) : f32
  (spmd-reduce
    sum
    ([i : i64 0 count])
    (cast 0.0 : f32)
    (array-ref values (+ i (array-ref offsets (program-index))))))

(define (bounds-f32-buffer [capacity : i64]) : f32v.Vec
  (let
    [out : f32v.Vec (f32v.with-capacity capacity)]
    [index : i64 0]
    (begin
      (while (< index capacity)
        (begin
          (f32v.push! out (cast 0.0 : f32))
          (set! index (+ index 1))))
      out)))

(define (bounds-i64-buffer [capacity : i64]) : i64v.Vec
  (let
    [out : i64v.Vec (i64v.with-capacity capacity)]
    [index : i64 0]
    (begin
      (while (< index capacity)
        (begin
          (i64v.push! out 0)
          (set! index (+ index 1))))
      out)))

(define (main) : i64
  (let
    [count : i64 16]
    [values : f32v.Vec (bounds-f32-buffer count)]
    [offsets : i64v.Vec (bounds-i64-buffer count)]
    [values-view : (&mut values (Slice f32)) (f32v.view-mut (&mut values))]
    [offsets-view : (&mut offsets (Slice i64)) (i64v.view-mut (&mut offsets))]
    [i : i64 0]
    (begin
      (while (< i count)
        (begin
          (set! (array-ref values-view i) (cast (+ i 1) : f32))
          (set! (array-ref offsets-view i) 0)
          (set! i (+ i 1))))
      ;; Lane zero is invalid in scalar, AVX2, and AVX-512 modes.
      (set! (array-ref offsets-view 0) count)
      (if (>
        (gathers-bounds-probe values-view offsets-view count)
        (cast 0.0 : f32))
        1
        2))))