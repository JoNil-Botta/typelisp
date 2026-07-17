;; Generated Vec shared iterator coverage: borrowed scalar and aggregate items
;; retain their vector source lifetime without moving the stored element.
(import stdlib.vector)
(import (vector.vector i64) as i64vec)

(defstruct SharedIteratorPoint
  (x i64)
  (y i64))

(defstruct SharedIteratorBall
  (center SharedIteratorPoint)
  (radius i64))

(import (vector.vector SharedIteratorBall) as ballvec)

(define (observe-i64 [_value : (& source i64)]) : i64
  1)

(define (ball-score [ball : (& source SharedIteratorBall)]) : i64
  (+
    (+
      (struct-get (struct-get ball center) x)
      (struct-get (struct-get ball center) y))
    (struct-get ball radius)))

(define (i64-step-score [result : (i64vec.IterNext source)]) : i64
  (match result
    [(i64vec.IterNext.Done) 0]
    [(i64vec.IterNext.Item value) (observe-i64 value)]))

(define (ball-step-score [result : (ballvec.IterNext source)]) : i64
  (match result
    [(ballvec.IterNext.Done) 0]
    [(ballvec.IterNext.Item ball) (ball-score ball)]))

(define (main) : i64
  (let
    [numbers : i64vec.Vec (i64vec.new)]
    [balls : ballvec.Vec (ballvec.new)]
    [empty : i64vec.Vec (i64vec.new)]
    (begin
      (i64vec.push! numbers 17)
      (i64vec.push! numbers 25)
      (ballvec.push! balls (SharedIteratorBall (SharedIteratorPoint 3 4) 5))
      (let
        [number-iter : (i64vec.Iter numbers) (i64vec.iterator (& numbers))]
        [ball-iter : (ballvec.Iter balls) (ballvec.iterator (& balls))]
        [empty-iter : (i64vec.Iter empty) (i64vec.iterator (& empty))]
        [early-iter : (i64vec.Iter numbers) (i64vec.iterator (& numbers))]
        [first : i64 0]
        [second : i64 0]
        [number-done : i64 1]
        [number-done-again : i64 1]
        [empty-done : i64 1]
        [empty-done-again : i64 1]
        [ball-total : i64 0]
        [ball-done : i64 1]
        [ball-done-again : i64 1]
        [early-exit-score : i64 0]
        (begin
          (set! first (i64-step-score (i64vec.next (&mut number-iter))))
          (set! second (i64-step-score (i64vec.next (&mut number-iter))))
          (set! number-done (i64-step-score (i64vec.next (&mut number-iter))))
          (set!
            number-done-again
            (i64-step-score (i64vec.next (&mut number-iter))))
          (set! empty-done (i64-step-score (i64vec.next (&mut empty-iter))))
          (set!
            empty-done-again
            (i64-step-score (i64vec.next (&mut empty-iter))))
          (set! ball-total (ball-step-score (ballvec.next (&mut ball-iter))))
          (set! ball-done (ball-step-score (ballvec.next (&mut ball-iter))))
          (set!
            ball-done-again
            (ball-step-score (ballvec.next (&mut ball-iter))))
          ;; Stopping after the first item is a valid early loop exit.
          (while true
            (match (i64vec.next (&mut early-iter))
              [(i64vec.IterNext.Done) (break)]
              [(i64vec.IterNext.Item value)
                (begin
                  (set! early-exit-score (observe-i64 value))
                  (break))]))
          (if (and
            (= first 1)
            (= second 1)
            (= number-done 0)
            (= number-done-again 0)
            (= empty-done 0)
            (= empty-done-again 0)
            (= ball-total 12)
            (= ball-done 0)
            (= ball-done-again 0)
            (= early-exit-score 1))
            42
            1))))))