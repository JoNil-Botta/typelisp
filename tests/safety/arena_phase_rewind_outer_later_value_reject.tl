;; #9480: rewinding a phase ends the phases taken after it, so a value of the
;; later phase `ph2` is ended by the rewind of `ph1`.
(import stdlib.arena)
(import stdlib.string)

(define (main) : i64
  (let
    [o : arena.Arena (arena.make)]
    [ph1 (arena.phase o)]
    [ph2 (arena.phase o)]
    [v (in-arena o (string.append "owner" "-text"))]
    (begin
      (arena.rewind-safe! ph1)
      (let
        [c (in-arena o (string.append "clobber" "-the-old-text"))]
        unit)
      (if (string.string=? (& v) "owner-text")
        42
        7))))