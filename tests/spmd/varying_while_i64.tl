;; SPMD varying-while corpus (#3752): per-lane loop convergence over i64 lanes.
(import stdlib.array)

(define (init-counts [xs : (Array i64)]) : unit
  (begin
    (array.array-set! xs 0 0)
    (array.array-set! xs 1 3)
    (array.array-set! xs 2 1)
    (array.array-set! xs 3 6)
    (array.array-set! xs 4 2)
    (array.array-set! xs 5 0)
    (array.array-set! xs 6 5)
    (array.array-set! xs 7 4)
    (array.array-set! xs 8 1)
    (array.array-set! xs 9 7)
    (array.array-set! xs 10 2)
    (array.array-set! xs 11 0)
    (array.array-set! xs 12 3)))

(define (fill-vwhile [work : (Array i64)] [out : (Array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (while (> (array.array-ref work i) 0)
      (begin
        (array.array-set! out i (+ (array.array-ref out i) 1))
        (array.array-set! work i (+ (array.array-ref work i) -1))))))

(define (fill-scalar [work : (Array i64)] [out : (Array i64)] [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (while (> (array.array-ref work i) 0)
          (begin
            (array.array-set! out i (+ (array.array-ref out i) 1))
            (array.array-set! work i (+ (array.array-ref work i) -1))))
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
    [work : (Array i64) (array.make-array i64 n)]
    [work-ref : (Array i64) (array.make-array i64 n)]
    [got : (Array i64) (array.make-array i64 n)]
    [want : (Array i64) (array.make-array i64 n)]
    (begin
      (init-counts work)
      (init-counts work-ref)
      (fill-vwhile work got n)
      (fill-scalar work-ref want n)
      (if (arrays-eq got want n)
        42
        1))))