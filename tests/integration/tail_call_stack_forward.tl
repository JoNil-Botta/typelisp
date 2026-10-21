;; Register permutations and duplicate sources cross the GP stack boundary.
(define (weighted
  [a : i64]
  [b : i64]
  [c : i64]
  [d : i64]
  [e : i64]
  [f : i64]
  [g : i64]) : i64
  (+
    a
    (+
      (* 11 b)
      (+
        (* 121 c)
        (+ (* 1331 d) (+ (* 14641 e) (+ (* 161051 f) (* 1771561 g))))))))

(define (fallback [a : i64] [b : i64] [c : i64] [d : i64] [e : i64] [f : i64]) : i64
  (weighted b a d c f e a))

(define (jump
  [a : i64]
  [b : i64]
  [c : i64]
  [d : i64]
  [e : i64]
  [f : i64]
  [g : i64]) : i64
  (weighted g a f b e c d))

(defstruct Wide
  (a i64)
  (b i64)
  (c i64)
  (d i64))

(define (make-wide [a : i64] [b : i64] [c : i64] [d : i64] [e : i64] [k : i64]) : Wide
  (Wide (+ a k) (+ b e) c d))

(define (forward-wide [a : i64] [b : i64] [c : i64] [d : i64] [e : i64]) : Wide
  (make-wide a b c d e 0))

(define (main) : i64
  (let
    [wide : Wide (forward-wide -3 11 17 23 31)]
    [zero : i64 (fallback 0 0 0 0 0 0)]
    [mixed : i64 (fallback -1 2 -3 4 -5 6)]
    (if (and
      (= (fallback 1 2 3 4 5 6) 2669152)
      (= (jump 1 2 3 4 5 6 7) 7646008)
      (= zero 0)
      (= mixed -2492488)
      (= wide.a -3)
      (= wide.b 42)
      (= wide.c 17)
      (= wide.d 23))
      42
      1)))