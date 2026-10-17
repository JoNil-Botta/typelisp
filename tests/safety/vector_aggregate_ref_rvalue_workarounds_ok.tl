;; Direct Copy reads and both documented alternatives produce independent values.
(import stdlib.comptime as _comptime)
(import stdlib.vector)
(import stdlib.test)
(import (vector.vector Ball) as bvec)

(defstruct Ball
  (x i64)
  (y i64))

(defstruct World
  (balls bvec.Vec))

(define seen : i64
  0)

(define (draw-ball [ball : Ball]) : unit
  (set! seen (+ seen (+ ball.x ball.y)))
  (set! ball.x 100)
  (test.assert-i64-eq ball.x 100 "callee writes its copy"))

(defmacro (for-each [vec : Expr] [body : Expr]) : unit
  `(let
    [idx : i64 0]
    (while (< idx (__tl-project-field-name ,vec "len"))
      (,body (array-ref (__tl-project-field-name ,vec "slots") idx))
      (set! idx (+ idx 1)))))

(define (draw-balls-direct [world : (& a World)]) : unit
  (for-each (& world.balls) draw-ball))

;; Give the macro a vector place, then borrow its slots place explicitly.
(defmacro (for-each-place [vec : Expr] [body : Expr]) : unit
  `(let
    [idx : i64 0]
    (while (< idx (__tl-project-field-name ,vec "len"))
      (,body (array-ref (& (__tl-project-field-name ,vec "slots")) idx))
      (set! idx (+ idx 1)))))

(define (draw-balls-from-place [world : (& a World)]) : unit
  (for-each-place world.balls draw-ball))

;; The generated helper returns an owned aggregate from a shared vector borrow.
(define (draw-ball-from-get [world : (& a World)] [idx : i64]) : unit
  (draw-ball (bvec.get (& world.balls) idx (Ball 0 0))))

(define (main) : i64
  (let
    [balls (bvec.new)]
    (bvec.push! balls (Ball 20 22))
    (let
      [world (World balls)]
      (draw-balls-direct (& world))
      (draw-balls-from-place (& world))
      (draw-ball-from-get (& world) 0)
      (test.assert-i64-eq seen 126 "all three reads see the original value")
      (let
        [original (bvec.get (& world.balls) 0 (Ball 0 0))]
        (test.assert-i64-eq original.x 20 "callee writes preserve source x")
        (test.assert-i64-eq original.y 22 "callee writes preserve source y"))))
  42)