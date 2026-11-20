;; #9480: the phase an inner `let` took is taken after `ph1`, so rewinding `ph1`
;; ends the value allocated in it, and it cannot be read afterwards.
(import stdlib.arena)
(import stdlib.string)

(define (main) : i64
  (let
    [o : arena.Arena (arena.make)]
    [ph1 (arena.phase o)]
    [v
      (let
        [ph2 (arena.phase o)]
        (in-arena o (string.append "owner" "-text")))]
    (begin
      (arena.rewind-safe! ph1)
      (in-arena o (string.append "clobber" "-the-old-text"))
      (if (string.string=? (& v) "owner-text")
        42
        7))))