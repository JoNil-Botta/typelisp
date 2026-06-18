;: SPEC byte view contract: immutable byte views block mutable owner borrows.
(import "stdlib/byte_buf.tl")

(define (main) : i64
  (let
    [buf : ByteBuf (byte-buf-from-string "abc")]
    [view : (& buf bytes) (byte-buf-as-bytes (& buf))]
    [exclusive : (&mut buf bytes) (byte-buf-as-mut-bytes (&mut buf))]
    (+ (bytes-length view) (bytes-mut-length exclusive))))