(import stdlib.io)
(import stdlib.string)

(define (main) : i64
  (string-length (io.read-stdin-bytes -1)))
