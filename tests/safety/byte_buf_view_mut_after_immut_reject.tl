;: SPEC byte view contract: immutable byte views block mutable owner borrows.
(import stdlib.byte_buf)

(define (main) : i64
  (let
    [buf : byte_buf.ByteBuf (byte_buf.from-string "abc")]
    [view : (& buf bytes) (byte_buf.as-bytes (& buf))]
    [exclusive : (&mut buf bytes) (byte_buf.as-mut-bytes (&mut buf))]
    (+ (byte_buf.bytes-length view) (byte_buf.bytes-mut-length exclusive))))