;; A Vec's consuming iterator owns raw element storage through an opaque state
;; pointer: safe code cannot forge one (#9783).
(import stdlib.vector)

(define (close-token [_value : i64]) : unit
  unit)

(defstruct Token
  (:cleanup cleanup-token)
  (value i64 (:cleanup close-token)))

(import (vector.vector Token) as tokens)

(define (main) : i64
  (with
    ([iter
        (tokens.IntoIter (ptr-null : (MutPtr tokens.IntoIterState)))
        tokens.cleanup-into-iter])
    0))