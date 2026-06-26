;; SPMD varying-match corpus (#3753): a match inside a masked-if branch.
(import stdlib.array)

(define (init-xs [xs : (Array i64)] [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (array.array-set! xs i (- i 5))
        (set! i (+ i 1))))))

(define (fill-match [xs : (Array i64)] [out : (Array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (if (> (array.array-ref xs i) 0)
      (match (> (array.array-ref xs i) 1)
        [true (array.array-set! out i 1)]
        [false (array.array-set! out i 2)])
      (array.array-set! out i 0))))

(define (fill-scalar [xs : (Array i64)] [out : (Array i64)] [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (if (> (array.array-ref xs i) 0)
          (match (> (array.array-ref xs i) 1)
            [true (array.array-set! out i 1)]
            [false (array.array-set! out i 2)])
          (array.array-set! out i 0))
        (set! i (+ i 1))))))

(define (arrays-eq [a : (Array i64)] [b : (Array i64)] [n : i64]) : bool
  (let
    [i : i64 0]
    [ok : bool true]
    (begin
      (while (< i n)
        (begin
          (if (!= (array.array-ref a i) (array.array-ref b i))
            (set! ok false)
            unit)
          (set! i (+ i 1))))
      ok)))

(define (main) : i64
  (let
    [n : i64 13]
    [xs : (Array i64) (array.make-array i64 n)]
    [got : (Array i64) (array.make-array i64 n)]
    [want : (Array i64) (array.make-array i64 n)]
    (begin
      (init-xs xs n)
      (fill-match xs got n)
      (fill-scalar xs want n)
      (if (arrays-eq got want n)
        42
        1))))