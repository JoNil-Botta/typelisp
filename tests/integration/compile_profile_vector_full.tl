;; Profile fixture for the backward-compatible full canonical vector module.
(import stdlib.vector)
(import (vector.vector i64) as vec)

(define (main) : i64
  (let
    [values : vec.Vec (vec.new)]
    (begin
      (vec.push! values 42)
      (vec.get (& values) 0 0))))