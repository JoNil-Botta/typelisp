;; Rank-2 foreach (#7190) lowers to the same scalar reference in every backend
;; mode: canonical row-major writes with nonzero lower bounds and a uniform
;; base, a literal span over a zero begin, and empty domains whose other
;; dimension would overflow. Exits 42 when every element matches.
(define (fill
  [out : (&mut out (__tl_dyn-array i64))]
  [base : i64]
  [y0 : i64]
  [y1 : i64]
  [x0 : i64]
  [x1 : i64]) : unit
  (foreach
    ([y : i64 y0 y1] [x : i64 x0 x1])
    (set!
      (array-ref out (+ base (+ (* (- y y0) (- x1 x0)) (- x x0))))
      (+ (* y 16) x))))

(define (fill-literal [out : (&mut out (__tl_dyn-array i64))]) : unit
  (foreach
    ([y : i64 0 3] [x : i64 0 5])
    (set! (array-ref out (+ x (* y 5))) (+ (* y 16) x))))

(define (main) : i64
  (let
    [out : (__tl_dyn-array i64) (__tl_make-array i64 40)]
    [lit : (__tl_dyn-array i64) (__tl_make-array i64 15)]
    [min : i64 (- -9223372036854775807 1)]
    [max : i64 9223372036854775807]
    [i : i64 0]
    [ok : bool true]
    (begin
      (fill (&mut out) 3 -2 3 4 11)
      (fill (&mut out) 0 7 7 min max)
      (fill (&mut out) 0 min max 9 2)
      (fill-literal (&mut lit))
      (while (< i 40)
        (let
          [k : i64 (- i 3)]
          [expected : i64
            (if (and (>= k 0) (< k 35))
              (+ (* (- (/ k 7) 2) 16) (+ (% k 7) 4))
              0)]
          (begin
            (when (not (= (array-ref out i) expected)) (set! ok false))
            (set! i (+ i 1)))))
      (set! i 0)
      (while (< i 15)
        (begin
          (when
            (not (= (array-ref lit i) (+ (* (/ i 5) 16) (% i 5))))
            (set! ok false))
          (set! i (+ i 1))))
      (if ok
        42
        1))))