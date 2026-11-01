(import stdlib.arena as pool)

(define (main) : i64
  (pool.Arena 12345).handle)