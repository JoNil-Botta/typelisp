(import stdlib.io)
(import stdlib.byte_buf)

(define (main) : i64
  (byte_buf.len
    (io.read-file "tests/integration/this-path-does-not-exist-zzz.txt")))