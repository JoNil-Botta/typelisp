;; stdlib_text_buf.tl - Integration witness for stdlib/text_buf.tl.
(import stdlib.text_buf)
(import stdlib.text_buf_borrowed)
(import stdlib.io)
(import stdlib.string)
(import stdlib.byte_buf)

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

(define (text-buf-write-file-integration-ok?) : bool
  (let
    [path : String "target/stdlib-text-buf-write-file.txt"]
    [buf : text_buf.TextBuf
      (text_buf.append (text_buf.append (text_buf.empty) "file") "-out")]
    [status : i64 (text_buf.write-file path buf)]
    [readback : String (byte_buf.to-string (io.read-file path))]
    (if (= status io.io-status-ok)
      (string.eq readback "file-out")
      false)))

(define (main) : i64
  (begin
    (unless (text-buf-integration-ok?) (return 2))
    (unless (text-buf-borrowed-integration-ok?) (return 3))
    (unless (text-buf-write-file-integration-ok?) (return 4))
    42))