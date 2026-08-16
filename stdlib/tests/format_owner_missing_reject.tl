(module format_owner_missing_reject)

(import stdlib.format)

(defstruct MissingDisplay
  (value i64))

(define (main) : i64
  (begin
    (format.format "{}" (MissingDisplay 1))
    42))