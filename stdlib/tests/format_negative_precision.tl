(import stdlib.format)

(define (main) : i64
  (begin
    (format.format-apply-options
      "123"
      false
      (format.FormatOptions ' ' 0 0 false false 0 true -1))
    1))