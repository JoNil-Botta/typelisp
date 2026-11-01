;; A closure capturing an atomic arena owner does not move it: it is one of the
;; owner's users (SPEC 5.16) and holds it borrowed while it lives. The closure
;; passed to this ordinary function named `spawn` is dead once the call
;; returns, so the destroy below is accepted.
(import stdlib.arena)

(define (spawn [entry : (-> i64 i64)] [base : i64]) : i64
  (entry base))

(define (main) : i64
  (let
    [owner : arena.Arena (arena.make-atomic)]
    [value : i64
      (spawn
        (lambda ([base : i64]) : i64
          (in-arena owner (+ base 2)))
        40)]
    (begin
      (arena.destroy-safe! owner)
      value)))