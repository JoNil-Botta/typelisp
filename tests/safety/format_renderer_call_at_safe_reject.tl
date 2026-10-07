;; A safe call of the raw format/arguments-renderer-call-at helper is rejected (#7700).
;; This check-only fixture must never execute.
(import stdlib.format)

(define (call) : i64
  (format.arguments-renderer-call-at 0 0 0))

(define (main) : i64
  0)