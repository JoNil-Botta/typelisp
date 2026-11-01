(import stdlib.arena)

(defstruct Point
  (x i64)
  (y i64))

(define (make [owner : (& handle (arena.Arena source))] [c : bool]) : Point
  (when c (return (in-arena owner (Point 40 2))))
  (Point 1 2))

(define (main) : i64
  (let
    [owner (arena.make)]
    [p (make (& owner) true)]
    (arena.destroy-safe! owner)
    (+ p.x p.y)))