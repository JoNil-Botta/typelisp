;; #9846 sibling: helper taking `(arena.Arena r)` returning an aggregate
;; `(in r Pair)` must carry the owner's active phase across `arena.rewind-safe!`.
(import stdlib.arena)
(import stdlib.string)

(defstruct Pair
  (s String)
  (n i64))

(define (fill-pair [a : (arena.Arena r)]) : (in r Pair)
  (in-arena a (Pair (string.append "a" "b") 42)))

(define (main) : i64
  (let
    [owner (arena.make)]
    [p (arena.phase owner)]
    [pair (fill-pair owner)]
    (arena.rewind-safe! p)
    (if (string.eq (& pair.s) "ab")
      pair.n
      7)))