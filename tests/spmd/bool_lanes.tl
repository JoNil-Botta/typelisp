(import stdlib.array)

(define (init-bool [flags : (Array bool)] [values : (Array i64)] [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set! flags i (< i 5))
        (array-set! values i (- i 4))
        (set! i (+ i 1))))))

(define (init-i32 [values : (Array i32)] [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set! values i (cast (- i 4) : i32))
        (set! i (+ i 1))))))

(define (init-i16 [values : (Array i16)] [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set! values i (cast (- i 4) : i16))
        (set! i (+ i 1))))))

(define (init-i8 [values : (Array i8)] [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set! values i (cast (- i 4) : i8))
        (set! i (+ i 1))))))

(define (fill-bool-copy-foreach
  [src : (Array bool)]
  [out : (Array bool)]
  [n : i64]) : unit
  (foreach ([i : i64 0 n]) (array-set! out i (array-ref src i))))

(define (fill-bool-copy-scalar
  [src : (Array bool)]
  [out : (Array bool)]
  [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set! out i (array-ref src i))
        (set! i (+ i 1))))))

(define (fill-bool-compare-foreach
  [values : (Array i64)]
  [out : (Array bool)]
  [n : i64]) : unit
  (foreach ([i : i64 0 n]) (array-set! out i (< (array-ref values i) 0))))

(define (fill-bool-compare-scalar
  [values : (Array i64)]
  [out : (Array bool)]
  [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set! out i (< (array-ref values i) 0))
        (set! i (+ i 1))))))

(define (fill-bool-compare-i32-foreach
  [values : (Array i32)]
  [out : (Array bool)]
  [n : i64]) : unit
  (foreach ([i : i64 0 n]) (array-set! out i (< (array-ref values i) 0))))

(define (fill-bool-compare-i32-scalar
  [values : (Array i32)]
  [out : (Array bool)]
  [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set! out i (< (array-ref values i) 0))
        (set! i (+ i 1))))))

(define (fill-bool-compare-i16-foreach
  [values : (Array i16)]
  [out : (Array bool)]
  [n : i64]) : unit
  (foreach ([i : i64 0 n]) (array-set! out i (< (array-ref values i) 0))))

(define (fill-bool-compare-i16-scalar
  [values : (Array i16)]
  [out : (Array bool)]
  [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set! out i (< (array-ref values i) 0))
        (set! i (+ i 1))))))

(define (fill-bool-compare-i8-foreach
  [values : (Array i8)]
  [out : (Array bool)]
  [n : i64]) : unit
  (foreach ([i : i64 0 n]) (array-set! out i (< (array-ref values i) 0))))

(define (fill-bool-compare-i8-scalar
  [values : (Array i8)]
  [out : (Array bool)]
  [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set! out i (< (array-ref values i) 0))
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
    [flags : (Array bool) (array.make-array bool n)]
    [values : (Array i64) (array.make-array i64 n)]
    [values32 : (Array i32) (array.make-array i32 n)]
    [values16 : (Array i16) (array.make-array i16 n)]
    [values8 : (Array i8) (array.make-array i8 n)]
    [copy-got : (Array bool) (array.make-array bool n)]
    [copy-want : (Array bool) (array.make-array bool n)]
    [cmp-got : (Array bool) (array.make-array bool n)]
    [cmp-want : (Array bool) (array.make-array bool n)]
    [cmp32-got : (Array bool) (array.make-array bool n)]
    [cmp32-want : (Array bool) (array.make-array bool n)]
    [cmp16-got : (Array bool) (array.make-array bool n)]
    [cmp16-want : (Array bool) (array.make-array bool n)]
    [cmp8-got : (Array bool) (array.make-array bool n)]
    [cmp8-want : (Array bool) (array.make-array bool n)]
    (begin
      (init-bool flags values n)
      (init-i32 values32 n)
      (init-i16 values16 n)
      (init-i8 values8 n)
      (fill-bool-copy-foreach flags copy-got n)
      (fill-bool-copy-scalar flags copy-want n)
      (fill-bool-compare-foreach values cmp-got n)
      (fill-bool-compare-scalar values cmp-want n)
      (fill-bool-compare-i32-foreach values32 cmp32-got n)
      (fill-bool-compare-i32-scalar values32 cmp32-want n)
      (fill-bool-compare-i16-foreach values16 cmp16-got n)
      (fill-bool-compare-i16-scalar values16 cmp16-want n)
      (fill-bool-compare-i8-foreach values8 cmp8-got n)
      (fill-bool-compare-i8-scalar values8 cmp8-want n)
      (and
        (eq-bool copy-got copy-want n)
        (and
          (eq-bool cmp-got cmp-want n)
          (and
            (eq-bool cmp32-got cmp32-want n)
            (and
              (eq-bool cmp16-got cmp16-want n)
              (eq-bool cmp8-got cmp8-want n))))))))

(define (all-cases) : bool
  (and
    (case-bool 0)
    (case-bool 3)
    (case-bool 8)
    (case-bool 9)
    (case-bool 64)
    (case-bool 65)))

(define (main) : i64
  (if (all-cases)
    42
    1))