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
  (foreach
    ([i : i64 0 n])
    (let
      [j : i64 (array-ref ix i)]
      (array-set! out i (array-ref xs j)))))

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
    [xs : (Array i64) (make-array i64 source-len)]
    [ix : (Array i64) (make-array i64 n)]
    [got : (Array i64) (make-array i64 n)]
    [want : (Array i64) (make-array i64 n)]
    (begin
      (init-source xs source-len)
      (init-index ix n source-len)
      (fill-gather-foreach xs ix got n)
      (fill-gather-scalar xs ix want n)
      (eq-i64 got want n))))

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
      ok)))

(define (main) : i64
  (if (all-cases)
    42
    1))