;; #9257: `text_buf_borrowed.text-buf-borrowed-view` requires `unsafe` because
;; it constructs an unanchored `String` header over borrowed bytes.
(import stdlib.text_buf_borrowed)

(define (main) : i64
  (let
    [s : String "hello"]
    [_v : String (text_buf_borrowed.text-buf-borrowed-view (& s) 0 5)]
    0))