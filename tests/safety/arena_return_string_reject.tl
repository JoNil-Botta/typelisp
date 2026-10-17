(import stdlib.string)

(define (leak [n : i64]) : String
  (with-arena phase (return (string.int->string n)))
  "")

(define (main) : i64
  (string.string-length (leak -5)))