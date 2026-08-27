(import stdlib.format)

(define (reject-pointer-format [value : (&mut value (Ptr i64))]) : String
  (unsafe
    (format.format "{:p}" value)))