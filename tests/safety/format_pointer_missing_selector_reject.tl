(import stdlib.format)

(define (reject-pointer-format [value : (Ptr i64)]) : String
  (format.format "{}" value))