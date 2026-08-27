;; AVX2/AVX-512 nested varying-while mask coverage. Exact-sized arrays make
;; every sub-gang and tail case an inactive-lane bounds-safety check too.

(define (fill-nested
  [outer : (&mut outer (__tl_dyn-array i64))]
  [inner : (&mut inner (__tl_dyn-array i64))]
  [out : (&mut out (__tl_dyn-array i64))]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (while (> (array-ref outer i) 0)
      (begin
        (while (> (array-ref inner i) 0)
          (begin
            (set! (array-ref out i) (+ (array-ref out i) 1))
            (set! (array-ref inner i) (+ (array-ref inner i) -1))))
        (set! (array-ref out i) (+ (array-ref out i) 10))
        (set! (array-ref outer i) (+ (array-ref outer i) -1))
        (set! (array-ref inner i) (+ (% i 2) 1))))))

(define (fill-scalar
  [outer : (&mut outer (__tl_dyn-array i64))]
  [inner : (&mut inner (__tl_dyn-array i64))]
  [out : (&mut out (__tl_dyn-array i64))]
  [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (while (> (array-ref outer i) 0)
          (begin
            (while (> (array-ref inner i) 0)
              (begin
                (set! (array-ref out i) (+ (array-ref out i) 1))
                (set! (array-ref inner i) (+ (array-ref inner i) -1))))
            (set! (array-ref out i) (+ (array-ref out i) 10))
            (set! (array-ref outer i) (+ (array-ref outer i) -1))
            (set! (array-ref inner i) (+ (% i 2) 1))))
        (set! i (+ i 1))))))

(define (run-case [n : i64]) : bool
  (let
    [outer : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    [outer-ref : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    [inner : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    [inner-ref : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    [got : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    [want : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    [i : i64 0]
    [ok : bool true]
    (begin
      (while (< i n)
        (let
          [outer-count : i64 (% i 4)]
          [inner-count : i64 (+ (% i 2) 1)]
          (begin
            (set! (array-ref outer i) outer-count)
            (set! (array-ref outer-ref i) outer-count)
            (set! (array-ref inner i) inner-count)
            (set! (array-ref inner-ref i) inner-count)
            (set! i (+ i 1)))))
      (fill-nested (&mut outer) (&mut inner) (&mut got) n)
      (fill-scalar (&mut outer-ref) (&mut inner-ref) (&mut want) n)
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