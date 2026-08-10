;; SPMD varying-match corpus (#3753): a match inside a masked-if branch.
(import stdlib.array)

(define (init-xs [xs : (__tl_dyn-array i64)] [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (set! (array-ref xs i) (- i 5))
        (set! i (+ i 1))))))

(define (fill-match
  [xs : (__tl_dyn-array i64)]
  [out : (__tl_dyn-array i64)]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (if (> (array-ref xs i) 0)
      (match (> (array-ref xs i) 1)
        [true (set! (array-ref out i) 1)]
        [false (set! (array-ref out i) 2)])
      (set! (array-ref out i) 0))))

(define (fill-scalar
  [xs : (__tl_dyn-array i64)]
  [out : (__tl_dyn-array i64)]
  [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (if (> (array-ref xs i) 0)
          (match (> (array-ref xs i) 1)
            [true (set! (array-ref out i) 1)]
            [false (set! (array-ref out i) 2)])
          (set! (array-ref out i) 0))
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
    [xs : (__tl_dyn-array i64) (array.make-array i64 n)]
    [got : (__tl_dyn-array i64) (array.make-array i64 n)]
    [want : (__tl_dyn-array i64) (array.make-array i64 n)]
    (begin
      (init-xs xs n)
      (fill-match xs got n)
      (fill-scalar xs want n)
      (if (arrays-eq got want n)
        42
        1))))