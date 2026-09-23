;; An import alias does not reach the deprecated builtin either (#7883).
(import stdlib.string as s)

(define (main) : i64
  (s.string-length (s.string-append "ab" "cd")))