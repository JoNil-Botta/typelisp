;; Literal conversions must produce destination-domain bits before splatting.
;; The integer table pins round-to-nearest-even, including an i64 -> f32 case
;; that would double-round if it passed through f64 first. Scalar oracles also
;; check arithmetic, comparisons, nested masks and untouched tail sentinels.
(import stdlib.math)
(import stdlib.test)

(defmacro (literal-case
  [name : Expr]
  [ty : type]
  [bits-ty : type]
  [from-bits : Expr]
  [to-bits : Expr]
  [literal : Expr]
  [bits : Expr]) : Decls
  `(define (,name [n : i64]) : bool
    (let
      [a : (__tl_dyn-array ,ty) (__tl_make-array ,ty 35)]
      [stored : (__tl_dyn-array ,ty) (__tl_make-array ,ty 35)]
      [added : (__tl_dyn-array ,ty) (__tl_make-array ,ty 35)]
      [compared : (__tl_dyn-array ,ty) (__tl_make-array ,ty 35)]
      [condition : (__tl_dyn-array ,ty) (__tl_make-array ,ty 35)]
      [bound : (__tl_dyn-array ,ty) (__tl_make-array ,ty 35)]
      [control : (__tl_dyn-array ,ty) (__tl_make-array ,ty 35)]
      [mapped : (__tl_dyn-array ,ty) (__tl_make-array ,ty 35)]
      [want : ,ty (,from-bits (cast ,bits : ,bits-ty))]
      [sentinel : ,ty (cast -99.0 : ,ty)]
      [i : i64 0]
      [ok : bool (= (,to-bits (cast ,literal : ,ty)) (cast ,bits : ,bits-ty))]
      (while (< i 35)
        (set! (array-ref a i) (cast (- (% i 7) 3) : ,ty))
        (set! (array-ref stored i) sentinel)
        (set! (array-ref added i) sentinel)
        (set! (array-ref compared i) sentinel)
        (set! (array-ref condition i) sentinel)
        (set! (array-ref bound i) sentinel)
        (set! (array-ref control i) sentinel)
        (set! (array-ref mapped i) sentinel)
        (set! i (+ i 1)))
      (foreach
        ([j : i64 0 n])
        (if (> (array-ref a j) (cast -2 : ,ty))
          (begin
            (set! (array-ref stored j) (cast ,literal : ,ty))
            (set! (array-ref added j) (+ (array-ref a j) (cast ,literal : ,ty)))
            (set!
              (array-ref compared j)
              (if (< (cast ,literal : ,ty) (array-ref a j))
                (cast 7.0 : ,ty)
                (cast 8.0 : ,ty)))
            (if (> (array-ref a j) (cast 0 : ,ty))
              (set! (array-ref condition j) (cast ,literal : ,ty))
              unit)
            (let
              [x : ,ty (cast ,literal : ,ty)]
              (set! (array-ref bound j) x))
            (set! (array-ref control j) (cast 3.0 : ,ty)))
          unit))
      (foreach
        ([j : i64 0 n])
        (set! (array-ref mapped j) (cast ,literal : ,ty)))
      (set! i 0)
      (while (< i 35)
        (let
          [active : bool (and (< i n) (> (array-ref a i) (cast -2.0 : ,ty)))]
          [expected : ,ty
            (if active
              want
              sentinel)]
          [sum : ,ty
            (if active
              (+ (array-ref a i) want)
              sentinel)]
          [choice : ,ty
            (if active
              (if (< want (array-ref a i))
                (cast 7.0 : ,ty)
                (cast 8.0 : ,ty))
              sentinel)]
          [conditional : ,ty
            (if (and active (> (array-ref a i) (cast 0.0 : ,ty)))
              want
              sentinel)]
          (unless
            (and
              (= (,to-bits (array-ref stored i)) (,to-bits expected))
              (= (,to-bits (array-ref added i)) (,to-bits sum))
              (= (,to-bits (array-ref compared i)) (,to-bits choice))
              (= (,to-bits (array-ref condition i)) (,to-bits conditional))
              (= (,to-bits (array-ref bound i)) (,to-bits expected))
              (=
                (array-ref control i)
                (if active
                  (cast 3.0 : ,ty)
                  sentinel))
              (=
                (,to-bits (array-ref mapped i))
                (,to-bits
                  (if (< i n)
                    want
                    sentinel))))
            (set! ok false)))
        (set! i (+ i 1)))
      ok)))

(literal-case zero-f32 f32 u32 math.f32-from-bits math.f32-to-bits 0 0)

(literal-case
  negative-f32
  f32
  u32
  math.f32-from-bits
  math.f32-to-bits
  -3
  0xc0400000)

(literal-case
  tie-even-f32
  f32
  u32
  math.f32-from-bits
  math.f32-to-bits
  16777217
  0x4b800000)

(literal-case
  tie-odd-f32
  f32
  u32
  math.f32-from-bits
  math.f32-to-bits
  16777219
  0x4b800002)

(literal-case
  direct-round-f32
  f32
  u32
  math.f32-from-bits
  math.f32-to-bits
  4611686293305294849
  0x5e800001)

(literal-case
  max-f32
  f32
  u32
  math.f32-from-bits
  math.f32-to-bits
  9223372036854775807
  0x5f000000)

(literal-case
  min-f32
  f32
  u32
  math.f32-from-bits
  math.f32-to-bits
  -9223372036854775808
  0xdf000000)

(literal-case zero-f64 f64 u64 math.f64-from-bits math.f64-to-bits 0 0)

(literal-case
  negative-f64
  f64
  u64
  math.f64-from-bits
  math.f64-to-bits
  -3
  0xc008000000000000)

(literal-case
  tie-even-f64
  f64
  u64
  math.f64-from-bits
  math.f64-to-bits
  9007199254740993
  0x4340000000000000)

(literal-case
  tie-odd-f64
  f64
  u64
  math.f64-from-bits
  math.f64-to-bits
  9007199254740995
  0x4340000000000002)

(literal-case
  hex-f64
  f64
  u64
  math.f64-from-bits
  math.f64-to-bits
  0x20000000000001
  0x4340000000000000)

(literal-case
  max-f64
  f64
  u64
  math.f64-from-bits
  math.f64-to-bits
  9223372036854775807
  0x43e0000000000000)

(literal-case
  min-f64
  f64
  u64
  math.f64-from-bits
  math.f64-to-bits
  -9223372036854775808
  0xc3e0000000000000)

(define (literal-matrix) : bool
  (let
    [n : i64 0]
    [ok : bool true]
    (while (< n 35)
      (unless
        (and
          (zero-f32 n)
          (negative-f32 n)
          (tie-even-f32 n)
          (tie-odd-f32 n)
          (direct-round-f32 n)
          (max-f32 n)
          (min-f32 n)
          (zero-f64 n)
          (negative-f64 n)
          (tie-even-f64 n)
          (tie-odd-f64 n)
          (hex-f64 n)
          (max-f64 n)
          (min-f64 n))
        (set! ok false))
      (set! n (+ n 1)))
    ok))

(define (main) : i64
  (if (literal-matrix)
    42
    1))

(test
  masked-float-literal-cast
  (test.assert-true (literal-matrix) "literal conversion, masking and rounding"))