;; #9302: private varying helper with eight varying arguments (the AVX-512 limit)
;; and stack-passed uniform floats i and j that live in frame slots. Their entry
;; copies must run before the varying values reach their homes. The length 11
;; leaves a three-lane tail on AVX2 and on AVX-512.
(define (heavy
  [a : f64]
  [b : f64]
  [c : f64]
  [d : f64]
  [e : f64]
  [f : f64]
  [g : f64]
  [h : f64]
  [x0 : f64]
  [x1 : f64]
  [x2 : f64]
  [x3 : f64]
  [x4 : f64]
  [x5 : f64]
  [x6 : f64]
  [x7 : f64]
  [i : f64]
  [j : f64]) : f64
  (+
    (+
      a
      (+
        (* 2.0 b)
        (+
          (* 4.0 c)
          (+
            (* 8.0 d)
            (+
              (* 16.0 e)
              (+
                (* 32.0 f)
                (+ (* 64.0 g) (+ (* 128.0 h) (+ (* 256.0 i) (* 512.0 j))))))))))
    (+
      x0
      (+
        (* 2.0 x1)
        (+
          (* 3.0 x2)
          (+ (* 4.0 x3) (+ (* 5.0 x4) (+ (* 6.0 x5) (+ (* 7.0 x6) (* 8.0 x7))))))))))

(define (fill
  [out : (&mut out (__tl_dyn-array f64))]
  [xs : (& xs (__tl_dyn-array f64))]
  [n : i64]
  [a : f64]
  [b : f64]
  [c : f64]
  [d : f64]
  [e : f64]
  [f : f64]
  [g : f64]
  [h : f64]
  [i : f64]
  [j : f64]) : unit
  (foreach
    ([k : i64 0 n])
    (let
      [x : f64 (array-ref xs k)]
      (set!
        (array-ref out k)
        (heavy
          a
          b
          c
          d
          e
          f
          g
          h
          x
          (+ x 1.0)
          (+ x 2.0)
          (+ x 3.0)
          (+ x 4.0)
          (+ x 5.0)
          (+ x 6.0)
          (+ x 7.0)
          i
          j)))))

;; The uniform part is 9217; the varying part is 36x + 168.
(define (main) : i64
  (let
    [xs : (__tl_dyn-array f64)
      (__tl_make-array 0.0 1.0 2.0 3.0 4.0 5.0 6.0 7.0 8.0 9.0 10.0)]
    [out : (__tl_dyn-array f64) (__tl_make-array f64 11)]
    (fill (&mut out) (& xs) 11 1.0 2.0 3.0 4.0 5.0 6.0 7.0 8.0 9.0 10.0)
    (if (and (= (array-ref out 0) 9385.0) (= (array-ref out 10) 9745.0))
      42
      1)))