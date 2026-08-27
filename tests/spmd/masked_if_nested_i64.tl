;; SPMD masked-if corpus (#2207): nested AVX-512 masked branches over i64
;; lanes. The n = 13 length exercises parent/child branch masks plus a tail.

(define (init-xs [xs : (&mut xs (__tl_dyn-array i64))]) : unit
  (begin
    (set! (array-ref xs 0) -3)
    (set! (array-ref xs 1) 4)
    (set! (array-ref xs 2) 0)
    (set! (array-ref xs 3) 12)
    (set! (array-ref xs 4) -1)
    (set! (array-ref xs 5) 8)
    (set! (array-ref xs 6) 2)
    (set! (array-ref xs 7) -9)
    (set! (array-ref xs 8) 0)
    (set! (array-ref xs 9) 7)
    (set! (array-ref xs 10) 13)
    (set! (array-ref xs 11) -2)
    (set! (array-ref xs 12) 5)))

(define (fill-masked
  [xs : (& xs (__tl_dyn-array i64))]
  [out : (&mut out (__tl_dyn-array i64))]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (let
      [x : i64 (array-ref xs i)]
      (cond
        [(< x 0) (set! (array-ref out i) -10)]
        [(= x 0) (set! (array-ref out i) 0)]
        [(< x 6) (set! (array-ref out i) 6)]
        [else (set! (array-ref out i) 12)]))))

(define (fill-scalar
  [xs : (& xs (__tl_dyn-array i64))]
  [out : (&mut out (__tl_dyn-array i64))]
  [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (let
          [x : i64 (array-ref xs i)]
          (cond
            [(< x 0) (set! (array-ref out i) -10)]
            [(= x 0) (set! (array-ref out i) 0)]
            [(< x 6) (set! (array-ref out i) 6)]
            [else (set! (array-ref out i) 12)]))
        (set! i (+ i 1))))))

(define (arrays-eq
  [a : (& a (__tl_dyn-array i64))]
  [b : (& b (__tl_dyn-array i64))]
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
    [xs : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    [got : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    [want : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    (begin
      (init-xs (&mut xs))
      (fill-masked (& xs) (&mut got) n)
      (fill-scalar (& xs) (&mut want) n)
      (if (arrays-eq (& got) (& want) n)
        42
        1))))