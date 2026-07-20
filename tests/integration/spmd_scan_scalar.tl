; Scalar-reference, AVX2, and AVX-512 lowering for `spmd-scan` (#2905, #5349,
; #5350). Each scan
; writes inclusive prefixes and is checked across empty, sub-lane, exact-lane,
; multiple-gang, and tail-sized ranges.
; Compatibility exception for #3772: spmd-scan value expressions and direct
; scan body writes still use bare array helpers so the checker sees compiler
; array ASTs.
(import stdlib.array)

(define (fill-i64 [xs : (Array i64)] [n : i64]) : unit
  (foreach ([i : i64 0 n]) (array-set! xs i (+ i 1))))

(define (fill-i64-mixed [xs : (Array i64)] [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set!
          xs
          i
          (match (% i 5)
            [0 6]
            [1 (- 0 2)]
            [2 7]
            [3 1]
            [_ (- 0 8)]))
        (set! i (+ i 1))))))

(define (fill-i32-mixed [xs : (Array i32)] [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set!
          xs
          i
          (cast
            (match (% i 5)
              [0 (- 0 3)]
              [1 4]
              [2 1]
              [3 9]
              [_ (- 0 2)])
            : i32))
        (set! i (+ i 1))))))

(define (fill-bools [all-in : (Array bool)] [any-in : (Array bool)] [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set! all-in i (!= (% i 11) 7))
        (array-set! any-in i (= (% i 13) 9))
        (set! i (+ i 1))))))

(define (scan-sum-i64 [xs : (Array i64)] [out : (Array i64)] [n : i64]) : unit
  (spmd-scan
    sum
    ([i : i64 0 n] [prefix : i64 0])
    (array-ref xs i)
    (array-set! out i prefix)))

(define (scan-min-i64 [xs : (Array i64)] [out : (Array i64)] [n : i64]) : unit
  (spmd-scan
    min
    ([i : i64 0 n] [prefix : i64 20])
    (array-ref xs i)
    (array-set! out i prefix)))

(define (scan-max-i64 [xs : (Array i64)] [out : (Array i64)] [n : i64]) : unit
  (spmd-scan
    max
    ([i : i64 0 n] [prefix : i64 (- 0 20)])
    (array-ref xs i)
    (array-set! out i prefix)))

(define (scan-sum-i32 [xs : (Array i32)] [out : (Array i32)] [n : i64]) : unit
  (spmd-scan
    sum
    ([i : i64 0 n] [prefix : i32 (cast 0 : i32)])
    (array-ref xs i)
    (array-set! out i prefix)))

(define (scan-min-i32 [xs : (Array i32)] [out : (Array i32)] [n : i64]) : unit
  (spmd-scan
    min
    ([i : i64 0 n] [prefix : i32 (cast 10 : i32)])
    (array-ref xs i)
    (array-set! out i prefix)))

(define (scan-max-i32 [xs : (Array i32)] [out : (Array i32)] [n : i64]) : unit
  (spmd-scan
    max
    ([i : i64 0 n] [prefix : i32 (cast (- 0 10) : i32)])
    (array-ref xs i)
    (array-set! out i prefix)))

(define (scan-all-bool [xs : (Array bool)] [out : (Array bool)] [n : i64]) : unit
  (spmd-scan
    all
    ([i : i64 0 n] [prefix : bool true])
    (array-ref xs i)
    (array-set! out i prefix)))

(define (scan-any-bool [xs : (Array bool)] [out : (Array bool)] [n : i64]) : unit
  (spmd-scan
    any
    ([i : i64 0 n] [prefix : bool false])
    (array-ref xs i)
    (array-set! out i prefix)))

(define (take-bound [bounds : (Array i64)]) : i64
  (let
    [n : i64 (array-ref bounds 0)]
    (begin
      (array-set! bounds 0 0)
      n)))

(define (case-sum-i64 [n : i64]) : bool
  (let
    [xs : (Array i64) (array.make-array i64 9)]
    [out : (Array i64) (array.make-array i64 9)]
    (begin
      (fill-i64 xs 9)
      (scan-sum-i64 xs out n)
      (cond
        [(and (> n 0) (!= (array-ref out 0) 1)) false]
        [(and (> n 3) (!= (array-ref out 3) 10)) false]
        [(and (> n 4) (!= (array-ref out 4) 15)) false]
        [(and (> n 8) (!= (array-ref out 8) 45)) false]
        [else true]))))

