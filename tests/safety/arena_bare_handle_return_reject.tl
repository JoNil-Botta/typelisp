;; #8173: a call passing a branded owner to a bare `arena.Arena` parameter can
;; return a copy of its handle, so the result ends with the owner.
(import stdlib.arena)
(import stdlib.string)

(define (keep [a : arena.Arena]) : arena.Arena
  a)

(define (main) : i64
  (let
    [s : arena.Arena (arena.make)]
    [t : arena.Arena (keep s)]
    (begin
      (arena.destroy-safe! s)
      (string.string-length (in-arena t (string.concat "a" "b"))))))