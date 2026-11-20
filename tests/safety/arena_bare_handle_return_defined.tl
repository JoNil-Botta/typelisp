;; #8173 control: a handle copied through a bare parameter is usable before the
;; owner ends.
(import stdlib.arena)
(import stdlib.string)

(define (keep [a : arena.Arena]) : arena.Arena
  a)

(define (main) : i64
  (let
    [s : arena.Arena (arena.make)]
    [t : arena.Arena (keep s)]
    [n : i64 (string.string-length (in-arena t (string.concat "a" "b")))]
    (begin
      (arena.destroy-safe! s)
      (+ 40 n))))