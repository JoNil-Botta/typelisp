;: SPEC byte view contract: mutable byte views are exclusive.
(import "stdlib/byte_buf.tl")

(define (main) : i64
  (let
    [buf : ByteBuf (byte-buf-from-string "abc")]
    [first : (&mut buf bytes) (byte-buf-as-mut-bytes (&mut buf))]
    [second : (&mut buf bytes) (byte-buf-as-mut-bytes (&mut buf))]
    (+ (bytes-mut-length first) (bytes-mut-length second))))