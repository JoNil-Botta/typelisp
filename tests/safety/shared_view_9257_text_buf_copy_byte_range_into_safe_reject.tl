;; #9257: `text_buf_borrowed.copy-byte-range-into` requires `unsafe` because it
;; reads and writes through raw byte pointers.
(import stdlib.text_buf_borrowed)

(define (main) : i64
  (let
    [src : (Ptr u8) (ptr-null : (Ptr u8))]
    [dst : (MutPtr u8) (ptr-null : (MutPtr u8))]
    (text_buf_borrowed.copy-byte-range-into src 0 0 dst 0)
    0))