(import stdlib.arena)
(import stdlib.string)

;; Must pass: no store places the phase's values in `o2`, so rewinding it
;; leaves `x` live (#9445).
(define (main) : i64
  (let
    [o (arena.make)]
    [phase (arena.phase o)]
    [o2 (arena.make)]
    [x (in-arena o2 (string.append "o2" "-text"))]
    (begin
      (arena.rewind-safe! phase)
      (+ (string.string-length x) 35))))