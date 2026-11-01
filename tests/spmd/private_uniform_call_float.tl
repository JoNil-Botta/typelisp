;; Comparison-based clamp retains every input bit through uniform min/max calls.
;; Exercise all bound pairs, signed zeros and NaNs at empty/full/tail lengths.
(import stdlib.math)
(import stdlib.iterator)

(define (f32-min [a : f32] [b : f32]) : f32
  (if (< a b)
    a
    b))

(define (f32-max [a : f32] [b : f32]) : f32
  (if (> a b)
    a
    b))

(define (f32-clamp [x : f32] [a : f32] [b : f32]) : f32
  (let
    [lo : f32 (f32-min a b)]
    [hi : f32 (f32-max a b)]
    (if (< x lo)
      lo
      (if (> x hi)
        hi
        x))))

(defmacro (float-case
  [fill : Expr]
  [check : Expr]
  [ty : type]
  [bits-ty : type]
  [clamp : Expr]
  [from-bits : Expr]
  [to-bits : Expr]
  [sign : Expr]
  [one : Expr]
  [infinity : Expr]
  [nan : Expr]) : Decls
  `(begin
    (define (,fill
      [xs : (& xs (__tl_dyn-array ,ty))]
      [out : (&mut out (__tl_dyn-array ,ty))]
      [n : i64]
      [a : ,ty]
      [b : ,ty]) : unit
      (foreach
        ([i : i64 0 n])
        (set! (array-ref out i) (,clamp (array-ref xs i) a b))))
    (define (,check [n : i64] [a-index : i64] [b-index : i64]) : bool
      (let
        [bits : (Array ,bits-ty 8)
          (array
            (cast 0 : ,bits-ty)
            ,sign
            ,one
            (bit-or ,sign ,one)
            ,infinity
            (bit-or ,sign ,infinity)
            ,nan
            (bit-or ,sign ,nan))]
        [xs : (__tl_dyn-array ,ty) (__tl_make-array ,ty 69)]
        [out : (__tl_dyn-array ,ty) (__tl_make-array ,ty 69)]
        [a : ,ty (,from-bits (array-ref bits a-index))]
        [b : ,ty (,from-bits (array-ref bits b-index))]
        [lo : ,ty
          (if (< a b)
            a
            b)]
        [hi : ,ty
          (if (> a b)
            a
            b)]
        [i : i64 0]
        (while (< i 69)
          (set! (array-ref xs i) (,from-bits (array-ref bits (% i 8))))
          (set! (array-ref out i) (,from-bits ,one))
          (+= i 1))
        (,fill (& xs) (&mut out) n a b)
        (set! i 0)
        (while (< i 69)
          (let
            [x : ,ty (array-ref xs i)]
            [expected : ,ty
              (if (< i n)
                (if (< x lo)
                  lo
                  (if (> x hi)
                    hi
                    x))
                (,from-bits ,one))]
            (unless
              (= (,to-bits (array-ref out i)) (,to-bits expected))
              (return false)))
          (+= i 1))
        true))))

(float-case
  fill-f64
  check-f64
  f64
  u64
  math.f64-clamp
  math.f64-from-bits
  math.f64-to-bits
  9223372036854775808
  4607182418800017408
  9218868437227405312
  9221120237041090626)

(float-case
  fill-f32
  check-f32
  f32
  u32
  f32-clamp
  math.f32-from-bits
  math.f32-to-bits
  2147483648
  1065353216
  2139095040
  2143289410)

(define (main) : i64
  (let
    [lengths : (Array i64 7) (array 0 1 4 8 16 13 67)]
    (for [length-index (iterator.range 0 7)]
      (for [a (iterator.range 0 8)]
        (for [b (iterator.range 0 8)]
          (unless
            (and
              (check-f64 (array-ref lengths length-index) a b)
              (check-f32 (array-ref lengths length-index) a b))
            (return 1)))))
    42))