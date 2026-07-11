;; Both documented workarounds keep aggregate vector reads usable.
(import stdlib.comptime)
(import stdlib.vector)
(import (vector.vector Ball) as bvec)

(defstruct Ball
  (x i64)
  (y i64))

(defstruct World
  (balls bvec.Vec))

(define (draw-ball [ball : Ball]) : unit
  unit)

;; Give the macro a vector place, then borrow its slots place explicitly.
(defmacro (for-each-place [vec : Expr] [body : Expr]) : unit
  `(let
    [idx : i64 0]
    (while (< idx (struct-get ,vec len))
      (,body (array-ref (& (struct-get ,vec slots)) idx))
      (set! idx (+ idx 1)))))

(define (draw-balls-from-place [world : (& a World)]) : unit
  (for-each-place world.balls draw-ball))

;; The generated helper returns an owned aggregate from a shared vector borrow.
(define (draw-ball-from-get [world : (& a World)] [idx : i64]) : unit
  (draw-ball (bvec.get (& world.balls) idx (Ball 0 0))))