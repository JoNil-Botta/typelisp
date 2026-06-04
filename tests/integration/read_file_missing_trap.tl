(import "stdlib/io.tl")

(define (main) : i64
  (string-length
    (read-file "tests/integration/this-path-does-not-exist-zzz.txt")))