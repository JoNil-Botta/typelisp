(define (init-i64 [a : (Array i64)] [b : (Array i64)] [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set! a i (+ i 1))
        (array-set! b i (* i 2))
        (set! i (+ i 1))))))

(define (fill-i64-foreach
  [a : (Array i64)]
  [b : (Array i64)]
  [out : (Array i64)]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (array-set! out i (+ (array-ref a i) (array-ref b i)))))

(define (fill-i64-scalar
  [a : (Array i64)]
  [b : (Array i64)]
  [out : (Array i64)]
  [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set! out i (+ (array-ref a i) (array-ref b i)))
        (set! i (+ i 1))))))

(define (eq-i64 [a : (Array i64)] [b : (Array i64)] [n : i64]) : bool
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

(define (case-i64 [n : i64]) : bool
  (let
    [a : (Array i64) (make-array i64 n)]
    [b : (Array i64) (make-array i64 n)]
    [got : (Array i64) (make-array i64 n)]
    [want : (Array i64) (make-array i64 n)]
    (begin
      (init-i64 a b n)
      (fill-i64-foreach a b got n)
      (fill-i64-scalar a b want n)
      (eq-i64 got want n))))

(define (init-i32 [a : (Array i32)] [b : (Array i32)] [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set! a i (cast (+ i 1) : i32))
        (array-set! b i (cast (* i 2) : i32))
        (set! i (+ i 1))))))

(define (fill-i32-foreach
  [a : (Array i32)]
  [b : (Array i32)]
  [out : (Array i32)]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (array-set! out i (+ (array-ref a i) (array-ref b i)))))

(define (fill-i32-scalar
  [a : (Array i32)]
  [b : (Array i32)]
  [out : (Array i32)]
  [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set! out i (+ (array-ref a i) (array-ref b i)))
        (set! i (+ i 1))))))

(define (eq-i32 [a : (Array i32)] [b : (Array i32)] [n : i64]) : bool
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

(define (case-i32 [n : i64]) : bool
  (let
    [a : (Array i32) (make-array i32 n)]
    [b : (Array i32) (make-array i32 n)]
    [got : (Array i32) (make-array i32 n)]
    [want : (Array i32) (make-array i32 n)]
    (begin
      (init-i32 a b n)
      (fill-i32-foreach a b got n)
      (fill-i32-scalar a b want n)
      (eq-i32 got want n))))

(define (init-i8 [a : (Array i8)] [b : (Array i8)] [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set! a i (cast (+ i 1) : i8))
        (array-set! b i (cast (+ (* i 2) 3) : i8))
        (set! i (+ i 1))))))

(define (fill-i8-foreach
  [a : (Array i8)]
  [b : (Array i8)]
  [out : (Array i8)]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (array-set! out i (+ (array-ref a i) (array-ref b i)))))

(define (fill-i8-scalar
  [a : (Array i8)]
  [b : (Array i8)]
  [out : (Array i8)]
  [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set! out i (+ (array-ref a i) (array-ref b i)))
        (set! i (+ i 1))))))

(define (eq-i8 [a : (Array i8)] [b : (Array i8)] [n : i64]) : bool
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

(define (case-i8 [n : i64]) : bool
  (let
    [a : (Array i8) (make-array i8 n)]
    [b : (Array i8) (make-array i8 n)]
    [got : (Array i8) (make-array i8 n)]
    [want : (Array i8) (make-array i8 n)]
    (begin
      (init-i8 a b n)
      (fill-i8-foreach a b got n)
      (fill-i8-scalar a b want n)
      (eq-i8 got want n))))

(define (init-u8 [a : (Array u8)] [b : (Array u8)] [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set! a i (cast (+ i 1) : u8))
        (array-set! b i (cast (+ (* i 2) 3) : u8))
        (set! i (+ i 1))))))

(define (fill-u8-foreach
  [a : (Array u8)]
  [b : (Array u8)]
  [out : (Array u8)]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (array-set! out i (+ (array-ref a i) (array-ref b i)))))

(define (fill-u8-scalar
  [a : (Array u8)]
  [b : (Array u8)]
  [out : (Array u8)]
  [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set! out i (+ (array-ref a i) (array-ref b i)))
        (set! i (+ i 1))))))

(define (eq-u8 [a : (Array u8)] [b : (Array u8)] [n : i64]) : bool
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

(define (case-u8 [n : i64]) : bool
  (let
    [a : (Array u8) (make-array u8 n)]
    [b : (Array u8) (make-array u8 n)]
    [got : (Array u8) (make-array u8 n)]
    [want : (Array u8) (make-array u8 n)]
    (begin
      (init-u8 a b n)
      (fill-u8-foreach a b got n)
      (fill-u8-scalar a b want n)
      (eq-u8 got want n))))

(define (init-i16 [a : (Array i16)] [b : (Array i16)] [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set! a i (cast (+ (* i 257) 12000) : i16))
        (array-set! b i (cast (+ (* i 13) 300) : i16))
        (set! i (+ i 1))))))

