;; SPMD masked-if corpus (#2205): shifted contiguous AVX-512 masked branches
;; over i64 lanes, including a non-multiple-of-8 tail.

(define (init-xs [xs : (&mut xs (__tl_dyn-array i64))]) : unit
  (begin
    (set! (array-ref xs 0) 99)
    (set! (array-ref xs 1) -3)
    (set! (array-ref xs 2) 4)
    (set! (array-ref xs 3) -1)
    (set! (array-ref xs 4) 0)
    (set! (array-ref xs 5) 7)
    (set! (array-ref xs 6) -8)
    (set! (array-ref xs 7) 2)
    (set! (array-ref xs 8) 9)
    (set! (array-ref xs 9) -5)
    (set! (array-ref xs 10) 1)
    (set! (array-ref xs 11) 6)
    (set! (array-ref xs 12) -2)))

(define (init-out [out : (&mut out (__tl_dyn-array i64))] [len : i64]) : unit
  (let
    [i : i64 0]
    (while (< i len)
      (begin
        (set! (array-ref out i) -99)
        (set! i (+ i 1))))))

(define (fill-masked
  [xs : (& xs (__tl_dyn-array i64))]
  [out : (&mut out (__tl_dyn-array i64))]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (if (< (array-ref xs (+ i 1)) 0)
      (set! (array-ref out (+ i 1)) 0)
      (set! (array-ref out (+ i 1)) (+ (array-ref xs (+ i 1)) 1)))))

(define (fill-scalar
  [xs : (& xs (__tl_dyn-array i64))]
  [out : (&mut out (__tl_dyn-array i64))]
  [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (if (< (array-ref xs (+ i 1)) 0)
          (set! (array-ref out (+ i 1)) 0)
          (set! (array-ref out (+ i 1)) (+ (array-ref xs (+ i 1)) 1)))
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
    [n : i64 12]
    [len : i64 13]
    [xs : (__tl_dyn-array i64) (__tl_make-array i64 len)]
    [got : (__tl_dyn-array i64) (__tl_make-array i64 len)]
    [want : (__tl_dyn-array i64) (__tl_make-array i64 len)]
    (begin
      (init-xs (&mut xs))
      (init-out (&mut got) len)
      (init-out (&mut want) len)
      (fill-masked (& xs) (&mut got) n)
      (fill-scalar (& xs) (&mut want) n)
      (if (arrays-eq (& got) (& want) len)
        42
        1))))