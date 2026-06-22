(import stdlib.text_buf)

; Must fail: text-buf-render materializes a String in the inner active arena.
(define (main) : String
  (let
    [buf : text_buf.TextBuf
      (text_buf.text-buf-append (text_buf.text-buf-empty) "scoped")]
    (with-arena outer (with-arena inner (text_buf.text-buf-render buf)))))