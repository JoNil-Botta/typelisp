;; A tail call whose argument is a shared borrow of a by-value aggregate
;; parameter keeps the frame-reusing jump: the parameter lives in storage the
;; caller provided, so the borrow stays valid after the frame is reused, exactly
;; like passing the parameter itself.
(defstruct Quad
  (a i64)
  (b i64)
  (c i64)
  (d i64))

;; Not a leaf the inliner would fold away: it walks `k` steps.
(define (shift [q : (& Quad)] [k : i64]) : Quad
  (let
    [a : i64 q.a]
    [d : i64 q.d]
    [i : i64 0]
    (while (< i k)
      (set! a (+ a 1))
      (set! d (+ d 1))
      (set! i (+ i 1)))
    (Quad a q.b q.c d)))

(define (forward [q : Quad] [k : i64]) : Quad
  (shift (& q) k))

;; A parameter the body writes has private storage in this frame (#7901), so a
;; borrow of it is not a borrow of caller storage: the call keeps its frame, and
;; the callee sees the write.
(define (forward-written [q : Quad] [k : i64]) : Quad
  (set! q.b 0)
  (shift (& q) k))

(define (total [q : (& Quad)]) : i64
  (+ (+ q.a q.b) (+ q.c q.d)))

(define (main) : i64
  (let
    [r : Quad (forward (Quad 10 5 6 7) 7)]
    [w : Quad (forward-written (Quad 10 5 6 7) 7)]
    (if (= (total (& w)) 37)
      (total (& r))
      1)))