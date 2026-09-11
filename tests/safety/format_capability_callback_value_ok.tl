;; Checked token adapters remain ordinary first-class formatter callbacks.
(import stdlib.byte_buf)
(import stdlib.format)
(import stdlib.text_buf)

(define (main) : i64
  (let
    [_bytes : (-> i64 String i64) byte_buf.format-write-capability]
    [_text : (-> i64 String i64) text_buf.format-write-capability]
    [_arguments : (-> i64 String i64) format.arguments-string-write-capability]
    0))