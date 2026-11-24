;; #9846: `in-arena` through a phase-tagged bare `arena.Arena` copy returned
;; before rewind must tag the allocation with the active phase so it ends at
;; `arena.rewind-safe!`.
(import stdlib.arena)
(import stdlib.string)

(define (pass [a : arena.Arena]) : arena.Arena
  a)

(define (main) : i64
  (let
    [owner (arena.make)]
    [p (arena.phase owner)]
    [copy (pass owner)]
    [s (in-arena copy (string.append "hello" "world"))]
    (arena.rewind-safe! p)
    (if (string.eq (& s) "helloworld")
      42
      7)))