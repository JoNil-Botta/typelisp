(module format_owner_nested)

(import format_owner_point as point)
(import stdlib.format)

(defstruct Nested
  (point point.Point))

(define (to-string [value : (& value Nested)]) : String
  (format.format "nested<{}>" value.point))