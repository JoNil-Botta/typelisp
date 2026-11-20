;; #8173: a fixed-array result of a call through a bare `arena.Arena` formal
;; carries the owner's region, so the end of the owner reaches it.
(import stdlib.arena)

(define (one [a : arena.Arena]) : (Array arena.Arena 1)
  (array a))

(define (main) : i64
  (let
    [s : arena.Arena (arena.make)]
    [xs (one s)]
    (begin
      (arena.destroy-safe! s)
      (array-length (& xs)))))