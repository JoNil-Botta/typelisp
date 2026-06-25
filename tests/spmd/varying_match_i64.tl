;; SPMD varying-match corpus (#3753): scalar integer literal patterns inside a
;; foreach body. The n = 13 length also exercises tail handling in scalar-vs-SIMD
;; comparison runs.
(define (fill-match [out : (Array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (array-set!
      out
      i
      (match (% i 4)
        [0 10]
        [1 (+ i 20)]
        [2 30]
        [x (+ x 40)]))))

(define (fill-scalar [out : (Array i64)] [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set!
          out
          i
          (match (% i 4)
            [0 10]
            [1 (+ i 20)]
            [2 30]
            [x (+ x 40)]))
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
    [got : (Array i64) (make-array i64 n)]
    [want : (Array i64) (make-array i64 n)]
    (begin
      (fill-match got n)
      (fill-scalar want n)
      (if (arrays-eq got want n)
        42
        1))))