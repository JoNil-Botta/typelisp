;; stdlib_text_buf.tl - Integration witness for stdlib/text_buf.tl.
(import stdlib.text_buf)
(import stdlib.text_buf_borrowed)
(import stdlib.string)

(define (text-buf-integration-ok?) : bool
  (let
    [left : text_buf.TextBuf
      (text_buf.append-char (text_buf.append (text_buf.empty) "left") '-')]
    [right : text_buf.TextBuf
      (text_buf.append-int (text_buf.append (text_buf.empty) "right") 7)]
    (string.eq
      (text_buf.render (text_buf.append-buffer left right))
      "left-right7")))

(define (text-buf-borrowed-integration-render [seed : String] [tail : String]) : String
  (let
    [borrowed : (text_buf_borrowed.TextBufBorrowed seed)
      (text_buf_borrowed.append-owned
        (text_buf_borrowed.append (text_buf_borrowed.single (& seed)) (& seed))
        "-")]
    [copied : (text_buf_borrowed.TextBufBorrowed seed)
      (text_buf_borrowed.append-copy borrowed (& tail))]
    (text_buf_borrowed.render copied)))

(define (text-buf-borrowed-integration-ok?) : bool
  (let
    [seed : String "xy"]
    [tail : String "z"]
    (string.eq (text-buf-borrowed-integration-render seed tail) "xyxy-z")))

(define (main) : i64
  (if (text-buf-integration-ok?)
    (if (text-buf-borrowed-integration-ok?)
      42
      3)
    2))