;; SPMD masked-if corpus (#2205): AVX-512 value-producing masked `if`
;; feeding a predicated store. The n = 13 length exercises a masked tail.
(define (init-xs [xs : (Array i64)] [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set! xs i (- (* i 3) 17))
        (set! i (+ i 1))))))

(define (init-out [out : (Array i64)] [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set! out i -99)
        (set! i (+ i 1))))))

(define (fill-masked [xs : (Array i64)] [out : (Array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (array-set!
      out
      i
      (if (< (array-ref xs i) 0)
        0
        (+ (array-ref xs i) 1)))))

(define (fill-scalar [xs : (Array i64)] [out : (Array i64)] [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set!
          out
          i
          (if (< (array-ref xs i) 0)
            0
            (+ (array-ref xs i) 1)))
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
      (init-xs xs n)
      (init-out got n)
      (init-out want n)
      (fill-masked xs got n)
      (fill-scalar xs want n)
      (if (arrays-eq got want n)
        42
        1))))