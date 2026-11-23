;; #9846 control: helper taking `(arena.Arena r)` returning `(& r str)` remains
;; usable before `arena.rewind-safe!`.
(import stdlib.arena)
(import stdlib.string)

(define (peek-ref [_a : (arena.Arena r)] [s : (& r str)]) : (& r str)
  s)

(define (main) : i64
  (let
    [owner (arena.make)]
    [pre (in-arena owner (string.append "a" "b"))]
    [p (arena.phase owner)]
    [v (peek-ref owner (& pre))]
    [n (string.string-length v)]
    (arena.rewind-safe! p)
    (+ 40 n)))