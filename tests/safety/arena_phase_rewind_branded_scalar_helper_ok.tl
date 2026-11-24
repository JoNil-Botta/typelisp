;; #9846 control: helper taking `(arena.Arena r)` returning a scalar `i64`
;; stays usable after `arena.rewind-safe!`.
(import stdlib.arena)
(import stdlib.string)

(define (measure [a : (arena.Arena r)]) : i64
  (let
    [tmp (in-arena a (string.append "a" "b"))]
    (string.string-length (& tmp))))

(define (main) : i64
  (let
    [owner (arena.make)]
    [p (arena.phase owner)]
    [n (measure owner)]
    (arena.rewind-safe! p)
    (+ 40 n)))