;; SPMD masked-if corpus (#5182): i64 bit-and parity condition with add/sub
;; value lanes. The n = 13 length exercises a masked tail in both SIMD modes.

(define (init-xs [xs : (&mut xs (__tl_dyn-array i64))] [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (set! (array-ref xs i) (+ (* i 3) 2))
        (set! i (+ i 1))))))

(define (init-out [out : (&mut out (__tl_dyn-array i64))] [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (set! (array-ref out i) -99)
        (set! i (+ i 1))))))

(define (fill-masked
  [xs : (& xs (__tl_dyn-array i64))]
  [out : (&mut out (__tl_dyn-array i64))]
  [n : i64]
  [bias : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (set!
      (array-ref out i)
      (if (= (bit-and (array-ref xs i) 1) 1)
        (+ (array-ref xs i) bias)
        (- (array-ref xs i) bias)))))

(define (fill-scalar
  [xs : (& xs (__tl_dyn-array i64))]
  [out : (&mut out (__tl_dyn-array i64))]
  [n : i64]
  [bias : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (set!
          (array-ref out i)
          (if (= (bit-and (array-ref xs i) 1) 1)
            (+ (array-ref xs i) bias)
            (- (array-ref xs i) bias)))
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
      (init-xs (&mut xs) n)
      (init-out (&mut got) n)
      (init-out (&mut want) n)
      (fill-masked (& xs) (&mut got) n 7)
      (fill-scalar (& xs) (&mut want) n 7)
      (if (arrays-eq (& got) (& want) n)
        42
        1))))