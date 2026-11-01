;; Eight numeric inputs, a varying bool and an active mask cross repeated
;; ordinary calls and nested private calls, with mixed uniform arguments.
(import stdlib.iterator)

(defmacro (numeric-case
  [bias : Expr]
  [inner : Expr]
  [outer : Expr]
  [check : Expr]
  [ty : type]
  [one : Expr]
  [three : Expr]) : Decls
  `(begin
    (define (,bias [a : ,ty] [b : ,ty] [tag : i64]) : ,ty
      (let
        [first : ,ty (+ a b)]
        [second : ,ty (+ first b)]
        [third : ,ty (+ second b)]
        (if (> tag 0)
          (+ third b)
          a)))
    (define (,inner
      [x : ,ty]
      [y : ,ty]
      [z : ,ty]
      [w : ,ty]
      [p : ,ty]
      [q : ,ty]
      [r : ,ty]
      [s : ,ty]
      [a : ,ty]
      [b : ,ty]
      [tag : i64]) : ,ty
      (let
        [u : ,ty (,bias a b tag)]
        [v : ,ty (,bias b a tag)]
        (+ (+ (+ x y) (+ z w)) (+ (+ p q) (+ (+ r s) (+ u v))))))
    (define (,outer
      [x : ,ty]
      [y : ,ty]
      [keep : bool]
      [a : ,ty]
      [b : ,ty]
      [tag : i64]) : ,ty
      (let
        [first : ,ty (,inner x y x y x y x y a b tag)]
        [second : ,ty (,inner y x y x y x y x a b tag)]
        (if keep
          (+ first second)
          x)))
    (define (,check [n : i64]) : bool
      (let
        [xs : (__tl_dyn-array ,ty) (__tl_make-array ,ty 69)]
        [ys : (__tl_dyn-array ,ty) (__tl_make-array ,ty 69)]
        [out : (__tl_dyn-array ,ty) (__tl_make-array ,ty 69)]
        [i : i64 0]
        (while (< i 69)
          (set! (array-ref xs i) (cast (% i 5) : ,ty))
          (set! (array-ref ys i) (cast (% i 3) : ,ty))
          (set! (array-ref out i) (cast 99 : ,ty))
          (+= i 1))
        (foreach
          ([j : i64 0 n])
          (set!
            (array-ref out j)
            (,outer
              (array-ref xs j)
              (array-ref ys j)
              (> (array-ref xs j) (cast ,one : ,ty))
              (cast ,three : ,ty)
              (cast ,one : ,ty)
              3)))
        (set! i 0)
        (while (< i 69)
          (let
            [x : i64 (% i 5)]
            [y : i64 (% i 3)]
            [expected : i64
              (if (< i n)
                (if (> x 1)
                  (+ (+ (* 8 x) (* 8 y)) 40)
                  x)
                99)]
            (unless (= (array-ref out i) (cast expected : ,ty)) (return false)))
          (+= i 1))
        true))))

(numeric-case uniform-bias-i8 inner-i8 outer-i8 check-i8 i8 1 3)

(numeric-case uniform-bias-u8 inner-u8 outer-u8 check-u8 u8 1 3)

(numeric-case uniform-bias-i16 inner-i16 outer-i16 check-i16 i16 1 3)

(numeric-case uniform-bias-u16 inner-u16 outer-u16 check-u16 u16 1 3)

(numeric-case uniform-bias-i32 inner-i32 outer-i32 check-i32 i32 1 3)

(numeric-case uniform-bias-u32 inner-u32 outer-u32 check-u32 u32 1 3)

(numeric-case uniform-bias-i64 inner-i64 outer-i64 check-i64 i64 1 3)

(numeric-case uniform-bias-u64 inner-u64 outer-u64 check-u64 u64 1 3)

(numeric-case uniform-bias-f32 inner-f32 outer-f32 check-f32 f32 1.0 3.0)

(numeric-case uniform-bias-f64 inner-f64 outer-f64 check-f64 f64 1.0 3.0)

(define (main) : i64
  (let
    [lengths : (Array i64 8) (array 0 1 4 8 16 32 64 67)]
    (for [i (iterator.range 0 8)]
      (let
        [n : i64 (array-ref lengths i)]
        (unless
          (and
            (check-i8 n)
            (check-u8 n)
            (check-i16 n)
            (check-u16 n)
            (check-i32 n)
            (check-u32 n)
            (check-i64 n)
            (check-u64 n)
            (check-f32 n)
            (check-f64 n))
          (return 1))))
    42))