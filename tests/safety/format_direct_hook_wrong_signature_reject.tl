(import stdlib.format)

(defstruct DisplayValue
  (value i64))

(define (to-string [_value : (& value DisplayValue)]) : String
  "fallback")

;; The first parameter must borrow the nominal value being formatted.
(define (format-write
  [_value : (& value i64)]
  [_formatter : (&mut formatter format.Formatter)]) : unit
  unit)

(define (main) : i64
  (format.format "{}" (DisplayValue 7)))