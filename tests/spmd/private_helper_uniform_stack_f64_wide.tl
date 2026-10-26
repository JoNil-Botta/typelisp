;; #9302: private varying helper whose stack-passed uniform floats i and j live in
;; frame slots. Eight leading uniforms fill System V's float argument registers
;; and nine varying arguments fill the low vector homes, so on AVX2 the last
;; varying value is homed in %ymm2. The helper's entry used to copy i and j
;; through %xmm2 after loading that value, overwriting it. AVX-512 admits at
;; most eight varying arguments; private_helper_uniform_stack_f64.tl is the
;; AVX-512-legal sibling.
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
  [x8 : f64]
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
          (+
            (* 4.0 x3)
            (+
              (* 5.0 x4)
              (+ (* 6.0 x5) (+ (* 7.0 x6) (+ (* 8.0 x7) (* 9.0 x8)))))))))))

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
          (+ x 8.0)
          i
          j)))))

;; The uniform part is 9217; the varying part is 45x + 240.
(define (main) : i64
  (let
    [xs : (__tl_dyn-array f64)
      (__tl_make-array 0.0 1.0 2.0 3.0 4.0 5.0 6.0 7.0)]
    [out : (__tl_dyn-array f64) (__tl_make-array f64 8)]
    (fill (&mut out) (& xs) 8 1.0 2.0 3.0 4.0 5.0 6.0 7.0 8.0 9.0 10.0)
    (if (and (= (array-ref out 0) 9457.0) (= (array-ref out 7) 9772.0))
      42
      1)))