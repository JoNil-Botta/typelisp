;; #9257: `text_buf_borrowed.append-slice-chunks` requires `unsafe` because its
;; `start`/`len` slice bounds are unchecked.
(import stdlib.text_buf_borrowed)

(define (main) : i64
  (let
    [s : String "hello"]
    [chunks : (text_buf_borrowed.TextBufBorrowedChunkList s)
      (text_buf_borrowed.text-buf-borrowed-empty-chunks (& s))]
    [_next : (text_buf_borrowed.TextBufBorrowedChunkList s)
      (text_buf_borrowed.append-slice-chunks chunks (& s) 0 5)]
    0))