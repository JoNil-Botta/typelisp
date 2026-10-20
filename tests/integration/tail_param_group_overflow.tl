;; Probe: overflowing tail call with a two-word struct and a permuted GP prefix.
(defstruct P
  (x i64)
  (y i64))

(define (fin
  [a : i64]
  [b : i64]
  [c : i64]
  [d : i64]
  [e : i64]
  [f : i64]
  [g : i64]
  [h : i64]
  [p : P]) : i64
  (if (> a 0)
    (+
      (* 2 a)
      (+
        (* 3 b)
        (+
          (* 5 c)
          (+
            (* 7 d)
            (+ (* 11 e) (+ (* 13 f) (+ (* 17 g) (+ (* 19 h) (+ p.x p.y)))))))))
    (+ b c)))

(define (stp
  [a : i64]
  [n : i64]
  [m : i64]
  [b : i64]
  [c : i64]
  [d : i64]
  [e : i64]
  [f : i64]
  [g : i64]
  [h : i64]
  [p : P]) : i64
  (if (>= n m)
    (fin b c d e a f g h p)
    (stp a (+ n 1) m b c d e f g h p)))

;; 2+6+15+28+55+78+119+152+(4+5) = 464
(define (main) : i64
  (- (stp 5 0 3 1 2 3 4 6 7 8 (P 4 5)) 422))