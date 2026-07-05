(import stdlib.string)

(define (main) : i64
  (string-length (string.substring "abcdef" -1 1)))