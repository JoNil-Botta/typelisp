(import stdlib.vector)

(define (close-token [_value : i64]) : unit
  unit)

(defstruct CleanupToken
  (:cleanup cleanup-token)
  (value i64 (:cleanup close-token)))

(import (vector.vector CleanupToken) as tokens)

(define (make-items) : tokens.Vec
  (with ([items (tokens.new) tokens.cleanup-vec]) items))

(define (main) : i64
  (tokens.len (& (make-items))))