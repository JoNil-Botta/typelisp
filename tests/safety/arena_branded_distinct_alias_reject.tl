(import stdlib.arena as memory)

(define (same-brand
  [_left : (memory.Arena owner)]
  [_right : (memory.Arena owner)]) : i64
  0)

(define (main) : i64
  (same-brand (memory.make) (memory.make)))