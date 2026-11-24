;; The raw state probe of a Vec's consuming iterator is unsafe (#9783).
(import stdlib.vector)

(define (close-token [_value : i64]) : unit
  unit)

(defstruct Token
  (:cleanup cleanup-token)
  (value i64 (:cleanup close-token)))

(import (vector.vector Token) as tokens)

(define (main) : i64
  (with
    ([iter (tokens.into-iterator (tokens.new)) tokens.cleanup-into-iter])
    (if (tokens.into-iter-state-null? iter.state)
      1
      0)))