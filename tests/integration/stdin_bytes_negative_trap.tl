(import "stdlib/io.tl")

(define (main) : i64
  (string-length (read-stdin-bytes -1)))