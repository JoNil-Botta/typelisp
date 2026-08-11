;; SPMD varying-match corpus (#3753): scalar integer literal patterns inside a
;; foreach body. The n = 13 length also exercises tail handling in scalar-vs-SIMD
;; comparison runs.
(import stdlib.array)

(define (fill-match [out : (__tl_dyn-array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (set!
      (array-ref out i)
      (match (% i 4)
        [0 10]
        [1 (+ i 20)]
        [2 30]
        [x (+ x 40)]))))

(define (fill-scalar [out : (__tl_dyn-array i64)] [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (set!
          (array-ref out i)
          (match (% i 4)
            [0 10]
            [1 (+ i 20)]
            [2 30]
            [x (+ x 40)]))
        (set! i (+ i 1))))))

(define (arrays-eq
  [a : (__tl_dyn-array i64)]
  [b : (__tl_dyn-array i64)]
  [n : i64]) : bool
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
    [got : (__tl_dyn-array i64) (array.make-array i64 n)]
    [want : (__tl_dyn-array i64) (array.make-array i64 n)]
    (begin
      (fill-match got n)
      (fill-scalar want n)
      (if (arrays-eq got want n)
        42
        1))))