(define (fill-i16-foreach
  [a : (Array i16)]
  [b : (Array i16)]
  [out : (Array i16)]
  [n : i64]
  [factor : i16]) : unit
  (foreach
    ([i : i64 0 n])
    (array-set! out i (+ (array-ref a i) (* (array-ref b i) factor)))))

(define (fill-i16-scalar
  [a : (Array i16)]
  [b : (Array i16)]
  [out : (Array i16)]
  [n : i64]
  [factor : i16]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set! out i (+ (array-ref a i) (* (array-ref b i) factor)))
        (set! i (+ i 1))))))

(define (eq-i16 [a : (Array i16)] [b : (Array i16)] [n : i64]) : bool
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

(define (case-i16 [n : i64]) : bool
  (let
    [a : (Array i16) (make-array i16 n)]
    [b : (Array i16) (make-array i16 n)]
    [got : (Array i16) (make-array i16 n)]
    [want : (Array i16) (make-array i16 n)]
    [factor : i16 (cast 7 : i16)]
    (begin
      (init-i16 a b n)
      (fill-i16-foreach a b got n factor)
      (fill-i16-scalar a b want n factor)
      (eq-i16 got want n))))

(define (init-u16 [a : (Array u16)] [b : (Array u16)] [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set! a i (cast (+ (* i 257) 65000) : u16))
        (array-set! b i (cast (+ (* i 37) 500) : u16))
        (set! i (+ i 1))))))

(define (fill-u16-foreach
  [a : (Array u16)]
  [b : (Array u16)]
  [out : (Array u16)]
  [n : i64]
  [factor : u16]) : unit
  (foreach
    ([i : i64 0 n])
    (array-set! out i (+ (array-ref a i) (* (array-ref b i) factor)))))

(define (fill-u16-scalar
  [a : (Array u16)]
  [b : (Array u16)]
  [out : (Array u16)]
  [n : i64]
  [factor : u16]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set! out i (+ (array-ref a i) (* (array-ref b i) factor)))
        (set! i (+ i 1))))))

(define (eq-u16 [a : (Array u16)] [b : (Array u16)] [n : i64]) : bool
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

(define (case-u16 [n : i64]) : bool
  (let
    [a : (Array u16) (make-array u16 n)]
    [b : (Array u16) (make-array u16 n)]
    [got : (Array u16) (make-array u16 n)]
    [want : (Array u16) (make-array u16 n)]
    [factor : u16 (cast 19 : u16)]
    (begin
      (init-u16 a b n)
      (fill-u16-foreach a b got n factor)
      (fill-u16-scalar a b want n factor)
      (eq-u16 got want n))))

(define (init-f64 [a : (Array f64)] [b : (Array f64)] [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set! a i 1.5)
        (array-set! b i 2.25)
        (set! i (+ i 1))))))

(define (fill-f64-foreach
  [a : (Array f64)]
  [b : (Array f64)]
  [out : (Array f64)]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (array-set! out i (+ (array-ref a i) (array-ref b i)))))

(define (fill-f64-scalar
  [a : (Array f64)]
  [b : (Array f64)]
  [out : (Array f64)]
  [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set! out i (+ (array-ref a i) (array-ref b i)))
        (set! i (+ i 1))))))

(define (eq-f64 [a : (Array f64)] [b : (Array f64)] [n : i64]) : bool
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

(define (case-f64 [n : i64]) : bool
  (let
    [a : (Array f64) (make-array f64 n)]
    [b : (Array f64) (make-array f64 n)]
    [got : (Array f64) (make-array f64 n)]
    [want : (Array f64) (make-array f64 n)]
    (begin
      (init-f64 a b n)
      (fill-f64-foreach a b got n)
      (fill-f64-scalar a b want n)
      (eq-f64 got want n))))

(define (init-f32 [a : (Array f32)] [b : (Array f32)] [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set! a i 1.5)
        (array-set! b i 2.25)
        (set! i (+ i 1))))))

(define (fill-f32-foreach
  [a : (Array f32)]
  [b : (Array f32)]
  [out : (Array f32)]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (array-set! out i (+ (array-ref a i) (array-ref b i)))))

(define (fill-f32-scalar
  [a : (Array f32)]
  [b : (Array f32)]
  [out : (Array f32)]
  [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set! out i (+ (array-ref a i) (array-ref b i)))
        (set! i (+ i 1))))))

