;; A helper that grows a caller's vector, called outside any scoped arena,
;; allocates in the program-lifetime arena (#8692 twin).
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector String) as svec)

(define (add-name [names : (&mut n svec.Vec)] [k : i64]) : unit
  (svec.push-ref! names (string.int->string k)))

(define (main) : i64
  (let
    [names : svec.Vec (svec.new)]
    (add-name (&mut names) 40)
    (add-name (&mut names) 2)
    (+ (* (svec.len (& names)) 20) 2)))