;; A with exit cannot end an atomic arena, whose release checks precede a
;; direct end.
(import stdlib.arena)

(define (main) : i64
  (with ([a (arena.make-atomic) arena.destroy-safe!]) 42))