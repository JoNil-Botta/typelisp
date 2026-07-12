;: Compact vectors do not materialize clone/pop or other full-only APIs.
(import stdlib.vector)
(import (vector.vector i64 core) as compact)

(define (main) : unit
  (let
    [values : compact.Vec (compact.new)]
    (begin
      (compact.pop (&mut values))
      unit)))