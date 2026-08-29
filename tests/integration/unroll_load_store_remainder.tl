;; Runtime coverage for the load-AND-store body class of the counted-loop
;; unroller (src/compiler_optimize.tl, opt-unroll-body-copies).
;;
;; That class is rewritten into `guard -> two body copies -> the original block
;; as the remainder loop`, so a trip count the guard cannot cover in whole
;; groups has to finish in the remainder. Every trip count from 1 to 33 is run
;; here, which exercises both parities at every group boundary: an EVEN count
;; leaves the remainder up to two trips, an ODD count leaves one, and n = 1 and
;; n = 2 never enter the unrolled body at all (the guard admits only
;; `seed < bound - 2`).
;;
;; `merge!` is the admitted shape (`dst[i] = dst[i] | src[i]`: a load, a load
;; and a store under one counter). `merge-reference` computes the same
;; checksum without an array store, so it cannot be rewritten by this class;
;; a remainder that dropped, repeated or reordered a trip diverges from it
;; rather than only running at a different speed.
(define (merge!
  [dst : (&mut dst (__tl_dyn-array i64))]
  [src : (& src (__tl_dyn-array i64))]
  [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (set! (array-ref dst i) (bit-or (array-ref dst i) (array-ref src i)))
        (set! i (+ i 1))))))

(define (checksum [items : (& items (__tl_dyn-array i64))] [n : i64]) : i64
  (let
    [acc : i64 0]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! acc (+ (* acc 1000003) (array-ref items i)))
          (set! i (+ i 1))))
      acc)))

;; The same fold with no array store in the loop.
(define (merge-reference [n : i64] [total : i64]) : i64
  (let
    [acc : i64 0]
    [i : i64 0]
    (begin
      (while (< i total)
        (begin
          (set!
            acc
            (+
              (* acc 1000003)
              (if (< i n)
                (bit-or (* i 3) (* i 5))
                (* i 3))))
          (set! i (+ i 1))))
      acc)))

(define (run-one [n : i64] [total : i64]) : bool
  (let
    [dst : (__tl_dyn-array i64) (__tl_make-array i64 total)]
    [src : (__tl_dyn-array i64) (__tl_make-array i64 total)]
    [i : i64 0]
    (begin
      (while (< i total)
        (begin
          (set! (array-ref dst i) (* i 3))
          (set! (array-ref src i) (* i 5))
          (set! i (+ i 1))))
      (merge! (&mut dst) (& src) n)
      (= (checksum (& dst) total) (merge-reference n total)))))

(define (main) : i64
  (let
    [n : i64 1]
    [ok : bool true]
    (begin
      ;; Trip counts 1..33: both parities across the first sixteen groups.
      (while (<= n 33)
        (begin
          (when (not (run-one n 40)) (set! ok false))
          (set! n (+ n 1))))
      (if ok
        42
        1))))