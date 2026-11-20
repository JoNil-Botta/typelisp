;; #8692: growing an outer vector inside with-arena reallocates its buffer in
;; the scoped arena, with no user-written callee.
(import stdlib.vector)
(import (vector.vector i64) as ivec)

(define (main) : i64
  (let
    [v : ivec.Vec (ivec.new)]
    (with-arena phase (ivec.push-ref! (&mut v) 1))
    (ivec.get (& v) 0 -1)))