(import stdlib.vector)
(import (vector String) as sv)

(define (main) : i64
  (let
    [items : sv.Vec (sv.new)]
    (begin
      (sv.push! items "alpha")
      (sv.push! items "beta")
      (if (and
        (sv.contains? (& items) "beta")
        (not (sv.contains? (& items) "gamma")))
        42
        1))))