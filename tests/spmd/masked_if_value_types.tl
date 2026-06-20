;; SPMD masked-if corpus (#3356): AVX-512 value-producing masked `if`
;; over non-i64 lane result types. Each case uses a non-full tail.
(define (init-u32
  [keys : (Array u32)]
  [left : (Array u32)]
  [right : (Array u32)]
  [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set! keys i (cast (+ (* i 5) 1) : u32))
        (array-set! left i (cast (+ i 10) : u32))
        (array-set! right i (cast (+ i 100) : u32))
        (set! i (+ i 1))))))

(define (fill-u32-foreach
  [keys : (Array u32)]
  [left : (Array u32)]
  [right : (Array u32)]
  [out : (Array u32)]
  [n : i64]
  [pivot : u32]) : unit
  (foreach
    ([i : i64 0 n])
    (array-set!
      out
      i
      (if (< (array-ref keys i) pivot)
        (array-ref left i)
        (array-ref right i)))))

(define (fill-u32-scalar
  [keys : (Array u32)]
  [left : (Array u32)]
  [right : (Array u32)]
  [out : (Array u32)]
  [n : i64]
  [pivot : u32]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set!
          out
          i
          (if (< (array-ref keys i) pivot)
            (array-ref left i)
            (array-ref right i)))
        (set! i (+ i 1))))))

(define (eq-u32 [a : (Array u32)] [b : (Array u32)] [n : i64]) : bool
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

(define (case-u32 [n : i64]) : bool
  (let
    [keys : (Array u32) (make-array u32 n)]
    [left : (Array u32) (make-array u32 n)]
    [right : (Array u32) (make-array u32 n)]
    [got : (Array u32) (make-array u32 n)]
    [want : (Array u32) (make-array u32 n)]
    [pivot : u32 (cast 40 : u32)]
    (begin
      (init-u32 keys left right n)
      (fill-u32-foreach keys left right got n pivot)
      (fill-u32-scalar keys left right want n pivot)
      (eq-u32 got want n))))

(define (init-u64
  [keys : (Array u64)]
  [left : (Array u64)]
  [right : (Array u64)]
  [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set! keys i (cast (+ (* i 7) 2) : u64))
        (array-set! left i (cast (+ i 20) : u64))
        (array-set! right i (cast (+ i 200) : u64))
        (set! i (+ i 1))))))

(define (fill-u64-foreach
  [keys : (Array u64)]
  [left : (Array u64)]
  [right : (Array u64)]
  [out : (Array u64)]
  [n : i64]
  [pivot : u64]) : unit
  (foreach
    ([i : i64 0 n])
    (array-set!
      out
      i
      (if (< (array-ref keys i) pivot)
        (array-ref left i)
        (array-ref right i)))))

(define (fill-u64-scalar
  [keys : (Array u64)]
  [left : (Array u64)]
  [right : (Array u64)]
  [out : (Array u64)]
  [n : i64]
  [pivot : u64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set!
          out
          i
          (if (< (array-ref keys i) pivot)
            (array-ref left i)
            (array-ref right i)))
        (set! i (+ i 1))))))

(define (eq-u64 [a : (Array u64)] [b : (Array u64)] [n : i64]) : bool
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

(define (case-u64 [n : i64]) : bool
  (let
    [keys : (Array u64) (make-array u64 n)]
    [left : (Array u64) (make-array u64 n)]
    [right : (Array u64) (make-array u64 n)]
    [got : (Array u64) (make-array u64 n)]
    [want : (Array u64) (make-array u64 n)]
    [pivot : u64 (cast 50 : u64)]
    (begin
      (init-u64 keys left right n)
      (fill-u64-foreach keys left right got n pivot)
      (fill-u64-scalar keys left right want n pivot)
      (eq-u64 got want n))))

(define (init-f32
  [keys : (Array f32)]
  [left : (Array f32)]
  [right : (Array f32)]
  [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set! keys i (cast (+ i 1) : f32))
        (array-set! left i (cast (+ i 30) : f32))
        (array-set! right i (cast (+ i 300) : f32))
        (set! i (+ i 1))))))

(define (fill-f32-foreach
  [keys : (Array f32)]
  [left : (Array f32)]
  [right : (Array f32)]
  [out : (Array f32)]
  [n : i64]
  [pivot : f32]) : unit
  (foreach
    ([i : i64 0 n])
    (array-set!
      out
      i
      (if (< (array-ref keys i) pivot)
        (array-ref left i)
        (array-ref right i)))))

