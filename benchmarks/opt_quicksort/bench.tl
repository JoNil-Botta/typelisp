;# benchmarks/opt_quicksort/bench.tl - recursive quicksort workload.
;#
;# Equivalent to benchmarks/opt_quicksort/baseline.c. Each round refills an
;# direct access to a `Vec`'s inferred backing storage with a round-seeded LCG
;# pattern (masked into a small
;# non-negative range), sorts it in place with a Lomuto-partition quicksort, and
;# folds an order-sensitive rolling hash of the sorted array into a wrapping
;# accumulator. Exercises non-tail recursion, array bounds-checked indexing, and
;# in-place swaps. The array size and round count are runtime arguments, so the
;# whole computation cannot be constant-folded. Results stay in `[0, prime)` so
;# the printed decimal matches the C baseline's `%lld`.
(import stdlib.array)
(import stdlib.io)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector i64) as i64vec)

(define qs-modulus : i64
  1000000007)
(define qs-mask : i64
  2147483647)

(define (qs-swap [xs : (&mut xs i64vec.Vec)] [i : i64] [j : i64]) : unit
  (let
    [slots (i64vec.slots-mut xs)]
    [tmp : i64 (array-ref slots i)]
    (begin
      (array-set! slots i (array-ref slots j))
      (array-set! slots j tmp))))

(define (qs-partition [xs : (&mut xs i64vec.Vec)] [lo : i64] [hi : i64]) : i64
  (let
    [slots (i64vec.slots-mut xs)]
    [pivot : i64 (array-ref slots hi)]
    [store : i64 lo]
    [scan : i64 lo]
    (begin
      (while (< scan hi)
        (begin
          (if (< (array-ref slots scan) pivot)
            (begin
              (let
                [tmp : i64 (array-ref slots store)]
                (begin
                  (array-set! slots store (array-ref slots scan))
                  (array-set! slots scan tmp)))
              (set! store (+ store 1)))
            unit)
          (set! scan (+ scan 1))))
      (let
        [tmp : i64 (array-ref slots store)]
        (begin
          (array-set! slots store (array-ref slots hi))
          (array-set! slots hi tmp)))
      store)))

(define (qs-sort [xs : (&mut xs i64vec.Vec)] [lo : i64] [hi : i64]) : unit
  (if (< lo hi)
    (let
      [pivot-index : i64 (qs-partition xs lo hi)]
      (begin
        (qs-sort xs lo (- pivot-index 1))
        (qs-sort xs (+ pivot-index 1) hi)))
    unit))

(define (qs-fill [xs : (&mut xs i64vec.Vec)] [n : i64] [seed : i64]) : i64
  (let
    [slots (i64vec.slots-mut xs)]
    [i : i64 0]
    [state : i64 seed]
    (begin
      (while (< i n)
        (begin
          (set! state (bit-and (+ (* state 1103515245) 12345) qs-mask))
          (array-set! slots i state)
          (set! i (+ i 1))))
      state)))

(define (qs-checksum [xs : (&mut xs i64vec.Vec)] [n : i64]) : i64
  (let
    [slots (i64vec.slots-mut xs)]
    [i : i64 0]
    [hash : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! hash (% (+ (* hash 131) (array-ref slots i)) qs-modulus))
          (set! i (+ i 1))))
      hash)))

(define (qs-bench [n : i64] [rounds : i64]) : i64
  (let
    [xs : i64vec.Vec (i64vec.Vec (array.make-array i64 n) n)]
    [round : i64 0]
    [acc : i64 0]
    [seed : i64 1]
    (begin
      (while (< round rounds)
        (begin
          (set! seed (qs-fill (&mut xs) n (+ seed (* round 2654435761))))
          (qs-sort (&mut xs) 0 (- n 1))
          (set! acc (% (+ acc (qs-checksum (&mut xs) n)) qs-modulus))
          (set! round (+ round 1))))
      acc)))

(define (main) : i64
  (let
    [n : i64 (string.>int (io.arg 1))]
    [rounds : i64 (string.>int (io.arg 2))]
    (begin
      (io.print (qs-bench n rounds))
      0)))