;; The result of a call that brands its value with the owner's arena carries
;; that brand: destroying the arena ends it, so a later use is rejected.
(import stdlib.arena)
(import stdlib.string)

(define (keep [_o : (& a (arena.Arena r))] [t : (in r String)]) : (in r String)
  t)

(define (main) : i64
  (let
    [owner (arena.make)]
    [text (in-arena owner (keep (& owner) (string.append "a" "b")))]
    (begin
      (arena.destroy-safe! owner)
      (string.string-length text))))