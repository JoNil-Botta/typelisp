;; stdlib_text_buf.tl - Integration witness for stdlib/text_buf.tl.
(import "stdlib/text_buf.tl")
(import "stdlib/text_buf_borrowed.tl")
(import "stdlib/string.tl")

(define (text-buf-integration-ok?) : bool
  (let
    [left : TextBuf
      (text-buf-append-char (text-buf-append (text-buf-empty) "left") '-')]
    [right : TextBuf
      (text-buf-append-int (text-buf-append (text-buf-empty) "right") 7)]
    (string-eq
      (text-buf-render (text-buf-append-buffer left right))
      "left-right7")))

(define (text-buf-borrowed-integration-render [seed : String] [tail : String]) : String
  (let
    [borrowed : (TextBufBorrowed seed)
      (text-buf-borrowed-append-owned
        (text-buf-borrowed-append (text-buf-borrowed-single (& seed)) (& seed))
        "-")]
    [copied : (TextBufBorrowed seed)
      (text-buf-borrowed-append-copy borrowed (& tail))]
    (text-buf-borrowed-render copied)))

(define (text-buf-borrowed-integration-ok?) : bool
  (let
    [seed : String "xy"]
    [tail : String "z"]
    (string-eq (text-buf-borrowed-integration-render seed tail) "xyxy-z")))

(define (main) : i64
  (if (text-buf-integration-ok?)
    (if (text-buf-borrowed-integration-ok?)
      42
      3)
    2))
