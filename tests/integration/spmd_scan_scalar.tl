; Scalar reference lowering for `spmd-scan` (#2905). Each scan writes its
; inclusive prefix values to an output array and is checked across empty,
; sub-lane, exact-lane, and tail-sized ranges.
(define (fill-i64 [xs : (Array i64)] [n : i64]) : unit
  (foreach ([i : i64 0 n]) (array-set! xs i (+ i 1))))

(define (fill-i64-mixed [xs : (Array i64)]) : unit
  (begin
    (array-set! xs 0 6)
    (array-set! xs 1 (- 0 2))
    (array-set! xs 2 7)
    (array-set! xs 3 1)
    (array-set! xs 4 (- 0 8))))

(define (fill-i32-mixed [xs : (Array i32)]) : unit
  (begin
    (array-set! xs 0 (cast (- 0 3) : i32))
    (array-set! xs 1 (cast 4 : i32))
    (array-set! xs 2 (cast 1 : i32))
    (array-set! xs 3 (cast 9 : i32))
    (array-set! xs 4 (cast (- 0 2) : i32))))

(define (fill-bool-all [xs : (Array bool)]) : unit
  (begin
    (array-set! xs 0 true)
    (array-set! xs 1 true)
    (array-set! xs 2 false)
    (array-set! xs 3 true)))

(define (fill-bool-any [xs : (Array bool)]) : unit
  (begin
    (array-set! xs 0 false)
    (array-set! xs 1 false)
    (array-set! xs 2 true)
    (array-set! xs 3 false)))

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
    [xs : (Array i64) (make-array i64 9)]
    [out : (Array i64) (make-array i64 9)]
    (begin
      (fill-i64 xs 9)
      (scan-sum-i64 xs out n)
      (cond
        [(and (> n 0) (!= (array-ref out 0) 1)) false]
        [(and (> n 3) (!= (array-ref out 3) 10)) false]
        [(and (> n 4) (!= (array-ref out 4) 15)) false]
        [(and (> n 8) (!= (array-ref out 8) 45)) false]
        [else true]))))

(define (case-min-max-i64) : bool
  (let
    [xs : (Array i64) (make-array i64 5)]
    [out-min : (Array i64) (make-array i64 5)]
    [out-max : (Array i64) (make-array i64 5)]
    (begin
      (fill-i64-mixed xs)
      (scan-min-i64 xs out-min 5)
      (scan-max-i64 xs out-max 5)
      (and
        (= (array-ref out-min 0) 6)
        (= (array-ref out-min 1) (- 0 2))
        (= (array-ref out-min 2) (- 0 2))
        (= (array-ref out-min 3) (- 0 2))
        (= (array-ref out-min 4) (- 0 8))
        (= (array-ref out-max 0) 6)
        (= (array-ref out-max 1) 6)
        (= (array-ref out-max 2) 7)
        (= (array-ref out-max 3) 7)
        (= (array-ref out-max 4) 7)))))

(define (case-i32-ops) : bool
  (let
    [xs : (Array i32) (make-array i32 5)]
    [out-sum : (Array i32) (make-array i32 5)]
    [out-min : (Array i32) (make-array i32 5)]
    [out-max : (Array i32) (make-array i32 5)]
    (begin
      (fill-i32-mixed xs)
      (scan-sum-i32 xs out-sum 5)
      (scan-min-i32 xs out-min 5)
      (scan-max-i32 xs out-max 5)
      (and
        (= (array-ref out-sum 0) (cast (- 0 3) : i32))
        (= (array-ref out-sum 1) (cast 1 : i32))
        (= (array-ref out-sum 2) (cast 2 : i32))
        (= (array-ref out-sum 3) (cast 11 : i32))
        (= (array-ref out-sum 4) (cast 9 : i32))
        (= (array-ref out-min 0) (cast (- 0 3) : i32))
        (= (array-ref out-min 1) (cast (- 0 3) : i32))
        (= (array-ref out-min 2) (cast (- 0 3) : i32))
        (= (array-ref out-min 3) (cast (- 0 3) : i32))
        (= (array-ref out-min 4) (cast (- 0 3) : i32))
        (= (array-ref out-max 0) (cast (- 0 3) : i32))
        (= (array-ref out-max 1) (cast 4 : i32))
        (= (array-ref out-max 2) (cast 4 : i32))
        (= (array-ref out-max 3) (cast 9 : i32))
        (= (array-ref out-max 4) (cast 9 : i32))))))

(define (case-bool-scans) : bool
  (let
    [all-in : (Array bool) (make-array bool 4)]
    [all-out : (Array bool) (make-array bool 4)]
    [any-in : (Array bool) (make-array bool 4)]
    [any-out : (Array bool) (make-array bool 4)]
    (begin
      (fill-bool-all all-in)
      (fill-bool-any any-in)
      (scan-all-bool all-in all-out 4)
      (scan-any-bool any-in any-out 4)
      (and
        (array-ref all-out 0)
        (array-ref all-out 1)
        (not (array-ref all-out 2))
        (not (array-ref all-out 3))
        (not (array-ref any-out 0))
        (not (array-ref any-out 1))
        (array-ref any-out 2)
        (array-ref any-out 3)))))

(define (case-empty-range) : bool
  (let
    [xs : (Array i64) (make-array i64 1)]
    [out : (Array i64) (make-array i64 1)]
    (begin
      (array-set! out 0 7)
      (spmd-scan
        sum
        ([i : i64 0 0] [prefix : i64 99])
        (array-ref xs 99)
        (array-set! out 99 prefix))
      (= (array-ref out 0) 7))))

(define (case-end-bound-evaluated-once) : bool
  (let
    [bounds : (Array i64) (make-array i64 1)]
    [xs : (Array i64) (make-array i64 3)]
    [out : (Array i64) (make-array i64 3)]
    (begin
      (array-set! bounds 0 3)
      (fill-i64 xs 3)
      (spmd-scan
        sum
        ([i : i64 0 (take-bound bounds)] [prefix : i64 0])
        (array-ref xs i)
        (array-set! out i prefix))
      (and (= (array-ref bounds 0) 0) (= (array-ref out 2) 6)))))

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
    [xs : (Array i64) (make-array i64 3)]
    [out : (Array i64) (make-array i64 3)]
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
    [(not (case-min-max-i64)) 5]
    [(not (case-i32-ops)) 6]
    [(not (case-bool-scans)) 7]
    [(not (case-empty-range)) 8]
    [(not (case-end-bound-evaluated-once)) 9]
    [(not (case-prefix-binding-is-scoped)) 10]
    [(not (case-prefix-mutation-does-not-feed-acc)) 11]
    [else 42]))