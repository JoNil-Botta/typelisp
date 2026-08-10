;# benchmarks/opt_quicksort/bench.tl - recursive quicksort workload.
;#
;# Equivalent to benchmarks/opt_quicksort/baseline.c. Each round refills an
;# direct access to a `Vec`'s inferred backing storage with a round-seeded LCG
;# pattern (masked into a small
;# non-negative range), sorts it in place with a Lomuto-partition quicksort, and
;# folds an order-sensitive rolling hash of the sorted array into a wrapping
;# accumulator. The element and accumulator types are u64, mirroring the C
;# baseline's uint64_t so the two programs are semantically equivalent
;# operation for operation (the C modulo is unsigned; so is ours). Exercises non-tail recursion, array bounds-checked indexing, and
;# in-place swaps. The array size and round count are runtime arguments, so the
;# whole computation cannot be constant-folded. Results stay in `[0, prime)` so
;# the printed decimal matches the C baseline's `%lld`.
(import stdlib.array)
(import stdlib.io)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector u64) as u64vec)

(define qs-modulus : u64
  1000000007)
(define qs-mask : u64
  2147483647)

(define (qs-swap [xs : (&mut xs u64vec.Vec)] [i : i64] [j : i64]) : unit
  (let
    [slots (u64vec.slots-mut xs)]
    [tmp : u64 (array-ref slots i)]
    (begin
      (set! (array-ref slots i) (array-ref slots j))
      (set! (array-ref slots j) tmp))))

(define (qs-partition [xs : (&mut xs u64vec.Vec)] [lo : i64] [hi : i64]) : i64
  (let
    [slots (u64vec.slots-mut xs)]
    [pivot : u64 (array-ref slots hi)]
    [store : i64 lo]
    [scan : i64 lo]
    (begin
      (while (< scan hi)
        (begin
          (if (< (array-ref slots scan) pivot)
            (begin
              (let
                [tmp : u64 (array-ref slots store)]
                (begin
                  (set! (array-ref slots store) (array-ref slots scan))
                  (set! (array-ref slots scan) tmp)))
              (set! store (+ store 1)))
            unit)
          (set! scan (+ scan 1))))
      (let
        [tmp : u64 (array-ref slots store)]
        (begin
          (set! (array-ref slots store) (array-ref slots hi))
          (set! (array-ref slots hi) tmp)))
      store)))

(define (qs-sort [xs : (&mut xs u64vec.Vec)] [lo : i64] [hi : i64]) : unit
  (if (< lo hi)
    (let
      [pivot-index : i64 (qs-partition xs lo hi)]
      (begin
        (qs-sort xs lo (- pivot-index 1))
        (qs-sort xs (+ pivot-index 1) hi)))
    unit))

(define (qs-fill [xs : (&mut xs u64vec.Vec)] [n : i64] [seed : u64]) : u64
  (let
    [slots (u64vec.slots-mut xs)]
    [i : i64 0]
    [state : u64 seed]
    (begin
      (while (< i n)
        (begin
          (set! state (bit-and (+ (* state 1103515245) 12345) qs-mask))
          (set! (array-ref slots i) state)
          (set! i (+ i 1))))
      state)))

(define (qs-checksum [xs : (&mut xs u64vec.Vec)] [n : i64]) : u64
  (let
    [slots (u64vec.slots-mut xs)]
    [i : i64 0]
    [hash : u64 0]
    (begin
      (while (< i n)
        (begin
          (set! hash (% (+ (* hash 131) (array-ref slots i)) qs-modulus))
          (set! i (+ i 1))))
      hash)))

(define (qs-bench [n : i64] [rounds : i64]) : u64
  (let
    [xs : u64vec.Vec (u64vec.Vec (array.make-array u64 n) n)]
    [round : i64 0]
    [acc : u64 0]
    [seed : u64 1]
    (begin
      (while (< round rounds)
        (begin
          (set!
            seed
            (qs-fill (&mut xs) n (+ seed (* (cast round : u64) 2654435761))))
          (qs-sort (&mut xs) 0 (- n 1))
          (set! acc (% (+ acc (qs-checksum (&mut xs) n)) qs-modulus))
          (set! round (+ round 1))))
      acc)))

(define (main) : i64
  (let
    [n : i64 (string.>int (io.arg 1))]
    [rounds : i64 (string.>int (io.arg 2))]
    (begin
      (io.print (cast (qs-bench n rounds) : i64))
      0)))