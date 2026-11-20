;; A closure capturing a `&mut` to outer storage, called inside with-arena,
;; may grow that storage in the scoped arena.
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector String) as svec)

(define (main) : i64
  (let
    [names : svec.Vec (svec.new)]
    [r (&mut names)]
    [f : (-> unit)
      (lambda () : unit
        (svec.push-ref! r (string.int->string 1234567)))]
    (with-arena phase (f))
    (svec.len (& names))))