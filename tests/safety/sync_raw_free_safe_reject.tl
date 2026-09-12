;; A source integer conveys no ownership of the runtime allocation.
(import stdlib.sync)

(define (main) : i64
  (if (sync.runtime-free 0 8)
    1
    0))