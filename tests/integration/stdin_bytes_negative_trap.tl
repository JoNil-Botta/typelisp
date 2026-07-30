(import stdlib.io)

;; lint-allow: unused-import
(import stdlib.byte_buf)

(define (main) : i64
  (byte_buf.len (io.read-stdin-bytes -1)))
