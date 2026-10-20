;; Probe: tail call with a two-word struct argument next to two swapped GP
;; parameters.
(defstruct P
  (x i64)
  (y i64))

(define (g4 [a : i64] [b : i64] [p : P]) : i64
  (if (> a 0)
    (+ (* 3 a) (+ b (+ p.x p.y)))
    0))

(define (s4 [a : i64] [b : i64] [n : i64] [m : i64] [p : P]) : i64
  (if (>= n m)
    (g4 b a p)
    (s4 a b (+ n 1) m p)))

;; g4(10, 7, P(2, 3)) = 30 + 7 + 5 = 42
(define (main) : i64
  (s4 7 10 0 3 (P 2 3)))