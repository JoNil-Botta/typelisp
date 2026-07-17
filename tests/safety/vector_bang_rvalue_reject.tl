;: Generated vector bang mutators preserve the normal mutable-place diagnostic.
(import stdlib.vector)
(import (vector.vector i64) as ivec)

(define (main) : unit
  (ivec.push! (ivec.new) 1))