;: SPEC byte view contract: mutable byte views are exclusive.
(import stdlib.byte_buf)

(define (main) : i64
  (let
    [buf : byte_buf.ByteBuf (byte_buf.from-string "abc")]
    [first : (&mut buf bytes) (byte_buf.as-mut-bytes (&mut buf))]
    [second : (&mut buf bytes) (byte_buf.as-mut-bytes (&mut buf))]
    (+ (byte_buf.bytes-mut-length first) (byte_buf.bytes-mut-length second))))