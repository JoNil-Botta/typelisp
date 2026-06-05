(import "stdlib/text_buf_borrowed.tl")

; Must fail: a borrowed text buffer cannot outlive the chunk owner it stores.
(define (main [text : String]) : (TextBufBorrowed text)
  (let
    [chunk : String "inner"]
    (text-buf-borrowed-single (& chunk))))