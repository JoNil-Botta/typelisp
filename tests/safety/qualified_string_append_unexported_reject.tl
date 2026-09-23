;; stdlib.string exports `append`, not the deprecated builtin spelling (#7883).
(import stdlib.string)

(define (main) : i64
  (string.string-length (string.string-append "ab" "cd")))