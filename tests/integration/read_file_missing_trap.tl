(import stdlib.io)
(import stdlib.string)

(define (main) : i64
  (string.string-length
    (io.read-file "tests/integration/this-path-does-not-exist-zzz.txt")))