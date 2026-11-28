(import stdlib.arena as pool)

(define (main) : i64
  (pool.raw-handle (pool.Arena 0)))