;; #9479: a phase of an unannotated (branded) owner covers its `in-arena`
;; allocations, so the rewind ends `t` as it does for a bare owner.
(import stdlib.arena)
(import stdlib.string)

(define (main) : i64
  (let
    [o (arena.make)]
    [phase (arena.phase o)]
    [t (in-arena o (string.append "owner" "-text"))]
    (begin
      (arena.rewind-safe! phase)
      (in-arena o (string.append "clobber" "-the-old-text"))
      (if (string.string=? (& t) "owner-text")
        42
        7))))