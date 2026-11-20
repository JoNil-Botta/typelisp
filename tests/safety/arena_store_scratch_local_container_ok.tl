;; Body allocations pushed into a container created in the same scratch body
;; or with-arena stay inside it (#8805 twin).
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector String) as svec)
(import (vector.vector i64) as ivec)

(define (main) : i64
  (let
    [a : i64
      (with-scratch
        (let
          [names : svec.Vec (svec.new)]
          (svec.push-ref! (&mut names) (string.int->string 1234567))
          (svec.len (& names))))]
    [b : i64
      (with-arena
        phase
        (let
          [v : ivec.Vec (ivec.new)]
          (ivec.push-ref! (&mut v) 41)
          (ivec.get (& v) 0 -1)))]
    (+ a b)))