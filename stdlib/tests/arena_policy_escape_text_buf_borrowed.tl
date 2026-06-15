(import stdlib.text_buf_borrowed)

; Must fail: a borrowed text buffer cannot outlive the chunk owner it stores.
(define (main [text : String]) : (text_buf_borrowed.TextBufBorrowed text)
  (let
    [chunk : String "inner"]
    (text_buf_borrowed.text-buf-borrowed-single (& chunk))))