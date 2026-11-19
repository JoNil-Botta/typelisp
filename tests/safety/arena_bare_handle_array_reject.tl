;; #8173: a fixed-array result cannot carry the owner's region yet, so a call
;; that could return a copy of the owner's handle in one is rejected.
(import stdlib.arena)

(define (one [a : arena.Arena]) : (Array arena.Arena 1)
  (array a))

(define (main) : i64
  (let
    [s : arena.Arena (arena.make)]
    [xs (one s)]
    (begin
      (arena.destroy-safe! s)
      42)))