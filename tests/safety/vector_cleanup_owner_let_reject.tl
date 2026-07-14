(import stdlib.vector)

(define (close-token [_value : i64]) : unit
  unit)

(defstruct CleanupToken
  (:cleanup cleanup-token)
  (value i64 (:cleanup close-token)))

(import (vector.vector CleanupToken) as tokens)

(define (main) : i64
  (let
    [items : tokens.Vec (tokens.new)]
    (tokens.len (& items))))