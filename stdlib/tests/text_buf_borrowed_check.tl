(import "stdlib/text_buf.tl")

(define (text-buf-borrowed-check-render [text : String] [chunk : String]) : String
  (let
    [left : (TextBufBorrowed text)
      (text-buf-borrowed-append-owned (text-buf-borrowed-single (& text)) "-")]
    [right : (TextBufBorrowed text)
      (text-buf-borrowed-append
        (text-buf-borrowed-empty-like (& text))
        (& text))]
    [joined : (TextBufBorrowed text)
      (text-buf-borrowed-append-buffer left right)]
    [copied : (TextBufBorrowed text)
      (text-buf-borrowed-append-copy joined (& chunk))]
    (text-buf-borrowed-render copied)))

(define (main [text : String] [chunk : String]) : unit
  (let
    [empty : (TextBufBorrowed text) (text-buf-borrowed-empty-like (& text))]
    [rendered : String (text-buf-borrowed-check-render text chunk)]
    [empty? : bool (text-buf-borrowed-empty? empty)]
    [len : i64 (text-buf-borrowed-length empty)]
    unit))