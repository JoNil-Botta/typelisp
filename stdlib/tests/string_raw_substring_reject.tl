;; Check-only: never execute these deliberately invalid raw ranges (#7945).
(import stdlib.string)

(define (main) : i64
  (begin
    (string.substring-copy-checked "data" 99 1)
    42))