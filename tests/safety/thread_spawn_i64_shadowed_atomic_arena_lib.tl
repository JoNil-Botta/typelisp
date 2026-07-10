;; This intentional identity shadows the arena import name in the safety
;; fixture, so it must remain an explicit legacy module declaration.
(module shadow_arena)

(import stdlib.arena as real_arena)

(define (make-atomic) : real_arena.Arena
  (real_arena.make))