(import "stdlib/text_buf.tl")

; Must fail: text-buf-render materializes a String in the inner active arena.
(define (main) : String
  (let
    [buf : TextBuf (text-buf-append (text-buf-empty) "scoped")]
    (with-arena outer (with-arena inner (text-buf-render buf)))))