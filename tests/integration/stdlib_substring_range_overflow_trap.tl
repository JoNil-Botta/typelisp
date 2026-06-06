(import "stdlib/string.tl")

(define (main) : i64
  (string-length (substring "abcdef" 1 9223372036854775807)))