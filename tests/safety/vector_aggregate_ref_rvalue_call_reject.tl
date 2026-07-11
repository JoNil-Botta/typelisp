;; A direct aggregate read through a borrowed vector rvalue remains move-only.
;; The diagnostic must blame the caller's borrowed vector, not the macro body.
(import stdlib.comptime)
(import stdlib.vector)
(import (vector.vector Ball) as bvec)

(defmacro (for-each [vec : Expr] [body : Expr]) : unit
  `(let
    [idx : i64 0]
    (while (< idx (struct-get ,vec len))
      (,body (array-ref (struct-get ,vec slots) idx))
      (set! idx (+ idx 1)))))

(defstruct Ball
  (x i64)
  (y i64))

(defstruct World
  (balls bvec.Vec))

(define (draw-ball [ball : Ball]) : unit
  unit)

(define (draw-balls [world : (& a World)]) : unit
  (for-each (& world.balls) draw-ball))