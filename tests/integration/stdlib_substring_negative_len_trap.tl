(import "stdlib/string.tl")

(define (main) : i64
  (string-length (substring "abcdef" 0 -1)))