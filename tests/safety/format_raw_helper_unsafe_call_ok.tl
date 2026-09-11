;; Immediate raw helper calls compile only when the caller explicitly assumes
;; the live-cell address contract. This check-only fixture must never execute.
(import stdlib.byte_buf)
(import stdlib.format)
(import stdlib.text_buf)

(define (raw-writes) : i64
  (begin
    (unsafe
      (byte_buf.format-write-raw 1 "x"))
    (unsafe
      (text_buf.format-write-raw 1 "x"))
    (unsafe
      (format.arguments-string-write-raw 1 "x"))))

(define (raw-formatter-cell) : i64
  (begin
    (unsafe
      (format.formatter-write-string-at! 1 "x"))
    (unsafe
      (format.formatter-result-at 1))
    (unsafe
      (format.formatter-status-at 1))))

(define (main) : i64
  0)