(define (init-bool [flags : (Array bool)] [values : (Array i64)] [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set! flags i (< i 5))
        (array-set! values i (- i 4))
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
    [flags : (Array bool) (make-array bool n)]
    [values : (Array i64) (make-array i64 n)]
    [copy-got : (Array bool) (make-array bool n)]
    [copy-want : (Array bool) (make-array bool n)]
    [cmp-got : (Array bool) (make-array bool n)]
    [cmp-want : (Array bool) (make-array bool n)]
    (begin
      (init-bool flags values n)
      (fill-bool-copy-foreach flags copy-got n)
      (fill-bool-copy-scalar flags copy-want n)
      (fill-bool-compare-foreach values cmp-got n)
      (fill-bool-compare-scalar values cmp-want n)
      (and (eq-bool copy-got copy-want n) (eq-bool cmp-got cmp-want n)))))

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