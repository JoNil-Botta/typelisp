(module format_owner_ambiguous_reject)

(import stdlib.format)

(defstruct DuplicateDisplay
  (value i64))

(define (to-string [value : (& value DuplicateDisplay)]) : String
  "plain")

;; lint-allow: function-name-case -- exact nominal suffix is the protocol key.
(define (to-string-DuplicateDisplay [value : (& value DuplicateDisplay)]) : String
  "qualified")

(define (main) : i64
  (begin
    (format.format "{}" (DuplicateDisplay 1))
    42))