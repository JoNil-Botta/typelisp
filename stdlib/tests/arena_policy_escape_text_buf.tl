(import stdlib.text_buf)

; Must fail: text-buf-render materializes a String in the inner active arena.
(define (main) : String
  (let
    [buf : text_buf.TextBuf (text_buf.append (text_buf.empty) "scoped")]
    (with-arena outer (with-arena inner (text_buf.render buf)))))