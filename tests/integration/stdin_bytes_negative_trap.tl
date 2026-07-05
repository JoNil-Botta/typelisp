(import stdlib.io)

;; lint-allow: unused-import
(import stdlib.string)

(define (main) : i64
  (string-length (io.read-stdin-bytes -1)))