;; stdlib.string exports `concat`, not the deprecated builtin spelling (#7883).
(import stdlib.string)

(define (main) : i64
  (string.string-length (string.string-concat "ab" "cd")))