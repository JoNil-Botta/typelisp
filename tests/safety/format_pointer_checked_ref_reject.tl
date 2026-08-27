(import stdlib.format)

(define (reject-pointer-format [value : (& value i64)]) : String
  (unsafe
    (format.format "{:p}" value)))