(import stdlib.text_buf)

(define (main) : i64
  (let
    [buf : text_buf.TextBuf (text_buf.append (text_buf.empty) "x")]
    (text_buf.write-file "target/ir-observability-verify/text-buf.txt" buf)))