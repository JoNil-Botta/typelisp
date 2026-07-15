(import stdlib.array)

(define (init-source [xs : (Array i64)] [source-len : i64]) : unit
  (let
    [i : i64 0]
    (while (< i source-len)
      (begin
        (array-set! xs i (+ 100 (* i 3)))
        (set! i (+ i 1))))))

(define (init-index [ix : (Array i64)] [n : i64] [source-len : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set! ix i (% (+ (* i 5) 3) source-len))
        (set! i (+ i 1))))))

(define (fill-gather-foreach
  [xs : (Array i64)]
  [ix : (Array i64)]
  [out : (Array i64)]
  [n : i64]) : unit
  (foreach ([i : i64 0 n]) (array-set! out i (array-ref xs (array-ref ix i)))))

(define (fill-gather-scalar
  [xs : (Array i64)]
  [ix : (Array i64)]
  [out : (Array i64)]
  [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set! out i (array-ref xs (array-ref ix i)))
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

(define (case-gather [n : i64]) : bool
  (let
    [source-len : i64 17]
    [xs : (Array i64) (array.make-array i64 source-len)]
    [ix : (Array i64) (array.make-array i64 n)]
    [got : (Array i64) (array.make-array i64 n)]
    [want : (Array i64) (array.make-array i64 n)]
    (begin
      (init-source xs source-len)
      (init-index ix n source-len)
      (fill-gather-foreach xs ix got n)
      (fill-gather-scalar xs ix want n)
      (eq-i64 got want n))))

(define (case-numeric-gathers [n : i64]) : bool
  (let
    [source-len : i64 17]
    [ix : (Array i64) (array.make-array i64 n)]
    [xs32 : (Array i32) (array.make-array i32 source-len)]
    [got32 : (Array i32) (array.make-array i32 n)]
    [want32 : (Array i32) (array.make-array i32 n)]
    [xsf : (Array f32) (array.make-array f32 source-len)]
    [gotf : (Array f32) (array.make-array f32 n)]
    [wantf : (Array f32) (array.make-array f32 n)]
    [xsd : (Array f64) (array.make-array f64 source-len)]
    [gotd : (Array f64) (array.make-array f64 n)]
    [wantd : (Array f64) (array.make-array f64 n)]
    [i : i64 0]
    [ok : bool true]
    (begin
      (init-index ix n source-len)
      (while (< i source-len)
        (begin
          (array-set! xs32 i (cast (+ 11 (* i 7)) : i32))
          (array-set! xsf i (cast (+ 21 (* i 5)) : f32))
          (array-set! xsd i (cast (+ 31 (* i 9)) : f64))
          (set! i (+ i 1))))
      (foreach
        ([j : i64 0 n])
        (array-set! got32 j (array-ref xs32 (array-ref ix j))))
      (foreach
        ([j : i64 0 n])
        (array-set! gotf j (array-ref xsf (array-ref ix j))))
      (foreach
        ([j : i64 0 n])
        (array-set! gotd j (array-ref xsd (array-ref ix j))))
      (set! i 0)
      (while (< i n)
        (begin
          (array-set! want32 i (array-ref xs32 (array-ref ix i)))
          (array-set! wantf i (array-ref xsf (array-ref ix i)))
          (array-set! wantd i (array-ref xsd (array-ref ix i)))
          (set! i (+ i 1))))
      (set! i 0)
      (while (< i n)
        (begin
          (if (and
            (= (array-ref got32 i) (array-ref want32 i))
            (= (array-ref gotf i) (array-ref wantf i))
            (= (array-ref gotd i) (array-ref wantd i)))
            unit
            (set! ok false))
          (set! i (+ i 1))))
      ok)))

(define (all-cases) : bool
  (let
    [ok : bool true]
    (begin
      (if (case-gather 0)
        unit
        (set! ok false))
      (if (case-gather 1)
        unit
        (set! ok false))
      (if (case-gather 3)
        unit
        (set! ok false))
      (if (case-gather 13)
        unit
        (set! ok false))
      (if (case-gather 33)
        unit
        (set! ok false))
      (if (case-numeric-gathers 33)
        unit
        (set! ok false))
      ok)))

(define (main) : i64
  (if (all-cases)
    42
    1))