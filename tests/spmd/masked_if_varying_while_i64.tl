;; SPMD nested masked-if/varying-while corpus (#3752).
(import stdlib.array)

(define (init-counts [xs : (__tl_dyn-array i64)]) : unit
  (begin
    (set! (array-ref xs 0) -1)
    (set! (array-ref xs 1) 4)
    (set! (array-ref xs 2) 0)
    (set! (array-ref xs 3) 2)
    (set! (array-ref xs 4) 5)
    (set! (array-ref xs 5) -3)
    (set! (array-ref xs 6) 1)
    (set! (array-ref xs 7) 6)
    (set! (array-ref xs 8) 0)
    (set! (array-ref xs 9) 3)
    (set! (array-ref xs 10) -2)
    (set! (array-ref xs 11) 1)
    (set! (array-ref xs 12) 7)))

(define (fill-masked
  [work : (__tl_dyn-array i64)]
  [out : (__tl_dyn-array i64)]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (if (> (array-ref work i) 0)
      (while (> (array-ref work i) 0)
        (begin
          (set! (array-ref out i) (+ (array-ref out i) 2))
          (set! (array-ref work i) (+ (array-ref work i) -1))))
      (set! (array-ref out i) -1))))

(define (fill-scalar
  [work : (__tl_dyn-array i64)]
  [out : (__tl_dyn-array i64)]
  [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (if (> (array-ref work i) 0)
          (while (> (array-ref work i) 0)
            (begin
              (set! (array-ref out i) (+ (array-ref out i) 2))
              (set! (array-ref work i) (+ (array-ref work i) -1))))
          (set! (array-ref out i) -1))
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
    [work : (__tl_dyn-array i64) (array.make-array i64 n)]
    [work-ref : (__tl_dyn-array i64) (array.make-array i64 n)]
    [got : (__tl_dyn-array i64) (array.make-array i64 n)]
    [want : (__tl_dyn-array i64) (array.make-array i64 n)]
    (begin
      (init-counts work)
      (init-counts work-ref)
      (fill-masked work got n)
      (fill-scalar work-ref want n)
      (if (arrays-eq got want n)
        42
        1))))