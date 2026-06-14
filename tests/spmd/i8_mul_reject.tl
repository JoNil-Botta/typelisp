(define (init [a : (Array i8)] [b : (Array i8)] [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set! a i (cast (+ i 1) : i8))
        (array-set! b i (cast (+ i 2) : i8))
        (set! i (+ i 1))))))

(define (fill [a : (Array i8)] [b : (Array i8)] [out : (Array i8)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (array-set! out i (* (array-ref a i) (array-ref b i)))))

(define (sum [out : (Array i8)] [n : i64]) : i64
  (let
    [i : i64 0]
    [acc : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! acc (+ acc (cast (array-ref out i) : i64)))
          (set! i (+ i 1))))
      acc)))

(define (main) : i64
  (let
    [n : i64 9]
    [a : (Array i8) (make-array i8 n)]
    [b : (Array i8) (make-array i8 n)]
    [out : (Array i8) (make-array i8 n)]
    (begin
      (init a b n)
      (fill a b out n)
      (if (= (sum out n) 330)
        42
        1))))