(define (case-min-max-i64 [n : i64]) : bool
  (let
    [xs : (Array i64) (array.make-array i64 9)]
    [out-min : (Array i64) (array.make-array i64 9)]
    [out-max : (Array i64) (array.make-array i64 9)]
    [min-acc : i64 20]
    [max-acc : i64 (- 0 20)]
    [i : i64 0]
    [ok : bool true]
    (begin
      (fill-i64-mixed xs 9)
      (scan-min-i64 xs out-min n)
      (scan-max-i64 xs out-max n)
      (while (< i n)
        (let
          [value : i64 (array-ref xs i)]
          (begin
            (if (< value min-acc)
              (set! min-acc value)
              unit)
            (if (> value max-acc)
              (set! max-acc value)
              unit)
            (if (!= (array-ref out-min i) min-acc)
              (set! ok false)
              unit)
            (if (!= (array-ref out-max i) max-acc)
              (set! ok false)
              unit)
            (set! i (+ i 1)))))
      ok)))

(define (case-i32-ops [n : i64]) : bool
  (let
    [xs : (Array i32) (array.make-array i32 17)]
    [out-sum : (Array i32) (array.make-array i32 17)]
    [out-min : (Array i32) (array.make-array i32 17)]
    [out-max : (Array i32) (array.make-array i32 17)]
    [sum-acc : i32 (cast 0 : i32)]
    [min-acc : i32 (cast 10 : i32)]
    [max-acc : i32 (cast (- 0 10) : i32)]
    [i : i64 0]
    [ok : bool true]
    (begin
      (fill-i32-mixed xs 17)
      (scan-sum-i32 xs out-sum n)
      (scan-min-i32 xs out-min n)
      (scan-max-i32 xs out-max n)
      (while (< i n)
        (let
          [value : i32 (array-ref xs i)]
          (begin
            (set! sum-acc (+ sum-acc value))
            (if (< value min-acc)
              (set! min-acc value)
              unit)
            (if (> value max-acc)
              (set! max-acc value)
              unit)
            (if (!= (array-ref out-sum i) sum-acc)
              (set! ok false)
              unit)
            (if (!= (array-ref out-min i) min-acc)
              (set! ok false)
              unit)
            (if (!= (array-ref out-max i) max-acc)
              (set! ok false)
              unit)
            (set! i (+ i 1)))))
      ok)))

(define (case-wrapping-sums) : bool
  (let
    [i64-in : (Array i64) (array.make-array i64 4)]
    [i64-out : (Array i64) (array.make-array i64 4)]
    [i32-in : (Array i32) (array.make-array i32 8)]
    [i32-out : (Array i32) (array.make-array i32 8)]
    [i64-acc : i64 9223372036854775806]
    [i32-acc : i32 (cast 2147483646 : i32)]
    [i : i64 0]
    [ok : bool true]
    (begin
      (while (< i 8)
        (begin
          (if (< i 4)
            (array-set! i64-in i 1)
            unit)
          (array-set! i32-in i (cast 1 : i32))
          (set! i (+ i 1))))
      (spmd-scan
        sum
        ([lane : i64 0 4] [prefix : i64 9223372036854775806])
        (array-ref i64-in lane)
        (array-set! i64-out lane prefix))
      (spmd-scan
        sum
        ([lane : i64 0 8] [prefix : i32 (cast 2147483646 : i32)])
        (array-ref i32-in lane)
        (array-set! i32-out lane prefix))
      (set! i 0)
      (while (< i 8)
        (begin
          (if (< i 4)
            (begin
              (set! i64-acc (+ i64-acc (array-ref i64-in i)))
              (if (!= (array-ref i64-out i) i64-acc)
                (set! ok false)
                unit))
            unit)
          (set! i32-acc (+ i32-acc (array-ref i32-in i)))
          (if (!= (array-ref i32-out i) i32-acc)
            (set! ok false)
            unit)
          (set! i (+ i 1))))
      ok)))

(define (case-bool-scans [n : i64]) : bool
  (let
    [all-in : (Array bool) (array.make-array bool 65)]
    [all-out : (Array bool) (array.make-array bool 65)]
    [any-in : (Array bool) (array.make-array bool 65)]
    [any-out : (Array bool) (array.make-array bool 65)]
    [all-acc : bool true]
    [any-acc : bool false]
    [i : i64 0]
    [ok : bool true]
    (begin
      (fill-bools all-in any-in 65)
      (scan-all-bool all-in all-out n)
      (scan-any-bool any-in any-out n)
      (while (< i n)
        (begin
          (set! all-acc (and all-acc (array-ref all-in i)))
          (set! any-acc (or any-acc (array-ref any-in i)))
          (if (!= (array-ref all-out i) all-acc)
            (set! ok false)
            unit)
          (if (!= (array-ref any-out i) any-acc)
            (set! ok false)
            unit)
          (set! i (+ i 1))))
      ok)))