(define (fill-f32-scalar
  [keys : (Array f32)]
  [left : (Array f32)]
  [right : (Array f32)]
  [out : (Array f32)]
  [n : i64]
  [pivot : f32]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set!
          out
          i
          (if (< (array-ref keys i) pivot)
            (array-ref left i)
            (array-ref right i)))
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
    [keys : (Array f32) (make-array f32 n)]
    [left : (Array f32) (make-array f32 n)]
    [right : (Array f32) (make-array f32 n)]
    [got : (Array f32) (make-array f32 n)]
    [want : (Array f32) (make-array f32 n)]
    [pivot : f32 9.5]
    (begin
      (init-f32 keys left right n)
      (fill-f32-foreach keys left right got n pivot)
      (fill-f32-scalar keys left right want n pivot)
      (eq-f32 got want n))))

(define (init-f64
  [keys : (Array f64)]
  [left : (Array f64)]
  [right : (Array f64)]
  [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set! keys i (cast (+ i 1) : f64))
        (array-set! left i (cast (+ i 40) : f64))
        (array-set! right i (cast (+ i 400) : f64))
        (set! i (+ i 1))))))

(define (fill-f64-foreach
  [keys : (Array f64)]
  [left : (Array f64)]
  [right : (Array f64)]
  [out : (Array f64)]
  [n : i64]
  [pivot : f64]) : unit
  (foreach
    ([i : i64 0 n])
    (array-set!
      out
      i
      (if (< (array-ref keys i) pivot)
        (array-ref left i)
        (array-ref right i)))))

(define (fill-f64-scalar
  [keys : (Array f64)]
  [left : (Array f64)]
  [right : (Array f64)]
  [out : (Array f64)]
  [n : i64]
  [pivot : f64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set!
          out
          i
          (if (< (array-ref keys i) pivot)
            (array-ref left i)
            (array-ref right i)))
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
    [keys : (Array f64) (make-array f64 n)]
    [left : (Array f64) (make-array f64 n)]
    [right : (Array f64) (make-array f64 n)]
    [got : (Array f64) (make-array f64 n)]
    [want : (Array f64) (make-array f64 n)]
    [pivot : f64 7.5]
    (begin
      (init-f64 keys left right n)
      (fill-f64-foreach keys left right got n pivot)
      (fill-f64-scalar keys left right want n pivot)
      (eq-f64 got want n))))

(define (init-bool
  [keys : (Array bool)]
  [left : (Array bool)]
  [right : (Array bool)]
  [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set! keys i (< (% i 3) 2))
        (array-set! left i (= (% i 2) 0))
        (array-set! right i (= (% i 5) 0))
        (set! i (+ i 1))))))

(define (fill-bool-foreach
  [keys : (Array bool)]
  [left : (Array bool)]
  [right : (Array bool)]
  [out : (Array bool)]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (array-set!
      out
      i
      (if (array-ref keys i)
        (array-ref left i)
        (array-ref right i)))))

(define (fill-bool-scalar
  [keys : (Array bool)]
  [left : (Array bool)]
  [right : (Array bool)]
  [out : (Array bool)]
  [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set!
          out
          i
          (if (array-ref keys i)
            (array-ref left i)
            (array-ref right i)))
        (set! i (+ i 1))))))

(define (eq-bool [a : (Array bool)] [b : (Array bool)] [n : i64]) : bool
  (let
    [i : i64 0]
    [ok : bool true]
    (begin
      (while (< i n)
        (begin
          (if (array-ref a i)
            (if (array-ref b i)
              unit
              (set! ok false))
            (if (array-ref b i)
              (set! ok false)
              unit))
          (set! i (+ i 1))))
      ok)))

(define (case-bool [n : i64]) : bool
  (let
    [keys : (Array bool) (make-array bool n)]
    [left : (Array bool) (make-array bool n)]
    [right : (Array bool) (make-array bool n)]
    [got : (Array bool) (make-array bool n)]
    [want : (Array bool) (make-array bool n)]
    (begin
      (init-bool keys left right n)
      (fill-bool-foreach keys left right got n)
      (fill-bool-scalar keys left right want n)
      (eq-bool got want n))))

(define (main) : i64
  (begin
    (unless (case-u32 19) (return 2))
    (unless (case-u64 13) (return 3))
    (unless (case-f32 19) (return 4))
    (unless (case-f64 13) (return 5))
    (unless (case-bool 67) (return 6))
    42))