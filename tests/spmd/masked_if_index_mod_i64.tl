;; SPMD masked-if corpus (#2205): AVX-512 masked branches whose condition uses
;; `% i 2` lane-index arithmetic. The n = 13 length exercises a masked tail.
(define (init-out [out : (Array i64)] [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set! out i -99)
        (set! i (+ i 1))))))

(define (fill-masked [out : (Array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (if (= (% i 2) 0)
      (array-set! out i (+ i 10))
      (array-set! out i (+ i 100)))))

(define (fill-scalar [out : (Array i64)] [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (if (= (% i 2) 0)
          (array-set! out i (+ i 10))
          (array-set! out i (+ i 100)))
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
      (init-out got n)
      (init-out want n)
      (fill-masked got n)
      (fill-scalar want n)
      (if (arrays-eq got want n)
        42
        1))))
