;# benchmarks/spmd_mask/bench.tl - SPMD masked-conditional micro-benchmark (#1125).
;#
;# Equivalent to benchmarks/spmd_mask/baseline.c. Both run `reps` passes of a
;# data-dependent masked map over a fixed-size array using `foreach`:
;#   out[i] = if (odd a[i]) then a[i] + r else a[i] - r
;# then fold one element of each pass into an accumulator and return its low
;# byte as the process exit code. TypeLisp `+`/`-` wrap modulo 2^64 (SPEC),
;# matching C `uint64_t`, so both programs produce the identical exit code.
;#
;# The per-lane branch depends on the array contents (parity of a[i]), so this
;# exercises a divergent/masked lane body — the SIMD-tail/active-lane case the
;# #937 roadmap and #1014 vector-mask IR target — complementing spmd_map's and
;# spmd_zip's uniform lane bodies. Runtime-opaque trip count and per-pass `r`
;# keep the result deterministic while defeating constant folding and hoisting.
(import stdlib.io)
(import stdlib.vector)
(import (vector.vector i64) as i64v)

(define array-len : i64
  4096)
(define base-reps : i64
  300000)

(define (make-buffer [capacity : i64]) : i64v.Vec
  (let
    [out : i64v.Vec (i64v.with-capacity capacity)]
    [i : i64 0]
    (begin
      (while (< i capacity)
        (begin
          (i64v.push-ref! (&mut out) 0)
          (set! i (+ i 1))))
      out)))

(define (init [a : (&mut a (Slice i64))] [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (set! (array-ref a i) (+ i 1))
        (set! i (+ i 1))))))

(define (mask-kernel
  [a : (& a (Slice i64))]
  [out : (&mut out (Slice i64))]
  [r : i64]) : unit
  (foreach
    ([i : i64 0 array-len])
    (set!
      (array-ref out i)
      (if (= (bit-and (array-ref a i) 1) 1)
        (+ (array-ref a i) r)
        (- (array-ref a i) r)))))

(define (main) : i64
  (let
    [a : i64v.Vec (make-buffer array-len)]
    [out : i64v.Vec (make-buffer array-len)]
    [reps : i64 (+ base-reps (io.arg-count))]
    [acc : i64 0]
    [r : i64 0]
    (begin
      (let
        [init-view : (&mut a (Slice i64)) (i64v.view-mut (&mut a))]
        (init init-view array-len))
      (let
        [a-view : (& a (Slice i64)) (i64v.view (& a))]
        [out-view : (&mut out (Slice i64)) (i64v.view-mut (&mut out))]
        [kernel : (-> (& a (Slice i64)) (&mut out (Slice i64)) i64 unit)
          mask-kernel]
        (begin
          (while (< r reps)
            (begin
              (kernel a-view out-view r)
              (set!
                acc
                (+ acc (array-ref out-view (bit-and r (- array-len 1)))))
              (set! r (+ r 1))))
          (bit-and acc 255))))))