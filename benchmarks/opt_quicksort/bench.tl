;# benchmarks/opt_quicksort/bench.tl - recursive quicksort workload.
;#
;# Equivalent to benchmarks/opt_quicksort/baseline.c. Each round refills an
;# `(Array i64)` with a round-seeded LCG pattern (masked into a small
;# non-negative range), sorts it in place with a Lomuto-partition quicksort, and
;# folds an order-sensitive rolling hash of the sorted array into a wrapping
;# accumulator. Exercises non-tail recursion, array bounds-checked indexing, and
;# in-place swaps. The array size and round count are runtime arguments, so the
;# whole computation cannot be constant-folded. Results stay in `[0, prime)` so
;# the printed decimal matches the C baseline's `%lld`.
(import "stdlib/io.tl")
(import "stdlib/string.tl")

(define qs-modulus : i64
  1000000007)
(define qs-mask : i64
  2147483647)

(define (qs-swap [xs : (Array i64)] [i : i64] [j : i64]) : unit
  (let
    [tmp : i64 (array-ref xs i)]
    (begin
      (array-set! xs i (array-ref xs j))
      (array-set! xs j tmp))))

(define (qs-partition [xs : (Array i64)] [lo : i64] [hi : i64]) : i64
  (let
    [pivot : i64 (array-ref xs hi)]
    [store : i64 lo]
    [scan : i64 lo]
    (begin
      (while (< scan hi)
        (begin
          (if (< (array-ref xs scan) pivot)
            (begin
              (qs-swap xs store scan)
              (set! store (+ store 1)))
            unit)
          (set! scan (+ scan 1))))
      (qs-swap xs store hi)
      store)))

(define (qs-sort [xs : (Array i64)] [lo : i64] [hi : i64]) : unit
  (if (< lo hi)
    (let
      [pivot-index : i64 (qs-partition xs lo hi)]
      (begin
        (qs-sort xs lo (- pivot-index 1))
        (qs-sort xs (+ pivot-index 1) hi)))
    unit))

(define (qs-fill [xs : (Array i64)] [n : i64] [seed : i64]) : i64
  (let
    [i : i64 0]
    [state : i64 seed]
    (begin
      (while (< i n)
        (begin
          (set! state (bit-and (+ (* state 1103515245) 12345) qs-mask))
          (array-set! xs i state)
          (set! i (+ i 1))))
      state)))

(define (qs-checksum [xs : (Array i64)] [n : i64]) : i64
  (let
    [i : i64 0]
    [hash : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! hash (% (+ (* hash 131) (array-ref xs i)) qs-modulus))
          (set! i (+ i 1))))
      hash)))

(define (qs-bench [n : i64] [rounds : i64]) : i64
  (let
    [xs : (Array i64) (make-array i64 n)]
    [round : i64 0]
    [acc : i64 0]
    [seed : i64 1]
    (begin
      (while (< round rounds)
        (begin
          (set! seed (qs-fill xs n (+ seed (* round 2654435761))))
          (qs-sort xs 0 (- n 1))
          (set! acc (% (+ acc (qs-checksum xs n)) qs-modulus))
          (set! round (+ round 1))))
      acc)))

(define (main) : i64
  (let
    [n : i64 (string->int (arg 1))]
    [rounds : i64 (string->int (arg 2))]
    (begin
      (print (qs-bench n rounds))
      0)))