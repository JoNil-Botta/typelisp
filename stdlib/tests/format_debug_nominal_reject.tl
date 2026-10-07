(import stdlib.format)

(defstruct DebugMissing
  (value i64))

(define (main) : i64
  (format.format "{:?}" (DebugMissing 1))
  42)