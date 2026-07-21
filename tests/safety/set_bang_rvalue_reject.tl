;: Generated set bang mutators preserve the normal mutable-place diagnostic.
(import stdlib.set)
(import (set.set i64) as i64set)

(define (main) : unit
  (i64set.insert! (i64set.new) 1))