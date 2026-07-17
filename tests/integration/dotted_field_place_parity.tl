;; #2610: typed dotted fields are canonical places through check, lowering, and
;; native execution. The local `vector` binding also shadows the imported alias.
;; #4794: generated core `and` folds preserve a borrowed dotted-field place at
;; one, two, and three operands.
(import stdlib.vector)
(import (vector.vector i64) as ivec)

(defstruct World
  (balls ivec.Vec)
  (count i64))

(defstruct Shadow
  (value i64))

(define (append-through-ref [world : (&mut a World)]) : unit
  (begin
    (ivec.push! world.balls 31)
    (set! world.count (+ world.count 1))))

(define (main) : i64
  (let
    [world : World (World (ivec.new) 40)]
    [vector : Shadow (Shadow 9)]
    (begin
      ;; The bang macro reserves `world.balls` before evaluating the value, so
      ;; reading the disjoint sibling remains the same two-phase call-borrow
      ;; case as `(ivec.push-ref! (&mut world.balls) world.count)`.
      (ivec.push! world.balls world.count)
      (set! world.count (+ world.count 1))
      (append-through-ref (&mut world))
      (unless (and (= (ivec.len (& world.balls)) 2)) (return 0))
      (unless
        (and (= (ivec.len (& world.balls)) 2) (= world.count 42))
        (return 0))
      (unless
        (and
          (= (ivec.len (& world.balls)) 2)
          (= world.count 42)
          (= vector.value 9))
        (return 0))
      42)))