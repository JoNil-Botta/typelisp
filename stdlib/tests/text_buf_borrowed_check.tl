(import stdlib.text_buf_borrowed)

(define (text-buf-borrowed-check-render [text : String] [chunk : String]) : String
  (let
    [left : (text_buf_borrowed.TextBufBorrowed text)
      (text_buf_borrowed.text-buf-borrowed-append-owned (text_buf_borrowed.text-buf-borrowed-single (& text)) "-")]
    [right : (text_buf_borrowed.TextBufBorrowed text)
      (text_buf_borrowed.text-buf-borrowed-append
        (text_buf_borrowed.text-buf-borrowed-empty-like (& text))
        (& text))]
    [joined : (text_buf_borrowed.TextBufBorrowed text)
      (text_buf_borrowed.text-buf-borrowed-append-buffer left right)]
    [copied : (text_buf_borrowed.TextBufBorrowed text)
      (text_buf_borrowed.text-buf-borrowed-append-copy joined (& chunk))]
    (text_buf_borrowed.text-buf-borrowed-render copied)))

(define (main [text : String] [chunk : String]) : unit
  (let
    [empty : (text_buf_borrowed.TextBufBorrowed text) (text_buf_borrowed.text-buf-borrowed-empty-like (& text))]
    [rendered : String (text-buf-borrowed-check-render text chunk)]
    [empty? : bool (text_buf_borrowed.text-buf-borrowed-empty? empty)]
    [len : i64 (text_buf_borrowed.text-buf-borrowed-length empty)]
    unit))