(import stdlib.format)

(define (reject-pointer-format [value : String]) : String
  (unsafe
    (format.format "{:p}" value)))