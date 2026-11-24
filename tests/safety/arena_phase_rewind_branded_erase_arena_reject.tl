;; #9846: branded `(arena.Arena r)` helper returning an erased Copy
;; `arena.Arena` must tag the copy with the active phase so allocations
;; through it before rewind end at `arena.rewind-safe!`.
(import stdlib.arena)
(import stdlib.string)

(define (erase [a : (arena.Arena r)]) : arena.Arena
  a)

(define (main) : i64
  (let
    [owner (arena.make)]
    [p (arena.phase owner)]
    [copy (erase owner)]
    [s (in-arena copy (string.append "hello" "world"))]
    (arena.rewind-safe! p)
    (if (string.eq (& s) "helloworld")
      42
      7)))