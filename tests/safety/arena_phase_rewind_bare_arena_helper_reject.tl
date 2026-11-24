;; #9846 sibling: bare `arena.Arena` helper returning a copied handle during an
;; active phase must tag the returned handle with the active phase.
(import stdlib.arena)

(define (pass [a : arena.Arena]) : arena.Arena
  a)

(define (main) : i64
  (let
    [owner (arena.make)]
    [p (arena.phase owner)]
    [copy (pass owner)]
    (arena.rewind-safe! p)
    (let
      [s (in-arena copy (box (cast 42 : i64)))]
      (deref s))))