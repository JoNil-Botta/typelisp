;; #8805 shape 1: a scratch-body allocation pushed into a vector declared
;; outside the body.
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector String) as svec)

(define (main) : i64
  (let
    [names : svec.Vec (svec.new)]
    (with-scratch (svec.push-ref! (&mut names) (string.int->string 1234567)) 0)
    (svec.len (& names))))