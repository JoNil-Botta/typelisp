;; Eight varying inputs must survive two ordinary calls, alongside uniform
;; float arguments and an active mask. The helper exceeds the inlining budget.
(import stdlib.math)

(define (clamp-sum
  [a : f64]
  [b : f64]
  [c : f64]
  [d : f64]
  [e : f64]
  [f : f64]
  [g : f64]
  [h : f64]
  [lo : f64]
  [hi : f64]
  [take : bool]) : f64
  (let
    [low : f64 (math.f64-min lo hi)]
    [high : f64 (math.f64-max lo hi)]
    [sum : f64 (+ a (+ b (+ c (+ d (+ e (+ f (+ g h)))))))]
    (if take
      (if (< sum low)
        low
        (if (> sum high)
          high
          sum))
      17.0)))

(define (fill
  [xs : (& xs (__tl_dyn-array f64))]
  [out : (&mut out (__tl_dyn-array f64))]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (let
      [x : f64 (array-ref xs i)]
      (set!
        (array-ref out i)
        (clamp-sum
          x
          (+ x 1.0)
          (+ x 2.0)
          (+ x 3.0)
          (+ x 4.0)
          (+ x 5.0)
          (+ x 6.0)
          (+ x 7.0)
          -8.0
          8.0
          (!= x -4.0))))))

(define (check-length [n : i64]) : bool
  (let
    [xs : (__tl_dyn-array f64) (__tl_make-array f64 n)]
    [out : (__tl_dyn-array f64) (__tl_make-array f64 n)]
    [i : i64 0]
    [ok : bool true]
    (begin
      (while (< i n)
        (begin
          (set! (array-ref xs i) (cast (- (% i 13) 6) : f64))
          (set! (array-ref out i) 17.0)
          (set! i (+ i 1))))
      (fill (& xs) (&mut out) n)
      (set! i 0)
      (while (< i n)
        (let
          [sum : f64 (+ (* (array-ref xs i) 8.0) 28.0)]
          [expected : f64
            (if (= (array-ref xs i) -4.0)
              17.0
              (if (< sum -8.0)
                -8.0
                (if (> sum 8.0)
                  8.0
                  sum)))]
          (begin
            (set! ok (and ok (= (array-ref out i) expected)))
            (set! i (+ i 1)))))
      ok)))

(define (main) : i64
  (if (and
    (check-length 0)
    (check-length 1)
    (check-length 4)
    (check-length 8)
    (check-length 13)
    (check-length 32))
    42
    1))
