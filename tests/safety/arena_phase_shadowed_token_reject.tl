;; #9480: two phases named `p` are two binders with two phases: rewinding `x`
;; ends the phase the inner `p` took, so its value cannot be read afterwards.
(import stdlib.arena)
(import stdlib.string)

(define (main) : i64
  (let
    [o : arena.Arena (arena.make)]
    [p (arena.phase o)]
    [x (arena.phase o)]
    [v
      (let
        [p (arena.phase o)]
        (in-arena o (string.append "owner" "-text")))]
    (begin
      (arena.rewind-safe! x)
      (in-arena o (string.append "clobber" "-the-old-text"))
      (if (string.string=? (& v) "owner-text")
        42
        7))))