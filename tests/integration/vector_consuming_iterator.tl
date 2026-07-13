;; Generated Vec consuming iteration moves the source and yields owned items.
(import stdlib.vector)
(import (vector.vector i64) as i64vec)

(defstruct ConsumingIteratorPoint
  (x i64)
  (y i64))

(defstruct ConsumingIteratorBall
  (center ConsumingIteratorPoint)
  (radius i64))

(import (vector.vector ConsumingIteratorBall) as ballvec)

(define source-evaluations : i64
  0)

(define (make-counted-numbers) : i64vec.Vec
  (let
    [values : i64vec.Vec (i64vec.new)]
    (begin
      (set! source-evaluations (+ source-evaluations 1))
      (i64vec.push (&mut values) 9)
      values)))

(define (i64-item-or [step : i64vec.IntoNext] [fallback : i64]) : i64
  (match step
    [(i64vec.IntoNext.Done) fallback]
    [(i64vec.IntoNext.Item value) value]))

(define (i64-done? [step : i64vec.IntoNext]) : bool
  (match step
    [(i64vec.IntoNext.Done) true]
    [(i64vec.IntoNext.Item _) false]))

(define (ball-score [step : ballvec.IntoNext]) : i64
  (match step
    [(ballvec.IntoNext.Done) 0]
    [(ballvec.IntoNext.Item ball)
      (+ ball.center.x (+ ball.center.y ball.radius))]))

(define (main) : i64
  (let
    [empty : i64vec.Vec (i64vec.new)]
    [numbers : i64vec.Vec (i64vec.new)]
    [balls : ballvec.Vec (ballvec.new)]
    (begin
      (i64vec.push (&mut numbers) 10)
      (i64vec.push (&mut numbers) 32)
      (ballvec.push
        (&mut balls)
        (ConsumingIteratorBall (ConsumingIteratorPoint 3 4) 5))
      (ballvec.push
        (&mut balls)
        (ConsumingIteratorBall (ConsumingIteratorPoint 1 2) 7))
      (let
        [empty-iter : i64vec.IntoIter (i64vec.into-iterator empty)]
        [number-iter : i64vec.IntoIter (i64vec.into-iterator numbers)]
        [ball-iter : ballvec.IntoIter (ballvec.into-iterator balls)]
        [counted-iter : i64vec.IntoIter
          (i64vec.into-iterator (make-counted-numbers))]
        [first-ball : i64 (ball-score (ballvec.into-next (&mut ball-iter)))]
        ;; Pausing after one item models an early loop break. The iterator keeps
        ;; the unvisited second ball and can resume without copying it.
        [second-ball : i64 (ball-score (ballvec.into-next (&mut ball-iter)))]
        (if (and
          (i64-done? (i64vec.into-next (&mut empty-iter)))
          (i64-done? (i64vec.into-next (&mut empty-iter)))
          (= (i64-item-or (i64vec.into-next (&mut number-iter)) 0) 10)
          (= (i64-item-or (i64vec.into-next (&mut number-iter)) 0) 32)
          (i64-done? (i64vec.into-next (&mut number-iter)))
          (i64-done? (i64vec.into-next (&mut number-iter)))
          (= first-ball 12)
          (= second-ball 10)
          (= (ball-score (ballvec.into-next (&mut ball-iter))) 0)
          (= source-evaluations 1)
          (= (i64-item-or (i64vec.into-next (&mut counted-iter)) 0) 9))
          42
          1)))))