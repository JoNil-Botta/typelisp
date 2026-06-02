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
(define array-len : i64
  4096)

(define base-reps : i64
  300000)

(define (init [a : (Array i64)] [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set! a i (+ i 1))
        (set! i (+ i 1))))))

(define (main) : i64
  (let
    [a : (Array i64) (make-array i64 array-len)]
    [out : (Array i64) (make-array i64 array-len)]
    [reps : i64 (+ base-reps (arg-count))]
    [acc : i64 0]
    [r : i64 0]
    (begin
      (init a array-len)
      (while (< r reps)
        (begin
          (foreach
            ([i : i64 0 array-len])
            (array-set!
              out
              i
              (if (= (bit-and (array-ref a i) 1) 1)
                (+ (array-ref a i) r)
                (- (array-ref a i) r))))
          (set! acc (+ acc (array-ref out (bit-and r (- array-len 1)))))
          (set! r (+ r 1))))
      (bit-and acc 255))))