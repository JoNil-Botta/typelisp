;; Uniform arithmetic helpers share one template; foreach entry points keep
;; each admitted lane width homogeneous. Only scalar setup/check code narrows.
(import stdlib.comptime)

(defmacro (integer-case [T : type] [inner : Expr] [offset : Expr] [add : Expr]) : Decls
  `(begin
    (define (,inner [a : ,T] [b : ,T] [rounds : ,T]) : ,T
      (+ (+ (+ (+ (+ (+ (+ (+ a (* b rounds)) a) a) a) a) a) a) a))
    (define (,offset [a : ,T] [b : ,T]) : ,T
      (+ (,inner a b (cast 3 : ,T)) (,inner b a (cast 2 : ,T))))
    (define (,add [x : ,T] [y : ,T] [a : ,T] [b : ,T]) : ,T
      (+ (+ (+ (+ (+ (+ (+ (+ x y) (,offset a b)) x) x) x) x) x) x))))

(integer-case i8 uniform-inner-i8 uniform-offset-i8 add-i8)

(integer-case u8 uniform-inner-u8 uniform-offset-u8 add-u8)

(integer-case i16 uniform-inner-i16 uniform-offset-i16 add-i16)

(integer-case u16 uniform-inner-u16 uniform-offset-u16 add-u16)

(integer-case i32 uniform-inner-i32 uniform-offset-i32 add-i32)

(integer-case u32 uniform-inner-u32 uniform-offset-u32 add-u32)

(integer-case i64 uniform-inner-i64 uniform-offset-i64 add-i64)

(integer-case u64 uniform-inner-u64 uniform-offset-u64 add-u64)

(define (fill-i8
  [xs : (& xs (__tl_dyn-array i8))]
  [out : (&mut out (__tl_dyn-array i8))]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (let
      [x : i8 (array-ref xs i)]
      (set!
        (array-ref out i)
        (add-i8 x (+ x (+ x x)) (cast 1 : i8) (cast 2 : i8))))))

(define (fill-u8
  [xs : (& xs (__tl_dyn-array u8))]
  [out : (&mut out (__tl_dyn-array u8))]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (let
      [x : u8 (array-ref xs i)]
      (set!
        (array-ref out i)
        (add-u8 x (+ x (+ x x)) (cast 1 : u8) (cast 2 : u8))))))

(define (fill-i16
  [xs : (& xs (__tl_dyn-array i16))]
  [out : (&mut out (__tl_dyn-array i16))]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (let
      [x : i16 (array-ref xs i)]
      (set!
        (array-ref out i)
        (add-i16 x (+ x (+ x x)) (cast 1 : i16) (cast 2 : i16))))))

(define (fill-u16
  [xs : (& xs (__tl_dyn-array u16))]
  [out : (&mut out (__tl_dyn-array u16))]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (let
      [x : u16 (array-ref xs i)]
      (set!
        (array-ref out i)
        (add-u16 x (+ x (+ x x)) (cast 1 : u16) (cast 2 : u16))))))

(define (fill-i32
  [xs : (& xs (__tl_dyn-array i32))]
  [out : (&mut out (__tl_dyn-array i32))]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (let
      [x : i32 (array-ref xs i)]
      (set!
        (array-ref out i)
        (add-i32 x (+ x (+ x x)) (cast 1 : i32) (cast 2 : i32))))))

(define (fill-u32
  [xs : (& xs (__tl_dyn-array u32))]
  [out : (&mut out (__tl_dyn-array u32))]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (let
      [x : u32 (array-ref xs i)]
      (set!
        (array-ref out i)
        (add-u32 x (+ x (+ x x)) (cast 1 : u32) (cast 2 : u32))))))

(define (fill-i64
  [xs : (& xs (__tl_dyn-array i64))]
  [out : (&mut out (__tl_dyn-array i64))]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (let
      [x : i64 (array-ref xs i)]
      (set!
        (array-ref out i)
        (add-i64 x (+ x (+ x x)) (cast 1 : i64) (cast 2 : i64))))))

(define (fill-u64
  [xs : (& xs (__tl_dyn-array u64))]
  [out : (&mut out (__tl_dyn-array u64))]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (let
      [x : u64 (array-ref xs i)]
      (set!
        (array-ref out i)
        (add-u64 x (+ x (+ x x)) (cast 1 : u64) (cast 2 : u64))))))

(define (check-length [n : i64]) : bool
  (let
    [xs-i8 : (__tl_dyn-array i8) (__tl_make-array i8 n)]
    [out-i8 : (__tl_dyn-array i8) (__tl_make-array i8 n)]
    [xs-u8 : (__tl_dyn-array u8) (__tl_make-array u8 n)]
    [out-u8 : (__tl_dyn-array u8) (__tl_make-array u8 n)]
    [xs-i16 : (__tl_dyn-array i16) (__tl_make-array i16 n)]
    [out-i16 : (__tl_dyn-array i16) (__tl_make-array i16 n)]
    [xs-u16 : (__tl_dyn-array u16) (__tl_make-array u16 n)]
    [out-u16 : (__tl_dyn-array u16) (__tl_make-array u16 n)]
    [xs-i32 : (__tl_dyn-array i32) (__tl_make-array i32 n)]
    [out-i32 : (__tl_dyn-array i32) (__tl_make-array i32 n)]
    [xs-u32 : (__tl_dyn-array u32) (__tl_make-array u32 n)]
    [out-u32 : (__tl_dyn-array u32) (__tl_make-array u32 n)]
    [xs-i64 : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    [out-i64 : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    [xs-u64 : (__tl_dyn-array u64) (__tl_make-array u64 n)]
    [out-u64 : (__tl_dyn-array u64) (__tl_make-array u64 n)]
    [i : i64 0]
    [ok : bool true]
    (begin
      (while (< i n)
        (begin
          (set! (array-ref xs-i8 i) (cast i : i8))
          (set! (array-ref xs-u8 i) (cast i : u8))
          (set! (array-ref xs-i16 i) (cast i : i16))
          (set! (array-ref xs-u16 i) (cast i : u16))
          (set! (array-ref xs-i32 i) (cast i : i32))
          (set! (array-ref xs-u32 i) (cast i : u32))
          (set! (array-ref xs-i64 i) (cast i : i64))
          (set! (array-ref xs-u64 i) (cast i : u64))
          (set! i (+ i 1))))
      (fill-i8 (& xs-i8) (&mut out-i8) n)
      (fill-u8 (& xs-u8) (&mut out-u8) n)
      (fill-i16 (& xs-i16) (&mut out-i16) n)
      (fill-u16 (& xs-u16) (&mut out-u16) n)
      (fill-i32 (& xs-i32) (&mut out-i32) n)
      (fill-u32 (& xs-u32) (&mut out-u32) n)
      (fill-i64 (& xs-i64) (&mut out-i64) n)
      (fill-u64 (& xs-u64) (&mut out-u64) n)
      (set! i 0)
      (while (< i n)
        (let
          [expected : i64 (+ (* i 10) 32)]
          (begin
            (set!
              ok
              (and
                ok
                (= (array-ref out-i8 i) (cast expected : i8))
                (= (array-ref out-u8 i) (cast expected : u8))
                (= (array-ref out-i16 i) (cast expected : i16))
                (= (array-ref out-u16 i) (cast expected : u16))
                (= (array-ref out-i32 i) (cast expected : i32))
                (= (array-ref out-u32 i) (cast expected : u32))
                (= (array-ref out-i64 i) (cast expected : i64))
                (= (array-ref out-u64 i) (cast expected : u64))))
            (set! i (+ i 1)))))
      ok)))

(define (main) : i64
  (if (and
    (check-length 0)
    (check-length 1)
    (check-length 4)
    (check-length 8)
    (check-length 13)
    (check-length 32))
    42
    1))