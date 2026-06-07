;; SPMD masked-if corpus (#2205): direct-index AVX-512 masked branches over
;; i64 lanes, including a non-multiple-of-8 tail.
(define (init-xs [xs : (Array i64)]) : unit
  (begin
    (array-set! xs 0 -3)
    (array-set! xs 1 4)
    (array-set! xs 2 -1)
    (array-set! xs 3 0)
    (array-set! xs 4 7)
    (array-set! xs 5 -8)
    (array-set! xs 6 2)
    (array-set! xs 7 9)
    (array-set! xs 8 -5)
    (array-set! xs 9 1)
    (array-set! xs 10 6)
    (array-set! xs 11 -2)
    (array-set! xs 12 3)))

(define (fill-masked [xs : (Array i64)] [out : (Array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (if (< (array-ref xs i) 0)
      (array-set! out i 0)
      (array-set! out i (+ (array-ref xs i) 1)))))

(define (fill-scalar [xs : (Array i64)] [out : (Array i64)] [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (if (< (array-ref xs i) 0)
          (array-set! out i 0)
          (array-set! out i (+ (array-ref xs i) 1)))
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
    [n : i64 13]
    [xs : (Array i64) (make-array i64 n)]
    [got : (Array i64) (make-array i64 n)]
    [want : (Array i64) (make-array i64 n)]
    (begin
      (init-xs xs)
      (fill-masked xs got n)
      (fill-scalar xs want n)
      (if (arrays-eq got want n)
        42
        1))))