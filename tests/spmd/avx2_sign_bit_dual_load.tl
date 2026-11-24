;; AVX2 sign-bit blend after a dual-load fold candidate: the inner `bit_and`
;; of two loads feeds a second `bit_and` whose single-bit compare the sign-bit
;; plan rewrites (inverted polarity for `= 0`). The dual-load memory fold must
;; not consume that `bit_and`. Exits 42 when every result matches a scalar loop.
(define (dual-and-eq0
  [a : (& a (__tl_dyn-array i64))]
  [b : (& b (__tl_dyn-array i64))]
  [out : (&mut out (__tl_dyn-array i64))]
  [n : i64]
  [c1 : i64]
  [c2 : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (set!
      (array-ref out i)
      (if (= (bit-and (bit-and (array-ref a i) (array-ref b i)) 1) 0)
        c1
        c2))))

(define (dual-and-ne0
  [a : (& a (__tl_dyn-array i64))]
  [b : (& b (__tl_dyn-array i64))]
  [out : (&mut out (__tl_dyn-array i64))]
  [n : i64]
  [c1 : i64]
  [c2 : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (set!
      (array-ref out i)
      (if (!= (bit-and (bit-and (array-ref a i) (array-ref b i)) 4) 0)
        c1
        c2))))

(define (main) : i64
  (let
    [n : i64 37]
    [a : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    [b : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    [out : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    [i : i64 0]
    (while (< i n)
      (set! (array-ref a i) (- (* i 5) 17))
      (set! (array-ref b i) (+ (* i 3) 1))
      (+= i 1))
    (dual-and-eq0 (& a) (& b) (&mut out) n 11 -23)
    (set! i 0)
    (while (< i n)
      (let
        [want : i64
          (if (= (bit-and (bit-and (array-ref a i) (array-ref b i)) 1) 0)
            11
            -23)]
        (when (!= (array-ref out i) want) (return 1)))
      (+= i 1))
    (dual-and-ne0 (& a) (& b) (&mut out) n 7 -9)
    (set! i 0)
    (while (< i n)
      (let
        [want : i64
          (if (!= (bit-and (bit-and (array-ref a i) (array-ref b i)) 4) 0)
            7
            -9)]
        (when (!= (array-ref out i) want) (return 2)))
      (+= i 1))
    42))