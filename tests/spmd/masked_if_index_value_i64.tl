;; SPMD masked-if corpus (#2205): AVX-512 masked branches whose condition and
;; stored values use the foreach index as a varying lane value, not only as an
;; array address. The n = 13 length exercises a non-multiple-of-8 tail.
(define (init-out [out : (&mut out (__tl_dyn-array i64))] [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (set! (array-ref out i) -99)
        (set! i (+ i 1))))))

(define (fill-masked [out : (&mut out (__tl_dyn-array i64))] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (if (< i 6)
      (set! (array-ref out i) i)
      (set! (array-ref out i) (+ i 1)))))

(define (fill-scalar [out : (&mut out (__tl_dyn-array i64))] [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (if (< i 6)
          (set! (array-ref out i) i)
          (set! (array-ref out i) (+ i 1)))
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
    [got : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    [want : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    (begin
      (init-out (&mut got) n)
      (init-out (&mut want) n)
      (fill-masked (&mut got) n)
      (fill-scalar (&mut want) n)
      (if (arrays-eq (& got) (& want) n)
        42
        1))))