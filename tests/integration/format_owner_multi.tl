(module format_owner_multi)

(import stdlib.format)

(defstruct Primary
  (value i64))

(defstruct Secondary
  (value i64))

(define (to-string [value : (& value Primary)]) : String
  (format.format "primary={}" value.value))

;; lint-allow: function-name-case -- exact nominal suffix is the protocol key.
(define (to-string-Secondary [value : (& value Secondary)]) : String
  (format.format "secondary={}" value.value))