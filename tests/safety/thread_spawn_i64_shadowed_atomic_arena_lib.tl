(module shadow_arena)

(import stdlib.arena as real_arena)

(define (make-atomic) : real_arena.Arena
  (real_arena.make))