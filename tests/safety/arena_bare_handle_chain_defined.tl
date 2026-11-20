;; #8173 control: a handle copied through a bare `arena.Arena` parameter can
;; be passed on to another bare parameter, directly or nested, before the owner
;; ends.
(import stdlib.arena)
(import stdlib.string)

(define (keep [a : arena.Arena]) : arena.Arena
  a)

(define (use [a : arena.Arena]) : i64
  (string.string-length (in-arena a (string.concat "a" "b"))))

(define (main) : i64
  (let
    [s : arena.Arena (arena.make)]
    [t : arena.Arena (keep s)]
    [u : arena.Arena (keep (keep s))]
    [n : i64 (+ (use t) (use u))]
    (begin
      (arena.destroy-safe! s)
      (+ 38 n))))