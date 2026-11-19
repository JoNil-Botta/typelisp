;; #8173: a handle copied out through a reference to the owner ends with the
;; owner too.
(import stdlib.arena)
(import stdlib.string)

(define (keep [a : (& arena.Arena)]) : arena.Arena
  (deref a))

(define (main) : i64
  (let
    [s : arena.Arena (arena.make)]
    [t : arena.Arena (keep (& s))]
    (begin
      (arena.destroy-safe! s)
      (string.string-length (in-arena t (string.concat "a" "b"))))))