(import stdlib.vector)

(define (close-token [_value : i64]) : unit
  unit)

(defstruct CleanupToken
  (:cleanup cleanup-token)
  (value i64 (:cleanup close-token)))

(import (vector.vector CleanupToken) as tokens)

(define (main) : i64
  (with
    ([iter (tokens.into-iterator (tokens.new)) tokens.cleanup-into-iter])
    (let
      [step : tokens.IntoNext (tokens.into-next (&mut iter))]
      0)))