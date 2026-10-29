(import stdlib.arena)
(import stdlib.string)

;; Must pass: no store places `o`'s values in `r1`, so ending `o` leaves `x`
;; live (#9445).
(define (main) : i64
  (let
    [o (arena.make)]
    [t (in-arena o (string.append "owner" "-text"))]
    [n : i64 (string.string-length t)]
    (with-arena
      r1
      (let
        [x (string.append "r1" "-text")]
        (arena.destroy-safe! o)
        (+ (string.string-length x) n 25)))))