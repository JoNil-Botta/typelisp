; Scalar reference lowering for `spmd-reduce` (#499). Each reduction is checked
; against a hand-written while/set! loop (the scalar oracle) and against
; known constants, across reduction kinds, result types, and range lengths
; (0, < a likely lane width, exactly one lane, and a non-divisible tail).
; `main` returns 42 only when every case agrees.
(import "stdlib/core_macros.tl" module stdlib.core-macros as core)

(define (manual-sum [xs : (Array i64)] [n : i64]) : i64
  (let
    [acc : i64 0]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! acc (+ acc (array-ref xs i)))
          (set! i (+ i 1))))
      acc)))

(define (reduce-sum [xs : (Array i64)] [n : i64]) : i64
  (spmd-reduce sum ([i : i64 0 n]) 0 (array-ref xs i)))

(define (manual-max [xs : (Array i64)] [n : i64] [seed : i64]) : i64
  (let
    [acc : i64 seed]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (if (> (array-ref xs i) acc)
            (set! acc (array-ref xs i))
            (set! acc acc))
          (set! i (+ i 1))))
      acc)))

(define (reduce-max [xs : (Array i64)] [n : i64] [seed : i64]) : i64
  (spmd-reduce max ([i : i64 0 n]) seed (array-ref xs i)))

(define (reduce-min [xs : (Array i64)] [n : i64] [seed : i64]) : i64
  (spmd-reduce min ([i : i64 0 n]) seed (array-ref xs i)))

; f64 sum over an array of 1.0..n.
(define (reduce-sum-f64 [fs : (Array f64)] [n : i64]) : f64
  (spmd-reduce sum ([i : i64 0 n]) 0.0 (array-ref fs i)))

; i32 sum.
(define (reduce-sum-i32 [gs : (Array i32)] [n : i64]) : i32
  (spmd-reduce sum ([i : i64 0 n]) (cast 0 : i32) (array-ref gs i)))

(define (reduce-max-i32 [gs : (Array i32)] [n : i64] [seed : i32]) : i32
  (spmd-reduce max ([i : i64 0 n]) seed (array-ref gs i)))

(define (reduce-min-i32 [gs : (Array i32)] [n : i64] [seed : i32]) : i32
  (spmd-reduce min ([i : i64 0 n]) seed (array-ref gs i)))

; bool: are all elements positive? is any element zero?
(define (reduce-all-pos [xs : (Array i64)] [n : i64]) : bool
  (spmd-reduce all ([i : i64 0 n]) true (> (array-ref xs i) 0)))

(define (reduce-any-zero [xs : (Array i64)] [n : i64]) : bool
  (spmd-reduce any ([i : i64 0 n]) false (= (array-ref xs i) 0)))

(define (fill-i64 [xs : (Array i64)] [n : i64]) : unit
  (foreach ([i : i64 0 n]) (array-set! xs i (+ i 1))))

; Float casts are not supported yet, so seed the f64 array with literals.
(define (fill-f64 [fs : (Array f64)]) : unit
  (begin
    (array-set! fs 0 1.0)
    (array-set! fs 1 2.0)
    (array-set! fs 2 3.0)
    (array-set! fs 3 4.0)
    (array-set! fs 4 5.0)))

(define (fill-i32 [gs : (Array i32)] [n : i64]) : unit
  (foreach ([i : i64 0 n]) (array-set! gs i (cast (+ i 1) : i32))))

(define (fill-signed-i32 [hs : (Array i32)]) : unit
  (begin
    (array-set! hs 0 (cast 3 : i32))
    (array-set! hs 1 (cast (- 0 7) : i32))
    (array-set! hs 2 (cast 12 : i32))
    (array-set! hs 3 (cast (- 0 1) : i32))
    (array-set! hs 4 (cast 0 : i32))
    (array-set! hs 5 (cast 5 : i32))
    (array-set! hs 6 (cast (- 0 9) : i32))
    (array-set! hs 7 (cast 8 : i32))
    (array-set! hs 8 (cast (- 0 4) : i32))
    (array-set! hs 9 (cast 6 : i32))
    (array-set! hs 10 (cast (- 0 20) : i32))))

(define (main) : i64
  (let
    [n : i64 5]
    [xs : (Array i64) (make-array i64 5)]
    [fs : (Array f64) (make-array f64 5)]
    [n32 : i64 11]
    [gs : (Array i32) (make-array i32 11)]
    [hs : (Array i32) (make-array i32 11)]
    (begin
      (fill-i64 xs n)
      (fill-f64 fs)
      (fill-i32 gs n32)
      (fill-signed-i32 hs)
      ; xs = [1,2,3,4,5]; gs = [1..11]; hs has mixed signed i32 values;
      ; fs = [1.0..5.0].
      (core/cond
        (!= (reduce-sum xs n) (manual-sum xs n))
        1
        (!= (reduce-sum xs n) 15)
        2
        (!= (reduce-sum xs 3) 6)
        3
        (!= (reduce-sum xs 4) 10)
        16
        (!= (spmd-reduce sum ([i : i64 0 0]) 99 (array-ref xs i)) 99)
        4
        (!= (reduce-max xs n 0) (manual-max xs n 0))
        5
        (!= (reduce-max xs n 0) 5)
        6
        (!= (reduce-max xs n 100) 100)
        7
        (!= (reduce-min xs n 1000) 1)
        8
        (!= (reduce-min xs n 0) 0)
        9
        (!= (reduce-sum-i32 gs n) (cast 15 : i32))
        10
        (!= (reduce-sum-i32 gs 8) (cast 36 : i32))
        21
        (!= (reduce-sum-i32 gs n32) (cast 66 : i32))
        22
        (< (reduce-sum-f64 fs n) 14.5)
        11
        (> (reduce-sum-f64 fs n) 15.5)
        12
        (not (reduce-all-pos xs n))
        13
        (reduce-any-zero xs n)
        14
        (not (spmd-reduce all ([i : i64 0 0]) true (> (array-ref xs i) 0)))
        15
        (!= (reduce-max-i32 gs n (cast 0 : i32)) (cast 5 : i32))
        17
        (!= (reduce-max-i32 gs n (cast 100 : i32)) (cast 100 : i32))
        18
        (!= (reduce-min-i32 gs n (cast 1000 : i32)) (cast 1 : i32))
        19
        (!= (reduce-min-i32 gs n (cast 0 : i32)) (cast 0 : i32))
        20
        (!= (reduce-max-i32 gs n32 (cast 0 : i32)) (cast 11 : i32))
        23
        (!= (reduce-min-i32 gs n32 (cast 1000 : i32)) (cast 1 : i32))
        24
        (!= (reduce-sum-i32 hs 8) (cast 11 : i32))
        25
        (!= (reduce-sum-i32 hs n32) (cast (- 0 7) : i32))
        26
        (!= (reduce-max-i32 hs n32 (cast (- 0 100) : i32)) (cast 12 : i32))
        27
        (!= (reduce-min-i32 hs n32 (cast 100 : i32)) (cast (- 0 20) : i32))
        28
        42))))