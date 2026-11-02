;; Check-only: invalid pointer/range witnesses must never execute (#8915).
(import stdlib.string.substring-copy-checked)

(define (main) : i64
  (begin
    (substring-copy-checked "data" 99 1)
    42))