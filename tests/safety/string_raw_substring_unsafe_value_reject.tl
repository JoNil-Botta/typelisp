;; Check-only: invalid pointer/range witnesses must never execute (#8915).
(import stdlib.string as s)

(define (main) : i64
  (unsafe
    (let
      [writer s.substring-copy-checked]
      (writer "data" 99 1)
      42)))