;; #2610: typed dotted fields are canonical places through check, lowering, and
;; native execution. The local `vector` binding also shadows the imported alias.
(import stdlib.vector)
(import (vector.vector i64) as ivec)

(defstruct World
  (balls ivec.Vec)
  (count i64))

(defstruct Shadow
  (value i64))

(define (append-through-ref [world : (&mut a World)]) : unit
  (begin
    (ivec.push (&mut world.balls) 31)
    (set! world.count (+ world.count 1))))

(define (main) : i64
  (let
    [world : World (World (ivec.new) 40)]
    [vector : Shadow (Shadow 9)]
    (begin
      (ivec.push (&mut world.balls) 7)
      (set! world.count (+ world.count 1))
      (append-through-ref (&mut world))
      (if (and
        (= (ivec.len (& world.balls)) 2)
        (= world.count 42)
        (= vector.value 9))
        42
        0))))