; Scalar reference lowering for `spmd-reduce` (#499). Each reduction is checked
; against a hand-written foreach/set! loop (the scalar oracle) and against
; known constants, across reduction kinds, result types, and range lengths
; (0, < a likely lane width, and a non-divisible tail). `main` returns 42 only
; when every case agrees.

(define (manual-sum [xs : (Array i64)] [n : i64]) : i64
  (let ([acc : i64 0])
    (begin
      (foreach ([i : i64 0 n])
        (set! acc (+ acc (array-ref xs i))))
      acc)))

(define (reduce-sum [xs : (Array i64)] [n : i64]) : i64
  (spmd-reduce sum ([i : i64 0 n]) 0 (array-ref xs i)))

(define (manual-max [xs : (Array i64)] [n : i64] [seed : i64]) : i64
  (let ([acc : i64 seed])
    (begin
      (foreach ([i : i64 0 n])
        (if (> (array-ref xs i) acc)
            (set! acc (array-ref xs i))
            (set! acc acc)))
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

; bool: are all elements positive? is any element zero?
(define (reduce-all-pos [xs : (Array i64)] [n : i64]) : bool
  (spmd-reduce all ([i : i64 0 n]) true (> (array-ref xs i) 0)))

(define (reduce-any-zero [xs : (Array i64)] [n : i64]) : bool
  (spmd-reduce any ([i : i64 0 n]) false (= (array-ref xs i) 0)))

(define (fill-i64 [xs : (Array i64)] [n : i64]) : unit
  (foreach ([i : i64 0 n])
    (array-set! xs i (+ i 1))))

; Float casts are not supported yet, so seed the f64 array with literals.
(define (fill-f64 [fs : (Array f64)]) : unit
  (begin
    (array-set! fs 0 1.0)
    (array-set! fs 1 2.0)
    (array-set! fs 2 3.0)
    (array-set! fs 3 4.0)
    (array-set! fs 4 5.0)))

(define (fill-i32 [gs : (Array i32)] [n : i64]) : unit
  (foreach ([i : i64 0 n])
    (array-set! gs i (cast (+ i 1) : i32))))

(define (main) : i64
  (let ([n : i64 5]
        [xs : (Array i64) (make-array i64 5)]
        [fs : (Array f64) (make-array f64 5)]
        [gs : (Array i32) (make-array i32 5)])
    (begin
      (fill-i64 xs n)
      (fill-f64 fs)
      (fill-i32 gs n)
      ; xs = gs = [1,2,3,4,5]; fs = [1.0..5.0].
      (if (!= (reduce-sum xs n) (manual-sum xs n))
          1
          (if (!= (reduce-sum xs n) 15)
              2
              ; length 3 (< a likely SIMD lane width)
              (if (!= (reduce-sum xs 3) 6)
                  3
                  ; length 4 (exactly one i64 AVX2 lane width)
                  (if (!= (reduce-sum xs 4) 10)
                      16
                  ; empty range yields the seed, value untouched
                  (if (!= (spmd-reduce sum ([i : i64 0 0]) 99 (array-ref xs i)) 99)
                      4
                      (if (!= (reduce-max xs n 0) (manual-max xs n 0))
                          5
                          (if (!= (reduce-max xs n 0) 5)
                              6
                              ; seed larger than every element wins
                              (if (!= (reduce-max xs n 100) 100)
                                  7
                                  (if (!= (reduce-min xs n 1000) 1)
                                      8
                                      ; seed smaller than every element wins
                                      (if (!= (reduce-min xs n 0) 0)
                                          9
                                          (if (!= (reduce-sum-i32 gs n) (cast 15 : i32))
                                              10
                                              (if (< (reduce-sum-f64 fs n) 14.5)
                                                  11
                                                  (if (> (reduce-sum-f64 fs n) 15.5)
                                                      12
                                                      (if (not (reduce-all-pos xs n))
                                                          13
                                                          (if (reduce-any-zero xs n)
                                                              14
                                                              ; tail length 5 already covered; check all-false on empty
                                                              (if (not (spmd-reduce all ([i : i64 0 0]) true (> (array-ref xs i) 0)))
                                                                  15
                                                                  42)))))))))))))))))))
