(import stdlib.math)

(define (fill
  [xs : (& xs (__tl_dyn-array f64))]
  [out : (&mut out (__tl_dyn-array f64))]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (set! (array-ref out i) (math.f64-clamp (array-ref xs i) -3.0 3.0))))

(define (main) : i64
  (let
    [n : i64 13]
    [xs : (__tl_dyn-array f64) (__tl_make-array f64 n)]
    [out : (__tl_dyn-array f64) (__tl_make-array f64 n)]
    [i : i64 0]
    [ok : bool true]
    (begin
      (while (< i n)
        (begin
          (set! (array-ref xs i) (cast (- i 6) : f64))
          (set! i (+ i 1))))
      (fill (& xs) (&mut out) n)
      (set! i 0)
      (while (< i n)
        (let
          [x : f64 (array-ref xs i)]
          [expected : f64
            (if (< x -3.0)
              -3.0
              (if (> x 3.0)
                3.0
                x))]
          (begin
            (set! ok (and ok (= (array-ref out i) expected)))
            (set! i (+ i 1)))))
      (if ok
        42
        1))))