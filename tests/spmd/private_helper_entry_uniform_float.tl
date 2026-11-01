;; #9301: varying x precedes ten uniform floats in an out-of-line helper.
;; Loading x must preserve every unread incoming uniform XMM argument. Eleven
;; lanes also exercise the partial final gang in AVX2 and AVX-512.
(define (heavy
  [x : f64]
  [a : f64]
  [b : f64]
  [c : f64]
  [d : f64]
  [e : f64]
  [f : f64]
  [g : f64]
  [h : f64]
  [i : f64]
  [j : f64]) : f64
  (+
    x
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
                (+ (* 64.0 g) (+ (* 128.0 h) (+ (* 256.0 i) (* 512.0 j))))))))))))

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
    (set! (array-ref out k) (heavy (array-ref xs k) a b c d e f g h i j))))

(define (main) : i64
  (let
    [xs : (__tl_dyn-array f64)
      (__tl_make-array 0.0 1.0 2.0 3.0 4.0 5.0 6.0 7.0 8.0 9.0 10.0)]
    [out : (__tl_dyn-array f64) (__tl_make-array f64 11)]
    [index : i64 0]
    (fill (&mut out) (& xs) 11 1.0 2.0 3.0 4.0 5.0 6.0 7.0 8.0 9.0 10.0)
    (while (< index 11)
      (unless
        (= (array-ref out index) (+ 9217.0 (cast index : f64)))
        (return 1))
      (+= index 1))
    42))