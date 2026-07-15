(import stdlib.array)

(define (multi-output-case
  [a : (Array i64)]
  [b : (Array i64)]
  [out-x : (Array i64)]
  [out-y : (Array i64)]
  [n : i64]) : bool
  (let
    [i : i64 0]
    [ok : bool true]
    (begin
      (while (< i 20)
        (begin
          (array-set! a i (+ i 3))
          (array-set! b i (- 30 i))
          (array-set! out-x i 777)
          (array-set! out-y i 888)
          (set! i (+ i 1))))
      (foreach
        ([j : i64 0 n])
        (begin
          (array-set! out-x j (+ (* (array-ref a j) 2) (array-ref b j)))
          (array-set! out-y j (+ (* (array-ref a j) 2) 5))))
      (set! i 0)
      (while (and ok (< i n))
        (begin
          (if (= (array-ref out-x i) (+ (* (+ i 3) 2) (- 30 i)))
            unit
            (set! ok false))
          (if (= (array-ref out-y i) (+ (* (+ i 3) 2) 5))
            unit
            (set! ok false))
          (set! i (+ i 1))))
      (and
        ok
        (if (< n 20)
          (= (array-ref out-x n) 777)
          true)
        (if (< n 20)
          (= (array-ref out-y n) 888)
          true)))))

(define (main) : i64
  (let
    [a : (Array i64) (array.make-array i64 20)]
    [b : (Array i64) (array.make-array i64 20)]
    [out-x : (Array i64) (array.make-array i64 20)]
    [out-y : (Array i64) (array.make-array i64 20)]
    (if (and
      (multi-output-case a b out-x out-y 0)
      (multi-output-case a b out-x out-y 3)
      (multi-output-case a b out-x out-y 4)
      (multi-output-case a b out-x out-y 8)
      (multi-output-case a b out-x out-y 19))
      42
      1)))