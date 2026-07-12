;; Profile fixture for the compact canonical vector module.
(import stdlib.vector)
(import (vector.vector i64 core) as vec)

(define (main) : i64
  (let
    [values : vec.Vec (vec.new)]
    (begin
      (vec.push (&mut values) 42)
      (vec.get (& values) 0 0))))