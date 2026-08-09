(import stdlib.array)

(define (init [a : (__tl_dyn-array i8)] [b : (__tl_dyn-array i8)] [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set! a i (cast (+ i 1) : i8))
        (array-set! b i (cast (+ i 2) : i8))
        (set! i (+ i 1))))))

(define (fill
  [a : (__tl_dyn-array i8)]
  [b : (__tl_dyn-array i8)]
  [out : (__tl_dyn-array i8)]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (array-set! out i (* (array-ref a i) (array-ref b i)))))

(define (sum [out : (__tl_dyn-array i8)] [n : i64]) : i64
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
    [a : (__tl_dyn-array i8) (array.make-array i8 n)]
    [b : (__tl_dyn-array i8) (array.make-array i8 n)]
    [out : (__tl_dyn-array i8) (array.make-array i8 n)]
    (begin
      (init a b n)
      (fill a b out n)
      (if (= (sum out n) 330)
        42
        1))))