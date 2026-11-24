;; #9846: branded `(arena.Arena r)` helper returning a Copy `(Tuple arena.Arena i64)`
;; must tag the tuple with the active phase so allocations through its handle
;; end at `arena.rewind-safe!`.
(import stdlib.arena)
(import stdlib.string)

(define (erase-pair [a : (arena.Arena r)]) : (Tuple arena.Arena i64)
  (tuple a 1))

(define (main) : i64
  (let
    [owner (arena.make)]
    [p (arena.phase owner)]
    [pair (erase-pair owner)]
    [copy (tuple-ref pair 0)]
    [s (in-arena copy (string.append "hello" "world"))]
    (arena.rewind-safe! p)
    (if (string.eq (& s) "helloworld")
      42
      7)))