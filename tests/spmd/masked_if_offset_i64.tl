;; SPMD masked-if corpus (#2205): shifted contiguous AVX-512 masked branches
;; over i64 lanes, including a non-multiple-of-8 tail.
(define (init-xs [xs : (Array i64)]) : unit
  (begin
    (array-set! xs 0 99)
    (array-set! xs 1 -3)
    (array-set! xs 2 4)
    (array-set! xs 3 -1)
    (array-set! xs 4 0)
    (array-set! xs 5 7)
    (array-set! xs 6 -8)
    (array-set! xs 7 2)
    (array-set! xs 8 9)
    (array-set! xs 9 -5)
    (array-set! xs 10 1)
    (array-set! xs 11 6)
    (array-set! xs 12 -2)))

(define (init-out [out : (Array i64)] [len : i64]) : unit
  (let
    [i : i64 0]
    (while (< i len)
      (begin
        (array-set! out i -99)
        (set! i (+ i 1))))))

(define (fill-masked [xs : (Array i64)] [out : (Array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (if (< (array-ref xs (+ i 1)) 0)
      (array-set! out (+ i 1) 0)
      (array-set! out (+ i 1) (+ (array-ref xs (+ i 1)) 1)))))

(define (fill-scalar [xs : (Array i64)] [out : (Array i64)] [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (if (< (array-ref xs (+ i 1)) 0)
          (array-set! out (+ i 1) 0)
          (array-set! out (+ i 1) (+ (array-ref xs (+ i 1)) 1)))
        (set! i (+ i 1))))))

(define (arrays-eq [a : (Array i64)] [b : (Array i64)] [n : i64]) : bool
  (let
    [i : i64 0]
    [ok : bool true]
    (begin
      (while (< i n)
        (begin
          (if (!= (array-ref a i) (array-ref b i))
            (set! ok false)
            unit)
          (set! i (+ i 1))))
      ok)))

(define (main) : i64
  (let
    [n : i64 12]
    [len : i64 13]
    [xs : (Array i64) (make-array i64 len)]
    [got : (Array i64) (make-array i64 len)]
    [want : (Array i64) (make-array i64 len)]
    (begin
      (init-xs xs)
      (init-out got len)
      (init-out want len)
      (fill-masked xs got n)
      (fill-scalar xs want n)
      (if (arrays-eq got want len)
        42
        1))))