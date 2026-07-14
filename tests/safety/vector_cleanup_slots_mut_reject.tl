(import stdlib.vector)

(define (close-token [_value : i64]) : unit
  unit)

(defstruct CleanupToken
  (:cleanup cleanup-token)
  (value i64 (:cleanup close-token)))

(import (vector.vector CleanupToken) as tokens)

(define (main) : i64
  (with
    ([items (tokens.new) tokens.cleanup-vec])
    (begin
      (tokens.slots-mut (&mut items))
      0)))