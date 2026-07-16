;; AVX2/AVX-512 nested varying-while mask coverage. Exact-sized arrays make
;; every sub-gang and tail case an inactive-lane bounds-safety check too.
(import stdlib.array)

(define (fill-nested
  [outer : (Array i64)]
  [inner : (Array i64)]
  [out : (Array i64)]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (while (> (array-ref outer i) 0)
      (begin
        (while (> (array-ref inner i) 0)
          (begin
            (array-set! out i (+ (array-ref out i) 1))
            (array-set! inner i (+ (array-ref inner i) -1))))
        (array-set! out i (+ (array-ref out i) 10))
        (array-set! outer i (+ (array-ref outer i) -1))
        (array-set! inner i (+ (% i 2) 1))))))

(define (fill-scalar
  [outer : (Array i64)]
  [inner : (Array i64)]
  [out : (Array i64)]
  [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (while (> (array-ref outer i) 0)
          (begin
            (while (> (array-ref inner i) 0)
              (begin
                (array-set! out i (+ (array-ref out i) 1))
                (array-set! inner i (+ (array-ref inner i) -1))))
            (array-set! out i (+ (array-ref out i) 10))
            (array-set! outer i (+ (array-ref outer i) -1))
            (array-set! inner i (+ (% i 2) 1))))
        (set! i (+ i 1))))))

(define (run-case [n : i64]) : bool
  (let
    [outer : (Array i64) (array.make-array i64 n)]
    [outer-ref : (Array i64) (array.make-array i64 n)]
    [inner : (Array i64) (array.make-array i64 n)]
    [inner-ref : (Array i64) (array.make-array i64 n)]
    [got : (Array i64) (array.make-array i64 n)]
    [want : (Array i64) (array.make-array i64 n)]
    [i : i64 0]
    [ok : bool true]
    (begin
      (while (< i n)
        (let
          [outer-count : i64 (% i 4)]
          [inner-count : i64 (+ (% i 2) 1)]
          (begin
            (array-set! outer i outer-count)
            (array-set! outer-ref i outer-count)
            (array-set! inner i inner-count)
            (array-set! inner-ref i inner-count)
            (set! i (+ i 1)))))
      (fill-nested outer inner got n)
      (fill-scalar outer-ref inner-ref want n)
      (set! i 0)
      (while (< i n)
        (begin
          (if (!= (array-ref got i) (array-ref want i))
            (set! ok false)
            unit)
          (set! i (+ i 1))))
      ok)))

(define (main) : i64
  (if (and
    (run-case 0)
    (run-case 3)
    (run-case 4)
    (run-case 5)
    (run-case 8)
    (run-case 13))
    42
    1))