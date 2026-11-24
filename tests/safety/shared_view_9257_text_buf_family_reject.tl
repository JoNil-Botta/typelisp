;; #9257: `stdlib.text_buf_family/text-buf-family-shared-view` must not exist.
(import stdlib.text_buf_borrowed)
(import stdlib.text_buf_family)

(define (main) : i64
  (let
    [source : String "abc"]
    [buf : (text_buf_borrowed.TextBufBorrowed source)
      (text_buf_borrowed.empty-like (& source))]
    [_alias : (text_buf_borrowed.TextBufBorrowed source)
      (text_buf_family.text-buf-family-shared-view buf)]
    0))