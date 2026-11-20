;; The result of an `in-arena` over an arena with no region is a value from
;; outside it when its body only names one: storing it is still rejected.
(import stdlib.arena)
(import stdlib.string)

(define g : String
  "")

(define (keep!) : unit
  (let
    [s : String (string.int->string 1234567)]
    [owner : arena.Arena
      (unsafe
        (arena.Arena (arena.tl_arena_make_small)))]
    (set! g (in-arena owner s))))

(define (main) : i64
  (with-arena phase (keep!))
  0)