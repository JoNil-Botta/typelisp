;; #9479 control: a value a branded owner allocated before the phase stays
;; readable after the rewind.
(import stdlib.arena)
(import stdlib.string)

(define (main) : i64
  (let
    [o (arena.make)]
    [kept (in-arena o (string.append "kept" "-text"))]
    [phase (arena.phase o)]
    [t (in-arena o (string.append "temp" ""))]
    [n : i64 (string.string-length (& t))]
    (begin
      (arena.rewind-safe! phase)
      (in-arena o (string.append "clobber" "-the-old-text"))
      (if (string.string=? (& kept) "kept-text")
        (+ 38 n)
        7))))