(define (case-empty-range) : bool
  (let
    [xs : (Array i64) (array.make-array i64 1)]
    [out : (Array i64) (array.make-array i64 1)]
    (begin
      (array-set! out 0 7)
      (spmd-scan
        sum
        ([i : i64 0 0] [prefix : i64 99])
        (array-ref xs 99)
        (array-set! out 99 prefix))
      (= (array-ref out 0) 7))))

(define (case-extreme-empty-ranges) : bool
  (let
    [xs : (Array i64) (array.make-array i64 1)]
    [out : (Array i64) (array.make-array i64 1)]
    (begin
      (array-set! out 0 17)
      (spmd-scan
        sum
        ([i : i64 (- 0 1) (- 0 1)] [prefix : i64 3])
        (array-ref xs i)
        (array-set! out i prefix))
      (spmd-scan
        sum
        ([i : i64 9223372036854775807 9223372036854775807] [prefix : i64 5])
        (array-ref xs i)
        (array-set! out i prefix))
      (= (array-ref out 0) 17))))

(define (case-end-bound-evaluated-once) : bool
  (let
    [bounds : (Array i64) (array.make-array i64 1)]
    [xs : (Array i64) (array.make-array i64 3)]
    [out : (Array i64) (array.make-array i64 3)]
    (begin
      (array-set! bounds 0 3)
      (fill-i64 xs 3)
      (spmd-scan
        sum
        ([i : i64 0 (take-bound bounds)] [prefix : i64 0])
        (array-ref xs i)
        (array-set! out i prefix))
      (and (= (array-ref bounds 0) 0) (= (array-ref out 2) 6)))))

(define (case-nonzero-seeded-range) : bool
  (let
    [start-box : (Array i64) (array.make-array i64 1)]
    [end-box : (Array i64) (array.make-array i64 1)]
    [init-box : (Array i64) (array.make-array i64 1)]
    [xs : (Array i64) (array.make-array i64 12)]
    [out : (Array i64) (array.make-array i64 12)]
    (begin
      (array-set! start-box 0 2)
      (array-set! end-box 0 11)
      (array-set! init-box 0 5)
      (array-set! out 1 99)
      (fill-i64 xs 12)
      (spmd-scan
        sum
        ([i : i64 (take-bound start-box) (take-bound end-box)]
          [prefix : i64 (take-bound init-box)])
        (array-ref xs i)
        (array-set! out i prefix))
      (and
        (= (array-ref start-box 0) 0)
        (= (array-ref end-box 0) 0)
        (= (array-ref init-box 0) 0)
        (= (array-ref out 1) 99)
        (= (array-ref out 2) 8)
        (= (array-ref out 5) 23)
        (= (array-ref out 9) 57)
        (= (array-ref out 10) 68)))))

(define (case-prefix-binding-is-scoped) : bool
  (=
    (let
      [prefix : i64 7]
      (begin
        (spmd-scan sum ([i : i64 0 3] [prefix : i64 0]) i unit)
        prefix))
    7))

(define (case-prefix-mutation-does-not-feed-acc) : bool
  (let
    [xs : (Array i64) (array.make-array i64 3)]
    [out : (Array i64) (array.make-array i64 3)]
    (begin
      (fill-i64 xs 3)
      (spmd-scan
        sum
        ([i : i64 0 3] [prefix : i64 0])
        (array-ref xs i)
        (begin
          (array-set! out i prefix)
          (set! prefix 0)))
      (and
        (= (array-ref out 0) 1)
        (= (array-ref out 1) 3)
        (= (array-ref out 2) 6)))))

(define (main) : i64
  (cond
    [(not (case-sum-i64 0)) 1]
    [(not (case-sum-i64 3)) 2]
    [(not (case-sum-i64 4)) 3]
    [(not (case-sum-i64 9)) 4]
    [(not (case-min-max-i64 3)) 5]
    [(not (case-min-max-i64 4)) 6]
    [(not (case-min-max-i64 9)) 7]
    [(not (case-i32-ops 5)) 8]
    [(not (case-i32-ops 8)) 9]
    [(not (case-i32-ops 17)) 10]
    [(not (case-wrapping-sums)) 11]
    [(not (case-bool-scans 4)) 12]
    [(not (case-bool-scans 32)) 13]
    [(not (case-bool-scans 65)) 14]
    [(not (case-empty-range)) 15]
    [(not (case-extreme-empty-ranges)) 16]
    [(not (case-end-bound-evaluated-once)) 17]
    [(not (case-nonzero-seeded-range)) 18]
    [(not (case-prefix-binding-is-scoped)) 19]
    [(not (case-prefix-mutation-does-not-feed-acc)) 20]
    [else 42]))