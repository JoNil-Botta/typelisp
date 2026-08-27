(import stdlib.format)

(define (reject-pointer-format [value : (Box i64)]) : String
  (unsafe
    (format.format "{:p}" value)))