(import stdlib.format)

(defstruct PrimaryValue
  (value i64))

(defstruct DisplayValue
  (value i64))

(define (make [value : i64]) : DisplayValue
  (DisplayValue value))

;; lint-allow: function-name-case -- exact nominal suffix is the protocol key.
(define (to-string-DisplayValue [_value : (& value DisplayValue)]) : String
  "fallback")

;; lint-allow: function-name-case -- exact nominal suffix is the protocol key.
(define (format-write-DisplayValue
  [_value : (& value DisplayValue)]
  [formatter : (&mut formatter format.Formatter)]) : unit
  (format.formatter-write-string! formatter "direct"))