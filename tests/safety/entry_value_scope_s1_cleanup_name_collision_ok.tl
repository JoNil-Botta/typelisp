;; #9687: an entry cleanup named like a generated function, seen from an imported module.
(import stdlib.vector)

(define count : i64
  0)

(define (close-token [_value : i64]) : unit
  (set! count (+ count 1)))

(defstruct Tok
  (:cleanup push-ref!)
  (value i64 (:cleanup close-token)))

(import (vector.vector Tok) as toks)

(define (main) : i64
  (with ([v (toks.new) toks.cleanup-vec]) (toks.push-ref! (&mut v) (Tok 1)))
  (if (= count 1)
    42
    count))