(define (eq-f32 [a : (Array f32)] [b : (Array f32)] [n : i64]) : bool
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

(define (case-f32 [n : i64]) : bool
  (let
    [a : (Array f32) (make-array f32 n)]
    [b : (Array f32) (make-array f32 n)]
    [got : (Array f32) (make-array f32 n)]
    [want : (Array f32) (make-array f32 n)]
    (begin
      (init-f32 a b n)
      (fill-f32-foreach a b got n)
      (fill-f32-scalar a b want n)
      (eq-f32 got want n))))

(define (case-end-bound-evaluated-once) : bool
  (let
    [bounds : (Array i64) (make-array i64 1)]
    [out : (Array i64) (make-array i64 3)]
    (begin
      (array-set! bounds 0 3)
      (array-set! out 0 0)
      (array-set! out 1 0)
      (array-set! out 2 0)
      (foreach
        ([i : i64 0 (array-ref bounds 0)])
        (begin
          (array-set! bounds 0 0)
          (array-set! out i (+ i 1))))
      (= (array-ref out 2) 3))))

(define (case-index-binding-is-scoped) : bool
  (=
    (let
      [i : i64 7]
      (begin
        (foreach ([i : i64 0 3]) unit)
        i))
    7))

(define (all-cases) : bool
  (let
    [ok : bool true]
    (begin
      (if (case-i64 0)
        unit
        (set! ok false))
      (if (case-i64 3)
        unit
        (set! ok false))
      (if (case-i64 4)
        unit
        (set! ok false))
      (if (case-i64 9)
        unit
        (set! ok false))
      (if (case-i64 16)
        unit
        (set! ok false))
      (if (case-i64 17)
        unit
        (set! ok false))
      (if (case-i32 0)
        unit
        (set! ok false))
      (if (case-i32 3)
        unit
        (set! ok false))
      (if (case-i32 8)
        unit
        (set! ok false))
      (if (case-i32 9)
        unit
        (set! ok false))
      (if (case-i32 16)
        unit
        (set! ok false))
      (if (case-i32 17)
        unit
        (set! ok false))
      (if (case-i8 0)
        unit
        (set! ok false))
      (if (case-i8 3)
        unit
        (set! ok false))
      (if (case-i8 32)
        unit
        (set! ok false))
      (if (case-i8 33)
        unit
        (set! ok false))
      (if (case-i8 64)
        unit
        (set! ok false))
      (if (case-i8 65)
        unit
        (set! ok false))
      (if (case-u8 0)
        unit
        (set! ok false))
      (if (case-u8 3)
        unit
        (set! ok false))
      (if (case-u8 32)
        unit
        (set! ok false))
      (if (case-u8 33)
        unit
        (set! ok false))
      (if (case-u8 64)
        unit
        (set! ok false))
      (if (case-u8 65)
        unit
        (set! ok false))
      (if (case-i16 0)
        unit
        (set! ok false))
      (if (case-i16 3)
        unit
        (set! ok false))
      (if (case-i16 16)
        unit
        (set! ok false))
      (if (case-i16 17)
        unit
        (set! ok false))
      (if (case-i16 32)
        unit
        (set! ok false))
      (if (case-i16 33)
        unit
        (set! ok false))
      (if (case-u16 0)
        unit
        (set! ok false))
      (if (case-u16 3)
        unit
        (set! ok false))
      (if (case-u16 16)
        unit
        (set! ok false))
      (if (case-u16 17)
        unit
        (set! ok false))
      (if (case-u16 32)
        unit
        (set! ok false))
      (if (case-u16 33)
        unit
        (set! ok false))
      (if (case-f64 0)
        unit
        (set! ok false))
      (if (case-f64 3)
        unit
        (set! ok false))
      (if (case-f64 4)
        unit
        (set! ok false))
      (if (case-f64 9)
        unit
        (set! ok false))
      (if (case-f64 16)
        unit
        (set! ok false))
      (if (case-f64 17)
        unit
        (set! ok false))
      (if (case-f32 0)
        unit
        (set! ok false))
      (if (case-f32 3)
        unit
        (set! ok false))
      (if (case-f32 8)
        unit
        (set! ok false))
      (if (case-f32 9)
        unit
        (set! ok false))
      (if (case-f32 16)
        unit
        (set! ok false))
      (if (case-f32 17)
        unit
        (set! ok false))
      (if (case-end-bound-evaluated-once)
        unit
        (set! ok false))
      (if (case-index-binding-is-scoped)
        unit
        (set! ok false))
      ok)))

(define (main) : i64
  (if (all-cases)
    42
    1))