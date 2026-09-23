;; Nor does the full module path (#7883).
(import stdlib.string)

(define (main) : i64
  (string.string-length (stdlib.string.string-concat "ab" "cd")))