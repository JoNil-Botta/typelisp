;; #8173: a handle passed on through a second bare parameter still ends with
;; the owner.
(import stdlib.arena)
(import stdlib.string)

(define (keep [a : arena.Arena]) : arena.Arena
  a)

(define (main) : i64
  (let
    [s : arena.Arena (arena.make)]
    [u : arena.Arena (keep (keep s))]
    (begin
      (arena.destroy-safe! s)
      (string.string-length (in-arena u (string.concat "a" "b"))))))