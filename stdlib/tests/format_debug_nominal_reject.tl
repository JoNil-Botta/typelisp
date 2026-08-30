(import stdlib.format)

(defstruct DebugMissing
  (value i64))

(define (main) : i64
  (begin
    (format.format "{:?}" (DebugMissing 1))
    42))