(import "stdlib/io.tl")
(import "stdlib/string.tl")

(define (main) : i64
  (string-length (read-stdin-bytes -1)))
