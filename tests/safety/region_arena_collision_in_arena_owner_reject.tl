;; A with-arena named like the brand of an arena owner selected by an enclosing
;; in-arena is rejected at entry (#9593, D-C121).
(import stdlib.arena)

(define (probe [owner : (arena.Arena brand)]) : i64
  (in-arena
    owner
    ; Must fail: rename the arena.
    (with-arena brand 42)))

(define (main) : i64
  (probe (arena.make)))