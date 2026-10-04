;: Canonical rank-2 row-major writes are disjoint over the whole domain: any
;: stable uniform base and coordinate offsets, the span as (- end begin) or as a bare
;: end over a literal zero begin, and additive terms in any order or grouping.
(define (fill-offset
  [out : (&mut out (__tl_dyn-array i64))]
  [base : i64]
  [y0 : i64]
  [y1 : i64]
  [x0 : i64]
  [x1 : i64]) : unit
  (foreach
    ([y : i64 y0 y1] [x : i64 x0 x1])
    (set!
      (array-ref
        out
        (+ (+ (* base 1) (cast 0 : i64)) (+ (* (- y y0) (- x1 x0)) (- x x0))))
      (+ (* y 100) x))))

(define (fill-swapped
  [out : (&mut out (__tl_dyn-array i64))]
  [h : i64]
  [w : i64]) : unit
  (foreach
    ([y : i64 0 h] [x : i64 0 w])
    (set! (array-ref out (+ x (* w y))) (+ (* y 100) x))))

(define (fill-literal [out : (&mut out (__tl_dyn-array i64))]) : unit
  (foreach
    ([y : i64 0 2] [x : i64 0 4])
    (set! (array-ref out (+ (+ 8 (* y 4)) x)) (+ (* y 100) x))))

(define (fill-masked
  [out : (&mut out (__tl_dyn-array i64))]
  [h : i64]
  [w : i64]) : unit
  (foreach
    ([y : i64 0 h] [x : i64 0 w])
    (if (= (% x 2) 0)
      (set! (array-ref out (+ (* y w) x)) -1)
      unit)))

(define (fill-captured [out : (&mut out (__tl_dyn-array i64))]) : unit
  (let
    [memory : (Array i64 1) (make-array i64 1)]
    [base : i64 (array-ref memory 0)]
    (foreach
      ([y : i64 0 2] [x : i64 0 2])
      (begin
        (set! (array-ref out (+ base (+ (* y 2) x))) (+ (* y 100) x))
        (foreach-active [lane : i64] (set! (array-ref memory 0) 7))))))

(define (main) : i64
  (let
    [a : (__tl_dyn-array i64) (__tl_make-array i64 12)]
    [b : (__tl_dyn-array i64) (__tl_make-array i64 6)]
    [c : (__tl_dyn-array i64) (__tl_make-array i64 16)]
    [d : (__tl_dyn-array i64) (__tl_make-array i64 4)]
    (begin
      (fill-offset (&mut a) 2 1 4 -1 2)
      (fill-swapped (&mut b) 2 3)
      (fill-literal (&mut c))
      (fill-masked (&mut b) 2 3)
      (fill-captured (&mut d))
      (cond
        [(not
            (and
              (= (array-ref a 1) 0)
              (= (array-ref a 2) 99)
              (= (array-ref a 4) 101)
              (= (array-ref a 5) 199)
              (= (array-ref a 10) 301)
              (= (array-ref a 11) 0)))
          1]
        [(not
            (and
              (= (array-ref b 0) -1)
              (= (array-ref b 1) 1)
              (= (array-ref b 2) -1)
              (= (array-ref b 4) 101)
              (= (array-ref b 5) -1)))
          2]
        [(not
            (and
              (= (array-ref c 7) 0)
              (= (array-ref c 8) 0)
              (= (array-ref c 11) 3)
              (= (array-ref c 12) 100)
              (= (array-ref c 15) 103)))
          3]
        [(not
            (and
              (= (array-ref d 0) 0)
              (= (array-ref d 1) 1)
              (= (array-ref d 2) 100)
              (= (array-ref d 3) 101)))
          4]
        [else 42]))))