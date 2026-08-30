(import stdlib.vector)

(define cleanup-total : i64
  0)

(define (record-cleanup [value : i64]) : unit
  (set! cleanup-total (+ cleanup-total value)))

(defstruct CleanupToken
  (:cleanup cleanup-token)
  (value i64 (:cleanup record-cleanup)))

(import (vector.vector CleanupToken) as tokens)

(define (append-token [items : tokens.Vec] [value : i64]) : tokens.Vec
  (tokens.push-owned items (CleanupToken value)))

(define (main) : i64
  (with
    ([iter
        (tokens.into-iterator (append-token (append-token (tokens.new) 10) 100))
        tokens.cleanup-into-iter])
    (begin
      (with
        ([step (tokens.into-next (&mut iter)) tokens.cleanup-into-next])
        unit)
      (__tl-project-field (array-ref (tokens.slots (& iter.vec)) 0) value))))