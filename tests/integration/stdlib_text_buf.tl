;; stdlib_text_buf.tl - Integration witness for stdlib/text_buf.tl.
(import "stdlib/text_buf.tl")

(define (text-buf-integration-ok?) : bool
  (let (
    [left : TextBuf
      (text-buf-append-char (text-buf-append (text-buf-empty) "left") #-')]
    [right : TextBuf
      (text-buf-append-int (text-buf-append (text-buf-empty) "right") 7)])
    (string-eq
      (text-buf-render (text-buf-append-buffer left right))
      "left-right7")))

(define (main) : i64
  (if (text-buf-integration-ok?)
    42
    1))